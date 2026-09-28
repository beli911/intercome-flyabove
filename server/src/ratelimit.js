/// Fixed-window rate limiting, in memory.
///
/// In memory because this server is a single instance by design; if it ever
/// runs behind a load balancer, this is the second file (after db.js) that has
/// to move to shared storage. Making that explicit here is cheaper than
/// discovering it during a broadcast.

const buckets = new Map();

function prune(now) {
  for (const [key, bucket] of buckets) {
    if (bucket.resetAt <= now) buckets.delete(key);
  }
}

export function consume({ key, limit, windowSeconds }) {
  const now = Date.now();
  if (buckets.size > 10_000) prune(now);

  const bucket = buckets.get(key);
  if (!bucket || bucket.resetAt <= now) {
    buckets.set(key, { count: 1, resetAt: now + windowSeconds * 1000 });
    return { allowed: true, remaining: limit - 1, retryAfter: 0 };
  }

  bucket.count += 1;
  const retryAfter = Math.ceil((bucket.resetAt - now) / 1000);
  return {
    allowed: bucket.count <= limit,
    remaining: Math.max(0, limit - bucket.count),
    retryAfter,
  };
}

export function forget(key) {
  buckets.delete(key);
}

export function reset() {
  buckets.clear();
}

/// Express middleware. `identity` decides what is being limited — an IP for
/// anonymous endpoints, a user id where the caller is known.
export function limiter({ name, limit, windowSeconds, identity }) {
  return (req, res, next) => {
    const who = identity ? identity(req) : (req.ip ?? 'unknown');
    const result = consume({ key: `${name}:${who}`, limit, windowSeconds });
    res.set('X-RateLimit-Limit', String(limit));
    res.set('X-RateLimit-Remaining', String(result.remaining));
    if (result.allowed) return next();
    res.set('Retry-After', String(result.retryAfter));
    // The contract's error shape, not a special one: a client that shows
    // `error.message` for every failure must have something to show here too.
    return res.status(429).json({
      error: {
        code: 'rate_limited',
        message: `Túl sok kérés. Próbáld újra ${result.retryAfter} másodperc múlva.`,
      },
      retryAfter: result.retryAfter,
    });
  };
}
