// The properties worth a test are the ones that fail silently: a refresh token
// that keeps working after it leaked, a role check that is only in the UI, a
// room token that grants publish to somebody who may not talk. None of these
// show up as an error at the time — they show up as somebody on a line they
// should not be on.

import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';
import { seedDemoData, PRODUCTION_ID } from '../src/seed.js';
import { hashPassword, verifyPassword } from '../src/passwords.js';
import { reset as resetRateLimits } from '../src/ratelimit.js';
import { config } from '../src/config.js';
import * as db from '../src/db.js';

seedDemoData();
const server = createApp().listen(0);
const base = `http://127.0.0.1:${server.address().port}`;
test.after(() => server.close());

// Every test signs in, and signing in is rate limited by address and account.
// Without this the suite throttles itself and the failures look like bugs in
// whatever test happened to run eleventh.
test.beforeEach(() => resetRateLimits());

async function call(path, { method = 'GET', token, body } = {}) {
  const response = await fetch(`${base}/${path}`, {
    method,
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let json;
  try { json = JSON.parse(text); } catch { json = undefined; }
  return { status: response.status, json, text };
}

const login = (email, password = 'flyabove') =>
  call('v1/auth/login', { method: 'POST', body: { email, password } });

const OPERATOR = 'operator@flyabove.hu';
const CAMERA = 'kamera@flyabove.hu';
const PROGRAM_CHANNEL = '44444444-4444-4444-8444-444444444444';
const DIRECTOR_CHANNEL = '33333333-3333-4333-8333-333333333333';

test('a jelszó hash sózott és ellenőrizhető', () => {
  const first = hashPassword('titok');
  const second = hashPassword('titok');
  assert.notEqual(first, second, 'két hash ugyanarra a jelszóra nem lehet azonos');
  assert.ok(verifyPassword('titok', first));
  assert.ok(!verifyPassword('titok2', first));
  assert.ok(!first.includes('titok'));
});

test('rossz jelszó és ismeretlen e-mail ugyanazt a választ adja', async () => {
  const wrongPassword = await login(OPERATOR, 'nem-ez');
  const unknownEmail = await login('senki@flyabove.hu');
  assert.equal(wrongPassword.status, 401);
  assert.equal(unknownEmail.status, 401);
  assert.deepEqual(wrongPassword.json, unknownEmail.json);
});

test('a refresh token egyszer használható', async () => {
  const session = (await login(OPERATOR)).json;
  const first = await call('v1/auth/refresh', {
    method: 'POST', body: { refreshToken: session.refreshToken },
  });
  assert.equal(first.status, 200);
  const again = await call('v1/auth/refresh', {
    method: 'POST', body: { refreshToken: session.refreshToken },
  });
  assert.equal(again.status, 401);
});

test('újrafelhasznált refresh token az egész családot visszavonja', async () => {
  const session = (await login(OPERATOR)).json;
  // A legitimate rotation: this token is the live one.
  const rotated = (await call('v1/auth/refresh', {
    method: 'POST', body: { refreshToken: session.refreshToken },
  })).json;

  // The old token turns up again — it leaked, or a client is replaying.
  await call('v1/auth/refresh', { method: 'POST', body: { refreshToken: session.refreshToken } });

  // The live token must now be dead too: we cannot tell which side is genuine.
  const afterReuse = await call('v1/auth/refresh', {
    method: 'POST', body: { refreshToken: rotated.refreshToken },
  });
  assert.equal(afterReuse.status, 401, 'a szivárgás után az élő token is érvénytelen kell legyen');
});

test('a kijelentkezés minden munkamenetet megszüntet', async () => {
  const phone = (await login(OPERATOR)).json;
  const laptop = (await login(OPERATOR)).json;
  assert.equal((await call('v1/auth/logout', { method: 'POST', token: phone.accessToken })).status, 204);

  const revived = await call('v1/auth/refresh', {
    method: 'POST', body: { refreshToken: laptop.refreshToken },
  });
  assert.equal(revived.status, 401, 'egy elveszett telefon miatt minden munkamenet visszavonható');
});

test('nem tag produkció 404, nem 403', async () => {
  const session = (await login(CAMERA)).json;
  // The camera account is only in the first production.
  const other = await call('v1/productions/5a7a2b2f-7b5b-4b2f-8b3f-3b2c4d5e6f70/channels', {
    token: session.accessToken,
  });
  assert.equal(other.status, 404);
  assert.equal(other.json.error.code, 'production_not_found');
});

test('a token nélküli kérés 401', async () => {
  assert.equal((await call('v1/productions')).status, 401);
});

test('csak supervisor vagy admin módosíthat csatornát', async () => {
  const camera = (await login(CAMERA)).json;
  const patched = await call(`v1/productions/${PRODUCTION_ID}/channels/${DIRECTOR_CHANNEL}`, {
    method: 'PATCH', token: camera.accessToken, body: { name: 'Átnevezve' },
  });
  assert.equal(patched.status, 403);
  assert.equal(db.findChannel(DIRECTOR_CHANNEL).name, 'Rendező');
});

test('csak supervisor vagy admin adhat ki meghívót', async () => {
  const camera = (await login(CAMERA)).json;
  const invite = await call(`v1/productions/${PRODUCTION_ID}/invites`, {
    method: 'POST', token: camera.accessToken, body: {},
  });
  assert.equal(invite.status, 403);
});

test('a realtime token pontosan a jogosultságot hordozza', async () => {
  const session = (await login(CAMERA)).json;
  const response = await call(`v1/productions/${PRODUCTION_ID}/rt-tokens`, {
    method: 'POST',
    token: session.accessToken,
    body: { channelIds: [DIRECTOR_CHANNEL, PROGRAM_CHANNEL] },
  });
  assert.equal(response.status, 200);

  for (const grant of response.json.grants) {
    // Camera may listen to both of these and talk on neither.
    assert.equal(grant.canPublish, false, `${grant.channelId} publish jogot kapott`);
    assert.equal(grant.canSubscribe, true);

    const claims = JSON.parse(
      Buffer.from(grant.token.split('.')[1], 'base64url').toString('utf8'),
    );
    // The UI is courtesy; this is the enforcement point.
    assert.equal(claims.video.canPublish, false, 'a LiveKit JWT publish jogot ad');
    assert.equal(claims.video.room, grant.roomName);
  }
});

test('jog nélküli csatornára egyáltalán nincs grant', async () => {
  const camera = (await login(CAMERA)).json;
  const channel = db.createChannel({
    productionId: PRODUCTION_ID, name: 'Titkos', position: 99,
  });
  const response = await call(`v1/productions/${PRODUCTION_ID}/rt-tokens`, {
    method: 'POST', token: camera.accessToken, body: { channelIds: [channel.id] },
  });
  assert.equal(response.status, 200);
  assert.equal(response.json.grants.length, 0);

  // …and it is not even listed.
  const channels = await call(`v1/productions/${PRODUCTION_ID}/channels`, {
    token: camera.accessToken,
  });
  assert.ok(!channels.json.some((c) => c.id === channel.id));
  db.deleteChannel(channel.id);
});

test('a visszavont Talk a csatornalistában is megjelenik', async () => {
  const admin = (await login(OPERATOR)).json;
  const camera = (await login(CAMERA)).json;
  const cameraId = camera.user.id;

  const before = (await call(`v1/productions/${PRODUCTION_ID}/channels`, { token: camera.accessToken })).json;
  assert.equal(before.find((c) => c.id === '22222222-2222-4222-8222-222222222222').canTalk, true);

  const patched = await call(`v1/productions/${PRODUCTION_ID}/channels/22222222-2222-4222-8222-222222222222`, {
    method: 'PATCH',
    token: admin.accessToken,
    body: { permissions: { [cameraId]: { canTalk: false, canListen: true } } },
  });
  assert.equal(patched.status, 200);
  assert.ok(Number.isFinite(patched.json.version), 'a válasznak verziót kell hoznia');

  const after = (await call(`v1/productions/${PRODUCTION_ID}/channels`, { token: camera.accessToken })).json;
  assert.equal(after.find((c) => c.id === '22222222-2222-4222-8222-222222222222').canTalk, false);

  // Restore, so later tests see the seeded rights.
  await call(`v1/productions/${PRODUCTION_ID}/channels/22222222-2222-4222-8222-222222222222`, {
    method: 'PATCH',
    token: admin.accessToken,
    body: { permissions: { [cameraId]: { canTalk: true, canListen: true } } },
  });
});

test('a konfigurációs verzió minden változásnál nő', async () => {
  const admin = (await login(OPERATOR)).json;
  const first = (await call(`v1/productions/${PRODUCTION_ID}/channels/${PROGRAM_CHANNEL}`, {
    method: 'PATCH', token: admin.accessToken, body: { duckDecibels: 14 },
  })).json.version;
  const second = (await call(`v1/productions/${PRODUCTION_ID}/channels/${PROGRAM_CHANNEL}`, {
    method: 'PATCH', token: admin.accessToken, body: { duckDecibels: 15 },
  })).json.version;
  assert.ok(second > first, `${second} nem nagyobb, mint ${first}`);
});

test('egy párnak egy privát vonala van', async () => {
  const admin = (await login(OPERATOR)).json;
  const camera = (await login(CAMERA)).json;

  const first = await call(`v1/productions/${PRODUCTION_ID}/calls`, {
    method: 'POST', token: admin.accessToken, body: { peerId: camera.user.id },
  });
  assert.equal(first.status, 201);

  const second = await call(`v1/productions/${PRODUCTION_ID}/calls`, {
    method: 'POST', token: admin.accessToken, body: { peerId: camera.user.id },
  });
  assert.equal(second.status, 200, 'a második hívás ugyanarra a vonalra lép');
  assert.equal(second.json.id, first.json.id);

  // Each side sees the other's name, not a name neither of them chose.
  const cameraView = (await call(`v1/productions/${PRODUCTION_ID}/channels`, {
    token: camera.accessToken,
  })).json.find((c) => c.id === first.json.id);
  assert.equal(first.json.name, 'Teszt Kamera');
  assert.equal(cameraView.name, 'Teszt Operátor');

  await call(`v1/productions/${PRODUCTION_ID}/calls/${first.json.id}`, {
    method: 'DELETE', token: admin.accessToken,
  });
});

test('privát hívást csak a két fél zárhat le', async () => {
  const admin = (await login(OPERATOR)).json;
  const camera = (await login(CAMERA)).json;

  const created = (await call(`v1/productions/${PRODUCTION_ID}/calls`, {
    method: 'POST', token: admin.accessToken, body: { peerId: camera.user.id },
  })).json;

  const outsider = db.createUser({
    email: `kivul-${Date.now()}@flyabove.hu`,
    displayName: 'Kívülálló',
    passwordHash: hashPassword('flyabove'),
  });
  db.addMember({ productionId: PRODUCTION_ID, userId: outsider.id, role: 'admin' });
  const outsiderSession = (await login(outsider.email)).json;

  const refused = await call(`v1/productions/${PRODUCTION_ID}/calls/${created.id}`, {
    method: 'DELETE', token: outsiderSession.accessToken,
  });
  // Admin rights over a production are not rights to be on a private line.
  assert.equal(refused.status, 403);
  assert.ok(db.findChannel(created.id), 'a vonal nem tűnhet el');

  const closed = await call(`v1/productions/${PRODUCTION_ID}/calls/${created.id}`, {
    method: 'DELETE', token: camera.accessToken,
  });
  assert.equal(closed.status, 204);
  assert.equal(db.findChannel(created.id), undefined);
});

test('magaddal nem hívható privát vonal', async () => {
  const admin = (await login(OPERATOR)).json;
  const response = await call(`v1/productions/${PRODUCTION_ID}/calls`, {
    method: 'POST', token: admin.accessToken, body: { peerId: admin.user.id },
  });
  assert.equal(response.status, 400);
  assert.equal(response.json.error.code, 'invalid_peer');
});

test('a meghívó egyszer használható és lejár', async () => {
  const admin = (await login(OPERATOR)).json;
  const invite = (await call(`v1/productions/${PRODUCTION_ID}/invites`, {
    method: 'POST', token: admin.accessToken, body: {},
  })).json;
  assert.match(invite.code, /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$/);

  const newcomer = db.createUser({
    email: `uj-${Date.now()}@flyabove.hu`,
    displayName: 'Új Kolléga',
    passwordHash: hashPassword('flyabove'),
  });
  const session = (await login(newcomer.email)).json;

  assert.equal((await call('v1/productions', { token: session.accessToken })).json.length, 0);

  const redeemed = await call(`v1/invites/${invite.code.toLowerCase()}/redeem`, {
    method: 'POST', token: session.accessToken,
  });
  assert.equal(redeemed.status, 200);
  assert.equal(redeemed.json.production.id, PRODUCTION_ID);

  const again = await call(`v1/invites/${invite.code}/redeem`, {
    method: 'POST', token: session.accessToken,
  });
  assert.equal(again.status, 404);
  assert.equal(again.json.error.code, 'invite_used');

  // An expired invite is refused even though it was never spent.
  const expired = (await call(`v1/productions/${PRODUCTION_ID}/invites`, {
    method: 'POST', token: admin.accessToken, body: { expiresInMinutes: -1 },
  })).json;
  const stale = await call(`v1/invites/${expired.code}`, { token: session.accessToken });
  assert.equal(stale.json.error.code, 'invite_expired');
});

test('a beváltás nem ad hozzáférést privát vonalakhoz', async () => {
  const admin = (await login(OPERATOR)).json;
  const camera = (await login(CAMERA)).json;
  const privateLine = (await call(`v1/productions/${PRODUCTION_ID}/calls`, {
    method: 'POST', token: admin.accessToken, body: { peerId: camera.user.id },
  })).json;

  const invite = (await call(`v1/productions/${PRODUCTION_ID}/invites`, {
    method: 'POST', token: admin.accessToken, body: {},
  })).json;
  const newcomer = db.createUser({
    email: `keso-${Date.now()}@flyabove.hu`,
    displayName: 'Késői Érkező',
    passwordHash: hashPassword('flyabove'),
  });
  const session = (await login(newcomer.email)).json;
  await call(`v1/invites/${invite.code}/redeem`, { method: 'POST', token: session.accessToken });

  const channels = (await call(`v1/productions/${PRODUCTION_ID}/channels`, {
    token: session.accessToken,
  })).json;
  assert.ok(!channels.some((c) => c.id === privateLine.id),
    'egy meghívó nem nyithat rá két ember privát beszélgetésére');

  await call(`v1/productions/${PRODUCTION_ID}/calls/${privateLine.id}`, {
    method: 'DELETE', token: admin.accessToken,
  });
});

test('a rossz jelszavas próbálkozás korlátozott', async () => {
  resetRateLimits();
  const limit = config.loginAttemptsPerWindow;
  let last;
  for (let attempt = 0; attempt <= limit; attempt += 1) {
    last = await login(OPERATOR, 'nem-ez');
  }
  assert.equal(last.status, 429, `${limit + 1}. rossz jelszó után is átment`);
  // The contract's error shape, so the client has a message to show.
  assert.equal(last.json.error.code, 'rate_limited');
  assert.equal(typeof last.json.error.message, 'string');
  assert.ok(last.json.retryAfter > 0);

  // The account is not locked: the right password still gets in. A limit that
  // locks the account hands an attacker a way to silence an operator.
  const helped = await login(OPERATOR);
  assert.equal(helped.status, 200);
});

test('a sikeres bejelentkezés nem fogyaszt a limitből', async () => {
  resetRateLimits();
  // Twice the failure budget, all correct: a suite — or a busy production —
  // must not throttle itself by signing in.
  for (let attempt = 0; attempt < config.loginAttemptsPerWindow * 2; attempt += 1) {
    const response = await login(CAMERA);
    assert.equal(response.status, 200, `a ${attempt + 1}. sikeres bejelentkezés elakadt`);
  }
});

test('egy elrontott jelszó után a helyes törli az adósságot', async () => {
  resetRateLimits();
  const limit = config.loginAttemptsPerWindow;
  for (let attempt = 0; attempt < limit - 1; attempt += 1) await login(OPERATOR, 'nem-ez');
  assert.equal((await login(OPERATOR)).status, 200);
  // The bucket was cleared, so the budget starts over rather than sitting one
  // typo away from a lockout.
  for (let attempt = 0; attempt < limit - 1; attempt += 1) {
    assert.equal((await login(OPERATOR, 'nem-ez')).status, 401);
  }
  assert.equal((await login(OPERATOR)).status, 200);
});

test('ismeretlen végpont a szerződés hibaformátumát adja', async () => {
  const response = await call('v1/nincs-ilyen');
  assert.equal(response.status, 404);
  assert.equal(response.json.error.code, 'not_found');
});
