# Flycom

A FlyAbove produkciós intercom alkalmazása iOS-re. A cél egy alacsony késleltetésű,
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
- meghívó QR/kód és deep link; admin által küldött konfigurációváltás;
- program feed, IFB ducking és prioritás vonal;
- privát hívás efemer csatornaként;
- monitor fül: RTT, csomagvesztés, jitter és munkamenet-eseménynapló;
- 136 teszt: unit (auth, tokentárolás, view model eseménykezelés) és
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

## Név és jelölés

A termék neve **Flycom**; a cég FlyAbove. A jel a „szintmérő" logóirány: négy
sáv, ami maga a hang, nem a mikrofon képe. Csak téglalapokból áll, ezért 18
ponton és hímzésben is megmarad.

Az app ikonja fordított — sárga sávok fekete alapon —, mert a telefon a
legtöbbször sötét kezdőlapon és sötét pultban van. Ugyanaz a rajz adja az
ikont és a felületen látható jelet: a
[`scripts/make-app-icon.swift`](scripts/make-app-icon.swift) és a
[`FlycomMark`](FlyAboveIntercom/UI/FlycomMark.swift) ugyanazokat az arányokat
használja.

Az Xcode target, a bundle azonosító (`hu.flyabove.intercom`) és a repository
neve szándékosan maradt a régi: átnevezésük provisioning profilokat, telepített
appokat és külső hivatkozásokat törne el, és az külön döntés.

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
