# Biztonság és adatvédelem

## Kötelező production minimum

- HTTPS/WSS signaling és DTLS-SRTP média
- rövid életű hozzáférési token
- token tárolása iOS Keychainben
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

## Nyitott feladatok

- threat model a választott backendhez
- privacy manifest és App Store privacy answers
- certificate pinning szükségességének értékelése
- incidenskezelési és kulcsrotációs folyamat
