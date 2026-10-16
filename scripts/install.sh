#!/bin/zsh
# Install BreakTime.app and clear the macOS quarantine flag.
#
# Put this script next to BreakTime.app, then run:
#   ./install.sh
#
# The quarantine flag is what makes macOS show "无法打开，因为 Apple 无法检查"
# for apps downloaded from the internet. BreakTime is not notarized (that needs
# a paid Apple Developer account), so we clear it explicitly.
set -euo pipefail
cd "$(dirname "$0")"

APP="BreakTime.app"

if [[ ! -d "$APP" ]]; then
  echo "错误：当前目录下找不到 $APP"
  echo "请把 install.sh 和 BreakTime.app 放在同一目录后再运行。"
  exit 1
fi

DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

pkill -f "$DEST/$APP/Contents/MacOS/BreakTime" 2>/dev/null || true
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/$APP"
xattr -dr com.apple.quarantine "$DEST/$APP" 2>/dev/null || true

echo "已安装到：$DEST/$APP"
open "$DEST/$APP"
