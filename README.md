# FlyAbove Intercom

Natív iOS produkciós intercom alkalmazás. A cél egy alacsony késleltetésű,
többcsatornás, interneten és helyi hálózaton is használható kommunikációs rendszer.

## Jelenlegi állapot – 0.1 alap

- natív SwiftUI alkalmazás iOS 17+-hoz;
- csatornalista és résztvevőszám;
- csatornánkénti Listen kapcsoló;
- nyomva tartandó Talk/PTT gomb;
- mikrofonengedély és `AVAudioSession` voice-chat konfiguráció;
- kapcsolat- és hibastátusz;
- cserélhető `IntercomTransport` réteg;
- unit tesztek a kapcsolat és a PTT alapállapotaihoz.

A jelenlegi `PreviewIntercomTransport` helyi demó: a felület és az audio-session
működik, de még nem továbbít hangot hálózaton. A következő mérföldkő a WebRTC
transport és a signaling/backend szerződés.

## Indítás

1. Nyisd meg a `FlyAboveIntercom.xcodeproj` projektet Xcode 26-tal.
2. Válassz iOS 17 vagy újabb szimulátort/eszközt.
3. Futtasd a `FlyAboveIntercom` scheme-et.
4. Valódi mikrofon és Bluetooth teszthez használj fizikai iPhone-t.

Parancssoros ellenőrzés:

```sh
xcodebuild -project FlyAboveIntercom.xcodeproj \
  -scheme FlyAboveIntercom \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

## Dokumentáció

- [Architektúra](docs/ARCHITECTURE.md)
- [Fejlesztési terv](docs/ROADMAP.md)
- [Fejlesztői útmutató](docs/DEVELOPMENT.md)
- [Biztonság és adatvédelem](docs/SECURITY.md)

## Technológia

- Swift 6
- SwiftUI + Combine (`ObservableObject`)
- AVFAudio / AVAudioSession
- strukturált Swift concurrency
- tervezett: WebRTC, WebSocket/HTTPS signaling, STUN/TURN

## Licenc

A repository jelenleg privát projektként kezelendő. Nyilvános licenc kiadása előtt
a tulajdonosnak külön licencfájlt kell választania.
