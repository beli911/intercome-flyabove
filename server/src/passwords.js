import crypto from 'node:crypto';

/// scrypt, from Node's own crypto.
///
/// Chosen over bcrypt or argon2 because it is built in: a password hash that
/// depends on a native module is a password hash that breaks on the next Node
/// upgrade, at the worst possible time.
///
/// Everything here is async. `scryptSync` runs on the main thread, so twenty
/// concurrent logins hold the event loop for over a second — measurably: with
/// the synchronous version, `/health` answered in 1226 ms during a burst of
/// twenty wrong passwords. The async form runs on the libuv thread pool, and
/// the semaphore below caps how many run at once so a burst queues instead of
/// starving every other request of a thread.

const KEY_LENGTH = 32;
const SALT_LENGTH = 16;
/// Roughly 100 ms on a modern server. High enough to matter, low enough that a
/// login does not feel broken.
const PARAMETERS = { N: 2 ** 15, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };

/// Node's default thread pool is four threads, shared with file and DNS work.
/// Two concurrent hashes leave room for everything else to keep moving.
const MAX_CONCURRENT_HASHES = Number(process.env.PASSWORD_CONCURRENCY ?? 2);

let running = 0;
const waiting = [];

function acquire() {
  if (running < MAX_CONCURRENT_HASHES) {
    running += 1;
    return Promise.resolve();
  }
  return new Promise((resolve) => waiting.push(resolve));
}

function release() {
  const next = waiting.shift();
  if (next) return next();
  running -= 1;
  return undefined;
}

function scrypt(password, salt, length, parameters) {
  return new Promise((resolve, reject) => {
    crypto.scrypt(password, salt, length, parameters, (error, key) => {
      if (error) reject(error);
      else resolve(key);
    });
  });
}

async function derive(password, salt, length, parameters) {
  await acquire();
  try {
    return await scrypt(password, salt, length, parameters);
  } finally {
    release();
  }
}

export async function hashPassword(password) {
  const salt = crypto.randomBytes(SALT_LENGTH);
  const key = await derive(password, salt, KEY_LENGTH, PARAMETERS);
  return `scrypt$${PARAMETERS.N}$${PARAMETERS.r}$${PARAMETERS.p}$${salt.toString('base64')}$${key.toString('base64')}`;
}

export async function verifyPassword(password, stored) {
  try {
    const [scheme, n, r, p, salt, key] = String(stored).split('$');
    if (scheme !== 'scrypt') return false;
    const expected = Buffer.from(key, 'base64');
    const actual = await derive(
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

/// A hash of nothing in particular, with the real parameters.
///
/// Verified against when the e-mail address is unknown, so that the answer
/// costs the same either way. Without it an unknown address returns in about a
/// millisecond and a known one in about sixty-six — a sixty-fold difference
/// that tells anybody who asks which addresses have accounts, no matter how
/// identical the response body is.
const DECOY = crypto.scryptSync(
  crypto.randomBytes(32), crypto.randomBytes(SALT_LENGTH), KEY_LENGTH, PARAMETERS,
);
const DECOY_HASH =
  `scrypt$${PARAMETERS.N}$${PARAMETERS.r}$${PARAMETERS.p}$${crypto.randomBytes(SALT_LENGTH).toString('base64')}$${DECOY.toString('base64')}`;

/// Spends the same work as a real check and always fails.
export async function burnPasswordWork(password) {
  await verifyPassword(String(password ?? ''), DECOY_HASH);
  return false;
}
