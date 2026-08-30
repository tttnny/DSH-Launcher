#!/bin/bash
# 构建 DSH Launcher.app（本地 ad-hoc 签名，无需开发者账号）
set -euo pipefail
set -o pipefail
cd "$(dirname "$0")"

APP="dist/DSH Launcher.app"
ICONSET="build/AppIcon.iconset"
rm -rf "$APP" "$ICONSET"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"

echo "== 编译 App =="
swiftc -O -target arm64-apple-macos13.0 \
    -o "$APP/Contents/MacOS/DSHLauncher" \
    Sources/main.swift \
    Sources/MainWindow.swift \
    -framework AppKit

echo "== Info.plist / 资源 =="
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/favicon.svg "$APP/Contents/Resources/favicon.svg"

echo "== 生成图标（官方 favicon.svg → icns）=="
swiftc -O -o build/icon_gen tools/make-icon.swift -framework AppKit
./build/icon_gen "Resources/favicon.svg" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "== ad-hoc 签名 =="
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "签名校验通过"

echo "== 完成 =="
echo "App: $PWD/$APP"
du -sh "$APP"
