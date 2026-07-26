#!/bin/bash
# Build TrackpadStudio.dmg for distribution (unsigned — see README for the
# one-time Gatekeeper command users need after install).
set -euo pipefail
cd "$(dirname "$0")"

./make-app.sh

STAGE=$(mktemp -d)
cp -r TrackpadStudio.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f TrackpadStudio.dmg
hdiutil create -volname "Trackpad Studio" -srcfolder "$STAGE" -format UDZO TrackpadStudio.dmg
rm -rf "$STAGE"

echo "Built TrackpadStudio.dmg"
