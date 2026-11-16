#!/bin/bash
# Builds a distributable FlightDeck.dmg.
#   SIGN_ID="Developer ID Application: Name (TEAMID)"   sign with hardened runtime (otherwise ad-hoc)
#   NOTARY_PROFILE=<keychain profile>                   notarize + staple (xcrun notarytool store-credentials …)
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bundle.sh
APP=build/FlightDeck.app
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements scripts/FlightDeck.entitlements --sign "$SIGN_ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
else
  echo "SIGN_ID not set: ad-hoc signed (fine for this Mac; Gatekeeper will warn elsewhere)"
fi
DMG=build/FlightDeck.dmg
rm -f "$DMG"
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname FlightDeck -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
if [ -n "${SIGN_ID:-}" ]; then codesign --force --timestamp --sign "$SIGN_ID" "$DMG"; fi
if [ -n "${SIGN_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
echo "Built $DMG"
