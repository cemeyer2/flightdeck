#!/bin/bash
# Builds a universal release binary and wraps it in FlightDeck.app
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHS="${ARCHS:---arch arm64 --arch x86_64}"
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
  <key>CFBundleDisplayName</key><string>FlightDeck</string>
  <key>CFBundleIdentifier</key><string>app.flightdeck.Flightdeck</string>
  <key>CFBundleExecutable</key><string>FlightDeck</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
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
