#!/usr/bin/env node
// Az éles szerver kezelése a szerveren belülről: produkció, első admin,
// felhasználók.
//
// Miért kell: az API-n NINCS produkció-létrehozás és NINCS regisztráció (a
// meghívó beváltásához is be kell már jelentkezni). Egy friss éles szerver
// ezért üres és használhatatlan, amíg valaki ezt le nem futtatja. A konténerben
// nincs `sqlite3`, tehát a README régi kézi útja ott nem járható.
//
// Konténerben (a deployment/ mappából):
//   docker compose exec flycom-api node scripts/admin.js setup \
//     --email admin@flyabove.hu --name "Belián" --production "Flycom"
//   docker compose exec flycom-api node scripts/admin.js add-user \
//     --email kamera@flyabove.hu --name "Kamera 1" --production "Flycom" --role operator
//   docker compose exec flycom-api node scripts/admin.js list
//
// A jelszót a terminálról kéri, visszhang nélkül (vagy a stdin első sorából, ha
// csővezetékből jön). Parancssorban SOHA: azt a shell előzménye és a
// folyamatlista is olvassa.

import readline from 'node:readline';
import {
  db, findUserByEmail, createUser, createProduction, addMember,
  createChannel, channelsForProduction, setPermission,
} from '../src/db.js';
import { hashPassword } from '../src/passwords.js';

// Ugyanaz a négy vonal, amivel a demó is indul, csak fix azonosítók nélkül.
const DEFAULT_CHANNELS = [
  { name: 'Mindenki', detail: 'Teljes produkció', colorHex: '5B8CFF', role: 'line', duckDecibels: 12, defaultListening: true },
  { name: 'Kamera', detail: 'Kameraoperátorok', colorHex: '31C48D', role: 'line', duckDecibels: 12, defaultListening: true },
  { name: 'Rendező', detail: 'Rendezői vonal', colorHex: 'F59E0B', role: 'priority', duckDecibels: 12, defaultListening: false },
  // Az adáshangra senki nem beszél: csak hallgatható.
  { name: 'Program', detail: 'Adáshang', colorHex: '4FD6D2', role: 'program', duckDecibels: 15, defaultListening: true, listenOnly: true },
];

const ROLES = ['admin', 'supervisor', 'operator'];

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = {};
  for (let i = 0; i < rest.length; i++) {
    const key = rest[i];
    if (!key.startsWith('--')) fail(`Váratlan argumentum: ${key}`);
    const value = rest[i + 1];
    if (value === undefined || value.startsWith('--')) fail(`A ${key} kapcsolóhoz érték kell.`);
    options[key.slice(2)] = value;
    i++;
  }
  return { command, options };
}

function fail(message) {
  console.error(`Hiba: ${message}`);
  process.exit(1);
}

function need(options, key) {
  const value = options[key]?.trim();
  if (!value) fail(`Hiányzik: --${key}`);
  return value;
}

async function readPassword(label) {
  if (!process.stdin.isTTY) {
    // Csővezeték: az első sor a jelszó.
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    return Buffer.concat(chunks).toString('utf8').split('\n')[0];
  }
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  process.stdout.write(`${label}: `);
  rl._writeToOutput = () => {};
  const answer = await new Promise((resolve) => rl.question('', resolve));
  rl.close();
  process.stdout.write('\n');
  return answer;
}

async function newPassword() {
  const first = await readPassword('Jelszó');
  if (!first || first.length < 8) fail('A jelszó legalább 8 karakter legyen.');
  if (process.stdin.isTTY) {
    const second = await readPassword('Jelszó újra');
    if (first !== second) fail('A két jelszó nem egyezik.');
  }
  return first;
}

function findProductionByName(name) {
  const rows = db.prepare('SELECT id, name FROM productions WHERE name = ?').all(name);
  if (rows.length > 1) fail(`Több „${name}” nevű produkció van — nevezd át az egyiket.`);
  return rows[0] ?? null;
}

async function ensureUser(options) {
  const email = need(options, 'email').toLowerCase();
  const existing = findUserByEmail(email);
  if (existing) {
    console.log(`A felhasználó már létezik, a jelszava nem változik: ${email}`);
    return existing;
  }
  const displayName = need(options, 'name');
  const passwordHash = await hashPassword(await newPassword());
  const user = createUser({ email, displayName, passwordHash });
  console.log(`Felhasználó létrehozva: ${email}`);
  return user;
}

function grantAll(productionId, userId, { includeTalk = true } = {}) {
  for (const channel of channelsForProduction(productionId)) {
    if (channel.is_private) continue;
    const listenOnly = channel.role === 'program';
    setPermission({ channelId: channel.id, userId, canTalk: includeTalk && !listenOnly, canListen: true });
  }
}

async function setup(options) {
  const productionName = need(options, 'production');
  if (findProductionByName(productionName)) {
    fail(`Már van „${productionName}” nevű produkció. Új felhasználóhoz: add-user.`);
  }
  const user = await ensureUser(options);
  const production = db.transaction(() => {
    const created = createProduction({ name: productionName, ownerId: user.id, ownerRole: 'admin' });
    DEFAULT_CHANNELS.forEach((channel, position) => {
      createChannel({ productionId: created.id, position, ...channel });
    });
    grantAll(created.id, user.id);
    return created;
  })();
  console.log(`Produkció létrehozva: „${production.name}” (${DEFAULT_CHANNELS.length} vonal), admin: ${user.email}`);
}

async function addUser(options) {
  const productionName = need(options, 'production');
  const production = findProductionByName(productionName);
  if (!production) fail(`Nincs „${productionName}” nevű produkció.`);
  const role = options.role ?? 'operator';
  if (!ROLES.includes(role)) fail(`A szerep egyike legyen: ${ROLES.join(', ')}`);
  const user = await ensureUser(options);
  db.transaction(() => {
    addMember({ productionId: production.id, userId: user.id, role });
    grantAll(production.id, user.id);
  })();
  console.log(`${user.email} → „${production.name}”, szerep: ${role}`);
}

function list() {
  const productions = db.prepare('SELECT id, name FROM productions ORDER BY created_at').all();
  if (productions.length === 0) {
    console.log('Nincs produkció. Első lépés: setup.');
    return;
  }
  for (const production of productions) {
    console.log(`\n${production.name}`);
    const members = db.prepare(`
      SELECT u.email, u.display_name, m.role FROM memberships m
      JOIN users u ON u.id = m.user_id WHERE m.production_id = ? ORDER BY m.role, u.email
    `).all(production.id);
    for (const m of members) console.log(`  ${m.role.padEnd(10)} ${m.email}  (${m.display_name})`);
  }
}

const { command, options } = parseArgs(process.argv.slice(2));
switch (command) {
  case 'setup': await setup(options); break;
  case 'add-user': await addUser(options); break;
  case 'list': list(); break;
  default:
    console.log('Használat: node scripts/admin.js setup|add-user|list [kapcsolók] — részletek a fájl fejlécében.');
    process.exit(command ? 1 : 0);
}
