#!/bin/bash
# Builds build/Podcast-Reader.dmg, the file people download, from the app that
# scripts/build-app.sh made. It needs uv: brew install uv
set -euo pipefail
cd "$(dirname "$0")/.."

# The Command Line Tools toolchain is unreliable with Swift macros; use Xcode's.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

app="build/Podcast Reader.app"
dmg="build/Podcast-Reader.dmg"
if [ ! -d "$app" ]; then
    scripts/build-app.sh
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swift scripts/make-dmg-background.swift "$work"
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$work/background.tiff"

rm -f "$dmg"
uvx --from dmgbuild==1.6.7 dmgbuild -s scripts/dmg-settings.py \
    -D app="$app" -D icon=build/AppIcon.icns -D background="$work/background.tiff" \
    "Podcast Reader" "$dmg"
echo "Built: $PWD/$dmg"
