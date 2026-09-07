import crypto from 'node:crypto';
import os from 'node:os';

/// Everything the server needs, resolved and checked once at boot.
///
/// A misconfigured server that starts anyway is worse than one that refuses:
/// the first symptom of a default signing secret in production is that anybody
/// can mint their own session, and nothing about that looks like a fault.

const isProduction = (process.env.NODE_ENV ?? 'development') === 'production';

function detectLANAddress() {
  for (const addresses of Object.values(os.networkInterfaces())) {
    for (const address of addresses ?? []) {
      if (address.family === 'IPv4' && !address.internal) return address.address;
    }
  }
  return 'localhost';
}

const problems = [];

function required(name, fallback) {
  const value = process.env[name];
  if (value) return value;
  if (isProduction) {
    problems.push(`${name} hiányzik`);
    return undefined;
  }
  return fallback;
}

const jwtSecret = process.env.JWT_SECRET
  ?? (isProduction ? undefined : 'development-only-secret');
if (isProduction) {
  if (!process.env.JWT_SECRET) problems.push('JWT_SECRET hiányzik');
  else if (process.env.JWT_SECRET.length < 32) {
    problems.push('JWT_SECRET rövidebb 32 karakternél');
  }
}

/// In production this is a stable `wss://` hostname from the environment. The
/// development fallback is re-detected on every read, because a laptop's LAN
/// address changes when it moves between networks — and a URL captured at boot
/// then points at nothing, which reaches the phone as "the app cannot connect"
/// rather than "the machine moved".
const configuredLivekitUrl = process.env.LIVEKIT_URL;
if (!configuredLivekitUrl && isProduction) problems.push('LIVEKIT_URL hiányzik');
const livekitUrl = configuredLivekitUrl ?? `ws://${detectLANAddress()}:7880`;
const livekitKey = required('LIVEKIT_API_KEY', 'devkey');
const livekitSecret = required('LIVEKIT_API_SECRET', 'secret');

if (isProduction && livekitUrl && !livekitUrl.startsWith('wss://')) {
  problems.push('LIVEKIT_URL nem wss:// — éles környezetben a médiajelzésnek titkosítottnak kell lennie');
}

export const config = Object.freeze({
  isProduction,
  port: Number(process.env.PORT ?? 8080),
  /// `:memory:` is for tests; anything else is a file that must survive a restart.
  databasePath: process.env.DATABASE_PATH ?? './flycom.db',
  jwtSecret,
  accessTokenTtlSeconds: Number(process.env.ACCESS_TOKEN_TTL ?? 900),
  refreshTokenTtlSeconds: Number(process.env.REFRESH_TOKEN_TTL ?? 60 * 60 * 24 * 30),
  /// One hour. The client renews ten minutes before expiry, so anything under
  /// fifteen minutes leaves no room for a renewal to fail and be retried.
  roomTokenTtlSeconds: Number(process.env.ROOM_TOKEN_TTL ?? 3600),
  livekit: Object.freeze({
    get url() {
      return configuredLivekitUrl ?? `ws://${detectLANAddress()}:7880`;
    },
    apiKey: livekitKey,
    apiSecret: livekitSecret,
  }),
  /// Demo data, for local development and the test suite.
  seedDemo: process.env.SEED_DEMO === '1',
  /// Trust the reverse proxy's client address; wrong here means the login rate
  /// limit throttles the proxy instead of the caller.
  trustProxy: process.env.TRUST_PROXY === '1',
  loginAttemptsPerWindow: Number(process.env.LOGIN_ATTEMPTS ?? 10),
  loginWindowSeconds: Number(process.env.LOGIN_WINDOW ?? 900),
});

export function assertConfigured() {
  // Unsafe defaults are the ones worth shouting about: they work, which is
  // exactly why nobody notices them.
  if (!isProduction) {
    if (config.jwtSecret === 'development-only-secret') {
      console.warn('[figyelem] fejlesztői JWT titok — éles környezetben ez nem indulna el');
    }
    return;
  }
  if (problems.length > 0) {
    console.error('A szerver nem indul el, mert a konfiguráció hiányos:');
    for (const problem of problems) console.error(`  - ${problem}`);
    process.exit(1);
  }
}

export function generateSecret() {
  return crypto.randomBytes(48).toString('base64url');
}
