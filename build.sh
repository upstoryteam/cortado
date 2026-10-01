#!/bin/sh
# Builds build/Cortado.app.
# `./build.sh install` also copies it to /Applications and relaunches it.
# `./build.sh dmg` builds it for other people's Macs and packs it into
# build/Cortado.dmg, the download. See "Releasing" in the README.
set -eu
cd "$(dirname "$0")"

# The name of the first signing certificate of a kind, or nothing.
identity() {
    security find-identity -v -p codesigning | awk -F'"' -v kind="$1" 'index($2, kind) == 1 { print $2; exit }'
}

if [ "${1:-}" = dmg ]; then
    # For both kinds of Mac. A download can't know which it is going to.
    set -- dmg --arch arm64 --arch x86_64
    signer=$(identity "Developer ID Application")
    # Apple only notarizes a signature that carries its timestamp.
    stamp=${signer:+--timestamp}
else
    # A real signing identity keeps macOS permissions (Location Services) across rebuilds.
    signer=$(identity "Apple Development")
    stamp=
fi
mode=${1:-}
[ $# -eq 0 ] || shift

swift build -c release "$@"

app=build/Cortado.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$(swift build -c release "$@" --show-bin-path)/Cortado" "$app/Contents/MacOS/Cortado"
cp Support/Info.plist "$app/Contents/Info.plist"
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# The hardened runtime is what Apple asks of an app before it will notarize it.
# Every build has it, so the copy in /Applications behaves like the download.
codesign --force --options runtime --entitlements Support/Cortado.entitlements \
    $stamp --sign "${signer:--}" "$app"
echo "Built $app"

if [ "$mode" = install ]; then
    osascript -e 'tell application id "co.upstory.cortado" to quit' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Cortado.app
    ditto "$app" /Applications/Cortado.app
    open /Applications/Cortado.app
    echo "Installed and launched /Applications/Cortado.app"
fi

if [ "$mode" = dmg ]; then
    dmg=build/Cortado.dmg
    draft=build/draft.dmg
    folder=build/dmg
    [ ! -d /Volumes/Cortado ] || hdiutil detach -quiet /Volumes/Cortado
    rm -rf "$folder" "$draft" "$dmg"
    mkdir -p "$folder/.background"
    ditto "$app" "$folder/Cortado.app"
    ln -s /Applications "$folder/Applications"
    cp Support/DiskImage.tiff "$folder/.background/DiskImage.tiff"

    # Finder lays out the window of a disk image it can write to, and the layout
    # is saved in the image. Then the image is packed into one nobody can change.
    hdiutil create -quiet -srcfolder "$folder" -volname Cortado -fs HFS+ -format UDRW -size 32m "$draft"
    hdiutil attach -quiet -readwrite -noverify -noautoopen "$draft"
    # The icons sit where Support/dmg.swift draws its arrow between them.
    osascript <<'END'
tell application "Finder"
    tell disk "Cortado"
        open
        tell container window
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set bounds to {200, 140, 840, 568}
        end tell
        tell icon view options of container window
            set arrangement to not arranged
            set icon size to 128
            set text size to 13
        end tell
        set background picture of icon view options of container window to file ".background:DiskImage.tiff"
        set position of item "Cortado.app" to {170, 170}
        set position of item "Applications" to {470, 170}
        update without registering applications
        delay 2
        close
    end tell
end tell
END
    sync
    hdiutil detach -quiet /Volumes/Cortado
    hdiutil convert -quiet "$draft" -format UDZO -imagekey zlib-level=9 -o "$dmg"
    rm -rf "$folder" "$draft"

    if [ -z "$signer" ]; then
        echo "Built $dmg, for trying out only."
        echo "There is no Developer ID Application certificate on this Mac, so the app"
        echo "isn't signed for other Macs or notarized, and they will refuse to open it."
        exit 1
    fi
    # Apple checks the image and the app in it, and its answer is attached to the
    # image, so a Mac that downloads it opens it without complaint, even offline.
    codesign --sign "$signer" --timestamp "$dmg"
    xcrun notarytool submit "$dmg" --keychain-profile "${NOTARY_PROFILE:-cortado}" --wait
    xcrun stapler staple "$dmg"
    echo "Built $dmg, signed and notarized"
fi
