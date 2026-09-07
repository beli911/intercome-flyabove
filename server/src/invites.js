import crypto from 'node:crypto';
import * as db from './db.js';

/// The alphabet is deliberately incomplete: no `O`, `I`, `L`, `0` or `1`.
///
/// These codes get read out over talkback and typed in the dark. **This string
/// must match `InviteCode.swift` character for character** — a code the server
/// issues but the client filters out is a code nobody can enter.
export const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

/// `crypto.randomInt`, not `Math.random`: an invite is an access grant, and a
/// predictable one is a guessable way onto the production's lines.
export function generateInviteCode(length = 6) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    let code = '';
    for (let i = 0; i < length; i += 1) {
      code += CODE_ALPHABET[crypto.randomInt(CODE_ALPHABET.length)];
    }
    if (!db.findInvite(code)) return code;
  }
  throw new Error('nem sikerült szabad meghívókódot találni');
}
