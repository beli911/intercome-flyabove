# Fejlesztői útmutató

## Követelmények

- macOS és Xcode 26 vagy kompatibilis újabb verzió
- iOS 17+ deployment target
- fizikai iPhone mikrofon-, Bluetooth- és háttértesztekhez
- hálózat az első buildhez: a LiveKit SPM-csomagot fel kell oldani

## Futtatás és tesztelés

```sh
xcodebuild -project FlyAboveIntercom.xcodeproj -scheme FlyAboveIntercom \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Ha a `name=` alapú destination nem talál eszközt, használd az UDID-t
(`xcrun simctl list devices available`).

A LiveKit bináris frameworkjei dinamikusak, ezért a projekt
`LD_RUNPATH_SEARCH_PATHS` beállítása tartalmazza az
`@executable_path/Frameworks` útvonalat. Enélkül a build sikeres, de az app
indításkor dyld-hibával kilép — új target hozzáadásakor erre figyelj.

A `LiveKitTransportIntegrationTests` valódi LiveKit szervert igényel; enélkül
magát kihagyja. Lásd [dev-server/README.md](../dev-server/README.md).

## Projektelvek

- A UI nem hív közvetlenül WebRTC vagy HTTP SDK-t.
- Új hálózati megoldás az `IntercomTransport` implementációja legyen.
- Az `IntercomTransport.events()` és `AudioSessionControlling.events()` `async`.
  Actor esetén a szinkron változat nem elégíti ki a követelményt, és a hívó
  csendben üres folyamot kapna — ezért nincs alapértelmezett implementáció.
- Minden kapcsolatbontás állítsa le a mikrofon publikálását.
- Titkot, API-kulcsot és TURN jelszót nem commitolunk.
- A production URL és feature flag build configurationből, illetve az
  `Info.plist` `FlyAboveAPIBaseURL` kulcsából érkezzen.
- Tokent csak az `AuthService` írjon és olvasson; más réteg kész tokent kérjen tőle.
- A kliens által küldött jogosultság nem mérvadó; a szerver ellenőrizzen mindent.

## Branch és commit

- feature branch: `codex/<rövid-név>` vagy `feature/<rövid-név>`
- kis, önállóan buildelhető commitok
- pull requestben: cél, képernyőkép, tesztelés, ismert korlátok

## Definition of done

Egy változtatás akkor kész, ha:

1. buildel iOS Simulatorra;
2. a kapcsolódó unit tesztek lefutnak;
3. a hibás és megszakított állapot kezelve van;
4. VoiceOver feliratok megvannak az interaktív elemekhez;
5. a releváns dokumentáció frissült;
6. valódi audio módosítás esetén fizikai eszközön is ellenőrizték.
