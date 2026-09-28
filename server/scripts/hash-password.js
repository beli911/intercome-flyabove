#!/usr/bin/env node
// Hashes a password for manual insertion, without the password ever appearing
// in a shell history or a log line.
//
//   npm run hash            reads from the terminal, no echo
//   npm run hash -- <file>  reads the first line of a file

import fs from 'node:fs';
import readline from 'node:readline';
import { hashPassword } from '../src/passwords.js';

const path = process.argv[2];

if (path) {
  const password = fs.readFileSync(path, 'utf8').split('\n')[0];
  if (!password) {
    console.error('A fájl első sora üres.');
    process.exit(1);
  }
  console.log(await hashPassword(password));
} else {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  process.stdout.write('Jelszó: ');
  rl.question('', async (password) => {
    rl.close();
    process.stdout.write('\n');
    if (!password) {
      console.error('Üres jelszó.');
      process.exit(1);
    }
    console.log(await hashPassword(password));
  });
  // Suppress the echo, so the password is not left on screen or in a scrollback.
  rl.output.write = (chunk, encoding, callback) => {
    if (rl.stdoutMuted && typeof chunk === 'string' && !chunk.includes('Jelszó')) return callback?.();
    return process.stdout.constructor.prototype.write.call(process.stdout, chunk, encoding, callback);
  };
  rl.stdoutMuted = true;
}
