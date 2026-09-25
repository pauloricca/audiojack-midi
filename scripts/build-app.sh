#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo 'Usage: build-app.sh [arm64|x86_64]' >&2; exit 1 ;; esac
VERSION=0.1.10
BUILD=11
ICON="AppIcon-build-$BUILD"
export MACOSX_DEPLOYMENT_TARGET=12.0
BUILD_ARGS=(-c release --arch "$ARCH" --disable-sandbox --scratch-path ".build/release-$ARCH" --cache-path .build/cache)
swift build "${BUILD_ARGS[@]}"
BIN_DIR=$(swift build "${BUILD_ARGS[@]}" --show-bin-path)
APP="$PWD/dist/$ARCH/AudioJack MIDI.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
./scripts/build-icon.sh
for old_icon in "$APP/Contents/Resources"/AppIcon*.icns(N); do
    rm "$old_icon"
done
cp .build/AppIcon.icns "$APP/Contents/Resources/$ICON.icns"
cp "$BIN_DIR/AudioJackMIDI" "$APP/Contents/MacOS/AudioJackMIDI"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>AudioJack MIDI</string>
<key>CFBundleDisplayName</key><string>AudioJack MIDI</string>
<key>CFBundleIdentifier</key><string>local.audiojack.midi</string>
<key>CFBundleExecutable</key><string>AudioJackMIDI</string>
<key>CFBundleIconFile</key><string>$ICON.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p website/downloads
ditto -c -k --sequesterRsrc --keepParent "$APP" "website/downloads/AudioJack-MIDI-$VERSION-$ARCH.zip"
echo "Built: $APP"
