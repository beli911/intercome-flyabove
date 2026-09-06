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

Hátralévő feladat:

- éles LiveKit telepítés vagy LiveKit Cloud projekt, TURN-nel
- éles token- és API-szerver a `docs/API.md` szerint
- **elfogadási feltétel:** két fizikai iPhone külön hálózatról tud PTT és nyitott
  mikrofonos beszélgetést folytatni, bontás után automatikusan újracsatlakozik

## M2 – Produkció és több csatorna

- produkcióválasztó és meghívó link/QR
- csatornánkénti Talk/Listen jogosultság
- több csatorna párhuzamos hallgatása
- latch/momentary PTT beállítás
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
