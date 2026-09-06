# API-szerződés (M1)

A kliens és a backend közös szerződése. A `docs/ARCHITECTURE.md` a rétegeket írja
le, ez a dokumentum a drótformátumot.

Bázis-URL: az `Info.plist` `FlyAboveAPIBaseURL` kulcsa, például
`https://api.intercom.flyabove.hu/`. Ha a kulcs üres, a kliens **demó módban**
indul: nincs bejelentkezés, nincs hálózati hang.

Minden kérés és válasz `application/json`, UTF-8. Az időbélyegek RFC 3339
formátumúak, tört másodperccel is elfogadottak (`2026-09-06T08:14:03.512Z`).
Az azonosítók UUID-k, kisbetűsen.

## Hitelesítés

Rövid életű `accessToken` (Bearer) és hosszú életű `refreshToken`. A kliens az
`AuthService`-ben 60 másodperc ráhagyással frissít, és egyszerre csak egy
frissítést indít, mert a szerver a refresh tokent használatkor rotálhatja.

### `POST /v1/auth/login`

```json
{ "email": "operator@flyabove.hu", "password": "…", "deviceName": "Beli iPhone" }
```

Válasz `200`:

```json
{
  "accessToken": "…",
  "refreshToken": "…",
  "expiresIn": 900,
  "user": {
    "id": "8b2b8a5c-1b7c-4e1e-9c1f-1e6c2e5c4a11",
    "displayName": "Benner Belián",
    "email": "operator@flyabove.hu"
  }
}
```

`expiresIn` másodperc, a válasz pillanatához képest. A `deviceName` a szerver
munkamenet-listájában jelenik meg, hogy egy elveszett telefon visszavonható legyen.

### `POST /v1/auth/refresh`

```json
{ "refreshToken": "…" }
```

Válasza megegyezik a login válaszával. `401` esetén a kliens **törli** a tárolt
munkamenetet és újra bejelentkezést kér. Bármely más hibakód (például `503`)
esetén megtartja: egy átmeneti szerverhiba nem mondhatja meg a hitelesítő
adatainkról, hogy érvénytelenek.

### `POST /v1/auth/logout`

`Authorization: Bearer <accessToken>`, üres törzs, válasz `204`.
A kliens „best effort"-ként hívja: ha nem sikerül, a szerver a refresh tokent
magától járatja le.

## Produkciók és csatornák

### `GET /v1/productions`

```json
[{ "id": "…", "name": "Aréna 2026", "role": "operator" }]
```

A `role` értéke `operator`, `supervisor` vagy `admin`. Az M1 kliens az első
produkciót választja; a választó felület az M2 része.

### `GET /v1/productions/{productionId}/channels`

```json
[
  {
    "id": "…",
    "name": "Kamera",
    "detail": "Kameraoperátorok",
    "colorHex": "31C48D",
    "canTalk": true,
    "canListen": true,
    "defaultListening": true,
    "participantCount": 4
  }
]
```

A `canTalk` / `canListen` a felület számára van: a tényleges kikényszerítés a
realtime tokenben történik. A `participantCount` induló érték, utána a realtime
kapcsolat frissíti.

## Realtime (LiveKit)

**Egy csatorna = egy LiveKit szoba.** Ez teszi party-line-ná az intercomot: ha a
„Kamera" vonalon beszélek, az nem hallatszhat a „Rendező" vonalon, és SFU mellett
ezt csak külön szobákkal lehet megbízhatóan kimondani. Ára csatornánként egy peer
connection, ami néhány csatornánál elfogadható.

Szobanév-konvenció: `p_{productionId}.c_{channelId}`.

### `POST /v1/productions/{productionId}/rt-tokens`

```json
{ "channelIds": ["…", "…"] }
```

Válasz `200`:

```json
{
  "url": "wss://rt.intercom.flyabove.hu",
  "grants": [
    {
      "channelId": "…",
      "roomName": "p_….c_…",
      "token": "<LiveKit JWT>",
      "expiresAt": "2026-09-06T10:14:03Z",
      "canPublish": true,
      "canSubscribe": true
    }
  ]
}
```

A szerver **csak azokra a csatornákra** ad grantet, amelyekre a felhasználónak
joga van, és a LiveKit JWT `video` grantjében a `canPublish` / `canSubscribe`
pontosan a fenti értékekkel egyezzen. A kliens a `canPublish: false` esetén
azonnal, olvasható hibaüzenettel utasítja el a Talk gombot, de a védelem a
tokenben van.

Ajánlott token-élettartam: 1 óra. A kliens újracsatlakozáskor új tokent kér.

### TURN

A LiveKit a saját ICE-konfigurációját küldi a szobába lépéskor. Ha a produkció
külön TURN-relayt használ, azt a `LiveKitIntercomTransport`
`extraIceServers` paraméterén kell átadni. Zárt vendéghálózatokon TURN/TLS 443
kell, különben a média nem jut ki.

## Hibaformátum

Minden nem 2xx válasz törzse:

```json
{ "error": { "code": "forbidden_channel", "message": "Nincs jogosultságod ehhez a csatornához." } }
```

| Kód | HTTP | Jelentés |
| --- | --- | --- |
| `invalid_credentials` | 401 | Hibás e-mail vagy jelszó |
| `token_expired` | 401 | Lejárt vagy visszavont token |
| `forbidden_channel` | 403 | Nincs jog a csatornához |
| `production_not_found` | 404 | Nincs ilyen produkció, vagy nem tagja a felhasználó |
| `rate_limited` | 429 | Túl sok kérés |
| `internal_error` | 500 | Szerverhiba |

A `message` felhasználónak mutatható, magyar nyelvű szöveg. A kliens a `401`-et
külön kezeli (munkamenet-frissítés vagy újrabejelentkeztetés), minden mást a
`message` megjelenítésével.

## Ami még nincs a szerződésben

Az alábbiak a következő mérföldkövekhez tartoznak, és a szerződés bővítését
igénylik: meghívó link/QR (M2), csatornánkénti hangerő és admin-küldte
konfiguráció (M2), program feed és IFB (M3), tally események (M3).
