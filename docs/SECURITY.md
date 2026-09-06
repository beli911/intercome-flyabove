# Biztonság és adatvédelem

## Kötelező production minimum

- HTTPS/WSS signaling és DTLS-SRTP média
- rövid életű hozzáférési token
- token tárolása iOS Keychainben — megvalósítva:
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, hogy zárolt kijelzőnél is
  működjön az újracsatlakozás, de backuppal ne kerüljön másik eszközre
- szerveroldali produkció-, csatorna-, Talk- és Listen-jogosultság
- rate limiting és brute-force védelem
- TURN TLS hitelesítéssel; statikus publikus TURN jelszó tilos
- személyes és audiotartalom minimalizálása a naplókban
- dependency és konténer sérülékenységvizsgálat

## Audio

Az app nem rögzíthet hangot hallgatólagosan. Ha a jövőben felvétel készül, ahhoz
külön, jól látható állapot, jogalap és megőrzési szabályzat szükséges. A PTT
felengedése és a bontás azonnal tiltsa le a küldött mikrofon tracket.

## Naplózás

Engedélyezett: session ID, hibakód, kapcsolatállapot, jitter/packet loss aggregátum.
Alapértelmezésben tiltott: nyers audio, access token, TURN credential, teljes név
és IP-cím hosszú távú megőrzése.

## Kliensoldali állapot (M1)

- `AuthService`: egyszerre egy token-frissítés; `401`-re a munkamenet törlődik,
  átmeneti szerverhibára megmarad.
- A Talk gomb kényszerű elengedése interruption, eszközleválasztás,
  újracsatlakozás és szerveroldali jogvesztés esetén.
- A csatornajogosultság a felületen csak kényelmi jelzés; a kikényszerítés a
  szerver által kiadott LiveKit tokenben történik.

## Nyitott feladatok

- threat model a választott backendhez
- privacy manifest és App Store privacy answers
- certificate pinning szükségességének értékelése
- incidenskezelési és kulcsrotációs folyamat
