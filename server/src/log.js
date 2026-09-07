/// Structured, and deliberately narrow.
///
/// `docs/SECURITY.md` allows session ids, error codes, connection state and
/// quality aggregates. It forbids audio, tokens, TURN credentials and long-term
/// IP retention. A logger that takes arbitrary objects will eventually be
/// handed a token by someone in a hurry, so the redaction happens here rather
/// than at every call site.

const REDACTED_KEYS = new Set([
  'password', 'token', 'accessToken', 'refreshToken', 'authorization',
  'apiSecret', 'secret', 'credential', 'jwt',
]);

function redact(value, depth = 0) {
  if (depth > 4 || value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map((item) => redact(item, depth + 1));
  const output = {};
  for (const [key, item] of Object.entries(value)) {
    output[key] = REDACTED_KEYS.has(key) ? '[redacted]' : redact(item, depth + 1);
  }
  return output;
}

function emit(level, message, fields) {
  const line = { time: new Date().toISOString(), level, message, ...redact(fields ?? {}) };
  const stream = level === 'error' ? process.stderr : process.stdout;
  stream.write(`${JSON.stringify(line)}\n`);
}

export const log = {
  info: (message, fields) => emit('info', message, fields),
  warn: (message, fields) => emit('warn', message, fields),
  error: (message, fields) => emit('error', message, fields),
};
