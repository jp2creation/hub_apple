#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${JP2_APP_VERSION:-1.38}"
DERIVED_DATA_PATH="${JP2_MAC_DERIVED_DATA:-$ROOT_DIR/build/mac-derived-$VERSION}"

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

if [ -z "$HUB_URL" ]; then
  HUB_URL="$(read_env_value JP2_HUB_URL)"
fi

if [ -z "$HUB_URL" ]; then
  HUB_URL="$(read_env_value VITE_CRM_URL)"
fi

if [ -z "$HUB_URL" ]; then
  echo "Configure JP2_HUB_URL ou VITE_CRM_URL dans .env avant de construire l'app macOS." >&2
  exit 1
fi

xcodebuild \
  -project ios/App/App.xcodeproj \
  -scheme "JP2 Création Mac" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  JP2_HUB_URL="$HUB_URL" \
  build

echo "App macOS generee : $DERIVED_DATA_PATH/Build/Products/Release/JP2-Creation.app"
