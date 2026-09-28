# Flycom teljes biztonsági és megbízhatósági audit

**Dátum:** 2026-09-07  
**Vizsgált ág/commit:** `feature/m1-livekit-auth`, `1d751ef`  
**Audit jellege:** forráskód-ellenőrzés, unit/integrációs teszt, Thread Sanitizer,
Release build, API-abúzus, időzítési és erőforrás-terhelési próbák  
**Összegzés:** az alkalmazás ígéretes és a kliens állapotgépének tesztfedése jó,
de jelen állapotában **nem tekinthető éles, biztonságkritikus intercomnak**. Két P0
és több P1 hiba lezárása, majd két fizikai eszközös elfogadási teszt szükséges.

> „Atom biztos” szoftvert nem lehet bizonyítani. A reális cél: a veszélyes
> állapotok fail-closed kezelése, szerveroldali kényszerítés, mérhető SLO-k,
> ismételhető CI és dokumentált maradék kockázat.

## Vezetői összefoglaló

| Szint | Darab | Jelentés |
| --- | ---: | --- |
| P0 | 2 | jogosulatlan hangküldés vagy azonnali visszavonás hiánya |
| P1 | 9 | DoS, kliens-crash, versenyhelyzet vagy kiadási kontroll hiánya |
| P2 | 8 | hardening, hibaszerződés, üzemeltetési és tesztelési hiány |

Legfontosabb megállapítások:

1. A Talk-jog visszavonása csak kliensüzenet. A már kiadott, egyórás LiveKit
   token továbbra is `canPublish=true`; módosított vagy offline kliens tovább
   adhat hangot.
2. A logout csak a refresh tokeneket vonja vissza. A már kiadott REST access
   token a teljes, jelenleg 15 perces élettartama alatt továbbra is 200-as
   választ kap.
3. A szinkron `scryptSync` jelszó-ellenőrzés blokkolja az egész Node event
   loopot. Húsz párhuzamos hibás login közben a `/health` 1225,9 ms-ra lassult.
4. Ismert és ismeretlen e-mailre a válasz törzse azonos, de az időzítés nem:
   65,9 ms kontra 1,0 ms átlag, vagyis kb. 65,7-szeres különbség. Ez
   felhasználó-felderítési oldalcsatorna.
5. A teljes iOS suite-ból 127 teszt átment, 9 LiveKit-integrációs teszt
   elbukott. A szerver `ws://192.168.55.199:7880` címet adott vissza, amelyet a
   szimulátor nem ért el. Ez környezeti címzési hiba, de ettől a teljes
   rendszer elfogadási kapuja piros.
6. A teljes új `server/` könyvtár auditkor Git által nem követett volt, és nem
   volt `.github` workflow. Az éles backend és a minőségkapu így nem része a
   reprodukálható repository-állapotnak.

## Bizonyított P0 hibák

### P0-1 — A visszavont Talk-jog nem állítja le szerveroldalon a publikálást

**Bizonyíték:** adminisztrátori permission-visszavonás előtt kiadott LiveKit JWT
dekódolva a változtatás után is `video.canPublish=true`; az újonnan kért grant
már helyesen `false`. A `PATCH` csak adatbázist ír és konfigurációs adatüzenetet
küld. Nem hív `RoomServiceClient.updateParticipant(...)` vagy eltávolítást.

**Hatás:** rosszhiszemű, módosított, lefagyott vagy a push üzenetet elvesztő
kliens a jogosultság elvétele után is beszélhet. Intercomnál ez adatvédelmi és
üzembiztonsági főhiba.

**Javítás:** permission-visszavonás tranzakciójában, minden érintett aktív
szobában azonnal szerveroldali `updateParticipant` hívás `canPublish=false`
értékkel. Ennek automatikusan le kell publikálnia az aktív trackeket. Ha a
LiveKit-hívás nem igazolható, fail-closed módon az érintett résztvevőt el kell
távolítani, a REST válasz pedig ne állítsa, hogy a művelet teljesen sikerült.
LiveKit Cloudon a permission update a korábbi tokent is visszavonja; self-hosted
környezetben rövid, 5–10 perces room-token TTL szükséges második védelmi
rétegként. A kliens push maradjon gyors UX-mechanizmus, ne biztonsági határ.

**Kötelező regressziós teszt:** egy fizikai kliens folyamatosan publikál;
admin visszavonja a Talk-jogot; a LiveKit szerver által látott track rövid,
előre rögzített határidőn belül eltűnik, és a régi tokennel reconnect sem ad
publish jogot.

### P0-2 — Logout után az access token tovább él

**Bizonyíték:** login → védett kérés 200 → logout 204 → ugyanazzal az access
tokennel védett kérés ismét 200. A logout csak `revokeAllForUser` műveletet
hív a refresh tokenekre; `verifyAccessToken` kizárólag JWT-aláírást és időt
ellenőriz.

**Hatás:** elveszett vagy ellopott készülékről a kijelentkezés nem vonja vissza
azonnal az aktív REST-hozzáférést. A dokumentáció „minden munkamenetet
megszüntet” állítása így félrevezető.

**Javítási lehetőségek:**

- hozzáférési tokenbe session/family azonosító, a szerveren rövid életű
  revocation/session-version ellenőrzés;
- felhasználói `token_version` mező, amelyet logout-all növel;
- 2–5 perces access TTL kiegészítő kárkorlátozásként.

Az access- és LiveKit-session visszavonását egy közös, auditálható
„terminate sessions” műveletben érdemes kezelni.

## P1 hibák

### P1-1 — Login időzítési oldalcsatorna

Az ismeretlen e-mail kihagyja a költséges hash-ellenőrzést a
`Boolean(user) && verifyPassword(...)` rövidzár miatt.

**Mérés (izolált, in-memory szerver):**

- létező e-mail + rossz jelszó: átlag 65,9 ms, minimum 60,2 ms;
- ismeretlen e-mail: átlag 1,0 ms, minimum 0,6 ms;
- arány: kb. 65,7×.

**Javítás:** ismeretlen felhasználónál ugyanazzal a paraméterezéssel előállított,
fix dummy scrypt hash ellenőrzése; azonos rate-limit út; statisztikai
regressziós teszt több száz mintával. A válasz mesterséges `sleep`-pel történő
kiegyenlítése önmagában nem elég stabil.

### P1-2 — Szinkron jelszóhash miatt alkalmazásszintű DoS

`crypto.scryptSync` fut a fő Node szálon. Húsz párhuzamos, hibás, ismert
fiókra küldött login alatt a `/health` 1225,9 ms késleltetést mutatott, a teljes
login hullám 1316,9 ms volt. A flood limit csak a drága hash után tud teljes
védelmet adni.

**Javítás:** aszinkron `crypto.scrypt`, korlátozott worker pool/semaphore,
edge rate limit a hash előtt, felhasználó- és IP-alapú keret, terheléses teszt.
A health/readiness végpontnak külön event-loop lag riasztást kell adnia.

### P1-3 — Ismételt channel ID-k JWT- és válasz-amplifikációt okoznak

Egy 1000 azonos, jogos csatornaazonosítót tartalmazó, kb. 39 KB-os hitelesített
kérés 1000 tokent adott vissza: 692 045 bájt, 38,2 ms. A végpont nem deduplikál
és nincs műveletszám-limitje vagy saját rate limitje.

**Javítás:** request elején `Set`, duplikátum esetén 400 vagy determinisztikus
deduplikálás; maximum csatornaszám (a termék reális felső korlátja, például
32/64); user+production rate limit; válaszméret- és tokenmintási metrika.

### P1-4 — Duplikált szerverválasz kontrollálatlan iOS crasht okozhat

Két hely használ `Dictionary(uniqueKeysWithValues:)`-t validálatlan hálózati
adaton:

- `LiveKitIntercomTransport.connect` a grantokra;
- `IntercomViewModel.applyUpdatedChannels` a csatornákra.

A szerver bizonyítottan képes duplikált grantot előállítani. A kliens ilyenkor
trap-pel leáll.

**Javítás:** válaszséma-validátor; duplikátumnál kontrollált
`invalidServerResponse` hiba, eseménynapló és fail-closed bontás. Ne az utolsó
elemet fogadja el csendben.

### P1-5 — QR-kamera indítás/leállítás versenyez

A Release build és a Thread Sanitizer build egyaránt jelezte a nem `Sendable`
`AVCaptureSession` háttér-closure capture-t. A `startRunning` globális queue-n,
a `stopRunning` a main queue-n fut. A kód kommentje szerint egyetlen háttér
queue kezeli, de ez nem igaz.

**Hatás:** gyors sheet nyitás-zárás, QR-találat vagy kameraállapot-váltás közben
fagyás, figyelmeztetés vagy crash fizikai eszközön.

**Javítás:** saját soros `sessionQueue`; konfigurálás, start és stop mind ezen;
egy generáció/lifecycle flag; main actorra csak UI callback. Fizikai kamerás
stresszteszt szükséges, a szimulátor ezt nem bizonyítja.

### P1-6 — Konfigurációfrissítések sorrendje nincs védve

A LiveKit esemény verziót hoz, de az `AppEnvironment` eldobja. Minden esemény
új, strukturálatlan `Task`-ot indít, a REST kérések párhuzamosan futhatnak, és
egy régebbi válasz egy újabb után alkalmazható.

**Hatás:** permission-visszavonás átmenetileg visszacsinálható régi válasszal.
Ez a P0-1 hibával együtt súlyos.

**Javítás:** single-flight konfiguráció-reconciler, monoton
`lastAppliedVersion`, generáció/cancellation, és csak az aktuális
production+session válasza alkalmazható. Késleltethető spy-val determinisztikus
out-of-order teszt kell.

### P1-7 — Grant-megújítás nem törli a szerver által kihagyott grantokat

A `renewGrants` csak felülírja a visszaérkezett elemeket. A válaszból hiányzó,
közben visszavont grant a lokális dictionaryben marad, és recovery használhatja.

**Javítás:** teljes új map validálása, majd atomikus csere; az eltűnt grantokhoz
tartozó sessionök azonnali lezárása; generation guard minden await után.

### P1-8 — Ducking műveletek egymást felülírhatják

Talk- és remote-speaking változáskor külön strukturálatlan task indul. Egy task
egyszer olvassa ki a bemenetet, majd több `await`-en keresztül írja a
csatornákat. Régi és új task összefonódhat, így egy későbbi csatornára a régi
hangerő kerülhet utoljára.

**Javítás:** soros, generációs desired/applied reconciler; minden commit előtt
generation check; felfüggeszthető transport spy-val minden interleaving
determinista tesztje.

### P1-9 — Nincs reprodukálható CI és a backend nincs verziókezelve

Az audit pillanatában:

- `.github/` nem létezett;
- a teljes `server/` könyvtár `?? server/` állapotú volt;
- több app-, script- és docs-fájl módosított, nem commitolt állapotban volt.

**Javítás:** a backend ellenőrzött commitba; PR branch protection; kötelező
Release build, server teszt, Swift unit, integráció, TSAN, lint és audit job;
`set -o pipefail`; xcresult és log artifact; integrációs teszt kihagyása legyen
hiba a dedikált jobban. Titkok csak GitHub Environment/secret store-ból.

## P2 hardening és szerződéshibák

### P2-1 — Hibás éles konfigurációt elfogad

Hat külön subprocess próbában mindegyik `status=0` eredményt adott:
`PORT=abc`, `ACCESS_TOKEN_TTL=-1`, `REFRESH_TOKEN_TTL=0`,
`ROOM_TOKEN_TTL=Infinity`, `LOGIN_ATTEMPTS=0`, `LOGIN_WINDOW=NaN`.

Minden numerikus értékre finite, egész és dokumentált tartományellenőrzés kell;
hibánál boot-time kilépés. A host/bind, adatbázis elérhetőség és writable
ellenőrzése is legyen readiness előfeltétel.

### P2-2 — Hibás JSON és input validáció 500-at ad

- szintaktikailag hibás JSON: 500;
- nem numerikus `expiresInMinutes`: 500;
- negatív, végtelen vagy extrém meghívó-élettartam nincs korrektül korlátozva.

**Javítás:** központi schema-validáció; body-parser `SyntaxError` → 400,
túlméretes body → 413; meghívó TTL bounded integer; minden error code kerüljön
az API-szerződésbe és tesztbe.

### P2-3 — Logger redaction megkerülhető

Tesztben a `token` és `refreshToken` rejtve maradt, de kiszivárgott:
`Authorization: Bearer SECRET-B`, `access_token: SECRET-C`, valamint öt szintnél
mélyebb token. A kulcslista case- és elnevezésérzékeny; depth cutoff után az
objektumot változatlanul adja vissza.

**Javítás:** normalizált kulcs (`lowercase`, `_`/`-` eltávolítás), érzékeny
értékminták védelme, depth cutoffnál `[truncated]`, allowlistelt mezők és
adversarial logger tesztek. JWT-t és Authorization headert soha ne logoljon.

### P2-4 — A meghívó link és QR parser túl engedékeny

Az app custom URL scheme-et használ, Associated Domains entitlement/AASA nincs.
Az `InviteCode.from(url:)` bármely nem custom URL utolsó path elemét elfogadja,
így például idegen HTTPS host, `file:` vagy más custom scheme is kódforrás.

**Javítás:** HTTPS Universal Link, AASA és `applinks:` entitlement; kizárólag
engedélyezett scheme+host+pontosan rögzített `/invite/<code>` path; minden
paraméter validálása. A custom scheme legfeljebb fallback legyen. A kód bearer
titok, ezért proxy access logban a pathot maszkolni kell.

### P2-5 — A diagnosztikai script jelszót kér a parancssorban

`scripts/check-api.mjs --password x` shell historyban és process listában
látható. Jelszó érkezzen rejtett stdinről vagy dedikált environment secretből;
a használati példa se tartalmazzon parancssori jelszót.

### P2-6 — Biztonsági HTTP headerek hiányoznak

Az izolált szerver válaszából hiányzott többek között a
`X-Content-Type-Options`. A HSTS tipikusan a TLS reverse proxy felelőssége, de
ezt deployment teszttel kell bizonyítani. Használható Helmet vagy szűk saját
middleware, CORS pedig maradjon tiltott/alapértelmezett, amíg böngészős kliens
nincs.

### P2-7 — Direkt publikus bind és proxy-bizalom üzemeltetési kockázat

A Node folyamat mindig `0.0.0.0`-ra bindol. Ha a port kívülről elérhető, a
reverse proxy TLS- és edge-védelme megkerülhető. `HOST` beállítás legyen,
élesben alapértelmezésként loopback/private socket; firewall bizonyíték;
`TRUST_PROXY` csak ismert egyhopos proxyval. Több API instance esetén az
in-memory limiter és SQLite nem konzisztens; shared rate-limit store és HA
adatbázis kell.

### P2-8 — Lefedetlen elfogadási területek

Nincs UI test target, fizikai kamera-stressz, két valódi iPhone közötti hang-,
route-, Bluetooth-, telefonhívás-, lock-screen-, hálózatváltás- és 30–60 perces
soak bizonyíték. Egy single-instance SQLite/API architektúra tervezett kiesési
pont; magas rendelkezésre állású produkciónál ezt külön kezelni kell.

## Futtatási eredmények

| Vizsgálat | Eredmény |
| --- | --- |
| `server/npm test` | 22/22 sikeres |
| `server/npm audit --omit=dev` | 0 ismert vulnerability |
| `dev-server/npm audit --omit=dev` | 0 ismert vulnerability |
| Node forrás syntax check | sikeres |
| teljes iOS `xcodebuild test` | 136 összes; 127 sikeres; 9 LiveKit-hiba; 0 skip |
| Thread Sanitizer, integráció nélkül | 123/123 sikeres; TSAN runtime hiba nem volt |
| Release, optimalizált szimulátor build | sikeres; QR scanner Sendable warning |
| 30× ViewModel stressz | nem értékelhető: külső párhuzamos Xcode-folyamat leállította a szimulátort |
| access token logout utáni replay | 200 — hiba bizonyítva |
| régi LiveKit grant permission revoke után | `canPublish=true` — hiba bizonyítva |
| rossz login ×20 közben `/health` | 1225,9 ms |
| ismert/rossz vs. ismeretlen login | 65,9 ms vs. 1,0 ms |
| 1000 duplikált realtime token kérés | 1000 grant, 692 045 byte, 38,2 ms |
| malformed JSON / invalid invite TTL | 500 / 500 |

Az `npm audit = 0` csak az adatbázisában ismert dependency sebezhetőségekről
szól; a fenti logikai, jogosultsági és rendelkezésre állási hibákat nem zárja ki.

## Mi működik jól

- A refresh token egyszer használható, hash-elve tárolt és reuse esetén a
  token family visszavonódik.
- A REST production membership és admin jogosultság szerveroldali.
- Jog nélküli csatornára új LiveKit grant nem készül.
- Az iOS API base URL Release módban HTTPS-t követel.
- A Keychain `AfterFirstUnlockThisDeviceOnly` használata a háttér-audio és a
  nem migrálható credential között tudatos kompromisszum.
- A mikrofon-leállítási fail-safe és a talk-worker generációs védelem unit
  tesztekkel fedett.
- A Thread Sanitizerrel futtatott 123 lokális teszt zöld.
- A Release build elkészül; a LiveKit Swift SDK 2.16.0-ra rögzített.

## Kötelező javítási és elfogadási sorrend

### 1. kapu — jogosultság és session revocation

- P0-1 és P0-2 javítva;
- rosszhiszemű klienssel szerveroldali negatív teszt;
- permission revoke és logout audit-esemény;
- régi tokenes reconnect teszt Cloudon és a tényleges célkörnyezetben.

### 2. kapu — crash és concurrency

- duplikált input kontrollált hibává alakítva;
- konfiguráció-, grant- és ducking reconciler soros/generációs;
- QR session saját serial queue-n;
- 30× stressz, TSAN és lehetőség szerint ASAN zöld, külső tesztfolyamat nélkül.

### 3. kapu — API/DoS hardening

- async scrypt + dummy hash + concurrency cap;
- realtime request darabszám/deduplikáció/rate limit;
- schema-validáció és pontos 400/413 válaszok;
- boot-time config range validation;
- logger és security-header regressziók.

### 4. kapu — reproducibility és deployment

- `server/` verziókezelve;
- kötelező CI valóban lefutott legalább egy PR-en;
- titokkezelés, TLS/WSS, proxy/firewall, backup/restore és rollback próbálva;
- staging környezet címei stabil DNS-nevek, nem automatikusan választott LAN IP-k.

### 5. kapu — fizikai elfogadás

Legalább két külön hálózaton lévő fizikai iPhone-nal:

- 1000 gyors PTT press/release, latch váltás közben is;
- Talk All, permission revoke nyitott mikrofonnal;
- Wi‑Fi ↔ mobilnet, 20% packet loss, magas jitter, szerver restart;
- AirPods/Bluetooth/wired route change és kihúzás adás közben;
- bejövő telefonhívás, Siri, Control Center, lock/unlock, háttér/foreground;
- 60 perces soak, memória/CPU/energia/hő és nyitott room/track számlálás;
- hangszivárgás teszt: egy csatorna hangja semmilyen körülmények között ne
  jelenjen meg másik csatornán.

Csak mind az öt kapu után indokolt éles pilot. A pilotban feature flag,
gyors session-kill, szerveroldali mute/evict, incidensnapló és hagyományos
backup intercom szükséges.

## Reprodukálhatóság és auditkorlátok

- Az audit nem módosította az alkalmazáskódot, nem commitolt és nem pusholt.
- A repository már az audit előtt dirty volt; ezeket a változásokat érintetlenül
  hagytam.
- Egy másik, párhuzamos Xcode/Claude folyamat futott és szimulátorokat állított
  le. Emiatt a külön 30× stressz eredménye nem használható.
- A kilenc LiveKit-integrációs bukásnál a REST elérhető volt, de a válaszban
  kapott `ws://192.168.55.199:7880` cím nem. Ez nem bizonyít médiahibát, viszont
  azt igen, hogy a jelenlegi integrációs környezet nem stabil/reprodukálható.
- Statikus audit és szimulátor nem helyettesíti a fizikai RF/audio/route tesztet,
  külső penetrációs tesztet vagy infrastruktúra-auditot.

## Elsődleges szakmai hivatkozások

- LiveKit token lifecycle, revocation és permission update:
  <https://docs.livekit.io/home/server/generating-tokens>
- LiveKit participant permission update, publish track automatikus
  unpublish: <https://docs.livekit.io/intro/basics/rooms-participants-tracks/participants/>
- LiveKit JS `RoomServiceClient.updateParticipant`:
  <https://docs.livekit.io/reference/server-sdk-js/classes/RoomServiceClient.html>
- Apple `AVCaptureSession`: a `startRunning()` blokkol, soros queue javasolt:
  <https://developer.apple.com/documentation/avfoundation/avcapturesession>
- Apple Universal Links és Associated Domains:
  <https://developer.apple.com/documentation/Xcode/supporting-associated-domains>
- OWASP API4:2023 — Unrestricted Resource Consumption:
  <https://owasp.org/API-Security/editions/2023/en/0xa4-unrestricted-resource-consumption/>
