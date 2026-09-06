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

DEVICE="${1:-}"
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null \
    | awk '/iPhone/ && /available/ {print $(NF-3)}' | head -1)
fi
if [ -z "$DEVICE" ]; then
  echo "Nincs elérhető iPhone. Csatlakoztasd, oldd fel, és fogadd el a gépet." >&2
  echo "Ismert eszközök:" >&2
  xcrun devicectl list devices >&2
  exit 1
fi

echo "Eszköz: $DEVICE"
echo "API:    $BASE_URL"
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
  FLYABOVE_API_BASE_URL="$BASE_URL"

APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name "FlyAboveIntercom.app" | head -1)
echo
echo "Telepítés: $APP"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" hu.flyabove.intercom
