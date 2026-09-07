import express from 'express';
import { config } from './config.js';
import { log } from './log.js';
import * as db from './db.js';
import { burnPasswordWork, verifyPassword } from './passwords.js';
import { issueAccessToken, issueRefreshToken, rotateRefreshToken, verifyAccessToken } from './tokens.js';
import { consume, forget, limiter } from './ratelimit.js';
import { generateInviteCode } from './invites.js';
import {
  broadcastConfiguration, evictParticipant, issueRoomToken, listParticipants,
  removeParticipant, roomName, updateParticipantPermission,
} from './livekit.js';

const INVITE_TTL_MINUTES = 60 * 12;
/// More lines than any production has, and few enough that one request cannot
/// cost the server a megabyte of signed tokens.
const MAX_CHANNELS_PER_REQUEST = 64;
/// A minute to a week. An invite is a temporary way in; one that lasts a month
/// is a permanent way in for whoever still has the group chat.
const MIN_INVITE_MINUTES = 1;
const MAX_INVITE_MINUTES = 60 * 24 * 7;
const ADMIN_ROLES = new Set(['supervisor', 'admin']);

/// Swift encodes UUIDs uppercase; the database stores them lowercase.
const normalizeId = (value) => String(value ?? '').trim().toLowerCase();

function fail(res, status, code, message) {
  return res.status(status).json({ error: { code, message } });
}

export function createApp() {
  const app = express();
  if (config.trustProxy) app.set('trust proxy', 1);
  app.disable('x-powered-by');

  app.use((_req, res, next) => {
    // Narrow on purpose. There is no browser client, so CORS stays absent and
    // a same-origin policy has nothing to relax.
    res.set('X-Content-Type-Options', 'nosniff');
    res.set('X-Frame-Options', 'DENY');
    res.set('Referrer-Policy', 'no-referrer');
    res.set('Cache-Control', 'no-store');
    // HSTS is the TLS proxy's job, but stating it here means it holds even if a
    // deployment forgets to configure the proxy.
    if (config.isProduction) {
      res.set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
    }
    return next();
  });

  app.use(express.json({ limit: '64kb' }));

  // A malformed body is the caller's mistake, not a server fault: answering
  // 500 tells them to retry, and they will.
  app.use((error, _req, res, next) => {
    if (error instanceof SyntaxError && 'body' in error) {
      return fail(res, 400, 'invalid_request', 'A kérés törzse nem érvényes JSON.');
    }
    if (error?.type === 'entity.too.large') {
      return fail(res, 413, 'invalid_request', 'A kérés törzse túl nagy.');
    }
    return next(error);
  });

  // MARK: - Middleware

  function authenticate(req, res, next) {
    const [scheme, token] = (req.get('authorization') ?? '').split(' ');
    if (scheme !== 'Bearer' || !token) {
      return fail(res, 401, 'token_expired', 'Hiányzó hozzáférési token.');
    }
    const payload = verifyAccessToken(token);
    if (!payload) return fail(res, 401, 'token_expired', 'Lejárt vagy érvénytelen token.');

    const user = db.findUserById(payload.sub);
    if (!user) return fail(res, 401, 'token_expired', 'A felhasználó már nem létezik.');

    // A signed token is otherwise valid until it expires, so logging out of a
    // lost phone would leave REST access open for the rest of the token's life.
    if (payload.sv !== user.session_version) {
      return fail(res, 401, 'token_expired', 'A munkamenet megszűnt.');
    }

    req.user = user;
    return next();
  }

  /// Resolves `req.production` and the caller's role in it.
  ///
  /// A production the caller is not a member of answers 404, not 403: a
  /// membership check that leaks which production ids exist is a directory.
  function withProduction(req, res, next) {
    const productionId = normalizeId(req.params.productionId);
    const member = db.membership(productionId, req.user.id);
    if (!member) return fail(res, 404, 'production_not_found', 'Nincs ilyen produkció.');
    req.production = { id: productionId, role: member.role };
    return next();
  }

  function requireAdminRole(req, res, next) {
    if (!ADMIN_ROLES.has(req.production.role)) {
      return fail(res, 403, 'forbidden', 'Ehhez supervisor vagy admin szerep kell.');
    }
    return next();
  }

  // MARK: - Health

  app.get('/health', (_req, res) => res.json({ status: 'ok' }));

  // MARK: - Auth

  // A coarse ceiling on the endpoint itself, so it cannot be flooded regardless
  // of whether the attempts succeed.
  const loginFloodLimiter = limiter({ name: 'login-flood', limit: 120, windowSeconds: 300 });

  app.post('/v1/auth/login', loginFloodLimiter, async (req, res) => {
    const { email, password, deviceName } = req.body ?? {};
    // Per address and per account: limiting only by address lets one attacker
    // lock every user out, limiting only by account lets a botnet spread out.
    const attemptKey = `login:${req.ip}|${String(email ?? '').toLowerCase()}`;
    const limit = config.loginAttemptsPerWindow;

    const user = db.findUserByEmail(email);
    // The same answer whether the address is unknown or the password is wrong,
    // and the same amount of work: an unknown address that returns sixty times
    // faster tells the caller which addresses have accounts, however identical
    // the response body is.
    const correct = user
      ? await verifyPassword(String(password ?? ''), user.password_hash)
      : await burnPasswordWork(password);

    if (!correct) {
      const spent = consume({ key: attemptKey, limit, windowSeconds: config.loginWindowSeconds });
      if (!spent.allowed) {
        res.set('Retry-After', String(spent.retryAfter));
        return res.status(429).json({
          error: {
            code: 'rate_limited',
            message: `Túl sok sikertelen próbálkozás. Várj ${spent.retryAfter} másodpercet.`,
          },
          retryAfter: spent.retryAfter,
        });
      }
      return fail(res, 401, 'invalid_credentials', 'Hibás e-mail vagy jelszó.');
    }

    // The password is checked before the limit is enforced, on purpose: a limit
    // that blocks the right password is an account lockout, and an attacker who
    // can lock out a director mid-broadcast has done real damage without ever
    // guessing anything. Guessing is still bounded — by the flood limiter above
    // and by scrypt, which costs about a tenth of a second per attempt.
    // A fumbled password followed by the right one leaves no debt behind.
    forget(attemptKey);

    const access = issueAccessToken(user);
    const refresh = issueRefreshToken({ userId: user.id, deviceName });
    log.info('bejelentkezés', { userId: user.id, deviceName: deviceName ?? null });
    return res.json({
      accessToken: access.token,
      refreshToken: refresh.token,
      expiresIn: access.expiresIn,
      user: { id: user.id, displayName: user.display_name, email: user.email },
    });
  });

  app.post('/v1/auth/refresh', limiter({
    name: 'refresh', limit: 60, windowSeconds: 300,
  }), (req, res) => {
    const result = rotateRefreshToken({
      token: String(req.body?.refreshToken ?? ''),
      deviceName: req.body?.deviceName,
    });
    if (result.failure) {
      if (result.failure === 'reused') {
        log.warn('refresh token újrafelhasználás — család visszavonva');
      }
      return fail(res, 401, 'token_expired', 'A refresh token már nem érvényes.');
    }
    return res.json({
      accessToken: result.access.token,
      refreshToken: result.refresh.token,
      expiresIn: result.access.expiresIn,
      user: {
        id: result.user.id,
        displayName: result.user.display_name,
        email: result.user.email,
      },
    });
  });

  app.post('/v1/auth/logout', authenticate, (req, res) => {
    db.endAllSessions(req.user.id);
    log.info('kijelentkezés, minden munkamenet megszüntetve', { userId: req.user.id });
    return res.status(204).end();
  });

  // MARK: - Productions, channels, crew

  app.get('/v1/productions', authenticate, (req, res) => {
    res.json(db.productionsForUser(req.user.id));
  });

  /// A private line is named after the other person, so both ends see who they
  /// are talking to rather than a name neither of them chose.
  function channelDescriptor(channel, user) {
    const { canTalk, canListen } = db.permissionFor(channel.id, user.id);
    let name = channel.name;
    if (channel.is_private) {
      const otherId = db.privateCallMembers(channel.id).find((id) => id !== user.id);
      name = db.findUserById(otherId)?.display_name ?? 'Privát hívás';
    }
    return {
      id: channel.id,
      name,
      detail: channel.detail,
      colorHex: channel.color_hex,
      canTalk,
      canListen,
      defaultListening: Boolean(channel.default_listening) && canListen,
      participantCount: 0,
      role: channel.role,
      duckDecibels: channel.duck_decibels,
      isPrivate: Boolean(channel.is_private),
    };
  }

  app.get('/v1/productions/:productionId/channels', authenticate, withProduction, (req, res) => {
    const payload = db.channelsForProduction(req.production.id)
      .map((channel) => channelDescriptor(channel, req.user))
      // A channel the user may neither hear nor speak on should not be listed.
      .filter((channel) => channel.canTalk || channel.canListen);
    return res.json(payload);
  });

  app.get('/v1/productions/:productionId/crew', authenticate, withProduction, (req, res) => {
    // The roster, not presence: who is actually connected is something only the
    // realtime layer can answer.
    return res.json(db.crewForProduction(req.production.id));
  });

  // MARK: - Invites

  app.post('/v1/productions/:productionId/invites',
    authenticate, withProduction, requireAdminRole, (req, res) => {
      const requestedMinutes = req.body?.expiresInMinutes;
      let minutes = INVITE_TTL_MINUTES;
      if (requestedMinutes !== undefined) {
        minutes = Number(requestedMinutes);
        if (!Number.isFinite(minutes) || !Number.isInteger(minutes)
          || minutes < MIN_INVITE_MINUTES || minutes > MAX_INVITE_MINUTES) {
          return fail(res, 400, 'invalid_request',
            `Az expiresInMinutes egész szám legyen ${MIN_INVITE_MINUTES} és ${MAX_INVITE_MINUTES} között.`);
        }
      }
      const code = generateInviteCode();
      const expiresAt = new Date(Date.now() + minutes * 60 * 1000);
      const role = ADMIN_ROLES.has(req.body?.role) || req.body?.role === 'operator'
        ? req.body.role : 'operator';

      db.createInvite({
        code, productionId: req.production.id, createdBy: req.user.id, role, expiresAt,
      });
      const production = db.productionsForUser(req.user.id)
        .find((p) => p.id === req.production.id);

      log.info('meghívó kiadva', { productionId: req.production.id, role });
      return res.status(201).json({
        code,
        url: `flyabove-intercom://invite/${code}`,
        productionId: req.production.id,
        productionName: production?.name ?? '—',
        expiresAt: expiresAt.toISOString(),
      });
    });

  function inviteOrFailure(rawCode) {
    const invite = db.findInvite(rawCode);
    if (!invite) return { error: ['invite_not_found', 'Nincs ilyen meghívókód.'] };
    if (new Date(invite.expires_at).getTime() <= Date.now()) {
      return { error: ['invite_expired', 'A meghívó lejárt.'] };
    }
    if (invite.redeemed_by) return { error: ['invite_used', 'Ezt a meghívót már felhasználták.'] };
    return { invite };
  }

  // Rate limited even though it only reads: without it, this endpoint is an
  // oracle for guessing codes.
  const inviteLimiter = limiter({ name: 'invite', limit: 30, windowSeconds: 300 });

  app.get('/v1/invites/:code', authenticate, inviteLimiter, (req, res) => {
    const { invite, error } = inviteOrFailure(req.params.code);
    if (error) return fail(res, 404, error[0], error[1]);
    const production = db.db.prepare('SELECT name FROM productions WHERE id = ?')
      .get(invite.production_id);
    return res.json({
      code: invite.code,
      productionId: invite.production_id,
      productionName: production?.name ?? '—',
      expiresAt: new Date(invite.expires_at).toISOString(),
    });
  });

  app.post('/v1/invites/:code/redeem', authenticate, inviteLimiter, (req, res) => {
    const { invite, error } = inviteOrFailure(req.params.code);
    if (error) return fail(res, 404, error[0], error[1]);

    db.addMember({
      productionId: invite.production_id, userId: req.user.id, role: invite.role,
    });
    // Redeeming grants the production's non-private channels at the invite's
    // role. Anything finer is the admin's call afterwards.
    for (const channel of db.channelsForProduction(invite.production_id)) {
      if (channel.is_private) continue;
      db.setPermission({
        channelId: channel.id,
        userId: req.user.id,
        canTalk: true,
        canListen: true,
      });
    }
    db.redeemInvite(invite.code, req.user.id);

    const production = db.productionsForUser(req.user.id)
      .find((p) => p.id === invite.production_id);
    log.info('meghívó beváltva', { productionId: invite.production_id, userId: req.user.id });
    return res.json({ production });
  });

  // MARK: - Private calls

  /// Reduces a participant's rights inside the live room, and removes them if
  /// that cannot be confirmed.
  ///
  /// Fail-closed on purpose: the alternative to an eviction we are unsure about
  /// is somebody talking on a line they were just removed from. The client
  /// treats an eviction as a reconnect, and reconnecting mints a token with the
  /// new rights.
  async function enforceInRoom({ productionId, channelId, userId, canTalk, canListen }) {
    const result = await updateParticipantPermission({
      productionId, channelId, identity: userId, canPublish: canTalk, canSubscribe: canListen,
    });
    if (result.applied) return { userId, enforced: true };

    // Nobody in the room means nothing to silence.
    if (result.absent) return { userId, enforced: true };

    const evicted = await evictParticipant({ productionId, channelId, identity: userId });
    log.warn('jogosultság szobán belüli érvényesítése nem sikerült', {
      productionId, channelId, userId, evicted, message: result.message,
    });
    return { userId, enforced: evicted };
  }

  async function pushConfiguration(productionId) {
    const version = db.bumpConfigurationVersion();
    const channelIds = db.channelsForProduction(productionId).map((c) => c.id);
    await broadcastConfiguration({ productionId, channelIds, version });
    return version;
  }

  app.post('/v1/productions/:productionId/calls',
    authenticate, withProduction, async (req, res) => {
      const peerId = normalizeId(req.body?.peerId);
      if (peerId === req.user.id) {
        return fail(res, 400, 'invalid_peer', 'Magaddal nem lehet privát hívást indítani.');
      }
      const peer = db.findUserById(peerId);
      // Peer must be in the production, or a private call is a way to reach
      // somebody who never joined it.
      if (!peer || !db.membership(req.production.id, peerId)) {
        return fail(res, 404, 'not_found', 'Nincs ilyen felhasználó a produkcióban.');
      }

      const members = [req.user.id, peer.id];
      // One line per pair: calling somebody you are already on a private line
      // with should join that line, not open a second one.
      const existing = db.findPrivateChannelBetween(req.production.id, members);
      if (existing) return res.status(200).json(channelDescriptor(existing, req.user));

      const channel = db.createChannel({
        productionId: req.production.id,
        name: 'Privát hívás',
        detail: 'Privát vonal',
        colorHex: 'B36BFF',
        role: 'line',
        duckDecibels: 12,
        defaultListening: true,
        isPrivate: true,
        position: 1000,
      });
      for (const id of members) {
        db.addPrivateCallMember(channel.id, id);
        db.setPermission({ channelId: channel.id, userId: id, canTalk: true, canListen: true });
      }

      await pushConfiguration(req.production.id);
      log.info('privát hívás nyitva', { productionId: req.production.id, channelId: channel.id });
      return res.status(201).json(channelDescriptor(channel, req.user));
    });

  app.delete('/v1/productions/:productionId/calls/:channelId',
    authenticate, withProduction, async (req, res) => {
      const channelId = normalizeId(req.params.channelId);
      const channel = db.findChannel(channelId);
      if (!channel || !channel.is_private || channel.production_id !== req.production.id) {
        return fail(res, 404, 'not_found', 'Nincs ilyen privát hívás.');
      }
      // Only the two people on the line may end it.
      if (!db.privateCallMembers(channelId).includes(req.user.id)) {
        return fail(res, 403, 'forbidden', 'Nem vagy résztvevője ennek a hívásnak.');
      }

      db.deleteChannel(channelId);
      await pushConfiguration(req.production.id);
      return res.status(204).end();
    });

  // MARK: - Admin configuration

  app.patch('/v1/productions/:productionId/channels/:channelId',
    authenticate, withProduction, requireAdminRole, async (req, res) => {
      const channelId = normalizeId(req.params.channelId);
      const channel = db.findChannel(channelId);
      if (!channel || channel.production_id !== req.production.id) {
        return fail(res, 404, 'not_found', 'Nincs ilyen csatorna.');
      }

      const fields = {};
      if (typeof req.body?.name === 'string') fields.name = req.body.name;
      if (typeof req.body?.detail === 'string') fields.detail = req.body.detail;
      if (typeof req.body?.colorHex === 'string') fields.colorHex = req.body.colorHex;
      if (['line', 'program', 'priority'].includes(req.body?.role)) fields.role = req.body.role;
      if (Number.isFinite(req.body?.duckDecibels)) fields.duckDecibels = req.body.duckDecibels;
      db.updateChannel(channelId, fields);

      // Permission changes are the reason this push exists: a revoked Talk has
      // to reach a phone that is holding the button down.
      const enforcement = [];
      if (req.body?.permissions && typeof req.body.permissions === 'object') {
        for (const [rawUserId, rights] of Object.entries(req.body.permissions)) {
          const userId = normalizeId(rawUserId);
          if (!db.membership(req.production.id, userId)) continue;
          const canTalk = Boolean(rights?.canTalk);
          const canListen = Boolean(rights?.canListen);
          const before = db.permissionFor(channelId, userId);
          db.setPermission({ channelId, userId, canTalk, canListen });

          // Only a reduction has to be enforced inside the room. Granting a
          // right needs no intervention: the client asks for a new token.
          if ((before.canTalk && !canTalk) || (before.canListen && !canListen)) {
            enforcement.push(enforceInRoom({
              productionId: req.production.id, channelId, userId, canTalk, canListen,
            }));
          }
        }
      }

      const applied = await Promise.all(enforcement);
      const version = await pushConfiguration(req.production.id);

      // The response says what was actually enforced. A `PATCH` that returns
      // 200 while somebody is still publishing is the kind of answer that gets
      // trusted for the rest of a broadcast.
      const unenforced = applied.filter((result) => !result.enforced);
      return res.json({
        ...channelDescriptor(db.findChannel(channelId), req.user),
        version,
        ...(unenforced.length > 0
          ? { unenforced: unenforced.map((result) => result.userId) }
          : {}),
      });
    });

  // MARK: - Realtime

  app.post('/v1/productions/:productionId/rt-tokens',
    authenticate, withProduction, async (req, res) => {
      if (!Array.isArray(req.body?.channelIds)) {
        return fail(res, 400, 'invalid_request', 'A channelIds tömb kötelező.');
      }
      // Deduplicated and capped. Without this, a thousand repeats of one legal
      // channel id produced a thousand tokens in a 692 KB response — an
      // authenticated request that costs the server far more than the caller.
      const requested = [...new Set(req.body.channelIds.map(normalizeId))];
      if (requested.length > MAX_CHANNELS_PER_REQUEST) {
        return fail(res, 400, 'invalid_request',
          `Egyszerre legfeljebb ${MAX_CHANNELS_PER_REQUEST} csatornára kérhető token.`);
      }

      const known = new Map(
        db.channelsForProduction(req.production.id).map((c) => [c.id, c]),
      );
      if (requested.some((id) => !known.has(id))) {
        return fail(res, 404, 'not_found', 'Ismeretlen csatorna a kérésben.');
      }

      const grants = [];
      for (const channelId of requested) {
        const { canTalk, canListen } = db.permissionFor(channelId, req.user.id);
        // No grant at all for a channel the user has no business in: the
        // enforcement point is the token, not the client.
        if (!canTalk && !canListen) continue;
        grants.push(await issueRoomToken({
          user: req.user, productionId: req.production.id, channelId, canTalk, canListen,
        }));
      }

      return res.json({ url: config.livekit.url, grants });
    });

  // MARK: - Debug
  //
  // Only the room's real participant list can prove that a join/leave/rejoin
  // churn left no orphan connection behind. Off in production: it names who is
  // in a room, which is not something an operator's token should reveal.

  if (!config.isProduction) {
    app.get('/v1/debug/rooms/:roomName/participants', authenticate, async (req, res) => {
      const participants = await listParticipants(req.params.roomName);
      return res.json({
        participants: participants.map((p) => ({
          identity: p.identity,
          state: p.state,
          // What the server sees them publishing. A client's own opinion of
          // whether it stopped is not evidence that it did.
          trackCount: (p.tracks ?? []).length,
        })),
      });
    });

    app.post('/v1/debug/rooms/:roomName/participants/:identity/remove',
      authenticate, async (req, res) => {
        try {
          await removeParticipant(req.params.roomName, req.params.identity);
          return res.status(204).end();
        } catch (error) {
          return fail(res, 404, 'not_found', String(error?.message ?? error));
        }
      });
  }

  // MARK: - Fallbacks

  app.use((_req, res) => fail(res, 404, 'not_found', 'Ismeretlen végpont.'));

  app.use((error, _req, res, _next) => {
    log.error('kezeletlen hiba', { message: String(error?.message ?? error) });
    // The message never carries the exception text: a stack trace in a client
    // response is a map of the server.
    fail(res, 500, 'internal_error', 'Szerverhiba.');
  });

  return app;
}

export { roomName };
