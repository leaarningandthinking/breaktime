#!/bin/zsh
# Package BreakTime.app into a distributable zip (app + install script).
#
#   ./scripts/make-dist.sh
#
# Output: dist/BreakTime-<version>.zip  and  dist/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP="BreakTime.app"
DIST="dist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
ZIP="$DIST/BreakTime-$VERSION.zip"

[[ -d "$APP" ]] || ./build.sh

rm -rf "$DIST"
mkdir -p "$DIST"

# `zip -X` omits extended attributes. ditto (and plain zip) would store them as
# AppleDouble `._*` entries, and a later `unzip` writes those *into* the bundle,
# which invalidates the code signature ("a sealed resource is missing").
zip -qryX "$ZIP" "$APP"
cp scripts/install.sh "$DIST/install.sh"
chmod +x "$DIST/install.sh"

echo "PACKAGED: $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "          $DIST/install.sh"
