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

## Futtatás fizikai iPhone-on

A szerver címe nem az `Info.plist`-ben áll, hanem a `FLYABOVE_API_BASE_URL`
build settingben. Alapértéke üres, ami demó módot jelent; így egyetlen
környezethez sem kell a plistet szerkeszteni, és nem is kerül véletlenül
verziókezelésbe egy gépspecifikus IP-cím.

```sh
scripts/check-device-setup.sh   # megmondja, mi hiányzik
scripts/install-device.sh       # ha minden megvan
```

Az ellenőrző azért van, mert az Xcode hibái ezekre közvetettek: egy párosítatlan
eszköz „nincs ilyen destination"-ként jelenik meg, egy hiányzó fiók pedig
„requires a development team"-ként — egyik sem nevezi meg a tényleges teendőt.

A script megkeresi a gép LAN-címét, felépíti belőle a szerver URL-jét,
buildel, telepít és elindít. A címet szándékosan nem rögzíti: hálózatváltáskor
egy elavult cím a telefonon „a szerver nem érhető el" hibaként jelenik meg, ami
alkalmazáshibának látszik, pedig konfigurációs.

Előfeltételek, amiket a build nem tud elintézni:

1. **Xcode → Settings → Accounts:** érvényes Apple ID munkamenet. Lejárt
   munkamenetnél a build `Unable to log in with account` hibával áll meg.
2. **A telefon** csatlakoztatva, feloldva, és a gépet elfogadva („Trust").
3. **A dev stack fusson a LAN-on**, különben nincs mihez csatlakozni:

```sh
livekit-server --dev --bind 0.0.0.0
```

```sh
cd dev-server && LIVEKIT_URL=ws://$(ipconfig getifaddr en0):7880 npm start
```

A telefon és a gép ugyanazon a Wi-Fi-n legyen. A LiveKit `nodeIP` értéke a gép
LAN-címe kell legyen — enélkül a jelzés létrejön, de a média nem.

Első indításkor a telefon rákérdez a helyi hálózat használatára; enélkül a
kliens nem éri el a szervert. Ha ezt elutasítod, az app nem általános
„hálózati hibát" mond, hanem megnevezi a szervert és a két valószínű okot
(rossz Wi-Fi, vagy hiányzó helyi hálózat engedély) — ez a hiba telefonon
gyakori, és a szövegétől függ, hogy hol keresi az ember.

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
