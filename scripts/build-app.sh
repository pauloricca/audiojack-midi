#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build -c release --disable-sandbox --cache-path .build/cache
BIN_DIR=$(swift build -c release --show-bin-path --disable-sandbox --cache-path .build/cache)
APP="$PWD/dist/AudioJack MIDI.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
./scripts/build-icon.sh
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/AudioJackMIDI" "$APP/Contents/MacOS/AudioJackMIDI"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>AudioJack MIDI</string>
<key>CFBundleDisplayName</key><string>AudioJack MIDI</string>
<key>CFBundleIdentifier</key><string>local.audiojack.midi</string>
<key>CFBundleExecutable</key><string>AudioJackMIDI</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.7</string>
<key>CFBundleVersion</key><string>8</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built: $APP"
