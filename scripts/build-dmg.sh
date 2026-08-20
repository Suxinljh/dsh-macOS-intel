#!/bin/bash
# =============================================================================
# DeepSeek Harness (dsh) — macOS x86_64 DMG 打包脚本（背景图 + 图标布局）
#
# 产出: dist/DeepSeek.Harness.Intel-<version>_x64.dmg
#
# 为什么用 dmgbuild:
#   之前的 AppleScript + Finder 方案不可靠——Finder 只在窗口状态变化后异步
#   写 .DS_Store，卷卸载太快时布局根本没落盘，DMG 打开后既没有背景图也没有
#   图标位置。dmgbuild 通过 ds_store 库以二进制格式直接写 .DS_Store
#   （窗口尺寸、图标视图、背景图别名、图标中心坐标），不依赖 Finder 与 TCC
#   自动化授权，结果可复现。
#
# 依赖:
#   - dmgbuild (pip3 install dmgbuild)
#   - 已构建好的 .app（scripts/build-tauri-macos.sh）
#   - src-tauri/dmg-background.png（1320x800 @2x 设计稿）
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="$(python3 -c "import json; print(json.load(open('$ROOT/src-tauri/tauri.conf.json'))['version'])")"
APP_DIR="$ROOT/src-tauri/target/x86_64-apple-darwin/release/bundle/macos/DeepSeek Harness.app"
BG_2X="$ROOT/src-tauri/dmg-background.png"   # 1320x800 (@2x)
VOLNAME="DeepSeek Harness"
OUT="$ROOT/dist/DeepSeek.Harness.Intel-${VERSION}_x64.dmg"

# 布局参数（逻辑 px；窗口 660x400，图标中心坐标）
LOGICAL_W=660
LOGICAL_H=400
ICON_SIZE=126
APP_POS="197,163"     # DeepSeek Harness.app 图标中心
APPS_POS="463,163"    # Applications 图标中心

python3 -c "import dmgbuild" 2>/dev/null \
  || { echo "error: 需要 dmgbuild，请先执行: pip3 install dmgbuild" >&2; exit 1; }
[ -d "$APP_DIR" ] || { echo "error: 未找到 .app: $APP_DIR" >&2; exit 1; }
[ -f "$BG_2X" ]   || { echo "error: 未找到背景图: $BG_2X" >&2; exit 1; }

BGDIR="$(mktemp -d /tmp/dsh-bg.XXXXXX)"
trap 'rm -rf "$BGDIR"' EXIT

echo "==> 版本: $VERSION"
echo "==> 准备背景图 (1x ${LOGICAL_W}x${LOGICAL_H} + 2x)"
cp "$BG_2X" "$BGDIR/background@2x.png"
sips -z "$LOGICAL_H" "$LOGICAL_W" "$BG_2X" --out "$BGDIR/background.png" >/dev/null

echo "==> 写入 dmgbuild 配置"
cat > "$BGDIR/settings.json" <<JSON
{
  "title": "$VOLNAME",
  "background": "$BGDIR/background.png",
  "icon-size": $ICON_SIZE,
  "window": {"position": {"x": 100, "y": 100}, "size": {"width": $LOGICAL_W, "height": $LOGICAL_H}},
  "contents": [
    {"path": "$APP_DIR", "type": "file", "x": ${APP_POS%,*}, "y": ${APP_POS#*,}},
    {"path": "/Applications", "type": "link", "x": ${APPS_POS%,*}, "y": ${APPS_POS#*,}}
  ],
  "format": "UDZO",
  "compression-level": 9
}
JSON

echo "==> dmgbuild 构建（直接写 .DS_Store，无需 Finder/TCC）"
mkdir -p "$ROOT/dist"
rm -f "$OUT"
python3 -m dmgbuild -s "$BGDIR/settings.json" "$VOLNAME" "$OUT"

echo "==> 校验 .DS_Store（必须含背景与图标布局）"
hdiutil detach "/Volumes/$VOLNAME" 2>/dev/null || true
hdiutil attach "$OUT" -nobrowse >/dev/null 2>&1
MNT="/Volumes/$VOLNAME"
python3 - "$MNT/.DS_Store" <<'PY'
import sys
from ds_store import DSStore
path = sys.argv[1]
d = DSStore.open(path, "r")
root = d["."]
icvp = root[b"icvp"]
bt = icvp.get("backgroundType")
assert bt == 2, f"backgroundType={bt}（期望 2=图片背景）"
app = tuple(d["DeepSeek Harness.app"][b"Iloc"])
apps = tuple(d["Applications"][b"Iloc"])
print(f"  背景: OK (backgroundType={bt})  图标: app{app} apps{apps}")
d.close()
PY
hdiutil detach "$MNT" 2>/dev/null || hdiutil detach -force "$MNT" 2>/dev/null || true

echo "==> 完成: $OUT"
ls -lh "$OUT"
