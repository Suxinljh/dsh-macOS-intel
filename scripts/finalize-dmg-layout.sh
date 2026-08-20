#!/bin/bash
# DeepSeek Harness — DMG 图标布局终稿脚本
#
# 必须在带有 GUI 登录会话的普通用户下运行（不要在 SSH/daemon 上下文）。
# 首次运行若弹出“终端想要控制Finder“的授权框，请点“允许”——
# 这是 macOS 自动化(TCC)保护，脚本需要 Finder 来写入布局坐标。
#
# 背景图 1320x800 (@2x Retina)，逻辑尺寸 660x400。
# 布局（逻辑 px）：上面留 100、中间留 140 gap、图标 126、水平居中@660/2=330。
#   left(.app):  center=(197,163)   (占位左)
#   right(Apps): center=(463,163)   (占位右)
#
# 用法: finalize-dmg-layout.sh <已生成.dmg> [输出.dmg]
set -euo pipefail

DMG_IN="$1"
OUT_DMG="${2:-${DMG_IN%.dmg}.layout.dmg}"
ICON_SIZE=126
VOLNAME="DeepSeek Harness"
TEMPDIR="$(mktemp -d /tmp/dsh-layout.XXXXXX)"
RW="$TEMPDIR/rw.dmg"

[ -f "$DMG_IN" ] || { echo "error: DMG not found: $DMG_IN" >&2; exit 1; }

echo "==> 展开为可写 RW dmg（保留现有内容=含背景图）"
hdiutil convert "$DMG_IN" -format UDRW -o "$RW" >/dev/null

MNT="$TEMPDIR/mnt"
mkdir -p "$MNT"
hdiutil detach "/Volumes/$VOLNAME" 2>/dev/null || true
echo "==> 挂载（到 /Volumes/${VOLNAME}）"
ATTACH=$(hdiutil attach -readwrite -noverify -mountpoint "/Volumes/$VOLNAME" "$RW")
echo "$ATTACH"
MNT="/Volumes/$VOLNAME"

echo "==> AppleScript 布局（需 Finder 授权）"
cat > "$TEMPDIR/layout.scpt" <<APPLESCRIPT
on run
  set theVol to POSIX file "$MNT" as alias
  set theVolName to "$VOLNAME"
  set bgPath to "$MNT/.background/background.png"
  tell application "Finder"
    set theFolder to folder theVol
    open theFolder
    delay 1
    set theWindow to theFolder's window
    set theView to icon view options of theWindow
    set background picture of theView to (POSIX file bgPath as alias)
    set icon size of theView to $ICON_SIZE
    set theApp to item "DeepSeek Harness.app" of theFolder
    set theApps to item "Applications" of theFolder
    set position of theApp to {197 - $ICON_SIZE / 2, 163 - $ICON_SIZE / 2}
    set position of theApps to {463 - $ICON_SIZE / 2, 163 - $ICON_SIZE / 2}
    set bounds of theFolder's window to {0, 0, 660, 400}
    set current view of theFolder's window to icon view
    set statusbar visible of theFolder's window to false
    set sidebar width of theFolder's window to 0
    set toolbar visible of theFolder's window to false
  end tell
end run
APPLESCRIPT

if osascript "$TEMPDIR/layout.scpt"; then
  echo "  布局 OK"
else
  echo "  布局失败：无法控制 Finder。请确认有 GUI 会话且已授权自动化。" >&2
  echo "  若刚才弹出授权框，请点允许后重新运行本脚本。" >&2
  hdiutil detach "$MNT" 2>/dev/null || true
  exit 1
fi

echo "==> 修正权限 & 卸载"
chmod -Rf go-w "$MNT" 2>/dev/null || true
DEV=$(hdiutil info | grep "Volumes/$VOLNAME" | head -1 | awk '{print $1}')
hdiutil detach "$DEV" 2>/dev/null || hdiutil detach -force "$MNT" 2>/dev/null

echo "==> 压缩为最终 UDZO DMG"
rm -f "$OUT_DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" 2>&1 | tail -2
echo "==> 完成: $OUT_DMG"
rm -rf "$TEMPDIR"
