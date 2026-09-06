#!/usr/bin/env node
//
// Measures a server against docs/API.md.
//
// Written for the moment a real backend appears: instead of finding out where
// it differs one crash at a time on a phone, this says so in one run. It is
// read-mostly — the only writes are an invite and a private call, both of which
// it cleans up.
//
// Usage:
//   node scripts/check-api.mjs --base https://api.example/ --email a@b --password x
//     [--peer-email c@d]   another member, for the private-call checks
//     [--skip-writes]      only the read-only checks

const args = new Map();
for (let i = 2; i < process.argv.length; i += 1) {
  const key = process.argv[i];
  if (!key.startsWith('--')) continue;
  const next = process.argv[i + 1];
  if (next && !next.startsWith('--')) {
    args.set(key.slice(2), next);
    i += 1;
  } else {
    args.set(key.slice(2), true);
  }
}

const base = String(args.get('base') ?? '').replace(/\/*$/, '/');
const email = args.get('email');
const password = args.get('password');
const peerEmail = args.get('peer-email');
const skipWrites = Boolean(args.get('skip-writes'));

if (!base || !email || !password) {
  console.error('Használat: node scripts/check-api.mjs --base <url> --email <e-mail> --password <jelszó>');
  process.exit(2);
}

let passed = 0;
let failed = 0;
const notes = [];

function check(name, condition, detail) {
  if (condition) {
    passed += 1;
    console.log(`  ✓ ${name}`);
  } else {
    failed += 1;
    console.log(`  ✗ ${name}`);
    if (detail) console.log(`      ${detail}`);
  }
}

function note(text) {
  notes.push(text);
  console.log(`  · ${text}`);
}

async function call(path, { method = 'GET', token, body } = {}) {
  const headers = { Accept: 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const response = await fetch(new URL(path, base), {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let json;
  try { json = text ? JSON.parse(text) : undefined; } catch { json = undefined; }
  return { status: response.status, json, text };
}

const isUUID = (value) => typeof value === 'string'
  && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const isDate = (value) => typeof value === 'string' && !Number.isNaN(Date.parse(value));

console.log(`Szerver: ${base}\n`);

// ---- Auth -------------------------------------------------------------------
console.log('Hitelesítés');
const login = await call('v1/auth/login', {
  method: 'POST',
  body: { email, password, deviceName: 'API ellenőrzés' },
});
check('POST /v1/auth/login → 200', login.status === 200, `kapott: ${login.status} ${login.text.slice(0, 160)}`);
if (login.status !== 200) {
  console.log('\nBejelentkezés nélkül a többi ellenőrzés értelmetlen.');
  process.exit(1);
}

const session = login.json ?? {};
check('accessToken, refreshToken', typeof session.accessToken === 'string' && typeof session.refreshToken === 'string');
check('expiresIn szám (másodperc)', typeof session.expiresIn === 'number', `kapott: ${typeof session.expiresIn}`);
check('user.id UUID', isUUID(session.user?.id), `kapott: ${session.user?.id}`);
check('user.displayName és email', typeof session.user?.displayName === 'string' && typeof session.user?.email === 'string');

const badLogin = await call('v1/auth/login', {
  method: 'POST',
  body: { email, password: `${password}-rossz`, deviceName: 'x' },
});
check('rossz jelszó → 401', badLogin.status === 401, `kapott: ${badLogin.status}`);
check('hibaformátum { error: { code, message } }',
  typeof badLogin.json?.error?.code === 'string' && typeof badLogin.json?.error?.message === 'string',
  `kapott: ${badLogin.text.slice(0, 160)}`);
if (badLogin.json?.error?.code && badLogin.json.error.code !== 'invalid_credentials') {
  note(`a hibás jelszó kódja "${badLogin.json.error.code}", a szerződés szerint "invalid_credentials"`);
}

const noToken = await call('v1/productions');
check('token nélkül → 401', noToken.status === 401, `kapott: ${noToken.status}`);

const refreshed = await call('v1/auth/refresh', {
  method: 'POST',
  body: { refreshToken: session.refreshToken },
});
check('POST /v1/auth/refresh → 200', refreshed.status === 200, `kapott: ${refreshed.status}`);
const token = refreshed.json?.accessToken ?? session.accessToken;

const reused = await call('v1/auth/refresh', {
  method: 'POST',
  body: { refreshToken: session.refreshToken },
});
if (reused.status === 200) {
  note('a refresh token újra felhasználható — a kliens egyszer-használatra készült, ez nem hiba, de érdemes tudni');
} else {
  check('elhasznált refresh token → 401', reused.status === 401, `kapott: ${reused.status}`);
}

// ---- Productions and channels ----------------------------------------------
console.log('\nProdukciók és csatornák');
const productions = await call('v1/productions', { token });
check('GET /v1/productions → 200', productions.status === 200, `kapott: ${productions.status}`);
check('tömböt ad vissza', Array.isArray(productions.json), `kapott: ${typeof productions.json}`);

const production = Array.isArray(productions.json) ? productions.json[0] : undefined;
if (!production) {
  console.log('\nNincs produkció ehhez a fiókhoz; a további ellenőrzések kimaradnak.');
  process.exit(failed > 0 ? 1 : 0);
}
check('produkció id/name/role', isUUID(production.id) && typeof production.name === 'string' && typeof production.role === 'string',
  JSON.stringify(production).slice(0, 160));

const channels = await call(`v1/productions/${production.id}/channels`, { token });
check('GET .../channels → 200', channels.status === 200, `kapott: ${channels.status}`);
const channelList = Array.isArray(channels.json) ? channels.json : [];
check('legalább egy csatorna', channelList.length > 0);

const channel = channelList[0];
if (channel) {
  check('csatorna kötelező mezői',
    isUUID(channel.id) && typeof channel.name === 'string' && typeof channel.detail === 'string'
      && typeof channel.colorHex === 'string' && typeof channel.canTalk === 'boolean'
      && typeof channel.canListen === 'boolean' && typeof channel.defaultListening === 'boolean'
      && typeof channel.participantCount === 'number',
    JSON.stringify(channel).slice(0, 200));
  // Optional by contract: the client falls back to line / 12 dB / false.
  if (channel.role === undefined) note('nincs role mező — a kliens mindent sima vonalnak vesz, nem lesz ducking');
  else if (!['line', 'program', 'priority'].includes(channel.role)) {
    check('role értéke line|program|priority', false, `kapott: ${channel.role}`);
  }
  if (channel.duckDecibels !== undefined && typeof channel.duckDecibels !== 'number') {
    check('duckDecibels szám', false, `kapott: ${typeof channel.duckDecibels}`);
  }
  if (channel.isPrivate !== undefined && typeof channel.isPrivate !== 'boolean') {
    check('isPrivate logikai', false, `kapott: ${typeof channel.isPrivate}`);
  }
}

const crew = await call(`v1/productions/${production.id}/crew`, { token });
if (crew.status === 404) {
  note('nincs /crew végpont — a résztvevőlista üres marad');
} else {
  check('GET .../crew → 200', crew.status === 200, `kapott: ${crew.status}`);
  const member = Array.isArray(crew.json) ? crew.json[0] : undefined;
  if (member) {
    check('crew id/displayName/role',
      isUUID(member.id) && typeof member.displayName === 'string' && typeof member.role === 'string',
      JSON.stringify(member).slice(0, 160));
  }
}

// ---- Realtime ---------------------------------------------------------------
console.log('\nRealtime tokenek');
const tokens = await call(`v1/productions/${production.id}/rt-tokens`, {
  method: 'POST',
  token,
  body: { channelIds: channelList.map((c) => c.id) },
});
check('POST .../rt-tokens → 200', tokens.status === 200, `kapott: ${tokens.status} ${tokens.text.slice(0, 160)}`);
const realtime = tokens.json ?? {};
check('url wss:// vagy ws://', typeof realtime.url === 'string' && /^wss?:\/\//.test(realtime.url),
  `kapott: ${realtime.url}`);
if (typeof realtime.url === 'string' && realtime.url.startsWith('ws://')) {
  note('a LiveKit URL nem titkosított (ws://) — éles használatra wss:// kell');
}
const grants = Array.isArray(realtime.grants) ? realtime.grants : [];
check('grants tömb', Array.isArray(realtime.grants));
const grant = grants[0];
if (grant) {
  check('grant mezői',
    isUUID(grant.channelId) && typeof grant.roomName === 'string' && typeof grant.token === 'string'
      && isDate(grant.expiresAt) && typeof grant.canPublish === 'boolean' && typeof grant.canSubscribe === 'boolean',
    JSON.stringify({ ...grant, token: '…' }).slice(0, 200));

  const ttlMinutes = (Date.parse(grant.expiresAt) - Date.now()) / 60000;
  if (ttlMinutes < 15) {
    note(`a grant ${Math.round(ttlMinutes)} perc múlva lejár — a kliens 10 perccel lejárat előtt újít, ez szűk`);
  }
}

// A channel the account may not talk on must not come back with publish rights.
const mute = channelList.find((c) => c.canTalk === false);
if (mute) {
  const muteGrant = grants.find((g) => g.channelId === mute.id);
  check('publish jog nélküli csatornára nincs publish grant',
    !muteGrant || muteGrant.canPublish === false,
    `"${mute.name}" canTalk=false, de a grant canPublish=${muteGrant?.canPublish}`);
} else {
  note('minden csatornán van talk joga ennek a fióknak — a jogosultság-tiltás nem ellenőrizhető');
}

// ---- Writes -----------------------------------------------------------------
if (!skipWrites) {
  console.log('\nMeghívó és privát hívás');
  const invite = await call(`v1/productions/${production.id}/invites`, {
    method: 'POST', token, body: {},
  });
  if (invite.status === 404) {
    note('nincs meghívó végpont — a QR/kódos csatlakozás nem fog működni');
  } else if (invite.status === 403) {
    note('ez a fiók nem adhat ki meghívót (nem supervisor/admin) — a végpont létezik');
  } else {
    check('POST .../invites → 201', invite.status === 201, `kapott: ${invite.status}`);
    const code = invite.json?.code;
    check('kód 4 karakter, félreérthető betűk nélkül',
      typeof code === 'string' && /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$/.test(code),
      `kapott: ${code}`);
    if (code) {
      const preview = await call(`v1/invites/${code}`, { token });
      check('GET /v1/invites/{code} → 200', preview.status === 200, `kapott: ${preview.status}`);
      const lower = await call(`v1/invites/${String(code).toLowerCase()}`, { token });
      check('a kód kisbetűvel is elfogadott', lower.status === 200, `kapott: ${lower.status}`);
    }
  }

  if (peerEmail && Array.isArray(crew.json)) {
    const peer = crew.json.find((m) => m.id !== session.user?.id);
    if (peer) {
      const callCreated = await call(`v1/productions/${production.id}/calls`, {
        method: 'POST', token, body: { peerId: peer.id },
      });
      if (callCreated.status === 404) {
        note('nincs privát hívás végpont');
      } else {
        check('POST .../calls → 201 vagy 200', [200, 201].includes(callCreated.status), `kapott: ${callCreated.status}`);
        const callId = callCreated.json?.id;
        if (callId) {
          const removed = await call(`v1/productions/${production.id}/calls/${callId}`, {
            method: 'DELETE', token,
          });
          check('DELETE .../calls/{id} → 204', removed.status === 204, `kapott: ${removed.status}`);
        }
      }
    }
  } else if (!peerEmail) {
    note('--peer-email nélkül a privát hívás nem ellenőrizhető');
  }
}

console.log(`\n${passed} rendben, ${failed} eltérés, ${notes.length} megjegyzés.`);
process.exit(failed > 0 ? 1 : 0);
