#!/usr/bin/env bash
#
# Megméri, hogy az élesített Flycom tényleg az-e, aminek látszik.
#
# A szabály végig ugyanaz: egy ellenőrzés vagy MÉR, vagy kimondja, hogy nem
# futott le. Kihagyás sosem számít sikernek — egy zöld összegzés, ami alatt a
# TLS-ellenőrzés csendben elmaradt, rosszabb, mint a piros.
#
# Használat:
#   scripts/verify-production-stack.sh --domain api.intercom.flyabove.hu
#   scripts/verify-production-stack.sh --base http://127.0.0.1:8080 --no-tls
#
#   --livekit wss://...   a médiajelzés címe (alapból a LIVEKIT_URL környezetből)
#   --email a@b           ha megadod, a teljes API-szerződést is lefuttatja
#                         (a jelszót a check-api.mjs kéri be, sosem paraméterben)
set -u

DOMAIN=""; BASE=""; NO_TLS=0; LIVEKIT="${LIVEKIT_URL:-}"; EMAIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --livekit) LIVEKIT="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --no-tls) NO_TLS=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Ismeretlen kapcsoló: $1"; exit 2 ;;
  esac
done

[ -z "$BASE" ] && [ -n "$DOMAIN" ] && BASE="https://$DOMAIN"
if [ -z "$BASE" ]; then
  echo "Meg kell adni a --domain vagy a --base kapcsolót."; exit 2
fi

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32mRENDBEN\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mBUKIK\033[0m    %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mKIMARAD\033[0m  %s\n' "$1"; SKIP=$((SKIP+1)); }

echo "Flycom éles ellenőrzés — $BASE"
echo

# 1. Válaszol-e egyáltalán, és azt mondja-e, hogy egészséges.
HEALTH=$(curl -fsS -m 10 "$BASE/health" 2>/dev/null || true)
case "$HEALTH" in
  *'"status":"ok"'*) ok "a /health válaszol és egészséges" ;;
  "") bad "a /health nem válaszolt (DNS, tűzfal, vagy nem fut a stack)" ;;
  *)  bad "a /health váratlan választ adott: $HEALTH" ;;
esac

# 2. TLS. Ez a lényeg: iOS-en a titkosítatlan út élesben nem járható.
if [ "$NO_TLS" = "1" ]; then
  skip "TLS-ellenőrzés kihagyva (--no-tls) — EZ NEM ÉLES ELLENŐRZÉS"
  skip "tanúsítvány-lejárat nincs mérve (--no-tls)"
  skip "a titkosítatlan út nincs mérve (--no-tls)"
else
  HOST=${DOMAIN:-$(echo "$BASE" | sed -e 's|^https\{0,1\}://||' -e 's|[:/].*$||')}
  PEM=$(echo | openssl s_client -servername "$HOST" -connect "$HOST:443" 2>/dev/null | openssl x509 2>/dev/null || true)
  if [ -z "$PEM" ]; then
    bad "nincs kiolvasható TLS-tanúsítvány a $HOST:443 címen"
  else
    ISSUER=$(printf '%s' "$PEM" | openssl x509 -noout -issuer 2>/dev/null | cut -c1-70)
    ok "TLS-tanúsítvány kiolvasható ($ISSUER)"
    # Az `-checkend` a lejáratot MAGÁVAL az OpenSSL-lel dönti el. A korábbi
    # változat `date`-tel elemezte a "Oct 27 22:17:21 2026 GMT" alakot, és
    # macOS-en elhasalt rajta — egy hordozhatatlan dátum-elemzés ott hagyott egy
    # kimaradt ellenőrzést pont a lejárat helyén.
    NOTAFTER=$(printf '%s' "$PEM" | openssl x509 -noout -enddate 2>/dev/null | sed -n 's/^notAfter=//p')
    if ! printf '%s' "$PEM" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
      bad "a tanúsítvány LEJÁRT ($NOTAFTER)"
    elif ! printf '%s' "$PEM" | openssl x509 -noout -checkend 1209600 >/dev/null 2>&1; then
      bad "a tanúsítvány 14 napon belül lejár ($NOTAFTER)"
    else
      ok "a tanúsítvány több mint 14 napig érvényes ($NOTAFTER)"
    fi
  fi

  # A titkosítatlan út NEM szolgálhatja ki az API-t. Ha kiszolgálja, a TLS
  # megkerülhető, és pont az a kliens fogja megkerülni, amelyik nem tud róla.
  PLAIN=$(curl -fsS -m 10 --max-redirs 0 "http://$HOST/health" 2>/dev/null || true)
  case "$PLAIN" in
    *'"status":"ok"'*) bad "a http:// is kiszolgálja az API-t — a TLS megkerülhető" ;;
    *) ok "a http:// nem szolgálja ki az API-t" ;;
  esac
fi

# 3. Médiajelzés. Nem a hangot méri — azt csak két telefon tudja —, hanem hogy
#    a cím titkosított-e és egyáltalán elérhető-e.
if [ -z "$LIVEKIT" ]; then
  skip "LIVEKIT_URL nincs megadva, a médiajelzés nincs mérve"
else
  case "$LIVEKIT" in
    wss://*) ok "a LIVEKIT_URL titkosított (wss://)" ;;
    *) bad "a LIVEKIT_URL nem wss:// — a szerver élesben el sem indulna vele" ;;
  esac
  LKHOST=$(echo "$LIVEKIT" | sed -e 's|^wss\{0,1\}://||' -e 's|[:/].*$||')
  LKPORT=$(echo "$LIVEKIT" | sed -n 's|.*://[^:/]*:\([0-9]*\).*|\1|p'); LKPORT=${LKPORT:-443}
  if nc -z -G 5 "$LKHOST" "$LKPORT" 2>/dev/null || nc -z -w 5 "$LKHOST" "$LKPORT" 2>/dev/null; then
    ok "a médiajelzés címe elérhető ($LKHOST:$LKPORT)"
  else
    bad "a médiajelzés címe nem elérhető ($LKHOST:$LKPORT)"
  fi
  # ⚠️ A TURN-relét ez NEM méri. Hogy mobilhálózaton (CGNAT) átjön-e a hang,
  #    kizárólag két valódi telefon mondja meg, két külön szolgáltatón.
  skip "a TURN-relé NINCS mérve — ez csak két valódi telefonnal, két hálózaton dől el"
fi

# 4. A teljes API-szerződés, ha van kihez bejelentkezni.
if [ -z "$EMAIL" ]; then
  skip "API-szerződés nincs mérve (adj meg --email címet hozzá)"
else
  if node scripts/check-api.mjs --base "$BASE" --email "$EMAIL" --skip-writes; then
    ok "az API megfelel a docs/API.md szerződésnek"
  else
    bad "az API eltér a docs/API.md szerződéstől"
  fi
fi

echo
echo "Összegzés: $PASS rendben · $FAIL bukik · $SKIP kimarad"
[ "$SKIP" -gt 0 ] && echo "⚠️ A kimaradt ellenőrzések NEM sikerek."
[ "$FAIL" -gt 0 ] && exit 1
exit 0
