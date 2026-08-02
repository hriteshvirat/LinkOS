#!/bin/bash
set -e

echo "=== 1. Building LinkOS for arm64 & x86_64 ==="
swift build -c release --arch arm64 --arch x86_64
mkdir -p .build/release
lipo -create .build/apple/Intermediates.noindex/LinkOS.build/Release/LinkOS.build/Objects-normal/arm64/Binary/LinkOS .build/apple/Intermediates.noindex/LinkOS.build/Release/LinkOS.build/Objects-normal/x86_64/Binary/LinkOS -output .build/release/LinkOS

echo "=== 2. Creating App Bundle Directory ==="
rm -rf LinkOS.app
mkdir -p LinkOS.app/Contents/MacOS
mkdir -p LinkOS.app/Contents/Resources

echo "=== 3. Copying Binary, Plist, and Resources ==="
cp .build/release/LinkOS LinkOS.app/Contents/MacOS/
cp LinkOS/App/Info.plist LinkOS.app/Contents/
cp LinkOS/Resources/linkos_logo.png LinkOS.app/Contents/Resources/ 2>/dev/null || true
cp -r .build/apple/Products/Release/*.bundle LinkOS.app/Contents/Resources/ 2>/dev/null || true

echo "=== 4. Creating AppIcon.icns ==="
rm -rf AppIcon.iconset
mkdir -p AppIcon.iconset

SRC_ICONSET="LinkOS/Resources/Assets.xcassets/AppIcon.appiconset"
cp "$SRC_ICONSET/icon_16x16.png" AppIcon.iconset/icon_16x16.png
cp "$SRC_ICONSET/icon_32x32.png" AppIcon.iconset/icon_16x16@2x.png
cp "$SRC_ICONSET/icon_32x32.png" AppIcon.iconset/icon_32x32.png
cp "$SRC_ICONSET/icon_64x64.png" AppIcon.iconset/icon_32x32@2x.png
cp "$SRC_ICONSET/icon_128x128.png" AppIcon.iconset/icon_128x128.png
cp "$SRC_ICONSET/icon_256x256.png" AppIcon.iconset/icon_128x128@2x.png
cp "$SRC_ICONSET/icon_256x256.png" AppIcon.iconset/icon_256x256.png
cp "$SRC_ICONSET/icon_512x512.png" AppIcon.iconset/icon_256x256@2x.png
cp "$SRC_ICONSET/icon_512x512.png" AppIcon.iconset/icon_512x512.png
cp "$SRC_ICONSET/icon_1024x1024.png" AppIcon.iconset/icon_512x512@2x.png

iconutil -c icns AppIcon.iconset -o LinkOS.app/Contents/Resources/AppIcon.icns
rm -rf AppIcon.iconset

echo "=== 5. Installing to /Applications ==="
rm -rf /Applications/LinkOS.app
cp -r LinkOS.app /Applications/

echo "=== 6. Signing Bundle with Hardened Runtime & Embedded Entitlements ==="
codesign --force --deep --options runtime --entitlements LinkOS/App/LinkOS.entitlements -s "LinkOS Local Dev" -r '=designated => identifier "com.linkos.macos"' /Applications/LinkOS.app 2>/dev/null || codesign --force --deep --options runtime --entitlements LinkOS/App/LinkOS.entitlements -s - -r '=designated => identifier "com.linkos.macos"' /Applications/LinkOS.app

echo "=== 7. Verifying Code-Signing Identity & Embedded Entitlements ==="
codesign -dvv /Applications/LinkOS.app
codesign -d --entitlements :- /Applications/LinkOS.app

echo "=== 8. Cleanup ==="
rm -rf LinkOS.app

echo "=== SUCCESS: LinkOS.app signed & installed to /Applications ==="
