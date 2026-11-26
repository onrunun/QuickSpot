#!/bin/bash
set -euo pipefail

# Renders a Homebrew Cask formula for QuickSpot from release metadata.
# Usage:
#   ./scripts/render-homebrew-cask.sh --version 1.0.0 --sha256 <hex> --repo owner/QuickSpot [--dmg-name FILE] [--output PATH]

VERSION=""
SHA256=""
REPO=""
DMG_NAME=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2#v}"
      shift 2
      ;;
    --sha256)
      SHA256="$2"
      shift 2
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --dmg-name)
      DMG_NAME="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 --version X.Y.Z --sha256 <sha256> --repo owner/QuickSpot [--dmg-name FILE] [--output PATH]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$VERSION" || -z "$SHA256" || -z "$REPO" ]]; then
  echo "Error: --version, --sha256, and --repo are required." >&2
  exit 1
fi

VERSION_TOKEN='#{version}'
if [[ -z "$DMG_NAME" ]]; then
  DMG_NAME="QuickSpot-${VERSION_TOKEN}-macos-arm64.dmg"
else
  DMG_NAME="${DMG_NAME//$VERSION/$VERSION_TOKEN}"
fi

CASK_CONTENT="$(cat <<EOF
cask "quickspot" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "https://github.com/${REPO}/releases/download/v#{version}/${DMG_NAME}"
  name "QuickSpot"
  desc "Fast, 100% local macOS launcher with on-device Apple Vision OCR and semantic search"
  homepage "https://github.com/${REPO}"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "QuickSpot.app"

  zap trash: [
    "~/Library/Application Support/QuickSpot",
    "~/Library/Preferences/com.quickspot.app.plist",
  ]
end
EOF
)"

if [[ -n "$OUTPUT" ]]; then
  mkdir -p "$(dirname "$OUTPUT")"
  printf '%s\n' "$CASK_CONTENT" > "$OUTPUT"
else
  printf '%s\n' "$CASK_CONTENT"
fi
