#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="QuickSpot"
DIST_DIR="build.noindex/dist"
DMG_STAGE="build.noindex/dmg-stage"
APP_BUNDLE="build.noindex/$APP_NAME.app"

UNIVERSAL_FLAG=()
VERSION=""
BUILD_NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --universal)
      UNIVERSAL_FLAG=(--universal)
      shift
      ;;
    --version)
      VERSION="${2#v}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="$2"
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

if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
fi

BUILD_CMD=(./build.sh --version "$VERSION")
if [[ ${#UNIVERSAL_FLAG[@]} -gt 0 ]]; then
  BUILD_CMD+=("${UNIVERSAL_FLAG[@]}")
fi
if [[ -n "$BUILD_NUMBER" ]]; then
  BUILD_CMD+=(--build-number "$BUILD_NUMBER")
fi

"${BUILD_CMD[@]}"

ARCH_SUFFIX="macos-arm64"
if [[ ${#UNIVERSAL_FLAG[@]} -gt 0 ]]; then
  ARCH_SUFFIX="macos-universal"
fi

ZIP_NAME="${APP_NAME}-${VERSION}-${ARCH_SUFFIX}.zip"
DMG_NAME="${APP_NAME}-${VERSION}-${ARCH_SUFFIX}.dmg"

rm -rf "$DIST_DIR" "$DMG_STAGE"
mkdir -p "$DIST_DIR" "$DMG_STAGE"

echo "Creating ZIP archive ($ZIP_NAME)..."
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$DIST_DIR/$ZIP_NAME"

echo "Creating DMG installer ($DMG_NAME)..."
cp -R "$APP_BUNDLE" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$DIST_DIR/$DMG_NAME" >/dev/null
rm -rf "$DMG_STAGE"

echo "Generating SHA256SUMS.txt..."
(
  cd "$DIST_DIR"
  shasum -a 256 "$ZIP_NAME" "$DMG_NAME" > SHA256SUMS.txt
)

echo "Release artifacts ready in $DIST_DIR:"
ls -lh "$DIST_DIR"
cat "$DIST_DIR/SHA256SUMS.txt"
