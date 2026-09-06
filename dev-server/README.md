# Fejlesztői szerver

A [docs/API.md](../docs/API.md) referencia-implementációja, **kizárólag
fejlesztéshez**. Azért van, hogy az M1 elfogadási feltétele — két telefon, valódi
hang — ne várjon az éles backendre.

Mindent memóriában tart, a jelszavak nyílt szövegek, és alapértelmezett titkos
kulccsal ír alá. **Éles környezetben nem használható**, és nem is arra készült.

## Előfeltételek

- Node 20+
- `livekit-server` (`brew install livekit`)

## Indítás

Két terminál kell.

**1. LiveKit**

```bash
livekit-server --dev --bind 0.0.0.0
```

Dev módban a kulcspár `devkey` / `secret`, ezt írja ki induláskor is.

**2. API**

```bash
cd dev-server
npm install
npm start
```

Alapértelmezés: `http://0.0.0.0:8080`, LiveKit `ws://localhost:7880`.

## Fizikai telefonhoz

A telefon nem éri el a `localhost`-ot, ezért a gép LAN-címét kell megadni:

```bash
# a gép címe, például 192.168.100.43
ipconfig getifaddr en0

LIVEKIT_URL=ws://192.168.100.43:7880 npm start
```

Az `Info.plist`-ben az `FlyAboveAPIBaseURL` legyen
`http://192.168.100.43:8080/`. A HTTP-t az `NSAllowsLocalNetworking` kivétel
engedi; éles forgalom HTTPS/WSS, ott nincs szükség kivételre.

Külön hálózatról (mobilnet) csak akkor működik, ha a gép kívülről elérhető —
ilyenkor TURN is kell. Ehhez érdemesebb LiveKit Cloud projektet használni:
állítsd be a `LIVEKIT_URL`, `LIVEKIT_API_KEY` és `LIVEKIT_API_SECRET`
környezeti változókat.

## Környezeti változók

| Változó | Alapérték | Leírás |
| --- | --- | --- |
| `PORT` | `8080` | API port |
| `JWT_SECRET` | `dev-only-secret` | app tokenek aláírása |
| `LIVEKIT_URL` | `ws://localhost:7880` | amit a kliens megkap |
| `LIVEKIT_API_KEY` | `devkey` | LiveKit kulcs |
| `LIVEKIT_API_SECRET` | `secret` | LiveKit titok |

## Produkciók

Kettő van, hogy a produkcióválasztó egyáltalán megjelenjen: egy produkcióval a
kliens szándékosan átlépi a választót.

| Név | Szerep |
| --- | --- |
| Bajnokok Ligája — Puskás | operator |
| Reggeli stúdió — 4. blokk | supervisor |

A csatornák és a névsor mindkettőnél ugyanaz — ez fejlesztői egyszerűsítés,
nem a szerződés része.

## Teszt-fiókok

Jelszó mindkettőhöz: `flyabove`.

| E-mail | Mindenki | Kamera | Rendező |
| --- | --- | --- | --- |
| `operator@flyabove.hu` | talk + listen | talk + listen | talk + listen |
| `kamera@flyabove.hu` | talk + listen | talk + listen | **csak listen** |

A `kamera@flyabove.hu` fiók szándékosan nem beszélhet a Rendező vonalon: így a
jogosultság-elutasítás valódi szerverrel is végigjátszható, nem csak unit
tesztben. A megtagadás a LiveKit tokenben történik, nem a kliens jóindulatán
múlik.

## Viselkedés, ami szándékos

- **A refresh token egyszer használatos.** Használatkor rotálódik, a régi
  azonnal érvénytelen. A kliens `AuthService`-e ezért indít egyszerre csak egy
  frissítést.
- **Jogosultság nélküli csatornára nincs grant.** A `rt-tokens` válasz egyszerűen
  kihagyja, nem `canPublish: false`-szal küldi.
- **A csatornalista szűr.** Amit a felhasználó se nem hallhat, se nem
  beszélhet rajta, azt meg sem kapja.

## Integrációs tesztek

Futó dev stack mellett a `LiveKitTransportIntegrationTests` valódi LiveKit
kapcsolaton méri a transportot. Stack nélkül a teszt magát kihagyja, így a
szokásos `xcodebuild test` enélkül is zöld.
