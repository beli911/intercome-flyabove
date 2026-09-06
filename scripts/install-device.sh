#!/bin/bash
#
# Builds and installs on the connected iPhone, pointed at the dev server on this
# machine's LAN address.
#
# The address is detected rather than hardcoded: it changes with the network,
# and a stale one fails as "server unreachable" on the phone, which looks like
# an app bug rather than a configuration one.
#
# Prerequisites, both of which need you and not the build:
#   1. Xcode → Settings → Accounts: the Apple ID session must be valid.
#   2. The iPhone connected, unlocked, and trusting this Mac.
#
# Usage: scripts/install-device.sh [device-udid]
set -euo pipefail

cd "$(dirname "$0")/.."

IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
if [ -z "$IP" ]; then
  echo "Nincs LAN-cím. Wi-Fi?" >&2
  exit 1
fi
BASE_URL="http://$IP:8080/"

# Parsed from JSON, not from the table: the column layout shifts with device
# names, and picking the wrong field silently builds for a device id that does
# not exist.
DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  JSON=$(mktemp)
  xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
  DEVICE=$(python3 - "$JSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
for device in devices:
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    platform = (hardware.get("platform") or "").lower()
    if platform != "ios":
        continue
    if connection.get("pairingState") != "paired":
        continue
    if connection.get("tunnelState") in ("unavailable", None):
        continue
    print(hardware.get("udid", ""))
    break
PY
)
fi

if [ -z "$DEVICE" ]; then
  echo "Nincs használható iPhone." >&2
  echo >&2
  echo "Ellenőrizd:" >&2
  echo "  - a telefon kábellel csatlakozik és fel van oldva;" >&2
  echo "  - Xcode → Window → Devices and Simulators: a telefon párosítva van;" >&2
  echo "  - a telefonon elfogadtad a 'Trust This Computer?' kérdést." >&2
  echo >&2
  echo "Jelenlegi állapot:" >&2
  xcrun devicectl list devices >&2
  exit 1
fi

# Xcode knows the team once the Apple ID is signed in; reading it here beats
# hardcoding one that may belong to a different account.
TEAM="${FLYABOVE_DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ]; then
  TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeams 2>/dev/null \
    | grep -oE '"teamID" = "[^"]+"' | head -1 | cut -d'"' -f4 || true)
fi

echo "Eszköz: $DEVICE"
echo "API:    $BASE_URL"
echo "Csapat: ${TEAM:-(Xcode válassza)}"
echo

if ! curl -s -o /dev/null --max-time 3 "http://$IP:8080/v1/productions"; then
  echo "Figyelem: a dev API nem válaszol a $IP:8080 címen." >&2
  echo "Indítsd el: livekit-server --dev --bind 0.0.0.0" >&2
  echo "         és: cd dev-server && LIVEKIT_URL=ws://$IP:7880 npm start" >&2
fi

DERIVED=$(mktemp -d)
xcodebuild build \
  -project FlyAboveIntercom.xcodeproj \
  -scheme FlyAboveIntercom \
  -destination "platform=iOS,id=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  FLYABOVE_API_BASE_URL="$BASE_URL" \
  ${TEAM:+FLYABOVE_DEVELOPMENT_TEAM="$TEAM"}

APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name "FlyAboveIntercom.app" | head -1)
echo
echo "Telepítés: $APP"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" hu.flyabove.intercom
