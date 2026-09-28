# Flycom backend — távoli szerveren, áthelyezhetően

A backend (API + saját LiveKit médiaszerver + Caddy TLS) egy **publikus gépen**
fut, és a telefonok egy **domainen** át érik el:

- `https://api.intercom.flyabove.hu` — az API
- `wss://livekit.intercom.flyabove.hu` — a médiajelzés

A telefon a domaint ismeri, nem a gépet. Ezért a szerver **bármikor
áthelyezhető** (Oracle → NAS → Hetzner): csak a DNS A-rekord változik, a
telefonokon semmit nem kell újratelepíteni, és — ha a titkok is átköltöznek —
senkinek nem kell újra bejelentkeznie.

| Fájl | Mit csinál |
|---|---|
| `deploy.sh` | telepít / frissít egy gépre ssh-n át, a Macről (újrafuttatható) |
| `remote-setup.sh` | a célgépen fut: Docker, a gép tűzfala, titkok, `compose up` |
| `data.sh` | adatbázis-mentés, visszatöltés, titkok átvitele gépek között |
| `docker-compose.yml`, `Caddyfile`, `livekit.yaml` | maga a stack |
| `../server/scripts/admin.js` | produkció, első admin, felhasználók (a szerveren belül) |

## Portok — mindhárom gépen ugyanez

| Port | Mire |
|---|---|
| 80/tcp | Let's Encrypt tanúsítvány-ellenőrzés + átirányítás |
| 443/tcp | API és médiajelzés (TLS) |
| 7882/udp | a hang (normál út) |
| 7881/tcp | a hang tartalék útja, ahol az UDP tiltott |

A 22/tcp (ssh) kell a telepítéshez. Más semmi ne legyen nyitva.

---

## 1. Oracle Cloud Free (a jelenlegi cél)

Egyszeri, a webes konzolban (cloud.oracle.com):

1. **Regisztráció.** Bankkártya kell az azonosításhoz, de az *Always Free*
   erőforrások nem kerülnek pénzbe. Home region: **Frankfurt** (a
   legközelebbi; utólag nem változtatható).
2. **Compute → Instances → Create instance**
   - Image: **Canonical Ubuntu 24.04**
   - Shape: **Ampere → VM.Standard.A1.Flex**, 2 OCPU / 12 GB (a free keret
     4 OCPU / 24 GB-ig ingyenes). Ha „Out of capacity” hibát ad, később újra
     kell próbálni — ez az Oracle ismert korlátja, nem a mi hibánk.
   - Networking: új VCN, **public IPv4 cím: igen**
   - SSH key: a saját publikus kulcsod (`~/.ssh/id_ed25519.pub`)
3. **A publikus IP legyen FOGLALT (reserved)**: Instance → Attached VNICs →
   IPv4 addresses → a publikus IP-nél *Reserved public IP*. Az alapértelmezett
   „ephemeral” cím leállításkor elveszhet, és akkor a DNS rossz gépre mutat.
4. **Felhős tűzfal**: Networking → Virtual Cloud Networks → a VCN → Security
   Lists → Default → *Add Ingress Rules*, forrás `0.0.0.0/0`:
   `80/TCP`, `443/TCP`, `7881/TCP`, `7882/UDP`.
   A gép *saját* tűzfalát (az Oracle Ubuntu-képe gyárilag REJECT-el) a
   `deploy.sh` nyitja meg magától.

⚠️ **Az Oracle visszaveheti a tétlen Always Free gépet** (ha 7 napon át a CPU
95. percentilise 20% alatt van). Egy intercom-szerver nagyrészt tétlen, tehát
ez valós kockázat. Ellenszer: a fiókot *Pay As You Go*-ra váltani (a free keret
azon belül is ingyenes marad, és a visszavétel nem vonatkozik rá) — ez döntés,
nem automatikus. A költözés a 3. pont szerint bármikor megy.

## 2. DNS és telepítés

A flyabove.hu DNS-szolgáltatójánál két **A-rekord** a gép publikus IP-jére:

```
api.intercom.flyabove.hu      A   <publikus IP>
livekit.intercom.flyabove.hu  A   <publikus IP>
```

Aztán a Macről, a repó gyökeréből:

```bash
deployment/deploy.sh ubuntu@<publikus IP>
```

A szkript előbb ellenőrzi, hogy a DNS már a gépre mutat (különben a
tanúsítvány-kérés elbukna és heti korlátba futna), feltölti a kódot (titok és
adatbázis nélkül — ezt a csomagon lemérve), telepíti a Dockert, megnyitja a gép
tűzfalát, a titkokat **a célgépen** generálja, elindítja a stacket, végül
kívülről végigméri (`scripts/verify-production-stack.sh`).

**Első admin és produkció** (egyszer; a jelszót a terminál kéri, visszhang
nélkül):

```bash
ssh -t ubuntu@<IP> 'cd ~/flycom/deployment && sudo docker compose exec flycom-api \
  node scripts/admin.js setup --email belian.benner@flyabove.hu --name "Belián" --production "Flycom"'
```

További kollégák:

```bash
ssh -t ubuntu@<IP> 'cd ~/flycom/deployment && sudo docker compose exec flycom-api \
  node scripts/admin.js add-user --email kamera@flyabove.hu --name "Kamera 1" --production "Flycom" --role operator'
```

(`--role`: `admin` · `supervisor` · `operator`. Áttekintés: `admin.js list`.)

**Az app** az éles címre, egyszer — utána gépcserénél sem kell újra:

```bash
scripts/install-device.sh --base-url https://api.intercom.flyabove.hu/ --release
```

**Frissítés** (új kód): ugyanaz a `deploy.sh` — a titkok és az adatbázis
maradnak, az előző kiadás a célgépen `~/flycom/.prev` alatt visszaállítható.

## 3. Költözés másik gépre (NAS vagy Hetzner)

```bash
# 1. friss mentés a régiről (a T7-re, ha csatolva van)
deployment/data.sh backup ubuntu@<RÉGI>
# 2. a titkok átvitele — csővezetéken, a képernyőre nem kerülnek
deployment/data.sh move-env ubuntu@<RÉGI> <felh>@<ÚJ>
# 3. DNS: a két A-rekord az ÚJ gép IP-jére (a TTL erejéig rövid kiesés)
# 4. telepítés az újra
deployment/deploy.sh <felh>@<ÚJ>
# 5. az adat visszatöltése (előtte a cél állapotát is menti)
deployment/data.sh restore <felh>@<ÚJ> <a 1. lépés fájlja>
# 6. a régi leállítása, ha minden rendben
ssh ubuntu@<RÉGI> 'cd ~/flycom/deployment && sudo docker compose down'
```

**Hetzner**: CAX11 (ARM) vagy CX22, Ubuntu 24.04, és a Cloud Firewallon
ugyanaz a négy port. Minden más azonos.

**NAS (UGREEN)**: a gyártó Docker-alkalmazása + SSH bekapcsolva kell. Mivel a
NAS a router mögött van:
- a routeren **port-továbbítás** a NAS belső IP-jére: 80, 443, 7881 TCP és 7882 UDP;
- a DNS A-rekord az **iroda publikus IP-jére** mutasson; ha az dinamikus,
  DDNS kell (vagy fix IP a szolgáltatótól);
- a LiveKit a külső címet STUN-nal maga deríti ki (`use_external_ip`), ehhez
  nincs teendő;
- ha a NAS-felhasználó a `docker` csoportban van, sudo nem kell; ha a Docker
  már telepítve van, a `remote-setup.sh` nem nyúl hozzá.
- ⚠️ ekkor az intercom az iroda netjén és áramán múlik.

## 4. Mentés

```bash
deployment/data.sh backup ubuntu@<IP>
```

Online SQLite-mentés (futó szerver mellett is konzisztens), a Macen
**ellenőrizve** (`integrity_check`, felhasználó- és produkciószám) és
SHA-256-tal. Személyes adat: **git és Drive tilos**; alap hely a T7
(`/Volumes/T7 BELIAN/programok/flycom-backups`), különben `~/flycom-backups`.

## Amit ez nem ad

- **Egy példány.** Ha a gép leáll, a folyó beszélgetés az addigi szobákban még
  élhet, de új csatlakozás nincs. Magas rendelkezésre állás nincs.
- **Az ütemezett mentés** nincs beállítva — kézi `data.sh backup`.
- **A TLS-t és a mobilhálózati hangot csak valódi gép és két valódi telefon
  (két szolgáltató) igazolja** — lásd a `verify-production-stack.sh` kimenetét.
