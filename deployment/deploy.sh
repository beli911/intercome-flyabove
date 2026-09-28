#!/usr/bin/env bash
#
# A Flycom backend telepítése / frissítése egy távoli gépre, a Macről.
#
# Gépfüggetlen: a cél bármilyen gép, amire ssh-val be lehet lépni (Oracle Cloud
# Free, Hetzner, a NAS). Költöztetni a data.sh-val lehet — lásd a
# deployment/README.md-t.
#
# Használat:
#   deployment/deploy.sh ubuntu@1.2.3.4
#   deployment/deploy.sh ubuntu@1.2.3.4 --api-domain api.intercom.flyabove.hu \
#       --livekit-domain livekit.intercom.flyabove.hu
#
#   --dir <út>           a telepítés helye a célgépen (alap: ~/flycom)
#   --skip-dns-check     ne ellenőrizze, hogy a domainek a célgépre mutatnak
#   --no-firewall        ne nyúljon a célgép saját tűzfalához
#   -i <kulcs>           ssh-kulcs (továbbadva az ssh-nak)
#
# Újrafuttatható: a második futás csak frissít, a titkok (.env) és az adatbázis
# érintetlen marad.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=""; API_DOMAIN="api.intercom.flyabove.hu"; LK_DOMAIN="livekit.intercom.flyabove.hu"
REMOTE_DIR=""; DNS_CHECK=1; FIREWALL=1; SSH_OPTS=(-o ServerAliveInterval=30)
while [ $# -gt 0 ]; do
  case "$1" in
    --api-domain) API_DOMAIN="$2"; shift 2 ;;
    --livekit-domain) LK_DOMAIN="$2"; shift 2 ;;
    --dir) REMOTE_DIR="$2"; shift 2 ;;
    --skip-dns-check) DNS_CHECK=0; shift ;;
    --no-firewall) FIREWALL=0; shift ;;
    -i) SSH_OPTS+=(-i "$2"); shift 2 ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Ismeretlen kapcsoló: $1" >&2; exit 2 ;;
    *) TARGET="$1"; shift ;;
  esac
done
[ -n "$TARGET" ] || { echo "Meg kell adni a célgépet, pl. ubuntu@1.2.3.4 (--help)" >&2; exit 2; }

rssh() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

echo "==> Kapcsolat: $TARGET"
rssh true || { echo "Az ssh nem sikerült." >&2; exit 1; }
PUBLIC_IP=$(rssh 'curl -fsS -4 -m 10 https://api.ipify.org 2>/dev/null || wget -qO- -T 10 https://api.ipify.org 2>/dev/null || true')
echo "    a célgép publikus IPv4-címe: ${PUBLIC_IP:-(nem sikerült megállapítani)}"

# A Let's Encrypt a domainen át ellenőriz. Ha a DNS még nem a célgépre mutat,
# a tanúsítvány-kérés elbukik, és az ismételt bukások heti korlátba futnak —
# ezért ezt a telepítés ELŐTT nézzük meg, nem utána.
if [ "$DNS_CHECK" = "1" ]; then
  echo "==> DNS"
  for d in "$API_DOMAIN" "$LK_DOMAIN"; do
    got=$(dig +short A "$d" @1.1.1.1 | tail -1)
    if [ -z "$PUBLIC_IP" ]; then
      echo "    $d → ${got:-(nincs A rekord)}  (a célgép IP-je ismeretlen, nem összevethető)"
    elif [ "$got" = "$PUBLIC_IP" ]; then
      echo "    $d → $got  RENDBEN"
    else
      echo "    $d → ${got:-(nincs A rekord)}  — a célgép viszont $PUBLIC_IP" >&2
      echo >&2
      echo "Állítsd be a DNS-ben:  $d  A  $PUBLIC_IP" >&2
      echo "(vagy ha tudatosan így akarod: --skip-dns-check)" >&2
      exit 1
    fi
  done
fi

echo "==> Csomag"
PKG=$(mktemp -t flycom-deploy).tgz
# COPYFILE_DISABLE: a macOS tar különben `._*` fájlokat tenne a csomagba.
COPYFILE_DISABLE=1 tar -czf "$PKG" \
  --exclude node_modules --exclude '*.db' --exclude '*.db-wal' --exclude '*.db-shm' \
  --exclude '.env' --exclude '._*' --exclude '.DS_Store' \
  server deployment scripts/verify-production-stack.sh
# A titok soha nem mehet fel a csomagban — ezt mérjük, nem feltételezzük.
if tar -tzf "$PKG" | grep -E '(^|/)\.env$|\.db$' >/dev/null; then
  echo "A csomagba titok vagy adatbázis került — leállok." >&2; rm -f "$PKG"; exit 1
fi
echo "    $(tar -tzf "$PKG" | wc -l | tr -d ' ') fájl, $(du -h "$PKG" | cut -f1)"

DIR_EXPR='$HOME/flycom'
[ -n "$REMOTE_DIR" ] && DIR_EXPR=$(printf '%q' "$REMOTE_DIR")
rssh "mkdir -p $DIR_EXPR && cat > $DIR_EXPR/.incoming.tgz" < "$PKG"
rm -f "$PKG"

echo "==> Telepítés a célgépen"
# A telepítő FÁJLKÉNT megy fel, és a bemenete /dev/null. `bash -s`-sel a
# standard bemenetről futna, és az első `docker compose exec` / `apt-get`
# megenné a szkript hátralévő részét — félbemaradt telepítés, hibaüzenet nélkül.
rssh "cat > $DIR_EXPR/.remote-setup.sh" < deployment/remote-setup.sh
rssh "FLYCOM_DIR=$DIR_EXPR FLYCOM_API_DOMAIN=$(printf '%q' "$API_DOMAIN") \
      FLYCOM_LIVEKIT_DOMAIN=$(printf '%q' "$LK_DOMAIN") FLYCOM_OPEN_FIREWALL=$FIREWALL \
      bash $DIR_EXPR/.remote-setup.sh < /dev/null"

echo
echo "==> Ellenőrzés kívülről (TLS, jelzés, portok)"
# A tanúsítvány kiadása az első indításnál fél-egy percig is eltarthat.
for _ in $(seq 1 12); do
  curl -fsS -m 5 "https://$API_DOMAIN/health" >/dev/null 2>&1 && break
  sleep 5
done
scripts/verify-production-stack.sh --domain "$API_DOMAIN" --livekit "wss://$LK_DOMAIN" || {
  echo
  echo "Ha a /health nem válaszol: a FELHŐS tűzfal (Oracle: VCN → Security List;" >&2
  echo "Hetzner: Cloud Firewall; NAS: router port-továbbítás) valószínűleg még zárva:" >&2
  echo "  80/tcp, 443/tcp, 7881/tcp, 7882/udp" >&2
  exit 1
}

echo
echo "Kész. Az app éles buildje:"
echo "  scripts/install-device.sh --base-url https://$API_DOMAIN/ --release"
