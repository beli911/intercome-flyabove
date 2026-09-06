// Seed data for local development. Passwords are plain text on purpose: this
// server exists to make two phones talk to each other on a desk, and pretending
// otherwise would only hide that it must never be deployed.

export const PRODUCTION_ID = '4f6f1a1e-6a4a-4a1e-9a2e-2a1b3c4d5e6f';

export const SECOND_PRODUCTION_ID = '5a7a2b2f-7b5b-4b2f-8b3f-3b2c4d5e6f70';

export const productions = [
  { id: PRODUCTION_ID, name: 'Bajnokok Ligája — Puskás', role: 'operator' },
  { id: SECOND_PRODUCTION_ID, name: 'Reggeli stúdió — 4. blokk', role: 'supervisor' },
];

export const channels = [
  {
    id: '11111111-1111-4111-8111-111111111111',
    name: 'Mindenki',
    detail: 'Teljes produkció',
    colorHex: '5B8CFF',
    defaultListening: true,
  },
  {
    id: '22222222-2222-4222-8222-222222222222',
    name: 'Kamera',
    detail: 'Kameraoperátorok',
    colorHex: '31C48D',
    defaultListening: true,
  },
  {
    id: '33333333-3333-4333-8333-333333333333',
    name: 'Rendező',
    detail: 'Rendezői vonal',
    colorHex: 'F59E0B',
    defaultListening: false,
  },
];

// Per-user channel permissions, so the client's "no talk permission" path is
// actually exercisable in a local test rather than only in unit tests.
export const users = [
  {
    id: '8b2b8a5c-1b7c-4e1e-9c1f-1e6c2e5c4a11',
    email: 'operator@flyabove.hu',
    password: 'flyabove',
    displayName: 'Teszt Operátor',
    role: 'operator',
    permissions: {
      '11111111-1111-4111-8111-111111111111': { canTalk: true, canListen: true },
      '22222222-2222-4222-8222-222222222222': { canTalk: true, canListen: true },
      '33333333-3333-4333-8333-333333333333': { canTalk: true, canListen: true },
    },
  },
  {
    id: '9c3c9b6d-2c8d-4f2f-8d20-2f7d3f6d5b22',
    email: 'kamera@flyabove.hu',
    password: 'flyabove',
    displayName: 'Teszt Kamera',
    role: 'kameraman',
    permissions: {
      '11111111-1111-4111-8111-111111111111': { canTalk: true, canListen: true },
      '22222222-2222-4222-8222-222222222222': { canTalk: true, canListen: true },
      // Listens to the director line but may not talk on it.
      '33333333-3333-4333-8333-333333333333': { canTalk: false, canListen: true },
    },
  },
];

/// Live invites, keyed by code. In-memory like everything else here.
export const invites = new Map();

/// Bumped whenever a channel changes, so a client can tell whether the
/// configuration it holds is still current.
export const configurationVersion = { value: 1 };

/// Ambiguous characters are left out on purpose: these codes get read aloud
/// over a talkback and typed on a phone in the dark.
// Must match InviteCode.alphabet on the client, character for character.
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

export function generateInviteCode(length = 4) {
  let code = '';
  for (let i = 0; i < length; i += 1) {
    code += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
  }
  return invites.has(code) ? generateInviteCode(length) : code;
}

export function findUserByEmail(email) {
  const normalized = String(email ?? '').trim().toLowerCase();
  return users.find((user) => user.email === normalized);
}

export function findUserById(id) {
  return users.find((user) => user.id === id);
}

/// One channel is one LiveKit room; see docs/API.md.
export function roomName(productionId, channelId) {
  return `p_${productionId}.c_${channelId}`;
}
