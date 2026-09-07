import crypto from 'node:crypto';

/// scrypt, from Node's own crypto.
///
/// Chosen over bcrypt or argon2 because it is built in: a password hash that
/// depends on a native module is a password hash that breaks on the next Node
/// upgrade, at the worst possible time.

const KEY_LENGTH = 32;
const SALT_LENGTH = 16;
/// Roughly 100 ms on a modern server. High enough to matter, low enough that a
/// login does not feel broken.
const PARAMETERS = { N: 2 ** 15, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };

export function hashPassword(password) {
  const salt = crypto.randomBytes(SALT_LENGTH);
  const key = crypto.scryptSync(password, salt, KEY_LENGTH, PARAMETERS);
  return `scrypt$${PARAMETERS.N}$${PARAMETERS.r}$${PARAMETERS.p}$${salt.toString('base64')}$${key.toString('base64')}`;
}

export function verifyPassword(password, stored) {
  try {
    const [scheme, n, r, p, salt, key] = String(stored).split('$');
    if (scheme !== 'scrypt') return false;
    const expected = Buffer.from(key, 'base64');
    const actual = crypto.scryptSync(
      password,
      Buffer.from(salt, 'base64'),
      expected.length,
      { N: Number(n), r: Number(r), p: Number(p), maxmem: 64 * 1024 * 1024 },
    );
    // Constant time: a comparison that returns early leaks the hash one byte
    // at a time.
    return crypto.timingSafeEqual(expected, actual);
  } catch {
    return false;
  }
}
