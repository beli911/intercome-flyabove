# Fejlesztési terv

## M0 – Natív alap (elkészült)

- Xcode projekt és iOS target
- domain modellek
- csatorna UI, Listen, momentary Talk
- mikrofonengedély és voice-chat audio-session
- transport absztrakció
- alap unit tesztek

## M1 – Működő kliensoldali prototípus, elfogadás alatt

Médiaszerver: **LiveKit**, `client-sdk-swift` 2.16. Egy csatorna = egy LiveKit szoba.

Kliensoldalon elkészült:

- backend/API szerződés rögzítése → [docs/API.md](API.md)
- autentikáció és Keychain tokenkezelés (`AuthService`, `KeychainTokenStore`)
- WebRTC SDK integráció (LiveKit SPM, beágyazott `LiveKitWebRTC.framework`)
- `LiveKitIntercomTransport`: szobánkénti join/leave, PTT publish/unpublish
- TURN átadási pont: `extraIceServers`
- connection statistics és RTT overlay fejlesztői módban
- audio interruption, route change és media-services-reset kezelés

Igazolva valódi LiveKit szerverrel (`LiveKitTransportIntegrationTests`):
csatlakozás és szobába lépés, mikrofon publikálása Talkra, publish jog nélküli
csatorna elutasítása, és két kliens egymás látása a közös csatornán.

Backend: [server/](../server/).

### Első ellenőrzés ([REVIEW_M1_2026-09-06.md](REVIEW_M1_2026-09-06.md))

Javítva, regressziós teszttel:

- PTT eseménysorrend: a gesztus saját lenyomás-állapotából dolgozik, nem a
  késleltetve renderelt értékből, és a Talk-hívások csatornánként sorosak
- bontás után érkező transport-esemény nem élesztheti újra a UI-t
- Listen kikapcsolás Talk közben: a transport külön tartja nyilván a kívánt
  Listen és Talk állapotot, és a szobát akkor engedi el, amikor egyik sem kéri
- induláskori átmeneti szerverhiba nem törli a munkamenetet — új
  `unavailable` fázis „Újra" gombbal
- többszobás kapcsolatállapot aggregálása: egy csatorna újracsatlakozása
  látszik akkor is, ha a többi rendben
- `AudioSessionController` az injektált `NotificationCenter`-ből iratkozik le
- az integrációs teszt health checkje ellenőrzi a várt `401`-et

### Újraellenőrzés ([VERIFICATION_M1_3FBB36C_2026-09-06.md](VERIFICATION_M1_3FBB36C_2026-09-06.md))

Az újraellenőrzés joggal mondta túl erősnek a korábbi „minden javítva"
megfogalmazást: a PTT regressziós teszt időzítésfüggő volt, tízből háromszor
elbukott. Saját méréssel visszaigazolva: tízből négyszer.

Javítva ebben a körben:

- **PTT sorrendiség, most már determinisztikusan.** A gesztus szándéka szinkron,
  felfüggesztési pont előtt kerül rögzítésre; csatornánként egy egyeztető
  alkalmazza mindig a legfrissebb kívánt állapotot. Stresszmérés: 30 futás,
  630 teszt, 0 hiba.
- **Listen-only mikrofonengedély nélkül.** A csatlakozás playback-only
  session-nel indul, engedélyt csak az első Talk előtt kérünk. Aki nem ad
  mikrofont, az továbbra is hallgathat.
- **Csatornánkénti single-flight join.** Actor izoláció nem véd a reentranciától
  a `room.connect` await-jén, így egy párhuzamos Listen+Talk két szobát nyitott
  volna ugyanarra a csatornára.
- **Az integrációs `waitForConnected` timeoutnál buktat**, nem mellékhatásként.

### Harmadik ellenőrzés ([VERIFICATION_M1_4E42E2D_2026-09-06.md](VERIFICATION_M1_4E42E2D_2026-09-06.md))

A korábban közölt 630/630 stresszeredmény egy valós mérés volt, de nem
reprodukálható: független ismétlésben 629/630. A hibás teszt nem a PTT, hanem az
interruption teszt volt, amely az optimista UI-jelzőre várt a tényleges
transport-hívás helyett. A teszt javítva; a mostani mérés `-test-iterations 30`
mellett **750/750**.

Javítva ebben a körben, mindegyik regressziós teszttel — és mindegyiket
ellenőriztem úgy is, hogy a javítás visszavételekor elbukik:

- **Felengedés az engedélykérés alatt.** A worker a jogosultság megszerzése után
  újraolvassa a kívánt állapotot, így egy közben elengedett gomb nem nyitja meg
  a mikrofont.
- **Single-flight mikrofonengedély.** A Talk All csatornánként indított workerei
  egyetlen engedélykérésen és egyetlen session-váltáson osztoznak.
- **Egy leszakadt szoba nem bújhat el.** Zöld csak akkor, ha minden belépett
  vonal fent van; minden más újracsatlakozásként látszik.
- **Reconnecting alatt nincs implicit új kapcsolat.** A gomb bontást kínál, a
  `connect()` pedig visszalép.
- **Join életciklus.** Session-generáció, saját bejegyzést törlő cleanup, a
  megszakított join bevárása, és a `room.connect` után ellenőrzés — egy későn
  megérkező szoba nem telepíti be magát bontás után.
- **Módváltás nyitott latch mellett** minden Talkot elenged, és a háttérbe
  kerülés is.
- **Fail-safe:** ha a mikrofon nem áll le határidőre, a kapcsolat bontásra kerül.
  Drasztikus, de egy beragadt mikrofon élő produkción rosszabb.

CI: [.github/workflows/ci.yml](../.github/workflows/ci.yml) — build és teljes
teszt futó LiveKit + dev API mellett, plusz külön 30-szoros PTT stresszjob. A
job elbukik, ha az integrációs teszt kihagyásra kerül, mert az azt jelentené,
hogy a stack nem is futott.

### Negyedik ellenőrzés ([VERIFICATION_M1_4669953_2026-09-06.md](VERIFICATION_M1_4669953_2026-09-06.md))

Javítva:

- **A mic-off hibája megkerülte a fail-safe-et.** A `clearTalk` a sikertelen
  leállítást is `off`-ként könyvelte, így a fail-safe sosem indult el — pont
  abban az esetben, amire készült. Az alkalmazott állapot mostantól
  háromértékű (`off`/`on`/`unknown`), és egy sikertelen *leállítás* azonnal
  kényszerbontást vált ki. Sikertelen *indítás* nem: az nem sugároz semmit.
- **Engedélykérés alatti bontás.** A permission task session-generációt kap, így
  egy a rendszerablak alatt bontott munkamenet után nem aktivál felvételre kész
  audio sessiont.
- **Háttérbe kerülés** a view modelbe került (`handleSceneActivation`), így
  tesztelhető, nem csak egy SwiftUI módosító.
- **CI:** `defaults.run.shell: bash` a `pipefail` miatt — enélkül a
  `xcodebuild | tee` a `tee` kilépési kódját adta volna vissza. Az integrációs
  tesztek darabszáma kikényszerítve, xcresult bundle megőrizve.

Új tesztek: sikertelen mic-off kényszerbont, sikertelen mic-on nem, bontás az
engedélyablak alatt nem élesíti a felvételt, háttérbe kerülés elenged, és egy
élő join/leave/rejoin integrációs teszt.

**Amit nem sikerült igazolni:** az árva szoba elleni védelem kódszinten megvan,
de tesztelni nem tudtam. A LiveKit azonos identitás esetén kilépteti a korábbi
résztvevőt, ezért egy elhagyott kapcsolat soha nem jelenik meg duplikátumként a
szerver listájában — a védelem eltávolításával a teszt hatszor hatból átment.
Az integrációs teszt így egy valódi, de szűkebb invariánst őriz: párhuzamos
churn után pontosan egy kapcsolat marad, bontás után egy sem.

### Ötödik ellenőrzés ([VERIFICATION_M1_A9B7BD3_2026-09-06.md](VERIFICATION_M1_A9B7BD3_2026-09-06.md))

A 870/870 állításom nem állt: `test-without-building`-gel mértem, az
ellenőrzés `test`-tel futott, és signal kill lett a vége. Az ok a saját új
tesztem volt, amely iterációnként elégette az ötmásodperces settle-határidőt.
Javítva: a bontás párhuzamos taskban fut, a teszt 5,06 s helyett 0,04 s.
Az azonos paranccsal mért új eredmény **exit 0, 900/900**.

Javítva még:

- **Kényszerbontáskor a többi Talk worker.** A workerek session-generációhoz
  vannak kötve, és minden felfüggesztés után ellenőrzik. Egy elavult worker
  így nem ír a megszűnt munkamenetbe, nem indít második kényszerbontást, és
  nem blokkolja a következő munkamenet első Talkját.
- A CI felirata már nem „all six"; a darabszám a suite-tal együtt mozog.

### A review-kból nyitva maradt pontok lezárása

- **Realtime-token megújítás.** A transport egy órás grantekkel dolgozik, és
  lejárat előtt tíz perccel megújítja őket. Egy hosszú kimaradás után
  újracsatlakozó szoba így nem mutat be olyan tokent, amit a szerver már nem
  fogad el. Élő teszt fedi.
- **Helyreállítás leszakadt vonalra.** Ha a LiveKit feladja, a transport friss
  grantet kér és újra belép, növekvő várakozással, öt próbálkozásig. A teszt a
  a szerver debug végpontjával lépteti ki a résztvevőt — ez az egyetlen mód olyan bontást
  előidézni, amit nem a kliens kért.
- **Bázis-URL normalizálás és HTTPS-kényszer.** A záró perjel hiánya csendben
  elnyelte volna az útvonal utolsó elemét; a Release build pedig nem indul el
  `http://` címmel. Tíz unit teszt fedi.
- **Profil visszatöltése.** A felhasználó a tokenek mellé kerül a Keychainbe,
  így egy még érvényes access tokennel induló app is tudja, ki van bejelentkezve
  — refresh kör nélkül. A régi formátumú tárolt elem továbbra is betöltődik.
- **A publish-tiltás bizonyítása rosszhiszemű klienssel.** Egy nyers LiveKit
  `Room` csatlakozik a szerver saját tokenjével, és megpróbál publikálni. A
  szervernek kell elutasítania — ellenőrizve azzal is, hogy a szerver
  ideiglenesen megadott jogánál a teszt elbukik.

Nyitva:

Hátralévő feladat:

- éles LiveKit telepítés vagy LiveKit Cloud projekt, TURN-nel
- éles token- és API-szerver a `docs/API.md` szerint
- **elfogadási feltétel:** két fizikai iPhone külön hálózatról tud PTT és nyitott
  mikrofonos beszélgetést folytatni, bontás után automatikusan újracsatlakozik

## Felület

A mobil UX javaslat vizuális rendszere és a már megépített képernyők:
[docs/DESIGN.md](DESIGN.md). A latch/momentary PTT-t — bár az M2 listán
szerepel — előrehoztuk, mert a megépített főképernyő része.

## M2 – Produkció és több csatorna

- produkcióválasztó és meghívó link/QR
- csatornánkénti Talk/Listen jogosultság
- több csatorna párhuzamos hallgatása
- ~~latch/momentary PTT beállítás~~ (elkészült az M1 felülettel)
- résztvevőlista és beszélőjelzés
- csatornánkénti hangerő
- admin által küldött konfiguráció

## M3 – Broadcast funkciók

Elkészült:

- **program feed és IFB/ducking, prioritás jelzéssel.** A csatorna `role`
  mezője dönt: a `priority` vonal beszédre lehalkítja a többit és soha nem
  halkul; a `program` adáshang a prioritásra **és** a saját beszédre is
  lehalkul (ez az IFB); a `line` csak a prioritásra. A `line` szándékosan nem
  halkul saját beszédre — az épp azokat némítaná, akikkel beszélünk.
  A szabály önálló, kimerítően tesztelt függvény; a duckolás a transportban
  külön szorzó, hogy az operátor beállított szintjét ne írja felül.

- **private/direct call.** Efemer csatornaként, nem külön mechanizmusként: a
  broadcast intercomok is így modellezik a point-to-pointot, így a
  konfigurációs push viszi el mindkét félhez, és nincs csengetési protokoll,
  amit ki kellene találni. Párra idempotens, és a csatorna neve
  nézőpontonként a másik fél neve.

Hátralévő:

- ~~program feed és IFB/ducking~~
- ~~private/direct call~~
- **esemény- és minőségmonitoring.** Külön MONITOR fül: RTT, csomagvesztés,
  jitter, aktív vonalak és kliensek, a legrosszabb kapcsolatok, és egy
  eseménynapló időbélyeggel. A napló korlátos, csak a memóriában él, és a
  `docs/SECURITY.md` szerinti körre szorítkozik — állapotok, hibakódok,
  csatornanevek; se hang, se token, se hitelesítő adat.
- ATEM tally
- Bitfocus Companion/Stream Deck gateway
- WHIP/WHEP vagy Dante/AES67 gateway
- ~~esemény- és minőségmonitoring~~

A maradék három külső hardvert és protokollt igényel. Meg lehet írni őket, de
igazolni nem — és ebben a projektben eddig minden nem igazolt állítás hibásnak
bizonyult.

## M4 – Üzembiztosság

- redundáns signaling és media node
- hálózatváltási tesztek
- hosszú, 8–12 órás soak teszt
- TestFlight pilot produkció
- incidensnapló és privacy dokumentumok
- App Store kiadás előkészítése

## Nem része az első verziónak

- videó
- felvétel/rögzítés
- publikus csatornakereső
- hagyományos telefonhálózati/SIP hívások
