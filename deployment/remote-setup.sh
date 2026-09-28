#!/usr/bin/env bash
#
# A CÉLGÉPEN fut (a deploy.sh küldi fel ssh-n). Ne futtasd kézzel a Macen.
#
# Gépfüggetlen: ugyanez telepít Oracle Cloud Free-re, Hetzner VPS-re vagy a
# NAS-ra. Ami gépenként eltér (Docker telepítése, tűzfal), azt itt ÉSZLELI, nem
# feltételezi — és amit nem tud megoldani, azt megnevezi, nem hallgatja el.
#
# Bemenet (környezeti változók, a deploy.sh adja):
#   FLYCOM_DIR              a telepítés helye (alap: ~/flycom)
#   FLYCOM_API_DOMAIN       pl. api.intercom.flyabove.hu
#   FLYCOM_LIVEKIT_DOMAIN   pl. livekit.intercom.flyabove.hu
#   FLYCOM_OPEN_FIREWALL    1 = a gép saját tűzfalát megnyitja (alap: 1)
set -euo pipefail

DIR="${FLYCOM_DIR:-$HOME/flycom}"
API_DOMAIN="${FLYCOM_API_DOMAIN:?hiányzik a FLYCOM_API_DOMAIN}"
LK_DOMAIN="${FLYCOM_LIVEKIT_DOMAIN:?hiányzik a FLYCOM_LIVEKIT_DOMAIN}"
INCOMING="$DIR/.incoming.tgz"

say() { printf '\n==> %s\n' "$1"; }
die() { printf '\nHIBA: %s\n' "$1" >&2; exit 1; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null || die "nem root a felhasználó, és nincs sudo"
  SUDO="sudo"
fi

[ -f "$INCOMING" ] || die "nincs feltöltött csomag: $INCOMING (a deploy.sh küldi)"

# --- 1. Docker ---------------------------------------------------------------
say "Docker"
if $SUDO docker compose version >/dev/null 2>&1; then
  echo "megvan: $($SUDO docker --version) · $($SUDO docker compose version --short)"
else
  if command -v apt-get >/dev/null; then
    # A disztribúció saját csomagjai, nem a `curl | sh` telepítő: az Ubuntu
    # 22.04+ tárolójában a compose v2 is benne van.
    $SUDO apt-get update -qq
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2 \
      || die "a docker.io / docker-compose-v2 nem telepíthető ebből a tárolóból. Ubuntu 22.04+ kell, vagy telepíts Dockert kézzel."
    $SUDO systemctl enable --now docker
  else
    die "nincs Docker Compose, és ez nem apt-alapú rendszer. Telepítsd kézzel (NAS-on: a gyártó Docker-alkalmazása), aztán futtasd újra."
  fi
  $SUDO docker compose version >/dev/null || die "a Docker Compose telepítés után sem fut"
fi

# --- 2. A gép saját tűzfala --------------------------------------------------
# A felhős tűzfalat (Oracle: VCN Security List, Hetzner: Cloud Firewall) innen
# NEM lehet állítani — az a webes konzolban van, és a runbook leírja.
# Itt csak a gépen belüli szabályok: az Oracle Ubuntu-képe gyárilag REJECT-tel
# zár mindent a 22-es porton kívül, és ez a leggyakoribb néma hiba.
if [ "${FLYCOM_OPEN_FIREWALL:-1}" = "1" ]; then
  say "A gép tűzfala"
  PORTS_TCP="80 443 7881"; PORTS_UDP="7882"
  if command -v ufw >/dev/null && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in $PORTS_TCP; do $SUDO ufw allow "$p/tcp" >/dev/null; done
    for p in $PORTS_UDP; do $SUDO ufw allow "$p/udp" >/dev/null; done
    echo "ufw: megnyitva ($PORTS_TCP /tcp, $PORTS_UDP /udp)"
  elif command -v iptables >/dev/null && $SUDO iptables -S INPUT 2>/dev/null | grep -q -- "-j REJECT"; then
    for p in $PORTS_TCP; do
      $SUDO iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
        || $SUDO iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT
    done
    for p in $PORTS_UDP; do
      $SUDO iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
        || $SUDO iptables -I INPUT 1 -p udp --dport "$p" -j ACCEPT
    done
    if command -v netfilter-persistent >/dev/null; then
      $SUDO netfilter-persistent save >/dev/null 2>&1 && echo "iptables: megnyitva és elmentve (újraindítás után is marad)"
    else
      echo "iptables: megnyitva, de NINCS elmentve (nincs netfilter-persistent) — újraindítás után újra futtasd a deployt"
    fi
  else
    echo "nincs zárt helyi tűzfal (se aktív ufw, se REJECT szabály) — nincs teendő"
  fi
fi

# --- 3. A kód cseréje --------------------------------------------------------
# Friss mappába bontjuk ki, és csak utána cseréljük: így a régi fájlok nem
# maradnak ott (egy törölt forrásfájl nem futhat tovább), az előző kiadás pedig
# `.prev` néven visszaállítható.
say "Kód cseréje ($DIR)"
STAGE="$DIR/.stage"
$SUDO rm -rf "$STAGE"
mkdir -p "$STAGE"
tar -xzf "$INCOMING" -C "$STAGE"
[ -f "$STAGE/deployment/docker-compose.yml" ] || die "a csomagból hiányzik a docker-compose.yml"
if [ -f "$DIR/deployment/.env" ]; then
  cp -p "$DIR/deployment/.env" "$STAGE/deployment/.env"
fi
$SUDO rm -rf "$DIR/.prev"
if [ -d "$DIR/deployment" ]; then
  mkdir -p "$DIR/.prev"
  mv "$DIR/server" "$DIR/deployment" "$DIR/.prev/" 2>/dev/null || true
  [ -d "$DIR/scripts" ] && mv "$DIR/scripts" "$DIR/.prev/"
fi
mv "$STAGE"/* "$DIR/"
rmdir "$STAGE"
rm -f "$INCOMING"

# --- 4. Titkok ---------------------------------------------------------------
# Csak ha még nincs: egy meglévő .env felülírása mindenkit kiléptetne (JWT) és
# szétválasztaná az API és a médiaszerver kulcsát. A titkok ezen a gépen
# születnek, és sosem íródnak ki a kimenetre.
ENV_FILE="$DIR/deployment/.env"
say "Titkok"
if [ -f "$ENV_FILE" ]; then
  echo "a meglévő .env marad (a titkok nem változnak)"
  # A domain viszont a paraméter szerint frissül — költöztetésnél ez a cél.
  sed -i.bak -e "s|^FLYCOM_API_DOMAIN=.*|FLYCOM_API_DOMAIN=$API_DOMAIN|" \
             -e "s|^FLYCOM_LIVEKIT_DOMAIN=.*|FLYCOM_LIVEKIT_DOMAIN=$LK_DOMAIN|" \
             -e "s|^LIVEKIT_URL=wss://.*|LIVEKIT_URL=wss://$LK_DOMAIN|" "$ENV_FILE"
  rm -f "$ENV_FILE.bak"
else
  command -v openssl >/dev/null || die "nincs openssl a titkok generálásához"
  gen() { openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | cut -c1-48; }
  umask 077
  sed -e "s|^FLYCOM_API_DOMAIN=.*|FLYCOM_API_DOMAIN=$API_DOMAIN|" \
      -e "s|^FLYCOM_LIVEKIT_DOMAIN=.*|FLYCOM_LIVEKIT_DOMAIN=$LK_DOMAIN|" \
      -e "s|^LIVEKIT_URL=wss://.*|LIVEKIT_URL=wss://$LK_DOMAIN|" \
      -e "s|^JWT_SECRET=.*|JWT_SECRET=$(gen)|" \
      -e "s|^LIVEKIT_API_SECRET=.*|LIVEKIT_API_SECRET=$(gen)|" \
      "$DIR/deployment/env.production.example" > "$ENV_FILE"
  echo "új .env létrehozva (chmod 600), a titkok ezen a gépen generálva"
fi
chmod 600 "$ENV_FILE"
for key in JWT_SECRET LIVEKIT_API_SECRET; do
  len=$(grep -E "^$key=" "$ENV_FILE" | cut -d= -f2- | tr -d '\n' | wc -c | tr -d ' ')
  [ "$len" -ge 32 ] || die "$key rövidebb 32 karakternél a .env-ben ($len)"
done

# --- 5. Indítás --------------------------------------------------------------
say "Indítás (docker compose up --build)"
cd "$DIR/deployment"
$SUDO docker compose up -d --build --remove-orphans

say "Az API egészsége a konténeren belül"
for _ in $(seq 1 30); do
  if $SUDO docker compose exec -T flycom-api wget -qO- http://127.0.0.1:8080/health 2>/dev/null | grep -q '"ok"'; then
    echo "az API fut"
    break
  fi
  sleep 2
done
$SUDO docker compose exec -T flycom-api wget -qO- http://127.0.0.1:8080/health 2>/dev/null | grep -q '"ok"' \
  || { $SUDO docker compose logs --tail 40 flycom-api; die "az API 60 s alatt sem lett egészséges"; }

USERS=$($SUDO docker compose exec -T flycom-api node -e \
  "import('better-sqlite3').then(m=>console.log(new m.default('/var/lib/flycom/flycom.db',{readonly:true}).prepare('select count(*) c from users').get().c))" 2>/dev/null || echo "?")
echo "felhasználók az adatbázisban: $USERS"
if [ "$USERS" = "0" ]; then
  echo
  echo "Az adatbázis ÜRES — senki nem tud belépni. Első admin és produkció:"
  echo "  ssh <gép> -t 'cd $DIR/deployment && $SUDO docker compose exec flycom-api node scripts/admin.js setup --email <email> --name <név> --production <produkció>'"
fi

$SUDO docker compose ps
