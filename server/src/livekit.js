import { AccessToken, RoomServiceClient } from 'livekit-server-sdk';
import { config } from './config.js';
import { log } from './log.js';

/// One channel is one LiveKit room. `docs/API.md` fixes the naming convention,
/// and both ends depend on it literally — a mismatch here is two people in two
/// rooms who each think the other is not talking.
const BROADCAST_TIMEOUT_MS = 2000;

export const roomName = (productionId, channelId) => `p_${productionId}.c_${channelId}`;

/// Rebuilt whenever the address changes, which in development it does — the
/// client caches a host, and a cached host that has moved fails as a three
/// second timeout on every push rather than as a configuration error.
let cached = { url: undefined, client: undefined };

function roomService() {
  const url = config.livekit.url;
  if (cached.url !== url) {
    cached = {
      url,
      client: new RoomServiceClient(
        url.replace(/^ws/, 'http'), config.livekit.apiKey, config.livekit.apiSecret,
      ),
    };
  }
  return cached.client;
}

/// Mints a room token whose grants are exactly the user's rights.
///
/// The client greys out a Talk button it may not use, but that is courtesy. The
/// enforcement is here: a token without `canPublish` cannot publish even from a
/// client written to ignore the UI.
export async function issueRoomToken({ user, productionId, channelId, canTalk, canListen }) {
  const room = roomName(productionId, channelId);
  const token = new AccessToken(config.livekit.apiKey, config.livekit.apiSecret, {
    identity: user.id,
    name: user.display_name,
    ttl: config.roomTokenTtlSeconds,
  });
  token.addGrant({
    roomJoin: true,
    room,
    canPublish: canTalk,
    canSubscribe: canListen,
    canPublishData: false,
  });
  return {
    channelId,
    roomName: room,
    token: await token.toJwt(),
    expiresAt: new Date(Date.now() + config.roomTokenTtlSeconds * 1000).toISOString(),
    canPublish: canTalk,
    canSubscribe: canListen,
  };
}

/// Tells every joined client that the configuration it holds is stale.
///
/// Only a version travels, not the configuration: REST stays the single source
/// of truth, and a client that missed one message converges on the next.
export async function broadcastConfiguration({ productionId, channelIds, version }) {
  const payload = new TextEncoder().encode(JSON.stringify({
    type: 'configuration', version, productionId,
  }));

  // Bounded: an unreachable LiveKit must not hold a REST request open. The push
  // is an optimisation — the client re-reads configuration on its own schedule
  // too — so a slow room is worth abandoning, not waiting for.
  const results = await Promise.allSettled(channelIds.map((channelId) => Promise.race([
    roomService().sendData(roomName(productionId, channelId), payload, 0),
    new Promise((_, reject) => setTimeout(
      () => reject(new Error('timeout')), BROADCAST_TIMEOUT_MS,
    ).unref()),
  ])));

  const failures = results.filter((r) => r.status === 'rejected').length;
  // A room nobody has joined rejects, and that is not an error worth waking
  // anyone for — but a total failure means the push is not arriving at all.
  if (failures === results.length && results.length > 0) {
    log.warn('konfigurációs push egyetlen szobába sem ért el', { productionId, version });
  }
}

export async function listParticipants(room) {
  try {
    return await roomService().listParticipants(room);
  } catch {
    return [];
  }
}

export async function removeParticipant(room, identity) {
  await roomService().removeParticipant(room, identity);
}
