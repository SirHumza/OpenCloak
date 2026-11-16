#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR=".build/opencloak-app"
APP="${1:-$BUILD_DIR/OpenCloak.app}"
mkdir -p "$BUILD_DIR/arm64" "$BUILD_DIR/x86_64" "$APP/Contents/MacOS"
for ARCH in arm64 x86_64; do
  swiftc -target "${ARCH}-apple-macosx12.0" -emit-module -module-name OpenCloakCore \
    Sources/OpenCloakCore/*.swift -framework AppKit -framework Security -framework LocalAuthentication \
    -framework CryptoKit -emit-module-path "$BUILD_DIR/$ARCH/OpenCloakCore.swiftmodule"
  swiftc -target "${ARCH}-apple-macosx12.0" -parse-as-library -I "$BUILD_DIR/$ARCH" \
    Sources/OpenCloakCore/*.swift Sources/OpenCloakApp/*.swift \
    -framework SwiftUI -framework AppKit -framework Security -framework LocalAuthentication \
    -framework CryptoKit -framework Carbon -framework UniformTypeIdentifiers \
    -framework AVFoundation -framework CoreMedia \
    -o "$BUILD_DIR/$ARCH/OpenCloak"
done
# Explicit path: MacPorts ships an unrelated `lipo` font tool that shadows Apple's.
/usr/bin/lipo -create "$BUILD_DIR/arm64/OpenCloak" "$BUILD_DIR/x86_64/OpenCloak" -output "$APP/Contents/MacOS/OpenCloak"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OpenCloak</string>
<key>CFBundleIdentifier</key><string>app.opencloak.privacy</string>
<key>CFBundleName</key><string>OpenCloak</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>OpenCloak reads only the active tab URL in a supported browser when you enable a website privacy screen.</string>
<key>NSCameraUsageDescription</key><string>OpenCloak takes an intruder photo only after a failed unlock when you turn that setting on. Photos stay on this Mac.</string>
<key>CFBundleDisplayName</key><string>OpenCloak</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 OpenCloak contributors. MIT License.</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Ad-hoc signature: required for arm64 to execute a locally built binary.
/usr/bin/codesign --force --sign - --timestamp=none --entitlements OpenCloak.entitlements "$APP" 2>/dev/null
printf 'Built %s\n' "$APP"
