# FlyAbove Intercom

Natív iOS produkciós intercom alkalmazás. A cél egy alacsony késleltetésű,
többcsatornás, interneten és helyi hálózaton is használható kommunikációs rendszer.

## Jelenlegi állapot – 0.2

Kliensoldalon:

- natív SwiftUI alkalmazás iOS 17+-hoz;
- csatornalista, résztvevőszám, beszélőjelzés;
- csatornánkénti Listen kapcsoló és momentary Talk/PTT;
- mikrofonengedély és `AVAudioSession` voice-chat konfiguráció;
- audio interruption, route change és media-services-reset kezelés;
- bejelentkezés, Keychain tokenkezelés, automatikus token-frissítés;
- LiveKit-alapú `IntercomTransport` implementáció (csatorna = LiveKit szoba);
- RTT/bitráta overlay fejlesztői módban;
- a mobil UX javaslat vizuális rendszere: bejelentkezés, produkcióválasztó,
  intercom főképernyő, crew lista, csatorna beállítás, profil — sötét és
  napfény témával;
- produkcióválasztó, résztvevőlista jelenléttel, csatornánkénti hangerő;
- 92 teszt: unit (auth, tokentárolás, view model eseménykezelés) és
  integrációs, utóbbi valódi LiveKit szerverrel.

**Szerver nélkül nem szól.** Amíg az `Info.plist` `FlyAboveAPIBaseURL` kulcsa
üres, az app **demó módban** indul: bejelentkezés nélkül, helyi transporttal,
a felületen jelzett módon.

Fejlesztéshez a [dev-server/](dev-server/) könyvtárban van egy futtatható
referencia-backend (LiveKit + token/API szerver), amivel a teljes lánc
végigjátszható. Éles használatra nem alkalmas.

## Indítás

1. Nyisd meg a `FlyAboveIntercom.xcodeproj` projektet Xcode 26-tal.
2. Válassz iOS 17 vagy újabb szimulátort/eszközt.
3. Futtasd a `FlyAboveIntercom` scheme-et. Első build előtt Xcode feloldja a
   LiveKit SPM-függőséget, ez néhány percet vehet igénybe.
4. Valódi mikrofon és Bluetooth teszthez használj fizikai iPhone-t.

Szerver bekötése: írd be a bázis-URL-t az `Info.plist` `FlyAboveAPIBaseURL`
kulcsába (például `https://api.intercom.flyabove.hu/`), és az app a
bejelentkezési képernyővel indul.

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
- [API-szerződés](docs/API.md)
- [Vizuális rendszer](docs/DESIGN.md)
- [Fejlesztői szerver](dev-server/README.md)
- [Fejlesztési terv](docs/ROADMAP.md)
- [Fejlesztői útmutató](docs/DEVELOPMENT.md)
- [Biztonság és adatvédelem](docs/SECURITY.md)

## Technológia

- Swift 6
- SwiftUI + Combine (`ObservableObject`)
- AVFAudio / AVAudioSession
- strukturált Swift concurrency (actorok, `AsyncStream`)
- LiveKit `client-sdk-swift` 2.16 (WebRTC, DTLS-SRTP, ICE/TURN)
- Security.framework / Keychain

## Licenc

A repository jelenleg privát projektként kezelendő. Nyilvános licenc kiadása előtt
a tulajdonosnak külön licencfájlt kell választania.
