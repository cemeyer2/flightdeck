#!/bin/bash
# Builds a distributable FlightDeck.dmg.
#   SIGN_ID="Developer ID Application: Name (TEAMID)"   sign with hardened runtime (otherwise ad-hoc)
#   TEAM_ID=<10-character team ID>                      required when SIGN_ID isn't "Name (TEAMID)" (e.g. a SHA-1)
#   NOTARY_PROFILE=<keychain profile>                   notarize + staple (xcrun notarytool store-credentials …)
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bundle.sh
APP=build/FlightDeck.app
if [ -n "${SIGN_ID:-}" ]; then
  # The root helper: pin launchd to this team's signature, then sign it before the app.
  HELPER="$APP/Contents/Library/LaunchServices/app.flightdeck.Flightdeck.helper"
  # A wrong team here means launchd never starts the helper, so stop rather than guess.
  if [ -z "${TEAM_ID:-}" ] && [[ "$SIGN_ID" == *"("*")" ]]; then TEAM_ID="${SIGN_ID##*(}"; TEAM_ID="${TEAM_ID%)}"; fi
  if ! [[ "${TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "Couldn't tell the team ID from SIGN_ID; set TEAM_ID to the 10-character Developer ID team." >&2; exit 1
  fi
  plutil -insert SpawnConstraint -json "{\"team-identifier\":\"$TEAM_ID\",\"signing-identifier\":\"app.flightdeck.Flightdeck.helper\"}" \
    "$APP/Contents/Library/LaunchDaemons/app.flightdeck.Flightdeck.helper.plist"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" --identifier app.flightdeck.Flightdeck.helper "$HELPER"
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
