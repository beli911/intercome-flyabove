# Flycom API

A Flycom backendje: hitelesítés, produkciók, csatornák, jogosultságok,
meghívók, privát hívások, és a LiveKit szobatokenek kiadása.

A média nem ezen megy át. Ez a szerver **azt mondja meg, ki mit hallhat és min
beszélhet**, a hang a LiveKittel közvetlenül utazik. Ezért egy pillanatra
kieső API nem szakítja meg a folyó beszélgetést — csak új csatlakozás nem
történhet, amíg vissza nem jön.

## Gyors indítás fejlesztéshez

```bash
cd server && npm install
npm run dev
```

Demó fiókok: `operator@flyabove.hu` és `kamera@flyabove.hu`, jelszó `flyabove`.
A `dev` mód memóriában dolgozik, tehát újraindításkor tiszta lappal indul.

Mellé kell egy LiveKit is:

```bash
livekit-server --dev --bind 0.0.0.0
```

## Tesztek

```bash
npm test
```

22 teszt. Nem a boldog utat fedik, hanem azt, ami csendben romlik el: egy
kiszivárgott refresh token, egy csak a felületen létező szerepellenőrzés, egy
publish jogot adó szobatoken. Ezek egyike sem hibaüzenetként jelentkezik —
hanem úgy, hogy valaki olyan vonalon van, ahol nem kellene lennie.

Mind a nyolc védelmet negatív kontroll igazolja: kivéve a védelmet, a hozzá
tartozó teszt elbukik.

Szerződés-ellenőrzés futó szerver ellen:

```bash
node ../scripts/check-api.mjs --base http://localhost:8080/ \
  --email operator@flyabove.hu --password flyabove --peer-email kamera@flyabove.hu
```

## Éles üzembe helyezés

### 1. LiveKit Cloud projekt

A [cloud.livekit.io](https://cloud.livekit.io) felületén **Settings → Keys →
Create key**. Három adat kell:

| Adat | Hol van | Példa |
| --- | --- | --- |
| `LIVEKIT_URL` | a projekt főoldalán | `wss://flycom-xxxx.livekit.cloud` |
| `LIVEKIT_API_KEY` | Settings → Keys | `APIxxxxxxxx` |
| `LIVEKIT_API_SECRET` | **csak létrehozáskor látszik** | hosszú karakterlánc |

A titkot a felület egyszer mutatja meg. Ha elveszett, új kulcsot kell
generálni; a régi visszavonásáig a kiadott szobatokenek még érvényesek.

A LiveKit Cloud adja a TURN-t és a TLS-t is, ezért zárt vendéghálózaton is
kijut a média — ez az a rész, amit saját LiveKit mellett külön kellene
üzemeltetni.

### 2. Titkok

```bash
npm run secret        # JWT_SECRET, 48 bájt
```

A `JWT_SECRET` cseréje **minden munkamenetet érvénytelenít**: mindenkinek újra
be kell jelentkeznie. Ez a visszavonás vészfékje, nem rutinművelet.

Másold a `.env.example`-t `.env`-be, töltsd ki, és `chmod 600`. Éles gépen ez a
fájl ne a repositoryban legyen.

### 3. Konfiguráció-ellenőrzés

`NODE_ENV=production` mellett a szerver **elutasítja az indulást**, ha
hiányzik a `JWT_SECRET` (vagy 32 karakternél rövidebb), ha nincs LiveKit
kulcs, vagy ha a `LIVEKIT_URL` nem `wss://`. Ez szándékos: egy alapértelmezett
aláíró titokkal futó szerver működik, és pont ezért nem tűnik fel senkinek,
hogy bárki saját munkamenetet gyárthat magának.

### 4. Futtatás systemd alatt

```ini
[Unit]
Description=Flycom API
After=network.target

[Service]
Type=simple
User=flycom
WorkingDirectory=/opt/flycom/server
EnvironmentFile=/etc/flycom/env
ExecStart=/usr/bin/node src/index.js
Restart=always
RestartSec=2
StateDirectory=flycom
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/flycom

[Install]
WantedBy=multi-user.target
```

A `SIGTERM`-re a szerver befejezi a folyamatban lévő kéréseket, majd kilép.

### 5. TLS

A szerver HTTP-t beszél; a TLS a fordított proxy dolga (Caddy, nginx). Caddyval:

```
api.intercom.flyabove.hu {
    reverse_proxy 127.0.0.1:8080
}
```

Proxy mögött `TRUST_PROXY=1` kell, különben a bejelentkezési limit a proxy
címét fojtja meg a hívóé helyett — vagyis egyetlen rossz jelszó mindenkit
kizárna.

Release buildben a kliens elutasítja a sima HTTP-t, tehát TLS nélkül az app
el sem indul a szerverhez.

### 6. Mentés

Az adatbázis egyetlen SQLite fájl. Menteni futás közben is biztonságos:

```bash
sqlite3 /var/lib/flycom/flycom.db ".backup '/var/backups/flycom-$(date +%F).db'"
```

Fájlmásolással **ne** mentsd: WAL módban a `.db` önmagában nem konzisztens.

## Fiókok felvétele

Nincs önkiszolgáló regisztráció — egy intercomra nem lehet bejelentkezni annak,
akit senki nem hívott meg. Két út van:

1. **Meghívó**: a supervisor vagy admin kiad egy kódot az appból, a kolléga
   beírja vagy beolvassa a QR-t.
2. **Kézzel**, első adminnak:

```bash
npm run hash                              # jelszó bekérése, echo nélkül
sqlite3 /var/lib/flycom/flycom.db
```

```sql
INSERT INTO users (id, email, display_name, password_hash, created_at)
VALUES (lower(hex(randomblob(4))||'-'||hex(randomblob(2))||'-4'||substr(hex(randomblob(2)),2)||'-a'||substr(hex(randomblob(2)),2)||'-'||hex(randomblob(6))),
        'admin@flyabove.hu', 'Admin', '<a hash>', datetime('now'));
```

A jelszó soha ne kerüljön a parancssorba: a shell előzménye és a
folyamatlista is olvassa.

## Skálázás

Egy példány, egy SQLite fájl. Néhány tucat fős produkcióhoz ez bőven elég: a
terhelés bejelentkezésekből és óránkénti tokenmegújításokból áll, nem
folyamatos forgalomból.

Két dolog akadályozza a több példányt, és mindkettő egy-egy fájl:

- `src/db.js` — minden SQL itt van, Postgresre ez az egy modul cserélendő.
- `src/ratelimit.js` — memóriában számol, megosztott tárolóra kellene tenni.

Ezt itt érdemes leírni, nem adás közben kideríteni.

## Naplózás

Strukturált JSON sorok. A `docs/SECURITY.md` tiltja a hang, a tokenek, a
TURN-hitelesítők és a hosszú távú IP-megőrzés naplózását — a redakció a
`src/log.js`-ben, központilag történik, mert egy tetszőleges objektumot fogadó
naplózónak előbb-utóbb valaki sietve átad egy tokent.
