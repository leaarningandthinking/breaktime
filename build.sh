#!/bin/zsh
# Build BreakTime.app.
#
#   ./build.sh              → universal binary (arm64 + x86_64)
#   ./build.sh arm64        → single architecture (faster, Apple silicon only)
#   ./build.sh arm64 x86_64 → explicit list
#
# Only the Xcode Command Line Tools are required (no full Xcode, no packages).
#
# The Swift language version is pinned so a local build and the CI runner
# (which ships a different Xcode) compile the source identically.
set -euo pipefail
cd "$(dirname "$0")"

APP="BreakTime.app"
MIN_MACOS="14.0"
BUILD_DIR=".build"

if [[ $# -gt 0 ]]; then
  ARCHS=("$@")
else
  ARCHS=(arm64 x86_64)
fi

rm -rf "$APP" "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR"

BINARIES=()
for ARCH in "${ARCHS[@]}"; do
  echo "==> compiling $ARCH"
  swiftc Sources/*.swift \
    -o "$BUILD_DIR/BreakTime-$ARCH" \
    -target "$ARCH-apple-macosx$MIN_MACOS" \
    -swift-version 5 \
    -O
  BINARIES+=("$BUILD_DIR/BreakTime-$ARCH")
done

if [[ ${#BINARIES[@]} -gt 1 ]]; then
  lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/BreakTime"
else
  cp "${BINARIES[1]}" "$APP/Contents/MacOS/BreakTime"
fi

cp Info.plist "$APP/Contents/"
cp -R Resources/Themes "$APP/Contents/Resources/"
[[ -f Assets/AppIcon.icns ]] && cp Assets/AppIcon.icns "$APP/Contents/Resources/"

# Re-sign ad-hoc: lipo invalidates the linker signature, and a stable signature
# keeps macOS privacy prompts from re-asking on every rebuild.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# Tell Launch Services about the fresh bundle so the icon and the
# breaktime:// URL scheme register immediately.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

rm -rf "$BUILD_DIR"
echo "BUILT: $APP [$(lipo -archs "$APP/Contents/MacOS/BreakTime")]"
