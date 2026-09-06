# Fejlesztői útmutató

## Követelmények

- macOS és Xcode 26 vagy kompatibilis újabb verzió
- iOS 17+ deployment target
- fizikai iPhone mikrofon-, Bluetooth- és háttértesztekhez

## Projektelvek

- A UI nem hív közvetlenül WebRTC vagy HTTP SDK-t.
- Új hálózati megoldás az `IntercomTransport` implementációja legyen.
- Minden kapcsolatbontás állítsa le a mikrofon publikálását.
- Titkot, API-kulcsot és TURN jelszót nem commitolunk.
- A production URL és feature flag build configurationből érkezzen.
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
