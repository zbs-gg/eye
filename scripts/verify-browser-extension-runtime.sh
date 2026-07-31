#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/ZBS Eye.app" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/BrowserExtension/Extension"
BUNDLED="$1/Contents/Resources/Extension"

test -d "$BUNDLED"
diff -qr -x .DS_Store "$SOURCE" "$BUNDLED"
echo "Browser Extension runtime matches bundled app resources byte-for-byte."
