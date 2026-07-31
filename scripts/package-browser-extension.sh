#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="$ROOT_DIR/BrowserExtension/Extension"
MANIFEST="$RUNTIME_DIR/manifest.json"
VERSION="$(/usr/bin/plutil -extract version raw -o - "$MANIFEST")"
OUTPUT_DIR="$ROOT_DIR/dist"
OUTPUT="$OUTPUT_DIR/ZBSEye-Browser-Bridge-${VERSION}.zip"

test -f "$MANIFEST"
test -f "$RUNTIME_DIR/icons/icon-128.png"
mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT"
(
  cd "$RUNTIME_DIR"
  /usr/bin/zip -X -q -r "$OUTPUT" . -x '*.DS_Store'
)

ROOT_MANIFEST="$(/usr/bin/unzip -Z1 "$OUTPUT" manifest.json)"
test "$ROOT_MANIFEST" = "manifest.json"
echo "$OUTPUT"
