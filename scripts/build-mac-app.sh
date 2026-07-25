#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${JP2_APP_VERSION:-1.38}"
DERIVED_DATA_PATH="${JP2_MAC_DERIVED_DATA:-$ROOT_DIR/build/mac-derived-$VERSION}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Martin Sols.app"

cd "$ROOT_DIR"

read_env_value() {
  local key="$1"

  if [ ! -f "$ROOT_DIR/.env" ]; then
    return 0
  fi

  while IFS='=' read -r env_key env_value; do
    case "$env_key" in
      "$key")
        env_value="${env_value%\"}"
        env_value="${env_value#\"}"
        env_value="${env_value%\'}"
        env_value="${env_value#\'}"
        printf '%s' "$env_value"
        return 0
        ;;
    esac
  done < "$ROOT_DIR/.env"
}

HUB_URL="${JP2_HUB_URL:-${VITE_CRM_URL:-}}"
APP_SIGN_IDENTITY="${JP2_MAC_APP_SIGN_IDENTITY:-}"

if [ -z "$HUB_URL" ]; then
  HUB_URL="$(read_env_value JP2_HUB_URL)"
fi

if [ -z "$HUB_URL" ]; then
  HUB_URL="$(read_env_value VITE_CRM_URL)"
fi

if [ -z "$APP_SIGN_IDENTITY" ]; then
  APP_SIGN_IDENTITY="$(read_env_value JP2_MAC_APP_SIGN_IDENTITY)"
fi

if [ -z "$HUB_URL" ]; then
  echo "Configure JP2_HUB_URL ou VITE_CRM_URL dans .env avant de construire l'app macOS." >&2
  exit 1
fi

xcodebuild \
  -project ios/App/App.xcodeproj \
  -scheme "Martin Sols Mac" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  JP2_HUB_URL="$HUB_URL" \
  build

if [ -n "$APP_SIGN_IDENTITY" ]; then
  codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --sign "$APP_SIGN_IDENTITY" \
    "$APP_PATH"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
fi

echo "App macOS generee : $APP_PATH"
