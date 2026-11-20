#!/bin/bash
# Builds a universal release binary and wraps it in FlightDeck.app
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHS="${ARCHS:---arch arm64 --arch x86_64}"
# Version shown in Finder and About; the release workflow sets these from the git tag (v1.2.3 → 1.2.3).
# Local builds: the latest tag's version, and "<commits since it>-<hash>" (e.g. 1.0.1 and 3-ge5d4b7e) as the build.
DESCRIBE="$(git describe --tags --long --match 'v[0-9]*' 2>/dev/null || true)"   # v1.0.1-3-ge5d4b7e
if [ -n "$DESCRIBE" ]; then TAG_VERSION="${DESCRIBE%%-*}"; TAG_VERSION="${TAG_VERSION#v}"; TAG_BUILD="${DESCRIBE#*-}"; fi
VERSION="${VERSION:-${TAG_VERSION:-1.0}}"
BUILD_NUMBER="${BUILD_NUMBER:-${TAG_BUILD:-1}}"
# The Command Line Tools lack the SwiftUIMacros plugin that the macOS 27 SDK needs for @State,
# so without full Xcode, build against the macOS 26 SDK instead (set SDKROOT to override).
CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [ -z "${SDKROOT:-}" ] && [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ] && [ -d "$CLT_SDK" ]; then
    export SDKROOT="$CLT_SDK"
fi
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/FlightDeck"
APP="build/FlightDeck.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FlightDeck"
# static app icon rendered by the app's own Dock tile renderer
ICONSET="$(mktemp -d)/FlightDeck.iconset"
"$BIN" --render-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FlightDeck</string>
  <key>NSHumanReadableCopyright</key><string>© Charlie Meyer</string>
  <key>CFBundleDisplayName</key><string>FlightDeck</string>
  <key>CFBundleIdentifier</key><string>app.flightdeck.Flightdeck</string>
  <key>CFBundleExecutable</key><string>FlightDeck</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>FlightDeck's Network and UPnP views list the devices on your local network (ARP table, Bonjour, UPnP, and an optional scan you start) and read your router's UPnP port mappings. Fleet finds your other Macs running FlightDeck and, only if you turn on sharing and pair them, lets them read this Mac's vital signs. Nothing is sent off your local network.</string>
  <key>NSBonjourServices</key><array><string>_airplay._tcp</string><string>_raop._tcp</string><string>_googlecast._tcp</string><string>_spotify-connect._tcp</string><string>_sonos._tcp</string><string>_amzn-wplay._tcp</string><string>_ipp._tcp</string><string>_ipps._tcp</string><string>_printer._tcp</string><string>_pdl-datastream._tcp</string><string>_uscan._tcp</string><string>_scanner._tcp</string><string>_smb._tcp</string><string>_afpovertcp._tcp</string><string>_ssh._tcp</string><string>_sftp-ssh._tcp</string><string>_rfb._tcp</string><string>_hap._tcp</string><string>_hap._udp</string><string>_homekit._tcp</string><string>_matter._tcp</string><string>_hue._tcp</string><string>_companion-link._tcp</string><string>_device-info._tcp</string><string>_http._tcp</string><string>_https._tcp</string><string>_flightdeck._tcp</string></array>
  <key>NSLocationUsageDescription</key><string>macOS shows Wi-Fi network names and access point addresses only to apps with Location access. FlightDeck's Wi-Fi page uses them to name nearby networks and notice roaming; it never reads your location.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>macOS shows Wi-Fi network names and access point addresses only to apps with Location access. FlightDeck's Wi-Fi page uses them to name nearby networks and notice roaming; it never reads your location.</string>
  <key>NSAppleEventsUsageDescription</key><string>FlightDeck reads your Login Items from System Events to list startup apps.</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>FlightDeck Trace</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSItemContentTypes</key><array><string>app.flightdeck.trace</string><string>app.meterline.trace</string></array>
  </dict></array>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>app.flightdeck.trace</string>
    <key>UTTypeDescription</key><string>FlightDeck Flight Recorder Trace</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>flightlog</string></array></dict>
  </dict></array>
  <key>UTImportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>app.meterline.trace</string>
    <key>UTTypeDescription</key><string>Meterline Flight Recorder Trace (legacy)</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>mltrace</string></array></dict>
  </dict></array>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"
