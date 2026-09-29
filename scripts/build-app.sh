#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
VERSION=0.1.10
BUILD=11
ICON="AppIcon-build-$BUILD"
export MACOSX_DEPLOYMENT_TARGET=12.0
ARCHITECTURES=(arm64 x86_64)
SCREENSHOT="$PWD/website/assets/audiojack-app.png"

if (( $# != 0 )); then
    echo 'Usage: ./scripts/build-app.sh' >&2
    echo 'The script always builds both arm64 and x86_64.' >&2
    exit 1
fi

./scripts/build-icon.sh
sips -z 256 256 Assets/AppIcon.png --out website/assets/audiojack-icon-0.1.8.png > /dev/null

build_architecture() {
    local arch="$1"
    local build_args=(-c release --arch "$arch" --disable-sandbox --scratch-path ".build/release-$arch" --cache-path .build/cache)
    local bin_dir
    local app="$PWD/dist/$arch/AudioJack MIDI.app"

    swift build "${build_args[@]}"
    bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    for old_icon in "$app/Contents/Resources"/AppIcon*.icns(N); do
        rm "$old_icon"
    done
    cp .build/AppIcon.icns "$app/Contents/Resources/$ICON.icns"
    cp "$bin_dir/AudioJackMIDI" "$app/Contents/MacOS/AudioJackMIDI"
    cat > "$app/Contents/Info.plist" <<PLIST
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
    codesign --force --sign - "$app"
    codesign --verify --deep --strict "$app"
    mkdir -p website/downloads
    ditto -c -k --sequesterRsrc --keepParent "$app" "website/downloads/AudioJack-MIDI-$VERSION-$arch.zip"
    echo "Built: $app"
}

capture_screenshot() {
    local host_arch
    local app
    local app_pid
    local window_id

    host_arch=$(uname -m)
    case "$host_arch" in
        arm64|x86_64) ;;
        *) echo "Cannot select a screenshot build for architecture: $host_arch" >&2; return 1 ;;
    esac
    app="$PWD/dist/$host_arch/AudioJack MIDI.app"

    "$app/Contents/MacOS/AudioJackMIDI" &
    app_pid=$!

    cleanup_screenshot_app() {
        if kill -0 "$app_pid" 2>/dev/null; then
            kill "$app_pid" 2>/dev/null || true
            wait "$app_pid" 2>/dev/null || true
        fi
    }
    trap cleanup_screenshot_app EXIT INT TERM

    window_id=$(swift - "$app_pid" <<'SWIFT'
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments[1])!
let deadline = Date().addingTimeInterval(10)

while Date() < deadline {
    let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] ?? []

    if let window = windows.first(where: {
        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
        ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
    }), let number = window[kCGWindowNumber as String] as? NSNumber {
        print(number.intValue)
        exit(EXIT_SUCCESS)
    }

    Thread.sleep(forTimeInterval: 0.1)
}

fputs("Timed out waiting for the AudioJack MIDI window.\n", stderr)
exit(EXIT_FAILURE)
SWIFT
    )

    mkdir -p "${SCREENSHOT:h}"
    screencapture -x -l "$window_id" "$SCREENSHOT"
    sips --resampleWidth 832 "$SCREENSHOT" > /dev/null
    cleanup_screenshot_app
    trap - EXIT INT TERM
    echo "Captured: $SCREENSHOT"
}

for arch in "${ARCHITECTURES[@]}"; do
    build_architecture "$arch"
done

capture_screenshot
