#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODULE_CACHE_DIR="$REPO_ROOT/.build/module-cache"

mkdir -p "$MODULE_CACHE_DIR"

xcodebuild build \
  -project "$REPO_ROOT/ClipMenu.xcodeproj" \
  -scheme ClipMenuTest \
  -destination 'platform=macOS' \
  >/dev/null

APP_PATH="$(
  find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*/Build/Products/Debug/ClipMenuTest.app" \
    ! -path "*/Index.noindex/*" \
    -type d \
    -print | \
    xargs -I{} stat -f "%m %N" "{}" | \
    sort -nr | \
    head -n 1 | \
    cut -d' ' -f2-
)"

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Could not resolve built app path" >&2
  exit 1
fi

swift -module-cache-path "$MODULE_CACHE_DIR" "$SCRIPT_DIR/preview_ax_smoke.swift" "$APP_PATH"
