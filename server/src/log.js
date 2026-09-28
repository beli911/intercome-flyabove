/// Structured, and deliberately narrow.
///
/// `docs/SECURITY.md` allows session ids, error codes, connection state and
/// quality aggregates. It forbids audio, tokens, TURN credentials and long-term
/// IP retention. A logger that takes arbitrary objects will eventually be
/// handed a token by someone in a hurry, so the redaction happens here rather
/// than at every call site.

/// Matched after the key is lowercased and stripped of separators, so
/// `refresh_token`, `Refresh-Token` and `refreshToken` are all the same key.
/// The earlier version matched exact camelCase names, which let
/// `Authorization` and `access_token` through untouched.
const REDACTED_KEYS = new Set([
  'password', 'passwd', 'passwordhash', 'token', 'accesstoken', 'refreshtoken',
  'idtoken', 'authorization', 'auth', 'apikey', 'apisecret', 'secret',
  'credential', 'credentials', 'jwt', 'cookie', 'setcookie', 'sessionid',
  'privatekey', 'signature',
]);

const normaliseKey = (key) => String(key).toLowerCase().replace(/[^a-z0-9]/g, '');

/// Values that look like a secret regardless of what they are called.
///
/// A key list only protects fields somebody thought to name; this catches the
/// bearer header pasted into a `message`, and the JWT stored under `data`.
const SECRET_SHAPES = [
  /\bBearer\s+[A-Za-z0-9._~+/-]{8,}=*/gi,
  // Three base64url segments: a JWT, whatever field it arrived in.
  /\beyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}/g,
];

function scrubString(value) {
  let output = value;
  for (const shape of SECRET_SHAPES) output = output.replace(shape, '[redacted]');
  return output;
}

const MAX_DEPTH = 6;

function redact(value, depth = 0) {
  if (typeof value === 'string') return scrubString(value);
  if (value === null || typeof value !== 'object') return value;
  // Past the limit the value is dropped, not passed through: the old code
  // returned the object unchanged here, so anything nested deeply enough was
  // logged verbatim.
  if (depth >= MAX_DEPTH) return '[truncated]';
  if (Array.isArray(value)) return value.map((item) => redact(item, depth + 1));

  const output = {};
  for (const [key, item] of Object.entries(value)) {
    output[key] = REDACTED_KEYS.has(normaliseKey(key)) ? '[redacted]' : redact(item, depth + 1);
  }
  return output;
}

function emit(level, message, fields) {
  const line = {
    time: new Date().toISOString(),
    level,
    message: scrubString(String(message)),
    ...redact(fields ?? {}),
  };
  const stream = level === 'error' ? process.stderr : process.stdout;
  stream.write(`${JSON.stringify(line)}\n`);
}

export const log = {
  info: (message, fields) => emit('info', message, fields),
  warn: (message, fields) => emit('warn', message, fields),
  error: (message, fields) => emit('error', message, fields),
};

/// Exposed for the tests, which are adversarial about it on purpose.
export const _redactForTests = redact;
