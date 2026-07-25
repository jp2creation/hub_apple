#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${JP2_APP_VERSION:-1.38}"
DERIVED_DATA_PATH="${JP2_MAC_DERIVED_DATA:-$ROOT_DIR/build/mac-derived-$VERSION}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/JP2 Création.app"
STAGING_DIR="$ROOT_DIR/build/mac-pkg-staging-$VERSION"
PKG_PATH="$ROOT_DIR/build/JP2-Creation-Mac-Installer-$VERSION.pkg"
EXPANDED_DIR="$ROOT_DIR/build/pkg-expanded-$VERSION"

cd "$ROOT_DIR"

bash scripts/build-mac-app.sh

if [ -d "$STAGING_DIR" ]; then
  find "$STAGING_DIR" -depth -delete
fi
mkdir -p "$STAGING_DIR"
COPYFILE_DISABLE=1 ditto --noextattr --norsrc "$APP_PATH" "$STAGING_DIR/JP2 Création.app"

if [ -f "$PKG_PATH" ]; then
  find "$PKG_PATH" -maxdepth 0 -delete
fi
COPYFILE_DISABLE=1 pkgbuild \
  --identifier fr.jp2creation.hubapple.mac.pkg \
  --version "$VERSION" \
  --install-location /Applications \
  --scripts ios/App/MacApp/Scripts \
  --component "$STAGING_DIR/JP2 Création.app" \
  "$PKG_PATH"

if [ -d "$EXPANDED_DIR" ]; then
  find "$EXPANDED_DIR" -depth -delete
fi
pkgutil --expand "$PKG_PATH" "$EXPANDED_DIR"
sed -n '1,20p' "$EXPANDED_DIR/PackageInfo"
shasum -a 256 "$PKG_PATH"

echo "Paquet macOS genere : $PKG_PATH"
