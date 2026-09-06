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

Az audio route change, interruption és media-services-reset események kezelése a
következő mérföldkő része.

### Transport

Az `IntercomTransport` protokoll választja le a UI-t a hálózatról. Production
implementáció feladata:

1. HTTPS/WebSocket signaling;
2. WebRTC kapcsolat és ICE negotiation;
3. TURN fallback korlátozott hálózatokon;
4. csatornánkénti subscribe/unsubscribe;
5. PTT esetén a mikrofon track publish/unpublish vagy enable/disable;
6. reconnect és session-helyreállítás;
7. résztvevő- és beszédaktivitás események.

## Tervezett rendszerkép

```text
iOS kliens
  ├─ REST/WebSocket ── Auth + Signaling API ── adatbázis
  └─ WebRTC/DTLS-SRTP ── Media server ── többi kliens
                              └─ TURN relay

Audio/Dante gateway ── WHIP/RTP/WebRTC ───────┘
ATEM/video mixer ───── tally események ── Signaling API
```

## Döntésre váró backend

Elsődleges javaslat: Eyevinn Open Intercom kompatibilitás vagy annak saját
telepítése. Alternatíva a LiveKit. Nulláról mediasoup-alapú rendszert csak akkor
érdemes választani, ha az IFB/mix-minus szabályok miatt teljes kontroll szükséges.

Backend-választás előtt egy rövid technikai spike mérje meg:

- egyirányú és oda-vissza késleltetés Wi-Fi-n és 5G-n;
- újracsatlakozási idő;
- 4/10/20 résztvevő terhelése;
- iOS háttérbe helyezés;
- Bluetooth HFP stabilitás;
- több csatorna egyidejű fogadása.
