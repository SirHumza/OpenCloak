#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP_BIN="$(mktemp -t nopal-core-tests)"
TEMP_DIR="$(mktemp -d -t nopal-core-tests)"
trap 'rm -f "$TEMP_BIN"; rm -rf "$TEMP_DIR"' EXIT
swiftc -emit-module -emit-library -static -module-name NopalCore Sources/NopalCore/*.swift \
  -framework AppKit -framework Security -framework LocalAuthentication \
  -o "$TEMP_DIR/libNopalCore.a" -emit-module-path "$TEMP_DIR/NopalCore.swiftmodule"
swiftc -I "$TEMP_DIR" -L "$TEMP_DIR" Tests/NopalTests/main.swift -lNopalCore \
  -framework AppKit -framework Security -framework LocalAuthentication -o "$TEMP_BIN"
"$TEMP_BIN"
