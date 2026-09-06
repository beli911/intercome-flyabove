#!/bin/bash
#
# Tells you exactly what is missing before the app can go on a phone.
#
# Written because the errors Xcode gives for these are indirect: an unpaired
# device reports as "no such destination", and a missing account reports as
# "requires a development team" — neither of which names the actual fix.
set -uo pipefail

cd "$(dirname "$0")/.."

ok=0
fail=0

pass() { echo "  ✓ $1"; ok=$((ok + 1)); }
miss() { echo "  ✗ $1"; echo "      → $2"; fail=$((fail + 1)); }

echo "1. Fejlesztői fiók"
teams=$(defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null \
  | grep -oE '"teamID" = "[^"]+"' | cut -d'"' -f4 | sort -u)
if [ -n "$teams" ]; then
  pass "csapat: $(echo "$teams" | tr '\n' ' ')"
else
  miss "az Xcode nem lát fejlesztői csapatot" \
    "Xcode → Settings → Accounts → jelentkezz be az Apple ID-val. A kulcstartóban lévő tanúsítvány önmagában nem elég: a profil létrehozásához fiók kell."
fi

echo
echo "2. Csatlakoztatott telefon"
json=$(mktemp)
xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
device=$(python3 - "$json" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
for device in devices:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    if (hardware.get("platform") or "").lower() != "ios":
        continue
    name = device.get("deviceProperties", {}).get("name", "?")
    print("\t".join([
        name,
        hardware.get("udid", ""),
        connection.get("pairingState", "?"),
        connection.get("tunnelState", "?"),
    ]))
PY
)

usable=""
if [ -z "$device" ]; then
  miss "nincs iOS eszköz" "Csatlakoztasd kábellel, és oldd fel a képernyőt."
else
  while IFS=$'\t' read -r name udid pairing tunnel; do
    [ -z "$name" ] && continue
    if [ "$pairing" != "paired" ]; then
      miss "$name — párosítatlan" \
        "Xcode → Window → Devices and Simulators, majd a telefonon fogadd el a 'Trust This Computer?' kérdést."
    elif [ "$tunnel" = "unavailable" ] || [ -z "$tunnel" ]; then
      miss "$name — párosítva, de nincs csatlakoztatva" "Dugd rá kábellel, feloldott képernyővel."
    else
      pass "$name ($udid)"
      usable="$udid"
    fi
  done <<< "$device"
fi

echo
echo "3. Dev stack a LAN-on"
ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
if [ -z "$ip" ]; then
  miss "nincs LAN-cím" "Csatlakozz Wi-Fi-re; a telefonnak ugyanazon a hálózaton kell lennie."
else
  api=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$ip:8080/v1/productions" || true)
  lk=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$ip:7880" || true)
  # 401 is the healthy answer from the API: it exists and demands a token.
  [ "$api" = "401" ] && pass "dev API — http://$ip:8080" \
    || miss "dev API nem válaszol ($ip:8080)" "cd dev-server && npm start"
  [ "$lk" = "200" ] && pass "LiveKit — http://$ip:7880" \
    || miss "LiveKit nem válaszol ($ip:7880)" "livekit-server --dev --bind 0.0.0.0"

  node_ip=$(grep -o '"nodeIP": "[^"]*"' /tmp/livekit.log 2>/dev/null | tail -1 | cut -d'"' -f4)
  if [ -n "$node_ip" ] && [ "$node_ip" != "$ip" ]; then
    miss "a LiveKit régi címen áll ($node_ip, most $ip)" \
      "Hálózatváltás után indítsd újra a LiveKitet és a dev API-t, különben a telefon 15 másodperc után 'hálózati hiba'-t jelez."
  fi
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "Minden megvan. Telepítés:  scripts/install-device.sh"
  exit 0
fi
echo "$fail hiányzó feltétel. A fentiek után:  scripts/install-device.sh"
exit 1
