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
    "participantCount": 4,
    "role": "line",
    "duckDecibels": 12
  }
]
```

A `role` értéke `line`, `program` vagy `priority`, és a duckolási szabályt
határozza meg — a produkció így egyszer nyilatkozik a szándékáról, a kliensnek
nem a nevekből kell kitalálnia:

| role | Mit tesz | Mikor halkul le |
| --- | --- | --- |
| `priority` | beszédre lehalkítja a többit | soha |
| `program` | adáshang | ha a prioritás szól, **vagy** ha a felhasználó beszél |
| `line` | sima vonal | csak ha a prioritás szól |

A `line` szándékosan **nem** halkul le, amikor a felhasználó beszél: az épp
azokat némítaná el, akikkel beszél. A `program` viszont igen — ez az IFB.

Mindkét mező elhagyható; hiányában `line` és 12 dB az alapérték.

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
| `not_found` | 404 | Ismeretlen végpont vagy erőforrás |
| `forbidden` | 403 | A szerep nem elég a művelethez |
| `invite_not_found` | 404 | Nincs ilyen meghívókód |
| `invite_expired` | 404 | A meghívó lejárt |
| `invite_used` | 404 | A meghívót már felhasználták |
| `invalid_peer` | 400 | Magával nem hívhat privát vonalat |
| `rate_limited` | 429 | Túl sok kérés |
| `internal_error` | 500 | Szerverhiba |

A `message` felhasználónak mutatható, magyar nyelvű szöveg. A kliens a `401`-et
külön kezeli (munkamenet-frissítés vagy újrabejelentkeztetés), minden mást a
`message` megjelenítésével.

## Meghívók

Egy meghívó egy produkciót nevez meg, lejár, és egyszer használható. Egy kód,
ami a műsor után is működik, bejárat annak, akinél megmaradt a csoportos üzenet.

A kódábécé szándékosan hiányos: nincs benne `O`, `I`, `L`, `0` és `1`. Ezeket a
kódokat talkbacken mondják be és sötétben gépelik. **A kliens és a szerver
ábécéjének karakterre egyeznie kell** — amit a szerver kiad, de a kliens
kiszűr, az begépelhetetlen kód.

### `POST /v1/productions/{productionId}/invites`

Csak `supervisor` vagy `admin` szerep. Válasz `201`:

```json
{
  "code": "MP9H",
  "url": "flyabove-intercom://invite/MP9H",
  "productionId": "…",
  "productionName": "Reggeli stúdió — 4. blokk",
  "expiresAt": "2026-09-07T01:04:23.489Z"
}
```

### `GET /v1/invites/{code}`

A kód megtekintése beváltás nélkül. A kód kis- és nagybetűvel is elfogadott.

### `POST /v1/invites/{code}/redeem`

Válasz `200`: `{ "production": ProductionSummary }`.

Hibakódok: `invite_not_found`, `invite_expired`, `invite_used`.

## Privát hívás

Egy privát hívás **efemer csatorna**, nem külön mechanizmus. A broadcast
intercomok is így modellezik a point-to-pointot, és így a már meglévő
konfigurációs push viszi el mindkét félhez: nincs csengetési protokoll, amit ki
kellene találni, és a lebontás útja is az, amit teszt fed.

### `POST /v1/productions/{productionId}/calls`

```json
{ "peerId": "…" }
```

Létrehoz egy `isPrivate: true` csatornát, amire pontosan a két félnek van
Talk+Listen joga. Válasz `201` az új csatorna leírójával — **vagy `200`, ha már
van vonal a két fél között**: aki olyan embert hív, akivel már beszél, arra a
vonalra akar rálépni, nem egy másodikat nyitni.

A csatorna neve **nézőpontonként más**: mindkét fél a másikét látja. Egy közösen
választott név egyik félnek sem mondana semmit.

### `DELETE /v1/productions/{productionId}/calls/{channelId}`

Csak a hívás két résztvevője zárhatja le. Válasz `204`; a konfigurációs
broadcast után a csatorna mindkét kliensről eltűnik.

## Admin által küldött konfiguráció

### `PATCH /v1/productions/{productionId}/channels/{channelId}`

Csak `supervisor` vagy `admin`. Módosítható: `name`, `detail`, `colorHex`, `role`, `duckDecibels`,
valamint `permissions` felhasználónként (`{ "<userId>": { "canTalk", "canListen" } }`).

A szerver a változás után **minden csatorna LiveKit szobájába** adatüzenetet
küld:

```json
{ "type": "configuration", "version": 12, "productionId": "…" }
```

Az üzenet szándékosan **csak verziót** hordoz, nem magát a konfigurációt: a
REST végpont marad az egyetlen igazságforrás, és egy kliens, aki lemaradt egy
üzenetről, a következővel úgyis felzárkózik.

A kliens ezután újraolvassa a csatornákat, és **először a visszavont Talkot
hallgattatja el** — az operátor épp nyomva tarthatja a gombot, és pontosan ez
az, amiért ez a push létezik.

## Fejlesztői referencia-implementáció

A `dev-server/` könyvtárban van egy Node-alapú, memóriában dolgozó
implementáció, kizárólag fejlesztéshez. Lásd [dev-server/README.md](../dev-server/README.md).

## Ami még nincs a szerződésben

Az alábbiak a következő mérföldkövekhez tartoznak, és a szerződés bővítését
igénylik: meghívó link/QR (M2), csatornánkénti hangerő és admin-küldte
konfiguráció (M2), program feed és IFB (M3), tally események (M3).
