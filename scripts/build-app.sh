#!/bin/bash
# Builds "build/Podcast Reader.app", signed ad hoc for use on this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

# The Command Line Tools toolchain is unreliable with Swift macros; use Xcode's.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

swift build -c release --product PodcastReader
binary="$(swift build -c release --show-bin-path)/PodcastReader"

app="build/Podcast Reader.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/PodcastReader"
cp Resources/Info.plist "$app/Contents/Info.plist"

icon="build/AppIcon.icns"
if [ ! -f "$icon" ]; then
    swift scripts/make-icon.swift "$icon"
fi
cp "$icon" "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$app"
echo "Built: $PWD/$app"
