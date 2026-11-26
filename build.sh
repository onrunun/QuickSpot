#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="QuickSpot"
APP="build.noindex/$APP_NAME.app"
ICONSET="build.noindex/AppIcon.iconset"
ICNS="build.noindex/AppIcon.icns"

UNIVERSAL=0
APP_VERSION="${APP_VERSION:-}"
APP_BUILD="${APP_BUILD:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal)
      UNIVERSAL=1
      shift
      ;;
    --version)
      APP_VERSION="$2"
      shift 2
      ;;
    --build-number)
      APP_BUILD="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--universal] [--version X.Y.Z] [--build-number N]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

mkdir -p build.noindex

BUILD_ARGS=(-c release --product QuickSpotApp)
if [[ "$UNIVERSAL" -eq 1 ]]; then
  echo "Building universal (arm64 + x86_64) release binary..."
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
else
  echo "Building release binary..."
fi

swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

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

if [[ -n "$APP_VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "$APP_BUILD" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$APP/Contents/Info.plist"
fi

SIGN_ID="${CODESIGN_IDENTITY:--}"
if [[ "$SIGN_ID" == "-" && -f .sign-id ]]; then
  SIGN_ID="$(head -n 1 .sign-id | xargs)"
fi

codesign --force --deep --options runtime -s "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built and signed: $APP (identity: $SIGN_ID)"
