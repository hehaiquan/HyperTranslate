#!/bin/bash
set -euo pipefail

# 生成原生应用包；不安装应用、不修改系统授权和登录项。
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.cache/swift-modules"

python3 scripts/prepare_dictionary.py
SWIFT_OPTIONS=(--disable-sandbox -debug-info-format none --cache-path "$PROJECT_ROOT/.cache/swiftpm"
               --config-path "$PROJECT_ROOT/.cache/swiftpm/config"
               --security-path "$PROJECT_ROOT/.cache/swiftpm/security")
swift build -c release "${SWIFT_OPTIONS[@]}"
PRODUCTS="$(swift build -c release "${SWIFT_OPTIONS[@]}" --show-bin-path)"
APP="$PROJECT_ROOT/dist/HyperTranslate.app"
# 只清理本脚本生成的固定构建产物。
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/HyperTranslate" "$APP/Contents/MacOS/HyperTranslate"
cp -R "$PRODUCTS/HyperTranslate_HyperTranslateCore.bundle" "$APP/Contents/Resources/"
cp ThirdParty/THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"
cp -R ThirdParty "$APP/Contents/Resources/ThirdParty"
cp scripts/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
xcrun swift scripts/create_icon.swift "$PROJECT_ROOT/.cache/AppIcon.iconset"
xcrun iconutil -c icns "$PROJECT_ROOT/.cache/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - --identifier com.hypertranslate.mac "$APP"
codesign --verify --deep --strict "$APP"
echo "应用已生成：$APP"
