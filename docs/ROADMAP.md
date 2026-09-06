# Fejlesztési terv

## M0 – Natív alap (elkészült)

- Xcode projekt és iOS target
- domain modellek
- csatorna UI, Listen, momentary Talk
- mikrofonengedély és voice-chat audio-session
- transport absztrakció
- alap unit tesztek

## M1 – Valós WebRTC hang

- backend/API szerződés rögzítése
- autentikáció és Keychain tokenkezelés
- WebRTC SDK integráció
- egy party-line csatorna kétirányú hangja
- STUN/TURN konfiguráció
- connection statistics és RTT kijelzés fejlesztői módban
- audio interruption és route-change kezelés

Elfogadási feltétel: két fizikai iPhone külön hálózatról tud PTT és nyitott
mikrofonos beszélgetést folytatni, bontás után automatikusan újracsatlakozik.

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
