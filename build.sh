#!/bin/zsh
# Build "PDF2ZH Web.app" from main.swift. See VIBE_CODING.md §8.
#
#   ./build.sh                        # 构建
#   PDF2ZH_VERSION=1.2.3 ./build.sh   # 指定版本号（默认 1.0.0）
#   PDF2ZH_REGEN_ICONS=1 ./build.sh   # 改了 scripts/make-icons.swift 后重新渲染图标
set -euo pipefail

APP_NAME="PDF2ZH Web"
EXEC_NAME="PDF2ZHWebMenuBar"
BUNDLE_ID="local.pdf2zh.web.menubar"
SHORT_VERSION="${PDF2ZH_VERSION:-1.0.0}"
BUILD_NUMBER="${PDF2ZH_BUILD:-1}"

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SRC_DIR/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
# Keep the module cache inside build/ so the build is self-contained and works in
# sandboxes / CI where ~/Library/Caches is not writable. Only the .app is removed
# between builds, so rebuilds stay fast.
MODULE_CACHE="$BUILD_DIR/.swift-module-cache"

# 图标：仓库里提交的产物是构建时的唯一真源（macOS 项目惯例），因此正常构建不依赖
# CoreText 渲染的可用性。只有显式要求、或产物缺失时才用生成器重新渲染并刷新 assets/。
ICON_TOOL_SRC="$SRC_DIR/scripts/make-icons.swift"
ICON_DIR="$BUILD_DIR/icons"
ICNS="$SRC_DIR/assets/AppIcon.icns"
STATUS_PNG="$SRC_DIR/assets/pdf2zh-status.png"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "找不到 swiftc，请先执行：xcode-select --install" >&2
  exit 1
fi

mkdir -p "$MODULE_CACHE" "$BUILD_DIR" "$SRC_DIR/assets"

if [[ "${PDF2ZH_REGEN_ICONS:-0}" == "1" || ! -f "$ICNS" || ! -f "$STATUS_PNG" ]]; then
  echo "渲染图标（scripts/make-icons.swift）…"
  swiftc "$ICON_TOOL_SRC" \
    -o "$ICON_DIR/make-icons" \
    -swift-version 5 \
    -O \
    -module-cache-path "$MODULE_CACHE"
  "$ICON_DIR/make-icons" "$ICON_DIR"
  iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$ICON_DIR/AppIcon.icns"
  cp "$ICON_DIR/AppIcon.icns" "$ICNS"
  cp "$ICON_DIR/pdf2zh-status.png" "$STATUS_PNG"
  cp "$ICON_DIR/icon-preview.png" "$SRC_DIR/assets/icon-preview.png"
  echo "已刷新 assets/ 中的图标产物，请一并提交。"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swiftc "$SRC_DIR/main.swift" \
  -o "$APP_DIR/Contents/MacOS/$EXEC_NAME" \
  -framework Cocoa \
  -swift-version 5 \
  -O \
  -module-cache-path "$MODULE_CACHE"

cp "$STATUS_PNG" "$APP_DIR/Contents/Resources/pdf2zh-status.png"
cp "$ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$EXEC_NAME</string>

    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>

    <key>CFBundleName</key>
    <string>$APP_NAME</string>

    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>CFBundleIconFile</key>
    <string>AppIcon</string>

    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>

    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>

    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>

    <!-- No Dock icon, no Cmd-Tab entry: status bar only. -->
    <key>LSUIElement</key>
    <true/>

    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null

# Ad-hoc signing is enough for a locally built app. --deep is deprecated on modern macOS.
codesign --force --sign - "$APP_DIR" >/dev/null
codesign --verify --strict "$APP_DIR"

echo "构建完成：$APP_DIR"
