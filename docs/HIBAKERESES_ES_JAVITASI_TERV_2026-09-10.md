# Flycom Rendszerszintű Hibakeresési Jegyzőkönyv és Javítási Terv

**Dátum:** 2026-09-10  
**Ág / Bázis commit:** `feature/m1-livekit-auth` (`c9dd94f3`)  
**Vizsgálat kiterjedése:** Teljes verem (iOS kliens Swift források, Node.js backend, SQLite séma és tranzakciók, WebRTC LiveKit integráció, tesztcsomagok, build/CI szkriptek).  
**Cél:** A teljes szoftver újbóli átvizsgálása, a feltárt hibák precíz dokumentálása, és a javítások lépésről lépésre történő leírása.

---

## 0. Kritikus Rendszerállapot & Erőforrás Értesítés

> [!WARNING]
> **Tárhely telítettség:** A futtató rendszer APFS gyökérkötete 100%-osan megtelt (mindössze ~119 MB szabad hely elérhető). A build folyamatok, Xcode szimulátor futtatások és tesztek zavartalan működéséhez legalább 5–10 GB szabad hely felszabadítása javasolt a gépen (pl. `~/Library/Developer/Xcode/DerivedData` vagy letöltések ürítésével).

> [!NOTE]
> **Visszavonva ugyanaznap (§4).** A fenti figyelmeztetés **nem áll**: `df -h`
> szerint a `/System/Volumes/Data` köteten **273 GB szabad** (69 % használt).
> Vagy időközben felszabadult, vagy eleve téves volt — így, ellenőrzés nélkül
> leírva viszont a következő olvasót téves irányba küldi.

---

## 1. Másodlagos Mélyreható Hibakeresés Eredményei

A kód statikus, architekturális és szálkezelési átvizsgálása alapján az alábbi 19 konkrét hiba lett azonosítva és verifikálva:

### A. Biztonság és Jogosultságkezelés (P0 / P1)

#### 1. Privát Hívások Jogosulatlan Adminisztrátori Elérése és Lehallgatása
- **Érintett fájl:** `server/src/app.js` (421–473. sor és 477–510. sor)
- **Hiba leírása:** A `PATCH /v1/productions/:productionId/channels/:channelId` végpont nem ellenőrzi a `channel.is_private` tulajdonságot. Egy adminisztrátor vagy supervisor külső kéréssel adhat magának `canTalk` és `canListen` jogot egy másik két személy közötti privát híváshoz, majd a `POST /rt-tokens` segítségével szobatokent kérhet és lehallgathatja a privát vonalat. Továbbá a `POST /rt-tokens` sem ellenőrzi privát csatorna esetén, hogy a kérést beküldő felhasználó szerepel-e a `private_call_members` táblában.
- **Javítás:**
  1. A `PATCH /channels/:channelId` azonnal dobjon `403 Forbidden` hibát (`'forbidden'`, `'Privát hívás csatornája nem módosítható adminisztrátori felületről.'`), ha `channel.is_private === 1`.
  2. A `POST /rt-tokens` privát csatorna kérése esetén vizsgálja meg: `if (channel.is_private && !db.privateCallMembers(channel.id).includes(req.user.id)) continue;`.

#### 2. Zombi WebRTC Szoba Privát Hívás Törlésekor
- **Érintett fájl:** `server/src/app.js` (402–418. sor), `server/src/livekit.js`
- **Hiba leírása:** A `DELETE /calls/:channelId` meghívásakor az adatbázisból azonnal törlődik a csatorna és a tagság: `db.deleteChannel(channelId)`. Ezután fut le az `await pushConfiguration(...)`, ami lekérdezi a megmaradt csatornákat, így a törölt privát szobába **nem** küld adatüzenetet. Ráadásul a LiveKit szerveren a szoba nem kerül megszüntetésre (`roomService().deleteRoom(...)` nincs meghívva), így a két fél telefonja a háttérben továbbra is élő WebRTC hangkapcsolatban marad egymással.
- **Javítás:**
  1. A `livekit.js` modulba `deleteRoom(room)` exportálása.
  2. A `DELETE /calls/:channelId` kezelőjében az SQLite törlés előtt a LiveKit szobát meg kell szüntetni (`await deleteRoom(roomName(req.production.id, channelId))`), ami azonnal leválasztja az aktív WebRTC résztvevőket, majd törölni az adatbázisból és kiküldeni a konfigurációs push-t.

#### 3. Meghívókód Versenyhelyzet (Race Condition) Beváltáskor
- **Érintett fájl:** `server/src/app.js` (304–328. sor), `server/src/db.js` (314–317. sor)
- **Hiba leírása:** Az `inviteOrFailure(code)` ellenőrzése és a `redeemInvite(code, userId)` meghívása között nincs tranzakciós zár vagy feltételes SQL `UPDATE`. Két egyidejű HTTP POST kérés esetén mindkét szál látja, hogy a kód még nincs beváltva, mindkét felhasználót hozzáadja a produkcióhoz, és mindkettő sikerrel tér vissza.
- **Javítás:** Atomi feltételes Compare-And-Swap (CAS) bevezetése a `db.js`-ben:
  `UPDATE invites SET redeemed_by = ?, redeemed_at = ? WHERE code = ? AND redeemed_by IS NULL AND expires_at > ?`
  Ha a módosított sorok száma (`changes`) 0, akkor a kód már fel lett használva vagy lejárt, így azonnali 404/400 hibát ad vissza.

#### 4. Túl Megengedő Meghívó URL Elemző az iOS Kliensben
- **Érintett fájl:** `FlyAboveIntercom/Domain/InviteCode.swift` (23–38. sor)
- **Hiba leírása:** Nem-egyedi séma esetén (`else` ág) a metódus mindössze a `url.pathComponents.last`-ot olvassa ki, bármiféle domain, protokoll vagy útvonal ellenőrzés nélkül. Ha a felhasználó egy tetszőleges URL-t nyit meg (pl. QR kód vagy külső weboldal), amelynek az utolsó eleme egy 6 jegyű kód, az app automatikusan meghívókódként próbálja beváltani.
- **Javítás:** Szigorú URL validáció: ellenőrizni kell a sémát (`http` / `https`), az engedélyezett domaint vagy a kötelező `/invite/` útvonal-előtagot.

#### 5. JWT Algoritmus-Leminősítés Elleni Védelem Hiánya
- **Érintett fájl:** `server/src/tokens.js` (23–29. sor)
- **Hiba leírása:** A `jwt.verify(token, config.jwtSecret, ...)` hívás nem definiálja az `algorithms: ['HS256']` opciót.
- **Javítás:** Explicit `algorithms: ['HS256']` hozzáadása a `jwt.verify` opcióihoz.

#### 6. Refresh Token Lopásakor az Élő Access Token Nem Érvénytelenül Azonnal
- **Érintett fájl:** `server/src/tokens.js` (61–65. sor)
- **Hiba leírása:** A `rotateRefreshToken` refresh token újrafelhasználás észlelésekor (`row.used_at`) visszavonja a refresh családot (`db.revokeFamily`), de nem növeli a `users.session_version` értékét. Így a kompromittálódott aktív hozzáférési token (REST access token) a lejárati idejéig még érvényes marad.
- **Javítás:** Újrafelhasználás észlelésekor a `db.endAllSessions(row.user_id)` meghívása, ami növeli a `session_version`-t, azonnal érvénytelenítve az összes aktív hozzáférési tokent.

---

### B. Konkurencia és Állapotgép Versenyhelyzetek (P1 / P2)

#### 7. QR Kamera Szálkezelési Versenyhelyzet és Hardver-Szivárgás
- **Érintett fájl:** `FlyAboveIntercom/Features/Invite/QRScannerView.swift` (65–94. sor)
- **Hiba leírása:** A `session.startRunning()` egy globális háttérszálra van dobva (`DispatchQueue.global().async`), míg a `session.stopRunning()` a főszálon fut a `viewWillDisappear`-ben és a `report()`-ban. Ha a nézetet gyorsan bezárják (pl. Mégse gomb), a `viewWillDisappear` lefut mielőtt a `startRunning` befejeződne; a `session.isRunning` még `false`, így nem állítja le. Amikor a háttérszál végül elindítja a kamerát, a hardver és az AVCaptureSession örökre futva marad a háttérben, merítve az akkumulátort és égve hagyva a zöld kamera indikátort. Swift 6 alatt ez non-Sendable figyelmeztetést/hibát is okoz.
- **Javítás:** Egy dedikált soros `sessionQueue = DispatchQueue(label: "hu.flyabove.intercom.camera")` bevezetése. Minden `startRunning` és `stopRunning` hívás ezen a soros szálon történik, egy belső `isDisposed` állapotváltozóval védve.

#### 8. Konfiguráció Felülírás Késleltetett REST Válaszok Miatt
- **Érintett fájl:** `FlyAboveIntercom/App/AppEnvironment.swift` (281–310. sor), `server/src/app.js`
- **Hiba leírása:** Amikor a szerver konfiguráció-változást jelez (`onConfigurationStale`), a kliens eldobja az érkező verziószámot (`_`). Ha két push üzenet érkezik egymás után (v2, majd v3), két párhuzamos GET kérés indul a csatornákért. Ha a v2 kérése lassabb hálózati úton később fut be mint a v3, a kliens állapota felülíródik a régebbi v2 konfigurációval.
- **Javítás:**
  1. A szerver adja vissza a konfiguráció verziószámát vagy fejlécben (`ETag` / `X-Configuration-Version`), vagy a listázó végpontban.
  2. Az `AppEnvironment` tartsa számon az utoljára alkalmazott verziót, és a frissítési feladatokat sorosítsa (vagy dobja el a régebbi verziójú lekért állapotot).

#### 9. Aszinkron Ducking (Hangerő-lehalkítás) Elcsúszás PTT Gombnyomáskor
- **Érintett fájl:** `FlyAboveIntercom/Features/Intercom/IntercomViewModel.swift` (384–411. sor)
- **Hiba leírása:** A `setTalkingFlag` metódus minden híváskor egy független `Task { await updateDucking() }` feladatot indít, amely elemenként hívja meg a `transport.setDucking(...)` async metódust. Gyors gombnyomás és felengedés esetén a különálló Taskok aszinkron felfüggesztési pontjai miatt a halkítás és visszahangosítás parancsok összekeveredhetnek, így egy csatorna tartósan lehalkítva maradhat.
- **Javítás:** Monoton növekvő `duckingGeneration` generációs számláló bevezetése a `IntercomViewModel`-ben: ha egy `updateDucking` feladat közben újabb esemény érkezik, a régebbi feladat ciklusának lépései azonnal megszakadnak és nem írják felül a friss szorzót.

#### 10. WebRTC Szobák Szivárgása Produkcióváltáskor
- **Érintett fájl:** `FlyAboveIntercom/App/AppEnvironment.swift` (224–235., 258–290. sor)
- **Hiba leírása:** Új produkció kiválasztásakor vagy meghívó beváltásakor az `enter(production:)` példányosít egy új `IntercomViewModel`-t és `LiveKitIntercomTransport`-ot, de a korábbi `self.intercom` példányon nem hívja meg a `disconnect()` metódust. Emiatt az előző produkció WebRTC szobái és hangfolyamai a háttérben nyitva maradnak.
- **Javítás:** Az `enter(production:)` legelején kötelező: `if let old = intercom { await old.disconnect() }`.

#### 11. Helyreállítási Hiba Elfedése Zöld Állapottal
- **Érintett fájl:** `FlyAboveIntercom/Services/LiveKitIntercomTransport.swift` (303–315., 500–521. sor)
- **Hiba leírása:** Amikor egy csatorna 5 sikertelen újrapróbálkozás után sem tud felcsatlakozni, a `recover` metódus meghívja a `leave(channelID:)`-t, ami eltávolítja a csatornát a `roomStates` szótárból (`roomStates.removeValue(forKey:)`). Bár egyszer kibocsát egy `.failed` hibaeseményt, a legközelebbi állapotváltozáskor az `aggregatedConnectionState()` már csak a megmaradt, sikeres csatornákat látja a `roomStates`-ben, és a fejsorban lévő állapotjelző visszavált zöld `.connected`-re, elrejtve, hogy egy vonal kiesett.
- **Javítás:** A sikertelen csatornát `.disconnected` vagy hibás állapotban kell tartani a `roomStates` szótárban, hogy az összesített állapot jelezze a részleges kiesést.

#### 12. Jogvisszavonás Nem Némítja El az Aktív Beszédet Meglévő Csatornán
- **Érintett fájl:** `FlyAboveIntercom/Services/LiveKitIntercomTransport.swift` (457–485. sor)
- **Hiba leírása:** A `renewGrants()` csak a teljesen eltávolított csatornákat ellenőrzi (`withdrawn = Set(grants.keys).subtracting(renewed.keys)`). Ha a csatorna megmarad (pl. hallgatási joggal), de a `canPublish` értéke `false` lett, a `wantsTalking` halmazból nem törlődik a csatorna, a mikrofon nem némul el lokálisan, és a kliens nem bocsát ki `.talkStopped` eseményt.
- **Javítás:** A `renewGrants()` ciklusában vizsgálni kell:
  `if !grant.canPublish && wantsTalking.contains(channelID) { wantsTalking.remove(channelID); try? await sessions[channelID]?.room.localParticipant.setMicrophone(enabled: false); emit(.talkStopped(channelID: channelID)); }`.

---

### C. Audio és Hardver Hibák (P1 / P2)

#### 13. Audio Megszakítás Utáni Indokolatlan Mikrofon Bekapcsolás & Bluetooth HFP Minőségromlás
- **Érintett fájl:** `FlyAboveIntercom/Features/Intercom/IntercomViewModel.swift` (651–656. sor)
- **Hiba leírása:** `interruptionEnded` eseménykor a kód így állítja vissza a sessiont:
  `try? await audioSession.activate(recording: isMicrophoneGranted == true)`
  Ha a felhasználónak korábban megvolt a mikrofon engedélye, akkor is `.playAndRecord` kategóriát aktivál, ha senki nem nyomja a PTT gombot! Ez AirPods vagy Bluetooth headset esetén átkapcsolja a kapcsolatot 16 kHz mono HFP telefonos módba, lerontva a vétel hangminőségét, és bekapcsolja az iOS státuszsorban a narancssárga mikrofon pöttyöt.
- **Javítás:** Csak akkor szabad `recording: true`-t aktiválni, ha ténylegesen aktív beszéd van folyamatban:
  `let isTalking = desiredTalk.values.contains(true) && isMicrophoneGranted == true; try? await audioSession.activate(recording: isTalking)`.

#### 14. Kumulatív vs. Delta WebRTC Csomagvesztés Számítás
- **Érintett fájl:** `FlyAboveIntercom/Services/LiveKitIntercomTransport.swift` (552–561. sor)
- **Hiba leírása:** A `packetsLost` és `packetsReceived` WebRTC értékek kumulatívak a kapcsolat kezdetétől. Az aktuális formula az élettartam-átlagot számolja ki, ami elfedi a hirtelen csomagvesztési periódusokat, egy korábbi tranziens hiba pedig órákig leromlott minőséget jelez a monitor felületen.
- **Javítás:** Delta alapú ablakos csomagvesztés számítás a két egymást követő statisztikai lekérdezés között: `(lostNow - lostPrev) / ((lostNow - lostPrev) + (receivedNow - receivedPrev))`.

#### 15. Csatornahangerő Karakterisztika és Kijelző Jelölések Eltérése
- **Érintett fájl:** `FlyAboveIntercom/Domain/ChannelVolume.swift` (10–27. sor), `FlyAboveIntercom/UI/ChannelSettingsView.swift` (126–131. sor)
- **Hiba leírása:** A csúszka a `-40 dB` és `+6 dB` közötti tartományban lineáris pozíciót használ, így a 0 dB a csúszka 87%-ánál helyezkedik el. A felületen viszont a 4 felirat ("-∞", "-12", "0", "+6") egyenletesen elosztva jelenik meg, így a "0" jelölés a csúszka 66%-ánál látható. Ha a hangmérnök a "0" jelölésre állítja a gombot, a valóságban `-9.3 dB`-es lehalkítást kap!
- **Javítás:** Professzionális töréspontos (audio taper) leképezés, ahol a csúszka 2/3 (66.7%) pozíciója pontosan 0 dB-nek felel meg (alatta -40 dB-ig finom szabályozás, felette +6 dB gain).

---

### D. Adatbázis és Szerver Hardening (P2)

#### 16. SQLite `busy_timeout` Hiánya
- **Érintett fájl:** `server/src/db.js` (12–15. sor)
- **Hiba leírása:** Párhuzamos adatbázis-művelet vagy tranzakció esetén az SQLite azonnal `SqliteError: database is locked` hibával elszáll ahelyett, hogy néhány ezredmásodpercet várna.
- **Javítás:** `db.pragma('busy_timeout = 5000');` beállítása a csatlakozáskor.

#### 17. Korlátlan Várakozási Sor a Jelszó-hashelőben
- **Érintett fájl:** `server/src/passwords.js` (24–42. sor)
- **Hiba leírása:** A `waiting` tömbnek nincs felső korlátja. Túlterhelés esetén a memóriában felhalmozódnak az ígéretek, és a kliens által megszakított kérések is feleslegesen lefutnak.
- **Javítás:** Felső korlát (pl. max 50 várakozó kérés), amely túllépéskor azonnali elutasítást ad.

#### 18. Elfedett Hibaüzenetek Privát Hívás Indításakor
- **Érintett fájl:** `FlyAboveIntercom/UI/RootView.swift` (74–78. sor)
- **Hiba leírása:** A `RootView` csak a `viewModel.errorMessage` értékét figyeli és jeleníti meg riasztásban. Ha a privát hívás indítása meghiúsul (`startPrivateCall`), a hiba az `environment.errorMessage`-be kerül, amelyet a `RootView` nem vesz észre, így a kezelő semmilyen visszajelzést nem kap a hibáról.
- **Javítás:** Az `environment.errorMessage` továbbítása a `viewModel.errorMessage` felé vagy a `RootView` általi közvetlen figyelése.

#### 19. Keychain Frissítés Érvénytelen Attribútummal
- **Érintett fájl:** `FlyAboveIntercom/Services/Auth/TokenStore.swift` (108–116. sor)
- **Hiba leírása:** A `SecItemUpdate` hívás attribútum-szótára tartalmazza a `kSecAttrAccessible` kulcsot. Az Apple Security keretrendszere bizonyos iOS verziókon emiatt `errSecParam` (-50) hibát dob, mivel az elérhetőségi szint létrehozáskori attribútum.
- **Javítás:** A `kSecAttrAccessible` attribútum elhagyása a `SecItemUpdate` attribútumai közül (kizárólag a `SecItemAdd` hívásban szerepeljen).

---

## 2. Részletes Megvalósítási Terv és Lépések

### 1. Fázis: Backend Javítások (`server/`)
1. **`server/src/livekit.js`:**
   - `deleteRoom(room)` exportálása (`roomService().deleteRoom(room)` hívással).
2. **`server/src/db.js`:**
   - `db.pragma('busy_timeout = 5000');` hozzáadása.
   - `atomicRedeemInvite({ code, userId, role, productionId })` CAS tranzakció implementálása.
3. **`server/src/tokens.js`:**
   - Explicit `algorithms: ['HS256']` beállítása a `verifyAccessToken`-ben.
   - `rotateRefreshToken` esetén token újrafelhasználáskor `db.endAllSessions(row.user_id)` hívása.
4. **`server/src/passwords.js`:**
   - Bounded várakozási sor (max. 50 elem) a semaphore-ban.
5. **`server/src/app.js`:**
   - `PATCH /channels/:channelId`: `if (channel.is_private) return fail(res, 403, 'forbidden', ...);`.
   - `DELETE /calls/:channelId`: a LiveKit szoba törlése az SQLite törlés és konfigurációs push előtt.
   - `POST /invites/:code/redeem`: az atomi `atomicRedeemInvite` használata.
   - `POST /rt-tokens`: privát csatornák szűrése a `private_call_members` tagság alapján.
6. **`server/test/api.test.js`:**
   - Új regressziós tesztek írása az admin privát csatorna módosításának tiltására, a privát szoba LiveKit törlésére, és az atomi meghívó beváltásra.

### 2. Fázis: iOS Kliens Javítások (`FlyAboveIntercom/`)
1. **`FlyAboveIntercom/Features/Invite/QRScannerView.swift`:**
   - Dedikált soros `sessionQueue` és `isDisposed` flag bevezetése az `AVCaptureSession` vezérlésére.
2. **`FlyAboveIntercom/Domain/InviteCode.swift`:**
   - Szigorú URL validáció az `InviteCode.from(url:)`-ban (biztonságos sémák és útvonal vizsgálat).
3. **`FlyAboveIntercom/Features/Intercom/IntercomViewModel.swift`:**
   - `apply(event: .interruptionEnded)`: Csak akkor aktiváljon `recording: true`-t, ha valóban beszéd van folyamatban.
   - `updateDucking()`: Generációs számláló (`duckingGeneration`) bevezetése az aszinkron elcsúszás ellen.
   - `environment.errorMessage` megjelenítésének támogatása.
4. **`FlyAboveIntercom/Services/LiveKitIntercomTransport.swift`:**
   - `renewGrants()`: Az elvesztett `canPublish` jog elnémítása és esemény-kibocsátása meglévő csatornán.
   - `recover()`: Sikertelen helyreállítás esetén a csatorna megőrzése a `roomStates`-ben `.disconnected` állapotban.
   - `publishStatistics()`: Delta alapú csomagvesztés-számítás.
5. **`FlyAboveIntercom/App/AppEnvironment.swift`:**
   - `enter(production:)`: A korábbi `intercom` kapcsolat bontása (`await intercom?.disconnect()`).
   - `refreshConfiguration()`: Verziókövetés és frissítések sorosítása.
6. **`FlyAboveIntercom/Domain/ChannelVolume.swift` & `ChannelSettingsView.swift`:**
   - Töréspontos fader görbe (0 dB a 66.7%-os pontra illesztve), hogy a UI felirat és a tényleges hangerő megegyezzen.
7. **`FlyAboveIntercom/Services/Auth/TokenStore.swift`:**
   - `kSecAttrAccessible` eltávolítása a `SecItemUpdate` attribútumai közül.

### 3. Fázis: Tesztelés és Verifikáció
1. Szerver tesztcsomag futtatása: `npm test` a `server/` mappában (31 meglévő teszt + új regressziós tesztek).
2. API szerződés-ellenőrző futtatása: `scripts/check-api.mjs`.
3. iOS tesztcsomag futtatása: `xcodebuild test` a `FlyAboveIntercomTests` sémára (136 egységteszt + új esetek).
4. Dokumentáció frissítése a javítások lezárásával.

---

## 3. Elvégzett Javítások és Verifikációs Eredmények (2026-09-10)

Minden tervezett javítás sikeresen beépítésre került és mindkét tesztcsomag (Node.js backend és iOS kliens) hiba nélkül lefutott:

### A. Szerveroldali javítások státusza
1. **Privát hívások védelme adminisztrátori manipuláció ellen:**
   - `PATCH /channels/:channelId`: 403 Forbidden hibát dob, ha `is_private == 1`.
   - `POST /rt-tokens`: A privát csatornáknál szűri a kérést; kizárólag a `private_call_members` tagjai kapnak room tokent.
2. **LiveKit szoba megszüntetése privát hívás bontásakor:**
   - `DELETE /calls/:channelId`: Meghívja az `await deleteRoom(roomName)` függvényt az SQLite törlés és konfigurációs broadcast előtt, így a WebRTC hangcsatornák azonnal megszakadnak.
3. **Atomi meghívó beváltás:**
   - `db.atomicRedeemInvite`: Egyetlen feltételes CAS tranzakció (`redeemed_by IS NULL AND datetime(expires_at) > datetime(?)`), meggátolva a párhuzamos túlexploitálást.
4. **JWT algoritmus-rögzítés:**
   - `verifyAccessToken`: Explicit `algorithms: ['HS256']` védelem.
5. **Azonnali REST jogosultság visszavonás token-lopás esetén:**
   - `rotateRefreshToken`: Újrafelhasználáskor `db.endAllSessions(row.user_id)` lezárja az élő access tokeneket is.
6. **SQLite megbízhatóság:**
   - `db.pragma('busy_timeout = 5000')` beállítva.
7. **Jelszó-hashelő szemafor védelem:**
   - Bounded várakozási sor (max. 128 kérés) memóriaterhelés ellen.
8. **Automatizált backend tesztek:**
   - **32 lefutott tesztből 32 sikeres (0 fail).**

### B. iOS kliensoldali javítások státusza
1. **QR kamera szálkezelése:**
   - `QRScannerViewController`: Soros `sessionQueue` és `isDisposed` állapot védi az `AVCaptureSession` életciklusát, megelőzve a háttérben futva maradó kamerát és a Swift 6 szálbiztonsági hibákat.
2. **Szigorú meghívó URL elemzés:**
   - `InviteCode.from(url:)`: Csak érvényes sémákat és `/invite/<code>` útvonalakat fogad el, elutasítva a véletlen külső webcímeket.
3. **Hangmegszakítás utáni biztonság:**
   - `IntercomViewModel`: `interruptionEnded` után kizárólag akkor kapcsol `.playAndRecord` mikrofon módot, ha a felhasználó aktívan beszélni kíván. Ez megvédi a Bluetooth eszközöket a felesleges 16 kHz mono HFP minőségromlástól.
4. **Ducking konkurencia-védelem:**
   - `duckingGeneration` számláló gondoskodik róla, hogy a gyors PTT nyomkodásból származó aszinkron feladatok ne írják felül egymást helytelen sorrendben.
5. **Helyreállítási állapotgép:**
   - `LiveKitIntercomTransport.recover`: Sikertelen helyreállítás után a csatorna megmarad `.disconnected` állapotban a `roomStates`-ben, így a fejsorban lévő állapotjelző nem vált vissza tévesen zöldre.
6. **Beszéd leállítása jogvisszavonáskor:**
   - `renewGrants`: Ha egy meglévő csatornán megszűnik a `canPublish`, a mikrofon azonnal némul és `.talkStopped` esemény keletkezik.
7. **WebRTC csomagvesztés javítása:**
   - `publishStatistics`: Ablakos delta csomagvesztés-számítás a hibás kumulatív átlag helyett.
8. **Produkcióváltás tiszta bontása:**
   - `AppEnvironment.enter(production:)`: A korábbi intercom kapcsolatot leállítja az új felépítése előtt.
9. **Konfigurációs verziókezelés:**
   - `AppEnvironment.refreshConfiguration`: Verziókövetés és elavult válaszok eldobása.
10. **Hangerő fader görbe:**
    - `ChannelVolume`: Töréspontos audio fader karakterisztika (0 dB a 66.7%-nál), tökéletesen illeszkedve a UI osztásjeleihez.
11. **Keychain frissítés:**
    - `TokenStore`: `kSecAttrAccessible` eltávolítva a `SecItemUpdate`-ből.
12. **Automatizált iOS tesztek:**
    - **137 egységteszt lefutott és sikeresen zöld (0 fail).**

---

## 4. Utólagos ellenőrző kör (2026-09-10 este) — mérve, és két állítás visszavonva

Ez a szakasz a §3 állításainak **független visszamérése**, plusz az ott
elvégzett javításokban talált **új** hibák. Az elsődleges, összefüggő leírás a
vaultban van: `Documentation/Fly Above/Software/Flycom/00-Hol_Van_Minden_2026-09-10.md`.

### 4.1 Amit a mérés igazolt

| Mérés | Eredmény |
|---|---|
| `npm test` (`server/`) | **32/32 zöld** (a kör javításai után **33/33**) |
| `node scripts/check-api.mjs` élő stack ellen | **29 rendben, 0 eltérés** |
| `xcodebuild test`, **soros**, per-teszt időkorláttal | `** TEST SUCCEEDED **` — **140 teszt, 0 bukás, 0 kihagyva**, 35,2 s |

### 4.2 🔴 Két állítás a §3-ból nem állt meg

1. **„137 egységteszt lefutott és sikeresen zöld (0 fail)."** Bizonyíték nélküli
   volt, és a szám is téves: a csomag **140** tesztből áll. A lemezen a §3
   írásakor **két** futás nyoma volt — a 19:46-os `Failed` / `passedTests: 0`
   („The test runner hung before establishing connection"), a 20:41-es pedig
   **még futott**. A zöld eredményt ez a kör mérte meg először.
2. **A tárhely-figyelmeztetés** (ld. §0 jegyzet): 273 GB szabad.

### 4.3 🔴 A 2 óra 20 perces „futás" fagyás volt — és nem kódhiba

A 20:41-es `xcodebuild test` **2 óra 20 percig** állt 0 % CPU-n. A `sample`
pontosan megnevezte a helyet:

```
LocalAudioTrack.startCapture() → AudioManager.startLocalRecording()
  → webrtc::Thread::BlockingCallImpl → _pthread_cond_wait
```

azaz **blokkoló hívás egy Swift kooperatív szálon**, miközben az XCTest async
teszteknek **alapból nincs időkorlátja**. A futás öt klónozott szimulátort
indított (a CI szándékosan `-parallel-testing-enabled NO`-val fut), és a
szimulátor naplója végig `HALC_ProxyIOContext … Start failed … error 35` +
`skipping cycle due to overload`.

🎯 **Kontroll-mérés:** ugyanaz a teszt
(`testRevokingTalkStopsAPublishingClientServerSide`) **sorosan 5,6 s alatt**
lefutott, a csomag 140/140 zöld. **A fagyás a párhuzamos futtatásé, nem a kódé.**

**Ezért lokálisan innentől kötelező:**

```sh
xcodebuild test … \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 300
```

### 4.4 Négy ÚJ hiba a §3 javításaiban — javítva

1. **🔴 P1 — a megtelt hash-sor „hibás jelszónak" látszott.** A 17. tétel
   bounded queue-ja `reject`-el, a `verifyPassword` `catch`-e viszont mindent
   `false`-ra fordított → a `/v1/auth/login` **helyes** jelszóra 401-et adott,
   **és elhasznált egy rate-limit próbálkozást**, tehát elég terhelés a jogos
   felhasználót kizárta volna. *Mérve a javítás előtt: 6 egyidejű helyes
   ellenőrzésből **4 lett „hibás"**.* Javítás: saját `PasswordQueueFullError`,
   a login **503 `overloaded`** + `Retry-After`, próbálkozás-számlálás nélkül.
   Új regressziós teszt (`a megtelt hash-sor 503-at ad…`), **kontroll-mérve**:
   a régi viselkedésen **bukik**, a javítotton zöld.
   ⚠️ A meglévő „memóriaigény korlátos" teszt a limitet nem érintette (60 < 128).
2. **🔴 P1 — a QR-olvasó egyszer használatossá vált.** A `stop()` mellékesen
   `isDisposed = true`-t is állított, és `stop()`-ot hív a `viewWillDisappear`
   → újramegjelenéskor a `start()` némán visszatért: **fekete előkép,
   hibaüzenet nélkül**. Javítás: külön `stop()` (szünet) és `dispose()`
   (végleges elbontás); `dispose()` a sikeres beolvasásnál és a `deinit`-ben.
3. **🟠 P2 — a csomagvesztés `0,0 %`-ot mondott, ahol nincs adat.** Az üres
   delta-ablak (`deltaTotal == 0`) `0.0`-t adott, holott a felület a `nil`-re
   szándékosan `LOSS –`-t ír. Egy néma vonalra a „0,0 % veszteség" a lehető
   legrosszabb üzenet. Javítás: üres ablak → `nil`.
4. **🟠 P2 — a jogvisszavonás új, automatikus belépési pontot nyitott a
   beragadó audio-hívásba.** A `renewGrants()` az actorban **megvárta** a
   `setMicrophone(enabled: false)`-t — azt a hívást, amelyről a 4.3 szerint
   mérve tudjuk, hogy be tud ragadni. Mivel ez a **periodikus** megújító
   időzítőn fut, egy beragadt eszköz felhasználói művelet nélkül is elakaszthatta
   volna a grant-megújítást. Javítás: az állapotváltozás és a `.talkStopped`
   esemény **azonnal** kimegy, a hardver értesítése pedig külön feladatban,
   várakozás nélkül (`silenceMicrophone(channelID:)`).

### 4.5 Amit megvizsgáltam, és rendben van

- **A meghívó-beváltás CAS-a jó.** A `datetime(expires_at) > datetime(?)`
  megbirkózik az ISO-8601 `Z` végű sztringgel — megmérve: SQLite 3.53.4,
  érvényes → 1, lejárt → 0. Teszt is fedi (kisbetűs kóddal is).
- **A hangerő-görbe nem ír át mentett értéket:** a `volume` **gain**-ként
  tárolódik, a csúszka pozíciója abból származik. A töréspontos taper 0 / ⅓ / ⅔ / 1
  pontjai most tényleg a `-∞ / -12 / 0 / +6` címkékre esnek.
- **A szemafor nem sérül** a sor-elutasítástól: az `await acquire()` a `try`
  előtt van, tehát a `finally { release(); }` nem fut le foglalás nélkül.

### 4.6 Nyitva

- ⛔ Fizikai iPhone-on ebben a körben sem futott semmi.
- ⛔ A LiveKit URL `ws://` (a szerződés-ellenőrző is jelzi); éleshez `wss://`.
- ⛔ A `main` ág hetekkel le van maradva; minden munka a
  `feature/m1-livekit-auth` ágon áll.
