#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP_BIN="$(mktemp -t opencloak-core-tests)"
TEMP_DIR="$(mktemp -d -t opencloak-core-tests)"
trap 'rm -f "$TEMP_BIN"; rm -rf "$TEMP_DIR"' EXIT
swiftc -emit-module -emit-library -static -module-name OpenCloakCore Sources/OpenCloakCore/*.swift \
  -framework AppKit -framework Security -framework LocalAuthentication -framework CryptoKit \
  -o "$TEMP_DIR/libOpenCloakCore.a" -emit-module-path "$TEMP_DIR/OpenCloakCore.swiftmodule"
swiftc -I "$TEMP_DIR" -L "$TEMP_DIR" Tests/OpenCloakTests/main.swift -lOpenCloakCore \
  -framework AppKit -framework Security -framework LocalAuthentication -framework CryptoKit -o "$TEMP_BIN"
"$TEMP_BIN"
