#!/usr/bin/env bash
#
# A Flycom adatai: mentés, visszaállítás, és költöztetés gépek között.
#
# Ez teszi a szervert ÁTHELYEZHETŐVÉ: ma Oracle Cloud Free, holnap a NAS vagy
# egy Hetzner gép — a telefonok a DOMAINT ismerik, nem a gépet, tehát a
# költözés után semmit nem kell újratelepíteni rajtuk.
#
#   deployment/data.sh backup  <ssh-cél> [mappa]     adatbázis-mentés a Macre
#   deployment/data.sh restore <ssh-cél> <fájl.db>   mentés visszatöltése
#   deployment/data.sh move-env <régi-cél> <új-cél>  a titkok (.env) átvitele
#
# A mentés SZEMÉLYES ADAT (nevek, e-mailek, jelszó-hashek): git és Drive TILOS.
# Alap hely: a T7, ha csatolva van, különben ~/flycom-backups (chmod 700).
#
# Környezet: FLYCOM_DIR (a célgépen, alap ~/flycom), SSH_OPTS (pl. "-i kulcs").
set -euo pipefail

CMD="${1:-}"; shift || true
RDIR="${FLYCOM_DIR:-\$HOME/flycom}"
read -r -a EXTRA <<< "${SSH_OPTS:-}"
rssh() { local t="$1"; shift; ssh ${EXTRA[@]+"${EXTRA[@]}"} "$t" "$@"; }
die() { echo "HIBA: $1" >&2; exit 1; }
# Ha a felhasználó a docker csoportban van (NAS-on jellemző), sudo nem kell;
# különben jelszó nélküli sudo (Oracle/Hetzner Ubuntu alapfelhasználója).
compose() { echo "cd $RDIR/deployment && if docker info >/dev/null 2>&1; then D=docker; else D='sudo -n docker'; fi && \$D compose $*"; }

default_dir() {
  if [ -d "/Volumes/T7 BELIAN/programok" ]; then echo "/Volumes/T7 BELIAN/programok/flycom-backups"
  else echo "$HOME/flycom-backups"; fi
}

# Egy mentés csak akkor mentés, ha ellenőrizve van: ép, és benne van, aminek
# benne kell lennie. A fájl jelenléte nem bizonyíték.
verify_db() {
  local f="$1"
  command -v sqlite3 >/dev/null || die "nincs sqlite3 a Macen, a mentés nem ellenőrizhető"
  [ "$(sqlite3 "$f" 'PRAGMA integrity_check;')" = "ok" ] || die "a mentés SÉRÜLT: $f"
  local users prods
  users=$(sqlite3 "$f" 'select count(*) from users;')
  prods=$(sqlite3 "$f" 'select count(*) from productions;')
  echo "  ép (integrity_check = ok) · $users felhasználó · $prods produkció · $(du -h "$f" | cut -f1)"
}

case "$CMD" in
  backup)
    TARGET="${1:?meg kell adni a célgépet}"; OUT="${2:-$(default_dir)}"
    mkdir -p "$OUT"; chmod 700 "$OUT"
    FILE="$OUT/flycom-$(date +%Y-%m-%d_%H%M%S).db"
    echo "==> Mentés: $TARGET → $FILE"
    # Az SQLite saját online-mentése: futó szerver mellett is konzisztens
    # pillanatkép (WAL-lal együtt), nem a nyers fájl másolata.
    rssh "$TARGET" "$(compose exec -T flycom-api node -e "\"import('better-sqlite3').then(async m=>{await new m.default('/var/lib/flycom/flycom.db').backup('/var/lib/flycom/export.db');})\"")" \
      || die "a mentés a célgépen nem sikerült"
    rssh "$TARGET" "$(compose exec -T flycom-api cat /var/lib/flycom/export.db)" > "$FILE"
    rssh "$TARGET" "$(compose exec -T flycom-api rm -f /var/lib/flycom/export.db)" || true
    chmod 600 "$FILE"
    verify_db "$FILE"
    shasum -a 256 "$FILE" | cut -d' ' -f1 > "$FILE.sha256"
    echo "  kész: $FILE"
    ;;

  restore)
    TARGET="${1:?meg kell adni a célgépet}"; FILE="${2:?meg kell adni a mentés fájlját}"
    [ -f "$FILE" ] || die "nincs ilyen fájl: $FILE"
    echo "==> A visszatöltendő mentés"
    verify_db "$FILE"
    # Felülírás előtt a cél jelenlegi állapotát is elmentjük — egy rossz
    # irányba futtatott restore így sem veszít adatot.
    echo "==> Előtte a cél mostani adatbázisa is mentésre kerül"
    "$0" backup "$TARGET" "$(default_dir)/restore-elotti"
    echo "==> Visszatöltés: $FILE → $TARGET"
    rssh "$TARGET" "$(compose stop flycom-api)"
    rssh "$TARGET" "$(compose run --rm --no-deps -T --entrypoint sh flycom-api -c "'cat > /var/lib/flycom/flycom.db.incoming && mv /var/lib/flycom/flycom.db.incoming /var/lib/flycom/flycom.db && rm -f /var/lib/flycom/flycom.db-wal /var/lib/flycom/flycom.db-shm'")" < "$FILE"
    rssh "$TARGET" "$(compose start flycom-api)"
    echo "==> A visszatöltött adat a célgépen:"
    sleep 3
    rssh "$TARGET" "$(compose exec -T flycom-api node scripts/admin.js list)"
    ;;

  move-env)
    FROM="${1:?meg kell adni a régi gépet}"; TO="${2:?meg kell adni az új gépet}"
    # A titkok csővezetéken mennek egyik gépről a másikra: sem a képernyőre,
    # sem a Mac lemezére nem kerülnek. Ugyanaz a JWT titok = senkinek nem kell
    # újra bejelentkeznie a költözés után.
    echo "==> A titkok átvitele: $FROM → $TO"
    rssh "$TO" "test ! -f $RDIR/deployment/.env" \
      || die "a célgépen már van .env — felülírás helyett nézd meg kézzel, melyik a helyes"
    rssh "$FROM" "cat $RDIR/deployment/.env" \
      | rssh "$TO" "mkdir -p $RDIR/deployment && umask 077 && cat > $RDIR/deployment/.env"
    rssh "$TO" "grep -c '^JWT_SECRET=.\{32,\}' $RDIR/deployment/.env >/dev/null" \
      || die "az átvitt .env hiányos (nincs benne érvényes JWT_SECRET)"
    echo "  kész (a titkok nem jelentek meg sehol). Következő: deploy.sh az új gépre."
    ;;

  *)
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
    [ -n "$CMD" ] && exit 2 || exit 0
    ;;
esac
