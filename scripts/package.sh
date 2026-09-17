#!/bin/zsh
# Package the built app into distributable .dmg / .zip artefacts.
#
#   ./scripts/package.sh 1.0.0
#
# Requires ./build.sh to have produced "build/PDF2ZH Web.app" first; this script
# builds it for you when it is missing. Output lands in build/dist/.
set -euo pipefail

VERSION="${1:-1.0.0}"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$SRC_DIR/build"
APP_NAME="PDF2ZH Web"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DIST_DIR="$BUILD_DIR/dist"
VOLUME_NAME="$APP_NAME $VERSION"
STAGE_DIR="$BUILD_DIR/.dmg-stage"

if [[ ! -d "$APP_DIR" ]]; then
  echo "未找到 $APP_DIR，先执行 build.sh…"
  (cd "$SRC_DIR" && PDF2ZH_VERSION="$VERSION" ./build.sh)
fi

mkdir -p "$DIST_DIR"
rm -f "$DIST_DIR/$APP_NAME-$VERSION.zip" "$DIST_DIR/$APP_NAME-$VERSION.dmg"

# ---- .zip (ditto keeps the bundle's metadata and signature intact) ----
echo "打包 .zip…"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/$APP_NAME-$VERSION.zip"

# ---- .dmg (app + an Applications symlink for the usual drag-install) ----
echo "打包 .dmg…"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
cp -R "$APP_DIR" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DIST_DIR/$APP_NAME-$VERSION.dmg" >/dev/null

rm -rf "$STAGE_DIR"

echo
echo "打包完成："
# `ls | awk '{print $9}'` would truncate at the space in "PDF2ZH Web"; stat is safe.
for artefact in "$DIST_DIR/$APP_NAME-$VERSION.dmg" "$DIST_DIR/$APP_NAME-$VERSION.zip"; do
  [[ -f "$artefact" ]] || continue
  size="$(du -h "$artefact" | cut -f1 | tr -d '[:space:]')"
  print -r -- "  $artefact  ($size)"
done

cat <<'NOTE'

提示：本 App 是 ad-hoc 签名、未做 Apple 公证，用户首次打开会被 Gatekeeper 拦下。
请把下面这段写进 Release 说明：

  首次打开提示"Apple 无法检查其是否包含恶意软件"时，任选一种：
  - 在"应用程序"里右键（Control-点击）图标 → 打开 → 再点"打开"；
  - 或终端执行：xattr -dr com.apple.quarantine "/Applications/PDF2ZH Web.app"
NOTE
