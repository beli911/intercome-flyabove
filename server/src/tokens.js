import crypto from 'node:crypto';
import jwt from 'jsonwebtoken';
import { config } from './config.js';
import * as db from './db.js';

/// Access tokens are short-lived JWTs; refresh tokens are opaque random strings
/// stored only as SHA-256 hashes.
///
/// The split matters: an access token can be verified without touching the
/// database, so the hot path stays cheap, while revocation still works because
/// every refresh has to come back here.

export function issueAccessToken(user) {
  const expiresIn = config.accessTokenTtlSeconds;
  const token = jwt.sign(
    { sub: user.id, email: user.email, name: user.display_name, sv: user.session_version },
    config.jwtSecret,
    { expiresIn, issuer: 'flycom', audience: 'flycom-app' },
  );
  return { token, expiresIn };
}

export function verifyAccessToken(token) {
  try {
    return jwt.verify(token, config.jwtSecret, { issuer: 'flycom', audience: 'flycom-app' });
  } catch {
    return undefined;
  }
}

function refreshExpiry() {
  return new Date(Date.now() + config.refreshTokenTtlSeconds * 1000);
}

export function issueRefreshToken({ userId, familyId, deviceName }) {
  const token = crypto.randomBytes(32).toString('base64url');
  const stored = db.storeRefreshToken({
    userId, token, familyId, deviceName, expiresAt: refreshExpiry(),
  });
  return { token, familyId: stored.familyId };
}

export const RefreshFailure = {
  unknown: 'unknown',
  expired: 'expired',
  revoked: 'revoked',
  reused: 'reused',
};

/// Rotates a refresh token, one use per token.
///
/// A token presented twice means the first presentation leaked or a client is
/// replaying. Neither case is safe to serve, so the whole family — every token
/// descended from that login — is revoked and the user has to sign in again.
export function rotateRefreshToken({ token, deviceName }) {
  const row = db.findRefreshToken(token);
  if (!row) return { failure: RefreshFailure.unknown };

  if (row.revoked_at) return { failure: RefreshFailure.revoked };

  if (row.used_at) {
    db.revokeFamily(row.family_id);
    return { failure: RefreshFailure.reused };
  }

  if (new Date(row.expires_at).getTime() <= Date.now()) {
    return { failure: RefreshFailure.expired };
  }

  const user = db.findUserById(row.user_id);
  if (!user) return { failure: RefreshFailure.unknown };

  db.markRefreshTokenUsed(row.id);
  const next = issueRefreshToken({
    userId: user.id,
    familyId: row.family_id,
    deviceName: deviceName ?? row.device_name,
  });
  const access = issueAccessToken(user);
  return { user, access, refresh: next };
}
