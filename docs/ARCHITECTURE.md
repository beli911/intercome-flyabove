# Architektúra

## Cél

A kliens feladata a felhasználó hitelesítése, a produkció és a csatornák
megjelenítése, valamint kis késleltetésű kétirányú hang küldése és fogadása.
A felület nincs összekötve egy konkrét médiaszerverrel.

## Rétegek

### UI

SwiftUI nézetek. A `RootView` megjeleníti a kapcsolatot, a `ChannelCard` pedig egy
party-line csatorna Listen és Talk állapotát. A Talk jelenleg momentary PTT:
érintéskor bekapcsol, felengedéskor kikapcsol.

### Presentation

Az `IntercomViewModel` a `@MainActor`-on fut. Optimisztikusan frissíti a felületet,
transport hiba esetén visszaállítja az előző csatornaállapotot. Bontáskor minden
Talk állapotot kötelezően töröl.

### Domain

Az `IntercomConfiguration`, `IntercomChannel` és `ConnectionState` nem függ UI-
vagy hálózati keretrendszertől. `Sendable` típusok, ezért actorok között biztonságosan
átadhatók.

### Audio session

Az `AudioSessionController` a natív iOS audio útvonalat `.playAndRecord` és
`.voiceChat` módban aktiválja. A kért mintavétel 48 kHz, az I/O buffer 10 ms.
Engedélyezett a Bluetooth HFP és alapértelmezésként a telefon hangszórója.

A route change, interruption és media-services-reset eseményeket az
`AudioSessionController` `AsyncStream`-en adja tovább, `AVFoundation`-típusok
nélkül, hogy a view model és a tesztjei ne függjenek a keretrendszertől.
A view model reakciói:

| Esemény | Reakció |
| --- | --- |
| interruption began | minden Talk azonnal el (hívás/Siri elvitte a mikrofont) |
| interruption ended, `shouldResume` | session újraaktiválás; a momentary Talk nem áll vissza magától |
| route change, `deviceDisconnected` | Talk el (a beépített mikrofonra visszaesés élő helyszínen gerjedés) |
| media services reset | teljes bontás, a felhasználó újracsatlakoztat |

LiveKit a track publikálásakor maga is újrakonfigurálja a session-t; a fenti
értékek azok, amelyek addig, illetve a demó transporttal érvényesek.

### Auth

Az `AuthService` az egyetlen hely, amely a tokentárolót írja és olvassa, és
amely eldönti, mikor kell frissíteni. Actor, mert a frissítésnek akkor is
pontosan egyszer kell megtörténnie, ha több hívó (csatornalista, realtime token,
reconnect) egyszerre veszi észre a lejáratot — a szerver a refresh tokent
használatkor rotálhatja.

A `KeychainTokenStore` `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
attribútummal ír: az appnak van `audio` háttérmódja, és zárolt kijelzőnél is
újracsatlakozhat, de a hitelesítő adat nem kerülhet át másik eszközre backupon.

Egy `401` a refresh híváskor törli a munkamenetet; bármely más hiba (például
`503`) megtartja.

### Transport

Az `IntercomTransport` protokoll választja le a UI-t a hálózatról. Két
implementáció van:

- `PreviewIntercomTransport` — helyi demó, szerver nélkül futtatható;
- `LiveKitIntercomTransport` — production.

A transport a saját megfigyeléseit `IntercomTransportEvent` folyamon adja vissza
(kapcsolatállapot, résztvevőszám, beszélőjelzés, kényszerű Talk-leállítás,
statisztika).

#### Miért egy szoba csatornánként

Ez teszi party-line intercommá a rendszert konferenciahívás helyett: ha a
„Kamera" vonalon beszélek, az nem hallatszhat a „Rendező" vonalon, és SFU mellett
ezt csak külön szobákkal lehet megbízhatóan kimondani. Ára csatornánként egy peer
connection, ami a produkciók néhány csatornájánál elfogadható, és pontosan ez
adja az M2 „több csatorna párhuzamos hallgatása" pontját.

A csatlakozás lusta: az app csak azokba a szobákba lép be, amelyeket hallgatunk,
Talk-nyomásra pedig belép a hiányzóba. Egy tétlen kliens nem tart fenn peer
connectiont, amire nincs szüksége.

#### Jogosultság

A `canPublish` / `canListen` a felületnek szól, hogy olvasható hibaüzenettel
tudjon elutasítani. A kikényszerítés a szerver által kiadott LiveKit tokenben van.

## Tervezett rendszerkép

```text
iOS kliens
  ├─ REST/WebSocket ── Auth + Signaling API ── adatbázis
  └─ WebRTC/DTLS-SRTP ── Media server ── többi kliens
                              └─ TURN relay

Audio/Dante gateway ── WHIP/RTP/WebRTC ───────┘
ATEM/video mixer ───── tally események ── Signaling API
```

## Backend-döntés (M1)

**LiveKit**, `client-sdk-swift` 2.16. Indoklás: kész SFU, hivatalos Swift SDK,
beépített reconnect és ICE/TURN kezelés, így az M1–M2 kliensfunkciók nem
médiaszerver-fejlesztésen múlnak. A szerződés a [docs/API.md](API.md)-ban van.

A backend feladata egy LiveKit telepítés (vagy LiveKit Cloud projekt) és egy
token/API szerver. A kliens nem beszél közvetlenül a LiveKit admin API-val.

Üzembe állítás előtt egy rövid technikai spike mérje meg:

- egyirányú és oda-vissza késleltetés Wi-Fi-n és 5G-n;
- újracsatlakozási idő;
- 4/10/20 résztvevő terhelése;
- iOS háttérbe helyezés;
- Bluetooth HFP stabilitás;
- több csatorna egyidejű fogadása.
