import crypto from 'node:crypto';
import Database from 'better-sqlite3';
import { config } from './config.js';

/// Every SQL statement in the server lives here.
///
/// One module, so moving to Postgres is one file to rewrite rather than a hunt
/// through route handlers. SQLite is genuinely adequate for a production of a
/// few dozen people on one API instance; the moment a second instance is needed
/// for availability, this is the file that changes.

export const db = new Database(config.databasePath);
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id            TEXT PRIMARY KEY,
  email         TEXT NOT NULL UNIQUE,
  display_name  TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  created_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS productions (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS memberships (
  production_id TEXT NOT NULL REFERENCES productions(id) ON DELETE CASCADE,
  user_id       TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role          TEXT NOT NULL,
  PRIMARY KEY (production_id, user_id)
);

CREATE TABLE IF NOT EXISTS channels (
  id                TEXT PRIMARY KEY,
  production_id     TEXT NOT NULL REFERENCES productions(id) ON DELETE CASCADE,
  name              TEXT NOT NULL,
  detail            TEXT NOT NULL DEFAULT '',
  color_hex         TEXT NOT NULL DEFAULT '5B8CFF',
  role              TEXT NOT NULL DEFAULT 'line',
  duck_decibels     REAL NOT NULL DEFAULT 12,
  default_listening INTEGER NOT NULL DEFAULT 1,
  is_private        INTEGER NOT NULL DEFAULT 0,
  position          INTEGER NOT NULL DEFAULT 0,
  created_at        TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS permissions (
  channel_id  TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  can_talk    INTEGER NOT NULL DEFAULT 0,
  can_listen  INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (channel_id, user_id)
);

-- Refresh tokens are stored hashed. A database dump must not be a set of live
-- sessions, and a rotated token has to stay recognisable so reuse can be
-- detected.
CREATE TABLE IF NOT EXISTS refresh_tokens (
  id          TEXT PRIMARY KEY,
  family_id   TEXT NOT NULL,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash  TEXT NOT NULL,
  device_name TEXT,
  expires_at  TEXT NOT NULL,
  used_at     TEXT,
  revoked_at  TEXT,
  created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS refresh_family ON refresh_tokens(family_id);

CREATE TABLE IF NOT EXISTS invites (
  code          TEXT PRIMARY KEY,
  production_id TEXT NOT NULL REFERENCES productions(id) ON DELETE CASCADE,
  created_by    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role          TEXT NOT NULL DEFAULT 'operator',
  expires_at    TEXT NOT NULL,
  redeemed_by   TEXT REFERENCES users(id) ON DELETE SET NULL,
  redeemed_at   TEXT,
  created_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS private_call_members (
  channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  PRIMARY KEY (channel_id, user_id)
);

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
`);

const now = () => new Date().toISOString();
export const uuid = () => crypto.randomUUID();

// MARK: - Configuration version

export function configurationVersion() {
  const row = db.prepare('SELECT value FROM meta WHERE key = ?').get('configuration_version');
  return row ? Number(row.value) : 1;
}

export function bumpConfigurationVersion() {
  const next = configurationVersion() + 1;
  db.prepare('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = ?')
    .run('configuration_version', String(next), String(next));
  return next;
}

// MARK: - Users

export function findUserByEmail(email) {
  return db.prepare('SELECT * FROM users WHERE email = ?')
    .get(String(email ?? '').trim().toLowerCase());
}

export function findUserById(id) {
  return db.prepare('SELECT * FROM users WHERE id = ?').get(id);
}

export function createUser({ email, displayName, passwordHash }) {
  const id = uuid();
  db.prepare(`INSERT INTO users (id, email, display_name, password_hash, created_at)
              VALUES (?, ?, ?, ?, ?)`)
    .run(id, String(email).trim().toLowerCase(), displayName, passwordHash, now());
  return findUserById(id);
}

// MARK: - Productions and membership

export function productionsForUser(userId) {
  return db.prepare(`
    SELECT p.id, p.name, m.role
    FROM productions p
    JOIN memberships m ON m.production_id = p.id
    WHERE m.user_id = ?
    ORDER BY p.created_at
  `).all(userId);
}

export function membership(productionId, userId) {
  return db.prepare('SELECT * FROM memberships WHERE production_id = ? AND user_id = ?')
    .get(productionId, userId);
}

export function createProduction({ name, ownerId, ownerRole = 'admin' }) {
  const id = uuid();
  db.prepare('INSERT INTO productions (id, name, created_at) VALUES (?, ?, ?)')
    .run(id, name, now());
  addMember({ productionId: id, userId: ownerId, role: ownerRole });
  return { id, name, role: ownerRole };
}

export function addMember({ productionId, userId, role }) {
  db.prepare(`INSERT INTO memberships (production_id, user_id, role) VALUES (?, ?, ?)
              ON CONFLICT(production_id, user_id) DO UPDATE SET role = ?`)
    .run(productionId, userId, role, role);
}

export function crewForProduction(productionId) {
  return db.prepare(`
    SELECT u.id, u.display_name AS displayName, m.role
    FROM memberships m
    JOIN users u ON u.id = m.user_id
    WHERE m.production_id = ?
    ORDER BY u.display_name
  `).all(productionId);
}

// MARK: - Channels and permissions

export function channelsForProduction(productionId) {
  return db.prepare('SELECT * FROM channels WHERE production_id = ? ORDER BY position, created_at')
    .all(productionId);
}

export function findChannel(id) {
  return db.prepare('SELECT * FROM channels WHERE id = ?').get(id);
}

export function createChannel({
  productionId, name, detail = '', colorHex = '5B8CFF',
  role = 'line', duckDecibels = 12, defaultListening = true,
  isPrivate = false, position = 0,
}) {
  const id = uuid();
  db.prepare(`INSERT INTO channels
    (id, production_id, name, detail, color_hex, role, duck_decibels,
     default_listening, is_private, position, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
    .run(id, productionId, name, detail, colorHex, role, duckDecibels,
      defaultListening ? 1 : 0, isPrivate ? 1 : 0, position, now());
  return findChannel(id);
}

export function updateChannel(id, fields) {
  const allowed = {
    name: 'name', detail: 'detail', colorHex: 'color_hex',
    role: 'role', duckDecibels: 'duck_decibels', defaultListening: 'default_listening',
  };
  const sets = [];
  const values = [];
  for (const [key, column] of Object.entries(allowed)) {
    if (fields[key] === undefined) continue;
    sets.push(`${column} = ?`);
    values.push(typeof fields[key] === 'boolean' ? (fields[key] ? 1 : 0) : fields[key]);
  }
  if (sets.length > 0) {
    db.prepare(`UPDATE channels SET ${sets.join(', ')} WHERE id = ?`).run(...values, id);
  }
  return findChannel(id);
}

export function deleteChannel(id) {
  db.prepare('DELETE FROM channels WHERE id = ?').run(id);
}

export function permissionFor(channelId, userId) {
  const row = db.prepare('SELECT can_talk, can_listen FROM permissions WHERE channel_id = ? AND user_id = ?')
    .get(channelId, userId);
  return { canTalk: Boolean(row?.can_talk), canListen: Boolean(row?.can_listen) };
}

export function setPermission({ channelId, userId, canTalk, canListen }) {
  db.prepare(`INSERT INTO permissions (channel_id, user_id, can_talk, can_listen)
              VALUES (?, ?, ?, ?)
              ON CONFLICT(channel_id, user_id) DO UPDATE SET can_talk = ?, can_listen = ?`)
    .run(channelId, userId, canTalk ? 1 : 0, canListen ? 1 : 0, canTalk ? 1 : 0, canListen ? 1 : 0);
}

// MARK: - Refresh tokens

const hashToken = (token) => crypto.createHash('sha256').update(token).digest('hex');

export function storeRefreshToken({ userId, token, familyId, deviceName, expiresAt }) {
  const id = uuid();
  db.prepare(`INSERT INTO refresh_tokens
    (id, family_id, user_id, token_hash, device_name, expires_at, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)`)
    .run(id, familyId ?? id, userId, hashToken(token), deviceName ?? null,
      expiresAt.toISOString(), now());
  return { id, familyId: familyId ?? id };
}

export function findRefreshToken(token) {
  return db.prepare('SELECT * FROM refresh_tokens WHERE token_hash = ?').get(hashToken(token));
}

export function markRefreshTokenUsed(id) {
  db.prepare('UPDATE refresh_tokens SET used_at = ? WHERE id = ?').run(now(), id);
}

/// Revokes an entire family.
///
/// Used when a spent token is presented again: either it leaked, or a client is
/// confused. Both are reasons to end every session descended from that login
/// rather than guess which one is genuine.
export function revokeFamily(familyId) {
  db.prepare('UPDATE refresh_tokens SET revoked_at = ? WHERE family_id = ? AND revoked_at IS NULL')
    .run(now(), familyId);
}

export function revokeAllForUser(userId) {
  db.prepare('UPDATE refresh_tokens SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL')
    .run(now(), userId);
}

// MARK: - Invites

export function createInvite({ code, productionId, createdBy, role, expiresAt }) {
  db.prepare(`INSERT INTO invites (code, production_id, created_by, role, expires_at, created_at)
              VALUES (?, ?, ?, ?, ?, ?)`)
    .run(code, productionId, createdBy, role, expiresAt.toISOString(), now());
  return findInvite(code);
}

export function findInvite(code) {
  return db.prepare('SELECT * FROM invites WHERE code = ?').get(String(code ?? '').toUpperCase());
}

export function redeemInvite(code, userId) {
  db.prepare('UPDATE invites SET redeemed_by = ?, redeemed_at = ? WHERE code = ?')
    .run(userId, now(), code);
}

// MARK: - Private calls

export function findPrivateChannelBetween(productionId, userIds) {
  const rows = db.prepare(`
    SELECT c.id, COUNT(m.user_id) AS members
    FROM channels c
    JOIN private_call_members m ON m.channel_id = c.id
    WHERE c.production_id = ? AND c.is_private = 1
    GROUP BY c.id
  `).all(productionId);

  for (const row of rows) {
    if (row.members !== userIds.length) continue;
    const members = privateCallMembers(row.id);
    if (userIds.every((id) => members.includes(id))) return findChannel(row.id);
  }
  return undefined;
}

export function privateCallMembers(channelId) {
  return db.prepare('SELECT user_id FROM private_call_members WHERE channel_id = ?')
    .all(channelId).map((row) => row.user_id);
}

export function addPrivateCallMember(channelId, userId) {
  db.prepare('INSERT OR IGNORE INTO private_call_members (channel_id, user_id) VALUES (?, ?)')
    .run(channelId, userId);
}
