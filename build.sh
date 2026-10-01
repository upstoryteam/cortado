#!/bin/sh
# Builds build/Cortado.app.
# `./build.sh install` also copies it to /Applications and relaunches it.
set -eu
cd "$(dirname "$0")"

swift build -c release

app=build/Cortado.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Cortado" "$app/Contents/MacOS/Cortado"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# A real signing identity keeps macOS permissions (Location Services) across rebuilds.
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
codesign --force --sign "${identity:--}" "$app"
echo "Built $app"

if [ "${1:-}" = install ]; then
    osascript -e 'tell application id "com.rickrussie.Cortado" to quit' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Cortado.app
    ditto "$app" /Applications/Cortado.app
    open /Applications/Cortado.app
    echo "Installed and launched /Applications/Cortado.app"
fi
