# M1 ellenőrzés – `a9b7bd3` + helyi CI `c8220f3` – 2026-09-06

## Hatókör

Az ellenőrzés tárgya a távoli `feature/m1-livekit-auth` branch
`a9b7bd3` commitja, valamint az arra épülő, még csak helyben létező
`c8220f3` CI-commit.

A vizsgálat a következő közölt állításokra terjedt ki:

- a sikertelen mikrofonleállítás már nem kerülhet `off` állapotba;
- a mikrofonengedély-ablak közbeni bontás nem aktiválhat később felvételt;
- háttérbe kerüléskor minden Talk elenged;
- a join/leave/rejoin integrációs teszt pontosan megmutatja, mit tud és mit
  nem tud bizonyítani;
- a CI megőrzi az `xcodebuild` hibakódját és pontosan hét integrációs tesztet
  követel meg;
- a teljes csomag 64/64, a 30-szoros stresszfutás pedig 870/870 sikeres.

Statikus kódvizsgálatot, helyi Node-ellenőrzést, teljes iOS-szimulátoros
tesztet, 30-szoros view-model ismétlést és az XCResult csomagok közvetlen
kiolvasását használtam. Az alkalmazáskódot nem módosítottam; ez a dokumentum
az ellenőrzés eredménye.

## Rövid eredmény

A közölt hat javítás lényegi része valóban bekerült. A legsúlyosabb korábbi
fail-safe hiba javítása helyes irányú: egy sikertelen mikrofonleállítás
`unknown` állapotot eredményez és kényszerbontást indít. A
session-generáció lezárja a későn visszatérő engedélykérés alapútját, a
háttérbe kerülés kezelése pedig a view modelben tesztelhető.

A teljes tesztcsomag nálam is **64/64 sikeres**, **0 kihagyott** eredménnyel
zárt. Ebben mind a **7/7 LiveKit-integrációs teszt** valódi helyi stack
ellen futott.

A közölt **870/870 stresszeredmény viszont nem reprodukálható**. A tiszta,
`test` művelettel indított 30-szoros futás **865 sikeres és 1 összeomlott**
tesztfutás után hibakóddal állt le; négy tervezett ismétlés már nem futott
le. A hibás teszt:

`IntercomViewModelTests/testDisconnectDuringThePermissionPromptDoesNotArmRecording()`

Az XCResult pontos hibája: **“Test crashed with signal kill.”**

**Minősítés: a normál M1 regressziós csomag zöld, de a stresszállítás hamis,
a CI még nem futott GitHubon, és maradt egy többcsatornás worker-életciklus
kockázat. Élő produkciós készültség továbbra sem igazolt.**

## Git-állapot

Az ellenőrzés kezdetén:

- helyi `HEAD`: `c8220f3`;
- távoli `origin/feature/m1-livekit-auth`: `a9b7bd3`;
- a helyi branch egy committal előrébb volt;
- a különbség kizárólag a CI workflow commitja volt.

Ez megerősíti a közlést: az alkalmazáskód felkerült, a workflow commitja még
nem.

Az ellenőrzés közben a munkafában külső folyamatból további, még nem
commitolt API/auth/LiveKit változások jelentek meg. Ezeket nem módosítottam,
nem állítottam vissza, és nem számítottam bele az `a9b7bd3` eredményébe.

## Független teszteredmények

### Teljes csomag

Parancs:

```bash
xcodebuild -project FlyAboveIntercom.xcodeproj \
  -scheme FlyAboveIntercom \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,id=B518C3B7-3E64-448C-BF99-D0BF8CB028DF' \
  -parallel-testing-enabled NO \
  test
```

Környezet: iPhone 17 Pro szimulátor, iOS 26.1.

XCResult összesítés:

- összesen: 64;
- sikeres: 64;
- hibás: 0;
- kihagyott: 0;
- LiveKit-integráció: 7/7.

XCResult:

```text
~/Library/Developer/Xcode/DerivedData/FlyAboveIntercom-adzsgxpjzqwfjddqupodjfdbbnsc/Logs/Test/Test-FlyAboveIntercom-2026.09.06_13-58-16-+0200.xcresult
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
  -parallel-testing-enabled NO \
  test
```

Eredmény:

- tervezett: 29 × 30 = 870 futás;
- ténylegesen rögzített: 866 futás;
- sikeres: 865;
- hibás: 1;
- nem végrehajtott: 4;
- `xcodebuild` kilépési kód: 65;
- eredmény: **FAILED**.

XCResult:

```text
~/Library/Developer/Xcode/DerivedData/FlyAboveIntercom-adzsgxpjzqwfjddqupodjfdbbnsc/Logs/Test/Test-FlyAboveIntercom-2026.09.06_14-00-08-+0200.xcresult
```

Az Xcode a tesztfolyamat váratlan kilépése után újraindította a futást. Az
újraindított rész végén megjelenő `Executed 630 tests, 0 failures` sor nem
az egész művelet eredménye. Az XCResult és az `xcodebuild` 65-ös kódja az
irányadó: a teljes stresszfutás hibás.

## Megerősített javítások

### Sikertelen mikrofonleállítás

Az alkalmazott Talk állapot háromértékű: `off`, `on`, `unknown`.
Sikertelen bekapcsolás biztonságos `off` eredményt és megtartott kapcsolatot
ad. Sikertelen kikapcsolás `unknown` állapotot állít, majd bontja a
transportot és deaktiválja az audio sessiont. Ez lezárja a korábbi
`clearTalk` fail-safe megkerülést.

### Engedélykérés utáni késői folytatás

A mikrofon task elmenti a session-generációt, és az engedély visszatérése után
ellenőrzi, hogy ugyanaz a kapcsolat él-e még. Bontás esetén `abandoned`
eredménnyel tér vissza, felvételi audio sessiont nem aktivál.

### Háttérbe kerülés

A `RootView` továbbítja a scene állapotváltozását a view modelnek, a view
model pedig inaktív állapotban bevárja a `stopTalkingEverywhere()`
műveletet. A közvetlen view-model regressziós teszt zöld.

Ez még nem fizikai iOS életciklus-teszt: a valódi háttérbe kerülés,
felfüggesztés és audio route kombinációját készüléken továbbra is ellenőrizni
kell.

### CI pipefail és integrációs darabszám

A workflow globális explicit `bash` shellt és a tesztlépésben külön
`set -o pipefail` beállítást használ. Így az
`xcodebuild | tee /tmp/test.log` nem tud zöldre váltani egy hibás
`xcodebuild` futást.

Az integrációs ellenőrzés `expected=7` értékkel pontos egyezést követel,
és külön elbukik bármilyen kihagyott teszten. Az XCResult csomag hibánál
artifactként megmarad.

A workflow YAML szintaktikailag olvasható, de GitHub Actionsben még egyszer
sem futott; a működése ezért továbbra is csak statikusan igazolt.

### Dev szerver

Független ellenőrzés:

- `node --check src/index.js`: sikeres;
- `node --check src/data.js`: sikeres;
- `npm ls --omit=dev`: sikeres;
- `npm audit --omit=dev`: 0 ismert sérülékenység.

## Nyitott problémák és korlátok

### P1 – A stresszfutás az új permission/bontás teszten összeomlik

Érintett hely:
`FlyAboveIntercomTests/IntercomViewModelTests.swift:331-348`.

A teszt blokkolja a permission választ, majd a blokkolás feloldása előtt
`await subject.disconnect()` hívást végez. A `disconnect()` közben a
`stopTalkingEverywhere()` a még blokkolt Talk workerre vár, a
`waitForTalkWorkToSettle` pedig csak öt másodperc után adja fel. Emiatt ez
az egy teszt ismétlésenként körülbelül 5,06 másodperc.

A 30-szoros futásban a tesztfolyamat a 26. ismétlés környékén signal kill-lel
meghalt. Ez nem bizonyít alkalmazás-összeomlást, de egyértelműen bizonyítja,
hogy a regressziós teszt és a 870/870 mérési állítás jelenleg nem stabil.

Javaslat: a bontást külön taskban indítani, megvárni, hogy valóban a workerre
várjon, feloldani a permission választ, majd bevárni a bontás taskját. Így a
versenyhelyzet megmarad, de minden iteráció nem égeti el az öt másodperces
határidőt.

### P2 – Kényszerbontáskor a többi Talk worker nincs lezárva

Érintett helyek:

- `IntercomViewModel.swift:228-239`;
- `IntercomViewModel.swift:260-296`.

Talk All esetén több csatorna workere futhat. Ha az egyik csatorna
kikapcsolása hibázik, a fail-safe törli a kívánt és alkalmazott állapotot,
majd bont. A többi, már folyamatban lévő worker azonban nincs megszakítva,
nem kap saját session-generációt, és nincs bevárva a kényszerbontás előtt.
Egy későn visszatérő worker a törlés után újra írhatja az `appliedTalk`
állapotot, újabb transporthívást vagy ismételt kényszerbontást indíthat, és
egy gyors újracsatlakozás első Talk kérését is blokkolhatja a
`talkWorkers.contains(channelID)`.

Ez kódszinten azonosítható életciklus-rés, de a jelenlegi tesztek nem
reprodukálják. Javaslat: a Talk workerek session-generációhoz kötése vagy
strukturált task-handle-ök megszakítása és bevárása, plusz kétcsatornás
regressziós teszt, ahol az egyik stop hibázik, a másik pedig felfüggesztve
tér vissza.

### Ismert igazolási hiány – az árva LiveKit szoba

Az új `testJoinLeaveRejoinChurnLeavesExactlyOneConnection` hasznos
végállapot-invariánst mér:

- churn után egy szerveroldali résztvevő marad;
- bontás után egy sem.

Nem bizonyítja az árva-room guard helyességét. Azonos LiveKit identity mellett
a szerver a régi résztvevőt kilépteti, ezért két klienskapcsolat nem jelenik
meg két azonos identityként. A teszt kommentje ezt korrektül és egyértelműen
közli. Ezt nem tekintem új hibás állításnak; a védelem továbbra is
kódvizsgálattal indokolt, de célzott transport/Room factory tesztdupla vagy
SDK-szintű hook nélkül nincs dinamikusan bizonyítva.

### P3 – Elavult CI-felirat

A workflow logikája hét tesztet vár, de a komment és a lépés neve még
„all six” szöveget tartalmaz
(`.github/workflows/ci.yml:100-104`). Ez nem működési hiba, de félrevezető
dokumentáció.

## Következtetés

Az `a9b7bd3` commit valódi és fontos biztonsági javításokat tartalmaz, a
normál 64/64-es eredmény reprodukálható. A jelentett 870/870 azonban nem
fogadható el: a független ismétlés 65-ös hibakóddal, signal kill-lel zárt.

Következő sorrend:

1. a permission/bontás teszt öt másodperces önblokkolásának megszüntetése;
2. a többcsatornás Talk workerek fail-safe utáni lezárása és célzott tesztje;
3. a helyi CI commit feltöltése és egy valódi GitHub Actions futás;
4. két fizikai iPhone-os, külön hálózatos, háttérbe kerülést és route-váltást
   is tartalmazó elfogadási mátrix;
5. az árva-room guard tesztelhetővé tétele SDK-független room factory vagy
   instrumentált transport segítségével.
