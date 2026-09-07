import { db, uuid } from './db.js';
import { hashPassword } from './passwords.js';
import { log } from './log.js';

/// Demo data for local development and the iOS integration suite.
///
/// The ids are fixed so a test can name a channel without first discovering it,
/// and the permissions are deliberately uneven: the "no talk permission" path
/// has to be reachable against a real server, not only in unit tests.

export const PRODUCTION_ID = '4f6f1a1e-6a4a-4a1e-9a2e-2a1b3c4d5e6f';
export const SECOND_PRODUCTION_ID = '5a7a2b2f-7b5b-4b2f-8b3f-3b2c4d5e6f70';

const CHANNELS = [
  { id: '11111111-1111-4111-8111-111111111111', name: 'Mindenki', detail: 'Teljes produkció', colorHex: '5B8CFF', role: 'line', duckDecibels: 12, defaultListening: true },
  { id: '22222222-2222-4222-8222-222222222222', name: 'Kamera', detail: 'Kameraoperátorok', colorHex: '31C48D', role: 'line', duckDecibels: 12, defaultListening: true },
  // The director's line: when this speaks, everything else steps back.
  { id: '33333333-3333-4333-8333-333333333333', name: 'Rendező', detail: 'Rendezői vonal', colorHex: 'F59E0B', role: 'priority', duckDecibels: 12, defaultListening: false },
  // Programme audio, dipped so a cue can be heard over it.
  { id: '44444444-4444-4444-8444-444444444444', name: 'Program', detail: 'Adáshang', colorHex: '4FD6D2', role: 'program', duckDecibels: 15, defaultListening: true },
];

const USERS = [
  {
    id: '8b2b8a5c-1b7c-4e1e-9c1f-1e6c2e5c4a11',
    email: 'operator@flyabove.hu',
    displayName: 'Teszt Operátor',
    role: 'admin',
    permissions: {
      '11111111-1111-4111-8111-111111111111': [true, true],
      '22222222-2222-4222-8222-222222222222': [true, true],
      '33333333-3333-4333-8333-333333333333': [true, true],
      // Programme audio is listen-only for everyone.
      '44444444-4444-4444-8444-444444444444': [false, true],
    },
  },
  {
    id: '9c3c9b6d-2c8d-4f2f-8d20-2f7d3f6d5b22',
    email: 'kamera@flyabove.hu',
    displayName: 'Teszt Kamera',
    role: 'operator',
    permissions: {
      '11111111-1111-4111-8111-111111111111': [true, true],
      '22222222-2222-4222-8222-222222222222': [true, true],
      // Listens to the director line but may not talk on it.
      '33333333-3333-4333-8333-333333333333': [false, true],
      '44444444-4444-4444-8444-444444444444': [false, true],
    },
  },
];

export function seedDemoData({ password = 'flyabove' } = {}) {
  const existing = db.prepare('SELECT COUNT(*) AS count FROM users').get();
  if (existing.count > 0) return false;

  const now = new Date().toISOString();
  const passwordHash = hashPassword(password);

  const insert = db.transaction(() => {
    db.prepare('INSERT INTO productions (id, name, created_at) VALUES (?, ?, ?)')
      .run(PRODUCTION_ID, 'Bajnokok Ligája — Puskás', now);
    db.prepare('INSERT INTO productions (id, name, created_at) VALUES (?, ?, ?)')
      .run(SECOND_PRODUCTION_ID, 'Reggeli stúdió — 4. blokk', now);

    CHANNELS.forEach((channel, index) => {
      db.prepare(`INSERT INTO channels
        (id, production_id, name, detail, color_hex, role, duck_decibels,
         default_listening, is_private, position, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`)
        .run(channel.id, PRODUCTION_ID, channel.name, channel.detail, channel.colorHex,
          channel.role, channel.duckDecibels, channel.defaultListening ? 1 : 0, index, now);
    });

    for (const user of USERS) {
      db.prepare(`INSERT INTO users (id, email, display_name, password_hash, created_at)
                  VALUES (?, ?, ?, ?, ?)`)
        .run(user.id, user.email, user.displayName, passwordHash, now);
      db.prepare('INSERT INTO memberships (production_id, user_id, role) VALUES (?, ?, ?)')
        .run(PRODUCTION_ID, user.id, user.role);
      for (const [channelId, [canTalk, canListen]] of Object.entries(user.permissions)) {
        db.prepare(`INSERT INTO permissions (channel_id, user_id, can_talk, can_listen)
                    VALUES (?, ?, ?, ?)`)
          .run(channelId, user.id, canTalk ? 1 : 0, canListen ? 1 : 0);
      }
    }

    // The second production exists so the picker has something to pick, and it
    // gives the admin account a supervisor role somewhere it is not owner.
    db.prepare('INSERT INTO memberships (production_id, user_id, role) VALUES (?, ?, ?)')
      .run(SECOND_PRODUCTION_ID, USERS[0].id, 'supervisor');
    const studio = uuid();
    db.prepare(`INSERT INTO channels
      (id, production_id, name, detail, color_hex, role, duck_decibels,
       default_listening, is_private, position, created_at)
      VALUES (?, ?, 'Stúdió', 'Stúdióvonal', '5B8CFF', 'line', 12, 1, 0, 0, ?)`)
      .run(studio, SECOND_PRODUCTION_ID, now);
    // Without a permission row the channel is filtered out of the list, and a
    // production whose only channel is invisible looks like an empty one.
    db.prepare(`INSERT INTO permissions (channel_id, user_id, can_talk, can_listen)
                VALUES (?, ?, 1, 1)`)
      .run(studio, USERS[0].id);
  });

  insert();
  log.info('demó adatok betöltve', { users: USERS.length, channels: CHANNELS.length });
  return true;
}
