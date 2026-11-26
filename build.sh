#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="QuickSpot"
APP="build.noindex/$APP_NAME.app"
ICONSET="build.noindex/AppIcon.iconset"
ICNS="build.noindex/AppIcon.icns"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

mkdir -p build.noindex

echo "Building release binary..."
swift build -c release --product QuickSpotApp
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "Generating AppIcon.icns..."
rm -rf "$ICONSET" "$ICNS"
"$BIN_DIR/QuickSpotApp" --generate-iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$ICONSET"

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/QuickSpotApp" "$APP/Contents/MacOS/QuickSpotApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
for bundle in "$BIN_DIR"/*.bundle; do
  if [[ -d "$bundle" ]]; then
    cp -R "$bundle" "$APP/Contents/Resources/"
  fi
done

SIGN_ID="-"
if [[ -f .sign-id ]]; then
  SIGN_ID="$(head -n 1 .sign-id | xargs)"
fi

codesign --force --deep --options runtime -s "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built and signed: $APP"
