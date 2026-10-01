#!/bin/sh
# Builds build/AgentBar.app.
# `./build.sh install` also copies it to /Applications and relaunches it.
set -eu
cd "$(dirname "$0")"

swift build -c release

app=build/AgentBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/AgentBar" "$app/Contents/MacOS/AgentBar"
cp Support/Info.plist "$app/Contents/Info.plist"

# A real signing identity keeps macOS permissions (Location Services) across rebuilds.
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')
codesign --force --sign "${identity:--}" "$app"
echo "Built $app"

if [ "${1:-}" = install ]; then
    osascript -e 'tell application id "com.rickrussie.AgentBar" to quit' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/AgentBar.app
    ditto "$app" /Applications/AgentBar.app
    open /Applications/AgentBar.app
    echo "Installed and launched /Applications/AgentBar.app"
fi
