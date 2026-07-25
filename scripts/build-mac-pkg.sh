#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${JP2_APP_VERSION:-1.38}"
DERIVED_DATA_PATH="${JP2_MAC_DERIVED_DATA:-$ROOT_DIR/build/mac-derived-$VERSION}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/JP2-Creation.app"
STAGING_DIR="$ROOT_DIR/build/mac-pkg-staging-$VERSION"
SCRIPTS_STAGING_DIR="$ROOT_DIR/build/mac-pkg-scripts-$VERSION"
PKG_PATH="$ROOT_DIR/build/JP2-Creation-Mac-Installer-$VERSION.pkg"
EXPANDED_DIR="$ROOT_DIR/build/pkg-expanded-$VERSION"

cd "$ROOT_DIR"

bash scripts/build-mac-app.sh

if [ -d "$STAGING_DIR" ]; then
  find "$STAGING_DIR" -depth -delete
fi
if [ -d "$SCRIPTS_STAGING_DIR" ]; then
  find "$SCRIPTS_STAGING_DIR" -depth -delete
fi
mkdir -p "$STAGING_DIR"
COPYFILE_DISABLE=1 ditto --noextattr --norsrc "$APP_PATH" "$STAGING_DIR/JP2-Creation.app"
mkdir -p "$SCRIPTS_STAGING_DIR"
COPYFILE_DISABLE=1 ditto --noextattr --norsrc ios/App/MacApp/Scripts "$SCRIPTS_STAGING_DIR"
xattr -cr "$STAGING_DIR" "$SCRIPTS_STAGING_DIR" 2>/dev/null || true
find "$STAGING_DIR" "$SCRIPTS_STAGING_DIR" -name '._*' -delete

if [ -f "$PKG_PATH" ]; then
  find "$PKG_PATH" -maxdepth 0 -delete
fi
COPYFILE_DISABLE=1 pkgbuild \
  --identifier fr.jp2creation.hubapple.mac.pkg \
  --version "$VERSION" \
  --install-location /Applications \
  --scripts "$SCRIPTS_STAGING_DIR" \
  --root "$STAGING_DIR" \
  "$PKG_PATH"

if [ -d "$EXPANDED_DIR" ]; then
  find "$EXPANDED_DIR" -depth -delete
fi
pkgutil --expand "$PKG_PATH" "$EXPANDED_DIR"
sed -n '1,20p' "$EXPANDED_DIR/PackageInfo"
shasum -a 256 "$PKG_PATH"

echo "Paquet macOS genere : $PKG_PATH"
