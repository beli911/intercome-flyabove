# M1 ellenőrzés – `4e42e2d` – 2026-09-06

## Hatókör

Az ellenőrzés tárgya a `feature/m1-livekit-auth` branch
`4e42e2d964185fa3c32c4218f17b433ea2a9f8ce` commitja, különösen a következő
állítások:

- determinisztikus PTT;
- listen-only kapcsolat mikrofonengedély nélkül;
- csatornánkénti single-flight LiveKit join;
- 49/49 teljes teszt és 30 × 21 = 630/630 view-model stresszfutás;
- új mobil UI, sötét és napfény témával;
- push és nyitott GitHub PR #1.

Az ellenőrzéshez statikus kódvizsgálatot, teljes szimulátoros tesztet, 30-szoros
view-model ismétlést, élő helyi REST + LiveKit integrációt, GitHub PR lekérdezést,
valamint telepített és elindított szimulátoros vizuális ellenőrzést használtam.
A programkódot nem módosítottam; ez a dokumentum az ellenőrzés eredménye.

## Rövid eredmény

Az előző PTT sorrendhibát érdemben javították. A `RootView` már szinkron hívja a
`requestTalking` metódust, a view model pedig kívánt és alkalmazott állapotot
egyeztet csatornánként. Az in-flight transporthívás közbeni felengedés tesztje
helyesebb és determinisztikusabb a korábbinál.

A teljes tesztcsomag nálam is **49/49 sikeres** lett, benne **6/6 valódi, nem
skipelt LiveKit-integrációs teszttel**. A közölt 630/630 stresszeredményt azonban
nem sikerült megismételni: az azonos 30 × 21 futás **629 sikeres és 1 hibás**
eredménnyel zárt.

Az M1 ezért sokkal jobb állapotban van, de továbbra sem nevezhető
produkcióbiztosnak. Az első mikrofonengedély-kérés alatt felengedett TALK rövid
időre még publikálhat, a többszobás állapotaggregálás egy végleg leszakadt szobát
elrejthet, és reconnect közben a UI új `connect()` hívást enged.

**Minősítés: jó fejlesztői/demo állapot, de a P1 szélső esetek és a fizikai
eszközös elfogadás lezárásáig nem élő produkcióra kész.**

## Ellenőrzött állítások

### Git és PR

- A helyi `HEAD` és az `origin/feature/m1-livekit-auth` egyaránt `4e42e2d`.
- A worktree az ellenőrzés kezdetén tiszta volt.
- A GitHub PR #1 létezik, állapota `OPEN`.
- PR head: `feature/m1-livekit-auth` / `4e42e2d`.
- PR base: `main`.
- PR URL: <https://github.com/beli911/intercome-flyabove/pull/1>
- A branchhez a GitHub nem jelent automatikus checket; jelenleg nincs látható
  kötelező CI futás.

### Teljes tesztcsomag

Parancs:

```bash
xcodebuild -project FlyAboveIntercom.xcodeproj \
  -scheme FlyAboveIntercom \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=B518C3B7-3E64-448C-BF99-D0BF8CB028DF' \
  test
```

Környezet: iPhone 17 Pro szimulátor, iOS 26.1.

Eredmény:

- összesen: 49;
- sikeres: 49;
- hibás: 0;
- kihagyott: 0;
- a hat `LiveKitTransportIntegrationTests` teszt valódi helyi
  `livekit-server` + `dev-server` ellen futott és sikerült.

XCResult:

```text
~/Library/Developer/Xcode/DerivedData/FlyAboveIntercom-adzsgxpjzqwfjddqupodjfdbbnsc/Logs/Test/Test-FlyAboveIntercom-2026.09.06_13-03-23-+0200.xcresult
```

### 30-szoros view-model stresszfutás

Parancs:

```bash
xcodebuild -project FlyAboveIntercom.xcodeproj \
  -scheme FlyAboveIntercom \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=B518C3B7-3E64-448C-BF99-D0BF8CB028DF' \
  -only-testing:FlyAboveIntercomTests/IntercomViewModelTests \
  -test-iterations 30 \
  test-without-building
```

Eredmény:

- összes futás: 630;
- sikeres: 629;
- hibás: 1;
- hibás teszt:
  `IntercomViewModelTests.testInterruptionStopsTalkingEverywhere()`;
- eltérés: az utolsó transporthívás `Optional(true)` volt a várt
  `Optional(false)` helyett.

XCResult:

```text
~/Library/Developer/Xcode/DerivedData/FlyAboveIntercom-adzsgxpjzqwfjddqupodjfdbbnsc/Logs/Test/Test-FlyAboveIntercom-2026.09.06_13-04-55-+0200.xcresult
```

Ez nem ugyanaz a hiba, mint a korábbi rendezetlen press/release. A teszt az UI
`isTalking` állapotának nullázódására vár, de a kód ezt a transport `false` hívás
előtt végzi el. Az assertion így ritkán a még futó worker elé kerülhet. Ettől a
normál PTT reconciler nem bizonyult hibásnak, de a 630/630 állítás nem
reprodukálható, és az interruption teszt szinkronizációja nem megfelelő.

### Vizuális ellenőrzés

Az appot a friss buildből telepítettem és elindítottam az iPhone 17 Pro
szimulátoron. Az ellenőrzött főképernyő:

- elindult és stabilan renderelt;
- a napfény téma világos alapon olvasható volt;
- a csatornasorok, Listen/Talk oszlopok, alsó vezérlők és tab bar nem lógtak ki;
- a sárga, piros és zöld szerepe vizuálisan következetes;
- a nem elérhető Crew/Admin fülek letiltott állapotban látszanak;
- a demó mód egyértelműen jelzi, hogy nincs hálózati hang.

Ez manuális megjelenési ellenőrzés, nem snapshot/UI automata teszt. A különböző
képernyőméretek, Dynamic Type, VoiceOver, sötét téma és fizikai kültéri
olvashatóság nincs teljes mátrixban ellenőrizve.

## Megerősített javítások

### PTT eseménysorrend

A `RootView` nem indít külön `Task`-ot a press és release eseményekre. Mindkettő
szinkron, MainActor-isolált `requestTalking` hívással rögzíti a kívánt állapotot.
A csatornánkénti worker minden await után újraolvassa a kívánt és alkalmazott
állapotot. Az in-flight transporthívás közbeni release tesztje valóban
felfüggeszti a transportot, majd felengedést küld.

Ez lezárja a `3fbb36c` verzióban kimért, strukturálatlan UI taskokból eredő
alapversenyt.

### Listen-only mikrofon nélkül

A `connect()` playback-only audio sessiont aktivál, és nem kér
mikrofonengedélyt. Az első Talk előtt történik az engedélykérés és az audio
session `.playAndRecord` módra váltása. Az ezt fedő unit tesztek sikerültek.

### Integrációs timeout

Az `EventCollector.waitForConnected` már Bool eredményt ad, a hívók pedig
`XCTAssertTrue`-val ellenőrzik. A korábbi csendes timeout hiba javítva van.

### Single-flight join alapút

A transport a folyamatban lévő join taskot csatornánként eltárolja, és egy
második Listen/Talk kérés ugyanazt a taskot várja meg. Ez a normál párhuzamos
belépési esetet helyesen összevonja. A megszakítás és újrakezdés szélső esete
azonban még nincs lezárva; lásd a P2 pontot.

## Nyitott problémák

### P1 – Felengedés az első mikrofonengedély-kérés közben

Érintett hely:
`FlyAboveIntercom/Features/Intercom/IntercomViewModel.swift:193-208`.

A worker a ciklus elején lokális `desired = true` értéket olvas. Ezután awaiteli
az iOS mikrofonengedélyt. Ha a felhasználó a rendszerengedély-ablak alatt már
felengedi a TALK gombot, a `desiredTalk` közben false lesz, de a worker a korábban
kiolvasott `desired` értékkel még meghívja a
`transport.setTalking(true, ...)` műveletet. Csak annak befejezése után olvassa
újra az állapotot és küld false-t.

Következmény: az első engedélyezés után a mikrofon rövid időre úgy is
publikálhat, hogy a felhasználó már nem tartja nyomva a gombot.

Javaslat: az `ensureMicrophoneAccess()` minden awaitje után újra kell olvasni a
kívánt állapotot, és csak akkor publisholni, ha még mindig true. Külön teszt kell
felfüggesztett permission-válasszal és közben érkező release-zel.

### P1 – Talk All első használatakor nincs single-flight mikrofonengedély

Érintett helyek:

- `IntercomViewModel.requestTalkingOnAllChannels`;
- `IntercomViewModel.ensureMicrophoneAccess`.

A Talk All minden csatornához külön workert indít. Amíg az első permission kérés
awaitel és `isMicrophoneGranted` még nil, a többi worker is elindíthat külön
permission kérést és később külön `activate(recording: true)` hívást. Az iOS a
rendszerablakot várhatóan összevonja, de a kliensoldali művelet nem single-flight,
és nincs rá teszt.

Javaslat: egyetlen megosztott in-flight permission/recording-activation task.

### P1 – Egy végleg leszakadt szobát a többi zöld szoba elfed

Érintett hely:
`FlyAboveIntercom/Services/LiveKitIntercomTransport.swift:264-271`.

A komment szerint az app a „legrosszabb” room állapotát mutatja, de az
aggregáció csak a `.connecting`/`.reconnecting` állapotot rangsorolja előre. Ha
egy room `.disconnected`, egy másik pedig `.connected`, a függvény `.connected`
értéket ad. A kezelő teljesen zöld kapcsolatot lát, miközben egy vonal már
leszakadt.

Javaslat: dokumentált állapotprioritás és kötelező roomok esetén csak akkor
globális `.connected`, ha mindegyik connected. Kell kétroomos
connected+disconnected regressziós teszt.

### P1 – Reconnecting állapotban a BE gomb új kapcsolatot indíthat

Érintett hely: `FlyAboveIntercom/UI/RootView.swift:80-105`.

`isConnected` csak pontos `.connected` állapotnál true. Reconnecting közben a
gomb ezért `BE` feliratot mutat, és csak `.connecting` esetén van letiltva. A
felhasználó reconnect közben ismét meghívhatja a `connect()` metódust a még élő
transporton. A transport új grantválaszt kérhet, majd a meglévő sessionök mellett
tévesen `.connected` állapotot emitálhat.

Javaslat: a kapcsolatgomb kezelje külön a connecting/reconnecting állapotot;
reconnecting alatt legyen tiltva vagy kínáljon explicit bontást, ne implicit új
connectet.

### P2 – A single-flight join megszakítás/újrakezdés esetén versenyezhet

Érintett helyek:

- `LiveKitIntercomTransport.join`: 160-173;
- `leave`: 213-220;
- `teardown`: 223-238.

Az első join `defer { joinTasks[channelID] = nil }` blokkal vakon törli a map
bejegyzését. Ha közben a `leave` törli és megszakítja az első taskot, majd egy új
join ugyanarra a csatornára új taskot tárol, az első hívás késői deferje az új
task bejegyzését is törölheti. Egy harmadik hívás ekkor ismét párhuzamos joint
indíthat.

A teardown a taskokat cancelöli, de nem várja meg őket, a `performJoin` pedig a
`room.connect` után nem ellenőrzi sem a cancellationt, sem a session generációt.
Ha a LiveKit connect művelet későn sikerrel tér vissza, bontás után is visszaírhat
egy sessiont.

Javaslat: task-azonosító/generáció, csak a saját bejegyzést törlő defer, a
cancelölt taskok awaitelése, connect után cancellation/generation ellenőrzés és
az elkészült room explicit bontása. Kell join → leave/disconnect → rejoin teszt.

### P2 – Interruption teszt és optimista UI állapot

Érintett helyek:

- `IntercomViewModel.stopTalkingEverywhere`: 330-339;
- `testInterruptionStopsTalkingEverywhere`: 223-235.

A view model a `configuration.channels[index].isTalking` értéket a transport
false hívása előtt nullázza. Ez gyors vizuális reakciót ad, de a felület már
„nem élő” állapotot mutathat, miközben a tényleges mikrofonleállítás még folyamatban
van. A stresszfutás egy alkalommal pontosan e két állapot között érte el az
assertiont.

Javaslat: a teszt várja meg a `waitForTalkWorkToSettle()` végét. Biztonsági
szempontból érdemes külön „leállítás folyamatban” állapotot vagy hard fail-safe
room bontást alkalmazni, ha a mic-off nem fejeződik be határidőre.

### P2 – Talk mód váltása nyitott latch mellett nincs definiálva

A fejléc MOM/LATCH gombja közvetlenül átírja a módot. Ha egy mikrofon latch
módban nyitva van, MOM módra váltás nem zárja be. A piros élő állapot látható
marad, tehát nem rejtett hiba, de élő pultnál a módváltás biztonsági szemantikáját
egyértelműen dokumentálni és tesztelni kell. A biztonságos alapértelmezés a mód
váltásakor minden latch elengedése.

## Korábbról továbbra is nyitott

A commit leírása ezeket helyesen nyitottként jelöli:

- reconnect alatti explicit realtime-token megújítás;
- felhasználói profil visszatöltése érvényes, Keychainből hozott token mellé;
- API bázis-URL normalizálása;
- Release build HTTPS-kényszere;
- a LiveKit JWT publish-tiltásának közvetlen, rosszhiszemű klienses end-to-end
  bizonyítása;
- két fizikai iPhone eltérő hálózaton;
- Bluetooth, háttér/előttér, Wi-Fi/mobil handover és hosszú soak teszt.

## Dokumentációs pontosság

A `docs/ROADMAP.md` 49/49 állítása egy normál teljes futásra reprodukálható.
A 630/630 állítást viszont érdemes a teszt javításáig „egy korábbi futásban
630/630; független ismétlésben 629/630” formára pontosítani.

Az „M1 – kliensoldal kész” cím továbbra is túl erős a fenti P1 pontok és az
explicit reconnect-token hiánya mellett. Pontosabb: „M1 – működő kliensoldali
prototípus, elfogadás alatt”.

## Javasolt következő sorrend

1. Permission await utáni desired-state újraellenőrzés és single-flight
   permission task.
2. Reconnecting UI és connected+disconnected többszobás aggregáció javítása.
3. Join cancellation/generation életciklus javítása és tesztelése.
4. Interruption teszt determinisztikus megvárása; mic-off timeout hard fail-safe.
5. Módváltási biztonsági szabály, app háttérbe kerülésekor minden Talk elengedése.
6. Korábbról nyitott token/profil/URL feladatok.
7. Kötelező CI a PR-en, majd két fizikai iPhone-os elfogadási mátrix.
