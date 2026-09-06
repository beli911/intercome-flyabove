// Development-only implementation of docs/API.md.
//
// It exists so the M1 acceptance test — two phones, two networks, real audio —
// can be run without waiting for the production backend. It keeps everything in
// memory, trusts plain-text passwords and signs with a default secret, so it
// must never be exposed beyond a development machine.

import crypto from 'node:crypto';
import os from 'node:os';
import express from 'express';
import jwt from 'jsonwebtoken';
import { AccessToken, RoomServiceClient } from 'livekit-server-sdk';
import {
  channels,
  configurationVersion,
  findUserByEmail,
  findUserById,
  generateInviteCode,
  invites,
  productions,
  roomName,
  users,
} from './data.js';

const PORT = Number(process.env.PORT ?? 8080);
const JWT_SECRET = process.env.JWT_SECRET ?? 'dev-only-secret';
/// The address handed to clients.
///
/// Detected rather than defaulted to localhost: a phone cannot reach the Mac's
/// loopback, and a hardcoded LAN address goes stale the moment the network
/// changes — which then looks like a broken app rather than a moved machine.
function detectLANAddress() {
  for (const addresses of Object.values(os.networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family === 'IPv4' && !address.internal) return address.address;
    }
  }
  return 'localhost';
}

const LIVEKIT_URL = process.env.LIVEKIT_URL ?? `ws://${detectLANAddress()}:7880`;
const LIVEKIT_API_KEY = process.env.LIVEKIT_API_KEY ?? 'devkey';
// Defaults match `livekit-server --dev`, which prints exactly these.
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET ?? 'secret';

const ACCESS_TOKEN_TTL_SECONDS = 900; // 15 minutes, short enough to exercise refresh
const REFRESH_TOKEN_TTL_SECONDS = 60 * 60 * 24 * 30;
const ROOM_TOKEN_TTL_SECONDS = 60 * 60;

/// Live refresh tokens by id. A refresh token is single-use: presenting one
/// invalidates it and mints a new pair, which is what the client's
/// single-flight refresh is written to survive.
const liveRefreshTokens = new Map();

const roomService = new RoomServiceClient(
  LIVEKIT_URL.replace(/^ws/, 'http'),
  LIVEKIT_API_KEY,
  LIVEKIT_API_SECRET,
);

const app = express();
app.use(express.json());

app.use((req, _res, next) => {
  console.log(`${req.method} ${req.path}`);
  next();
});

// MARK: - Helpers

function fail(res, status, code, message) {
  return res.status(status).json({ error: { code, message } });
}

function issueSession(user) {
  const accessToken = jwt.sign({ sub: user.id, typ: 'access' }, JWT_SECRET, {
    expiresIn: ACCESS_TOKEN_TTL_SECONDS,
  });

  const refreshId = crypto.randomUUID();
  const refreshToken = jwt.sign({ sub: user.id, typ: 'refresh', jti: refreshId }, JWT_SECRET, {
    expiresIn: REFRESH_TOKEN_TTL_SECONDS,
  });
  liveRefreshTokens.set(refreshId, user.id);

  return {
    accessToken,
    refreshToken,
    expiresIn: ACCESS_TOKEN_TTL_SECONDS,
    user: { id: user.id, displayName: user.displayName, email: user.email },
  };
}

/// Express middleware: resolves `req.user` from the bearer token.
function authenticate(req, res, next) {
  const header = req.get('authorization') ?? '';
  const [scheme, token] = header.split(' ');
  if (scheme !== 'Bearer' || !token) {
    return fail(res, 401, 'token_expired', 'Hiányzó hozzáférési token.');
  }

  let payload;
  try {
    payload = jwt.verify(token, JWT_SECRET);
  } catch {
    return fail(res, 401, 'token_expired', 'Lejárt vagy érvénytelen token.');
  }
  if (payload.typ !== 'access') {
    return fail(res, 401, 'token_expired', 'Nem hozzáférési token.');
  }

  const user = findUserById(payload.sub);
  if (!user) {
    return fail(res, 401, 'token_expired', 'A felhasználó már nem létezik.');
  }

  req.user = user;
  return next();
}

/// Swift encodes UUIDs uppercase, the seed data is lowercase.
function normalizeId(value) {
  return String(value ?? '').trim().toLowerCase();
}

function permissionsFor(user, channelId) {
  return user.permissions[normalizeId(channelId)] ?? { canTalk: false, canListen: false };
}

// MARK: - Auth

app.post('/v1/auth/login', (req, res) => {
  const { email, password, deviceName } = req.body ?? {};
  const user = findUserByEmail(email);
  if (!user || user.password !== password) {
    return fail(res, 401, 'invalid_credentials', 'Hibás e-mail vagy jelszó.');
  }
  console.log(`  bejelentkezés: ${user.email} (${deviceName ?? 'ismeretlen eszköz'})`);
  return res.json(issueSession(user));
});

app.post('/v1/auth/refresh', (req, res) => {
  const { refreshToken } = req.body ?? {};
  let payload;
  try {
    payload = jwt.verify(String(refreshToken ?? ''), JWT_SECRET);
  } catch {
    return fail(res, 401, 'token_expired', 'Lejárt vagy érvénytelen refresh token.');
  }
  if (payload.typ !== 'refresh' || !liveRefreshTokens.has(payload.jti)) {
    // Either not a refresh token, or one that was already spent. Both mean the
    // session is over; the client is expected to clear it and ask for a login.
    return fail(res, 401, 'token_expired', 'A refresh token már nem érvényes.');
  }

  liveRefreshTokens.delete(payload.jti);
  const user = findUserById(payload.sub);
  if (!user) {
    return fail(res, 401, 'token_expired', 'A felhasználó már nem létezik.');
  }
  return res.json(issueSession(user));
});

app.post('/v1/auth/logout', authenticate, (req, res) => {
  for (const [id, userId] of liveRefreshTokens) {
    if (userId === req.user.id) liveRefreshTokens.delete(id);
  }
  return res.status(204).end();
});

// MARK: - Productions and channels

app.get('/v1/productions', authenticate, (_req, res) => {
  res.json(productions);
});

app.get('/v1/productions/:productionId/channels', authenticate, (req, res) => {
  const production = productions.find((p) => p.id === normalizeId(req.params.productionId));
  if (!production) {
    return fail(res, 404, 'production_not_found', 'Nincs ilyen produkció.');
  }

  const payload = channels
    .map((channel) => channelDescriptor(channel, req.user))
    // A channel the user may neither hear nor speak on should not be listed.
    .filter((channel) => channel.canTalk || channel.canListen);

  return res.json(payload);
});

app.get('/v1/productions/:productionId/crew', authenticate, (req, res) => {
  const production = productions.find((p) => p.id === normalizeId(req.params.productionId));
  if (!production) {
    return fail(res, 404, 'production_not_found', 'Nincs ilyen produkció.');
  }
  // The roster, not presence: who is actually connected is something only the
  // realtime layer can answer.
  return res.json(users.map((user) => ({
    id: user.id,
    displayName: user.displayName,
    role: user.role ?? 'operator',
  })));
});

function channelDescriptor(channel, user) {
  const { canTalk, canListen } = permissionsFor(user, channel.id);
  return {
    id: channel.id,
    name: channel.name,
    detail: channel.detail,
    colorHex: channel.colorHex,
    canTalk,
    canListen,
    defaultListening: channel.defaultListening && canListen,
    participantCount: 0,
    role: channel.role ?? 'line',
    duckDecibels: channel.duckDecibels ?? 12,
  };
}

// MARK: - Invites
//
// An invite is how a production gets a freelancer onto the line without an
// admin typing their address. It names one production, carries an expiry, and
// is spent once — a code that keeps working after the show is a way in for
// whoever still has the group chat.

const INVITE_TTL_MINUTES = 60 * 12;

app.post('/v1/productions/:productionId/invites', authenticate, (req, res) => {
  const production = productions.find((p) => p.id === normalizeId(req.params.productionId));
  if (!production) {
    return fail(res, 404, 'production_not_found', 'Nincs ilyen produkció.');
  }
  // Only a supervisor or admin hands out access.
  if (!['supervisor', 'admin'].includes(production.role)) {
    return fail(res, 403, 'forbidden', 'Meghívót csak supervisor vagy admin adhat ki.');
  }

  const minutes = Number(req.body?.expiresInMinutes ?? INVITE_TTL_MINUTES);
  const code = generateInviteCode();
  const expiresAt = new Date(Date.now() + minutes * 60 * 1000);
  invites.set(code, {
    code,
    productionId: production.id,
    expiresAt,
    createdBy: req.user.id,
    redeemedBy: null,
  });

  console.log(`  meghívó kiadva: ${code} → ${production.name}`);
  return res.status(201).json({
    code,
    url: `flyabove-intercom://invite/${code}`,
    productionId: production.id,
    productionName: production.name,
    expiresAt: expiresAt.toISOString(),
  });
});

function inviteOrFailure(rawCode) {
  const code = String(rawCode ?? '').trim().toUpperCase();
  const invite = invites.get(code);
  if (!invite) return { error: ['invite_not_found', 'Nincs ilyen meghívókód.'] };
  if (invite.expiresAt.getTime() <= Date.now()) {
    return { error: ['invite_expired', 'A meghívó lejárt.'] };
  }
  if (invite.redeemedBy) {
    return { error: ['invite_used', 'Ezt a meghívót már felhasználták.'] };
  }
  return { invite };
}

app.get('/v1/invites/:code', authenticate, (req, res) => {
  const { invite, error } = inviteOrFailure(req.params.code);
  if (error) return fail(res, 404, error[0], error[1]);
  const production = productions.find((p) => p.id === invite.productionId);
  return res.json({
    code: invite.code,
    productionId: invite.productionId,
    productionName: production?.name ?? '—',
    expiresAt: invite.expiresAt.toISOString(),
  });
});

app.post('/v1/invites/:code/redeem', authenticate, (req, res) => {
  const { invite, error } = inviteOrFailure(req.params.code);
  if (error) return fail(res, 404, error[0], error[1]);

  const production = productions.find((p) => p.id === invite.productionId);
  if (!production) {
    return fail(res, 404, 'production_not_found', 'A meghívóhoz tartozó produkció eltűnt.');
  }

  invite.redeemedBy = req.user.id;
  // Development shortcut: the seed users already have channel permissions, so
  // redeeming only has to report which production was joined.
  console.log(`  meghívó beváltva: ${invite.code} ← ${req.user.email}`);
  return res.json({ production });
});

// MARK: - Admin configuration

app.patch('/v1/productions/:productionId/channels/:channelId', authenticate, async (req, res) => {
  const productionId = normalizeId(req.params.productionId);
  const production = productions.find((p) => p.id === productionId);
  if (!production) {
    return fail(res, 404, 'production_not_found', 'Nincs ilyen produkció.');
  }
  if (!['supervisor', 'admin'].includes(production.role)) {
    return fail(res, 403, 'forbidden', 'Csatornát csak supervisor vagy admin módosíthat.');
  }

  const channelId = normalizeId(req.params.channelId);
  const channel = channels.find((c) => c.id === channelId);
  if (!channel) return fail(res, 404, 'not_found', 'Nincs ilyen csatorna.');

  if (typeof req.body?.name === 'string') channel.name = req.body.name;
  if (typeof req.body?.detail === 'string') channel.detail = req.body.detail;
  if (typeof req.body?.colorHex === 'string') channel.colorHex = req.body.colorHex;
  if (['line', 'program', 'priority'].includes(req.body?.role)) channel.role = req.body.role;
  if (Number.isFinite(req.body?.duckDecibels)) channel.duckDecibels = req.body.duckDecibels;

  // Permission changes are the reason this push exists: a revoked Talk has to
  // reach a phone that is holding the button down.
  if (req.body?.permissions && typeof req.body.permissions === 'object') {
    for (const [userId, rights] of Object.entries(req.body.permissions)) {
      const user = findUserById(normalizeId(userId));
      if (!user) continue;
      user.permissions[channelId] = {
        canTalk: Boolean(rights?.canTalk),
        canListen: Boolean(rights?.canListen),
      };
    }
  }

  configurationVersion.value += 1;
  await broadcastConfigurationChange(productionId);

  return res.json({ ...channelDescriptor(channel, req.user), version: configurationVersion.value });
});

/// Tells every joined client that the configuration it holds is stale.
///
/// The payload deliberately carries only a version, not the configuration
/// itself: the REST endpoint stays the single source of truth, and a client
/// that missed a message still converges on the next one.
async function broadcastConfigurationChange(productionId) {
  const payload = new TextEncoder().encode(JSON.stringify({
    type: 'configuration',
    version: configurationVersion.value,
    productionId,
  }));

  await Promise.all(channels.map(async (channel) => {
    try {
      await roomService.sendData(roomName(productionId, channel.id), payload, 0);
    } catch {
      // A room nobody has joined needs no notification.
    }
  }));
}

// MARK: - Realtime

app.post('/v1/productions/:productionId/rt-tokens', authenticate, async (req, res) => {
  const productionId = normalizeId(req.params.productionId);
  const production = productions.find((p) => p.id === productionId);
  if (!production) {
    return fail(res, 404, 'production_not_found', 'Nincs ilyen produkció.');
  }

  const requested = Array.isArray(req.body?.channelIds) ? req.body.channelIds.map(normalizeId) : [];
  const known = new Set(channels.map((channel) => channel.id));
  const unknown = requested.filter((id) => !known.has(id));
  if (unknown.length > 0) {
    return fail(res, 404, 'not_found', 'Ismeretlen csatorna a kérésben.');
  }

  const grants = [];
  for (const channelId of requested) {
    const { canTalk, canListen } = permissionsFor(req.user, channelId);
    // No grant at all for a channel the user has no business in: the
    // enforcement point is the token, not the client.
    if (!canTalk && !canListen) continue;

    const room = roomName(productionId, channelId);
    const token = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
      identity: req.user.id,
      name: req.user.displayName,
      ttl: ROOM_TOKEN_TTL_SECONDS,
    });
    token.addGrant({
      roomJoin: true,
      room,
      canPublish: canTalk,
      canSubscribe: canListen,
      canPublishData: false,
    });

    grants.push({
      channelId,
      roomName: room,
      token: await token.toJwt(),
      expiresAt: new Date(Date.now() + ROOM_TOKEN_TTL_SECONDS * 1000).toISOString(),
      canPublish: canTalk,
      canSubscribe: canListen,
    });
  }

  return res.json({ url: LIVEKIT_URL, grants });
});

// MARK: - Debug
//
// Only the room's real participant list can prove that a join/leave/rejoin
// churn left no orphan connection behind: an orphan room is invisible to the
// client that lost track of it. Development server, so this needs no auth
// beyond the caller already having a session.

app.get('/v1/debug/rooms/:roomName/participants', authenticate, async (req, res) => {
  try {
    const participants = await roomService.listParticipants(req.params.roomName);
    return res.json({
      participants: participants.map((p) => ({ identity: p.identity, state: p.state })),
    });
  } catch (error) {
    // A room nobody has joined yet simply does not exist.
    return res.json({ participants: [] });
  }
});

/// Evicts a participant, so a test can produce the one thing it cannot fake:
/// a room the client did not choose to leave.
app.post('/v1/debug/rooms/:roomName/participants/:identity/remove', authenticate, async (req, res) => {
  try {
    await roomService.removeParticipant(req.params.roomName, req.params.identity);
    return res.status(204).end();
  } catch (error) {
    return fail(res, 404, 'not_found', String(error?.message ?? error));
  }
});

// MARK: - Fallbacks

app.use((_req, res) => fail(res, 404, 'not_found', 'Ismeretlen végpont.'));

app.use((error, _req, res, _next) => {
  console.error(error);
  fail(res, 500, 'internal_error', 'Szerverhiba.');
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`FlyAbove intercom dev API: http://0.0.0.0:${PORT}`);
  console.log(`LiveKit: ${LIVEKIT_URL}`);
  console.log('Fejlesztői szerver — éles környezetben nem használható.');
});
