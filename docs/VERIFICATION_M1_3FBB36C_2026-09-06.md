# M1 újraellenőrzési jelentés – `3fbb36c` – 2026-09-06

## Hatókör

Az ellenőrzés a `feature/m1-livekit-auth` branch `3fbb36c55809e06c9f3602b888de34ac9fb7f0d7`
commitjára terjedt ki. A vizsgálat célja annak ellenőrzése volt, hogy a korábbi
`docs/REVIEW_M1_2026-09-06.md` jelentés megállapításait a következő két commit
valóban lezárta-e:

- `d4aa4a8` – fejlesztői backend, LiveKit integrációs tesztek és eseményjavítások;
- `3fbb36c` – a review P1–P3 javításai és regressziós tesztek.

Az ellenőrzés során a forráskódot nem módosítottam. Statikus kódvizsgálatot,
teljes iOS szimulátoros tesztfutást, ismételt célzott PTT tesztet, élő helyi
REST + LiveKit integrációs futást és Node-függőségi auditot végeztem.

## Vezetői összefoglaló

Az M1 jelentősen előrelépett: a helyi REST API és LiveKit médiaszerver ellen a
hat integrációs teszt mind sikerült, az auth/Keychain/bootstrap javítások is
működnek. A korábbi hibák többségére valódi kódjavítás érkezett.

Az állapot mégsem minősíthető zöldnek vagy produkcióképesnek. A teljes
tesztcsomag 44 tesztből 43 sikeres és 1 hibás eredménnyel zárt. A hibás teszt
éppen a kritikus, gyors PTT press/release sorrendet ellenőrzi. Tíz célzott
ismétlésből további három hibázott. A mikrofon tehát időzítésfüggően bekapcsolva
maradhat a TALK gomb felengedése után.

Emellett a kliens jelenleg a csak hallgatni jogosult felhasználótól is kötelezően
mikrofonengedélyt kér, és annak megtagadásakor egyáltalán nem engedi
csatlakozni. Ez a kamera/rendező jellegű listen-only szerepkörök működését és az
adatminimalizálást is sérti.

**Minősítés: feltételesen működő M1 fejlesztői build; bemutatásra alkalmas, élő
produkcióra a P1 pontok lezárásáig nem alkalmas.**

## Reprodukálható ellenőrzési eredmények

### Repository

- Branch: `feature/m1-livekit-auth`
- Vizsgált commit: `3fbb36c55809e06c9f3602b888de34ac9fb7f0d7`
- A vizsgálat kezdetén a branch megegyezett az
  `origin/feature/m1-livekit-auth` ággal, a worktree tiszta volt.
- A `git diff --check` nem jelzett whitespace hibát.
- Feloldott iOS függőségek: LiveKit `2.16.0`, SwiftProtobuf `1.38.1`,
  LiveKitUniFFI `0.0.6`, LiveKitWebRTC `144.7559.11`.

### Teljes iOS tesztfutás

Környezet: iPhone 17 Pro szimulátor, iOS 26.1, Xcode 26.1 SDK.

Parancs:

```bash
xcodebuild -project FlyAboveIntercom.xcodeproj \
  -scheme FlyAboveIntercom \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=B518C3B7-3E64-448C-BF99-D0BF8CB028DF' \
  test
```

Eredmény:

- összesen: 44;
- sikeres: 43;
- hibás: 1;
- kihagyott: 0;
- végső állapot: `TEST FAILED`;
- hibás teszt:
  `IntercomViewModelTests.testRapidTalkTogglesEndWithTheMicrophoneOff()`;
- pontos eltérés: az `activeTalkChannelCount` értéke `1` maradt a várt `0`
  helyett.

Az `.xcresult` helye:

```text
~/Library/Developer/Xcode/DerivedData/FlyAboveIntercom-adzsgxpjzqwfjddqupodjfdbbnsc/Logs/Test/Test-FlyAboveIntercom-2026.09.06_12-00-13-+0200.xcresult
```

### Célzott PTT ismétlés

A hibás teszt egy önálló újrafuttatásban sikerült, majd tíz ismétlésből:

- 7 sikeres;
- 3 hibás.

Ez időzítésfüggő versenyhelyzetet bizonyít, nem determinisztikus üzleti vagy
Xcode-konfigurációs hibát.

### Valódi helyi integráció

Az ellenőrzéskor a gépen ténylegesen futott:

- `livekit-server` a `7880` TCP porton;
- a repository `dev-server` Node folyamata a `8080` TCP porton.

Ezért az integrációs suite nem skipelt. Mind a hat teszt sikerült:

1. bejelentkezés és csatornajogok;
2. publish jog nélküli realtime grant;
3. lejárt access token valós refresh körrel;
4. LiveKit csatlakozás, room join és mikrofon publish/unpublish;
5. Talk elutasítása publish jog nélkül;
6. két kliens résztvevőként látja egymást a közös csatornában.

Ez erős bizonyíték arra, hogy a REST → token → LiveKit alapútvonal helyi
környezetben működik. Nem helyettesíti a két fizikai iPhone-os, külön hálózatos,
Bluetooth- és handover-elfogadási tesztet.

### Node fejlesztői szerver

- `node --check` sikeres a `dev-server/src/index.js` és `src/data.js` fájlokon;
- az `npm ls --omit=dev` konzisztens függőségi fát mutatott;
- telepített közvetlen verziók: Express `5.2.1`, jsonwebtoken `9.0.3`,
  livekit-server-sdk `2.18.0`;
- `npm audit --omit=dev`: **0 ismert sebezhetőség**;
- a `dev-server/.gitignore` kizárja a `node_modules/` könyvtárat.

Az audit pillanatfelvétel: a később publikált sérülékenységeket nem tudja
előre jelezni. A fejlesztői szerver továbbra sem éles backend.

## Megerősített javítások

### Induláskori átmeneti hiba nem törli a sessiont

Az `AppEnvironment` külön `.unavailable` állapotot használ 503/timeout és más
nem hitelesítési hibákra. Csak `APIError.unauthorized` vagy
`AuthError.notAuthenticated` vált ki kijelentkezést. A 503-, timeout-, 401- és
retry-esetek külön tesztben sikerültek.

### Bontás utáni késői esemény szűrése

Az `IntercomViewModel` eldobja a transport-eseményeket, ha a lokális állapot már
`.disconnected`. A késői `.connected` és participant esemény regressziós tesztje
sikerült.

### Listen/Talk kívánt állapot szétválasztása

A transport külön `wantsListening` és `wantsTalking` halmazt vezet, és csak akkor
lép ki a szobából, ha egyik igény sem aktív. A kód ezzel lezárja a korábbi
„Listen off Talk közben” életciklus-hibát. Közvetlen, erre a teljes sorrendre
írt regressziós vagy LiveKit integrációs teszt azonban jelenleg nincs.

### Többszobás állapot aggregálása

A `roomStates` map és az `aggregatedConnectionState()` már a legrosszabb aktív
szobaállapotot jelzi. A korábbi globális „utolsó callback nyer” hiba kód szinten
javult. Többszobás reconnect teszt még nincs.

### NotificationCenter életciklus

Az `AudioSessionController` már az injektált notification centerből távolítja el
az observereket. Ez a korábbi P3 kódhiba megfelelő javítása.

## Nyitott hibák és kockázatok

### P1 – A TALK felengedése után bekapcsolva maradhat a mikrofon

Érintett helyek:

- `FlyAboveIntercom/UI/RootView.swift:28-30`;
- `FlyAboveIntercom/Features/Intercom/IntercomViewModel.swift:98-108`;
- `FlyAboveIntercomTests/IntercomViewModelTests.swift:118-135`.

A `TalkButton` helyi `isPressed` állapota megszünteti az egy érintésen belüli
többszörös `true` callbacket, de a `RootView` továbbra is külön, strukturálatlan
`Task`-ot indít a press és release eseményre. Ezek belépési sorrendje nem
garantált. A view model csak abban a sorrendben láncol, amelyben ezek a taskok
elérik a `setTalking` metódust; ez nem feltétlenül egyezik a gesztus eredeti
sorrendjével.

A regressziós teszt ugyanezt három `async let` hívással modellezi, amelyek
indulási sorrendje szintén nem garantált. A mért 3/10 hiba azt mutatja, hogy a
végeredmény időnként `true`: a UI szerint és a transport utolsó hívása szerint
is aktív maradhat a Talk.

Javaslat: a gesztus eseményét szinkron, main-actor metódusban azonnal rögzített
monoton sorszámmal vagy kívánt állapottal kell átadni; egyetlen csatornánkénti
worker alkalmazza mindig a legfrissebb kívánt állapotot. A tesztnek kontrollált
transport-felfüggesztéssel kell bizonyítania a `press → release` sorrendet, nem
ütemezetlen `async let` indulásra támaszkodva.

### P1 – A mikrofonengedély megtagadása a hallgatást is letiltja

Érintett hely: `FlyAboveIntercom/Features/Intercom/IntercomViewModel.swift:54-68`.

A `connect()` minden esetben mikrofonengedélyt kér, és megtagadáskor a LiveKit
kapcsolódás előtt visszatér. Így az a felhasználó sem tud egy csatornát hallgatni,
akinek `canListen == true`, de `canTalk == false`, vagy aki csak hallgatni akar és
adatvédelmi okból nem ad mikrofonengedélyt.

Javaslat: a hallgatáshoz szükséges audio session és room join indulhasson
mikrofonengedély nélkül. Engedélyt az első Talk előtt kell kérni; a Talk legyen
tiltva vagy adjon célzott hibát, a Listen ne.

### P2 – Ugyanarra a csatornára párhuzamos room join indulhat

Érintett hely: `FlyAboveIntercom/Services/LiveKitIntercomTransport.swift:155-190`.

Az actor izoláció önmagában nem zárja ki a versenyt, mert a `room.connect(...)`
`await` pontján az actor reentráns. Ha Listen és Talk gyorsan, külön UI taskból
ugyanarra a még nem csatlakozott csatornára érkezik, mindkét hívás láthat
`sessions[channelID] == nil` állapotot, és két `Room` kapcsolatot indíthat. A
szótárban az utolsó felülírhatja az elsőt, miközben az első kapcsolat nem kerül
szabályosan életciklus-kezelés alá.

Javaslat: csatornánkénti in-flight join task/single-flight mechanizmus, valamint
kontrollált párhuzamos Listen+Talk teszt.

### P2 – Realtime token megújítás továbbra sincs

A transport csak a kezdeti `/rt-tokens` választ tárolja, majd az SDK belső
reconnectjére hagyatkozik. A dokumentáció azt írja, hogy reconnectkor új tokent
kér, de ezt a kliens nem valósítja meg. Hosszabb hálózatkimaradás, tokenlejárat
vagy szerveroldali visszavonás után ez helyreállási hibát okozhat.

### P2 – A felhasználói profil nem áll helyre Keychainből

A Keychain csak tokeneket tárol. Ha appindításkor az access token még érvényes,
nincs refresh válasz, ezért `AuthService.currentUser` nil marad. A UI a produkció
nevét használja fallbackként, de a session profilja hiányos.

### P2 – API bázis-URL validáció hiányzik

A kliens nem normalizálja a záró perjelet, és Release buildben sem kényszeríti a
HTTPS-t. Hibás konfiguráció eltérő relatív útvonalat vagy nem biztonságos éles
kapcsolatot eredményezhet. URLProtocol-alapú API unit tesztek továbbra sincsenek.

### P2 – Az integrációs jogosultsági teszt nem bizonyít szerveroldali tiltást

A `testTalkIsRejectedWithoutPublishGrant()` a kliens
`guard grant.canPublish` feltételén áll meg. Ez igazolja a kliens gyors hibáját,
de nem próbálja meg közvetlen LiveKit klienssel, a kapott JWT használatával a
publish műveletet. Így a szerver által aláírt token tényleges publish-tiltása
nincs támadó vagy hibás klienssel end-to-end tesztelve.

### P3 – Az integrációs `waitForConnected` nem bukik timeoutnál

Az `EventCollector.waitForConnected(timeout:)` eldobja a belső Bool eredményt.
Ha nem érkezik `.connected`, maga a várakozás nem hibáztatja a tesztet; csak egy
későbbi művelet buktathatja meg mellékhatásként. Érdemes Boolt visszaadni és
`XCTAssertTrue`-val ellenőrizni vagy timeout hibát dobni.

## Dokumentációs eltérések

A `docs/ROADMAP.md` jelenleg azt állítja, hogy a review minden P1–P3 pontja
javítva van, mindegyik regressziós teszttel. Ez túl erős állítás:

- a PTT regressziós teszt időzítésfüggően elbukik;
- nincs közvetlen Listen-off-during-Talk regressziós teszt;
- nincs többszobás reconnect regressziós teszt.

Az M1 címében szereplő „kliensoldal kész” megfogalmazás szintén csak a fenti P1
hibák javítása után tekinthető pontosnak.

## Javasolt sorrend

1. PTT bemeneti események determinisztikus, legfrissebb-kívánt-állapot alapú
   kezelése; a 10–100 ismétléses teszt legyen 100%-ban zöld.
2. Listen-only csatlakozás mikrofonengedély nélkül.
3. Csatornánkénti single-flight `join` és párhuzamos Listen+Talk teszt.
4. Listen-off-during-Talk és többszobás reconnect közvetlen tesztje.
5. Realtime grant megújítás és visszavont/lejárt token helyreállási teszt.
6. Profil-visszatöltés, bázis-URL validáció és HTTP API unit tesztek.
7. Két fizikai iPhone, eltérő hálózat, Bluetooth route, háttér/előtérré válás,
   Wi-Fi–mobil handover és legalább 8 órás soak teszt.

## Elfogadási kapu a következő ellenőrzéshez

Az M1 kliensoldali lezárását akkor javasolt kimondani, ha:

- a teljes automata suite 0 hibával fut;
- a PTT stresszteszt legalább 100/100 sikeres;
- mikrofonengedély nélkül a listen-only út működik;
- párhuzamos Listen+Talk nem hoz létre dupla room kapcsolatot;
- a LiveKit integráció külön kötelező CI jobban fut, nem opcionális skipként;
- két fizikai iPhone-on a felengedés és minden bontási/interruption út azonnal
  megszünteti a mikrofon publikálását.
