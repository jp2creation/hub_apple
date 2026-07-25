#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${MARTIN_SOLS_APP_VERSION:-1.38}"
DERIVED_DATA_PATH="${MARTIN_SOLS_MAC_DERIVED_DATA:-$ROOT_DIR/build/mac-derived-$VERSION}"

cd "$ROOT_DIR"

xcodebuild \
  -project ios/App/App.xcodeproj \
  -scheme "Martin Sols Mac" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

echo "App macOS generee : $DERIVED_DATA_PATH/Build/Products/Release/Martin Sols.app"
