#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR=".build/nopal-app"
APP="${1:-$BUILD_DIR/Nopal.app}"
mkdir -p "$BUILD_DIR/arm64" "$BUILD_DIR/x86_64" "$APP/Contents/MacOS"
for ARCH in arm64 x86_64; do
  swiftc -target "${ARCH}-apple-macosx13.0" -emit-module -module-name NopalCore \
    Sources/NopalCore/*.swift -framework AppKit -framework Security -framework LocalAuthentication \
    -emit-module-path "$BUILD_DIR/$ARCH/NopalCore.swiftmodule"
  swiftc -target "${ARCH}-apple-macosx13.0" -parse-as-library -I "$BUILD_DIR/$ARCH" \
    Sources/NopalCore/*.swift Sources/NopalApp/*.swift \
    -framework SwiftUI -framework AppKit -framework Security -framework LocalAuthentication \
    -framework Carbon -framework UniformTypeIdentifiers \
    -o "$BUILD_DIR/$ARCH/Nopal"
done
# Explicit path: MacPorts ships an unrelated `lipo` font tool that shadows Apple's.
/usr/bin/lipo -create "$BUILD_DIR/arm64/Nopal" "$BUILD_DIR/x86_64/Nopal" -output "$APP/Contents/MacOS/Nopal"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Nopal</string>
<key>CFBundleIdentifier</key><string>app.nopal.privacy</string>
<key>CFBundleName</key><string>Nopal</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Nopal reads only the active tab URL in a supported browser when you enable a website privacy screen.</string>
<key>CFBundleDisplayName</key><string>Nopal</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Nopal contributors. MIT License.</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Ad-hoc signature: required for arm64 to execute a locally built binary.
/usr/bin/codesign --force --sign - --timestamp=none "$APP" 2>/dev/null
printf 'Built %s\n' "$APP"
