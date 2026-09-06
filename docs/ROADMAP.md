# Fejlesztési terv

## M0 – Natív alap (elkészült)

- Xcode projekt és iOS target
- domain modellek
- csatorna UI, Listen, momentary Talk
- mikrofonengedély és voice-chat audio-session
- transport absztrakció
- alap unit tesztek

## M1 – Valós WebRTC hang (kliensoldal kész, szerver nélkül nem igazolható)

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

Fejlesztői backend: [dev-server/](../dev-server/) — nem éles.

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

Nyitva mindkét review-ból: reconnect során explicit realtime-token megújítás,
a felhasználói profil visszatöltése érvényes access token mellett, a bázis-URL
normalizálása és HTTPS-kényszer éles buildben, valamint a LiveKit-token
szerveroldali publish-tiltásának end-to-end bizonyítása egy „rosszhiszemű"
klienssel.

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

- program feed és IFB/ducking
- private/direct call
- ATEM tally
- Bitfocus Companion/Stream Deck gateway
- WHIP/WHEP vagy Dante/AES67 gateway
- esemény- és minőségmonitoring

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
