#!/bin/bash
# Builds Ding from the Swift files in Sources/ and puts it in your Applications folder.
# In Terminal, type  bash  and a space, drag this file into the window, and press Return.

cd "$(dirname "$0")" || exit 1
HERE="$PWD"
LOG="$HERE/build.log"

build() {
    echo "Building Ding ($(date))"
    echo "macOS $(sw_vers -productVersion), $(uname -m)"

    if ! xcode-select -p >/dev/null 2>&1; then
        echo
        echo "Ding needs Apple's free Command Line Tools to build."
        echo "A window should open asking to install them. Click Install, wait until it's done,"
        echo "then run this file again."
        xcode-select --install >/dev/null 2>&1
        return 1
    fi
    echo "$(xcrun swiftc --version 2>&1 | head -n 1)"

    BUILD="$HERE/build"
    APP="$BUILD/Ding.app"
    rm -rf "$BUILD"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" || return 1

    SDK="$(xcrun --sdk macosx --show-sdk-path)" || return 1
    ARCH="$(uname -m)"

    echo
    echo "Compiling..."
    if ! xcrun swiftc -O -swift-version 5 \
            -target "$ARCH-apple-macos14.0" \
            -sdk "$SDK" \
            -module-name Ding \
            -o "$APP/Contents/MacOS/Ding" \
            Sources/*.swift; then
        echo
        echo "BUILD FAILED. The errors are above and in build.log, in this folder."
        return 1
    fi

    cp Info.plist "$APP/Contents/Info.plist" || return 1
    printf 'APPL????' > "$APP/Contents/PkgInfo"

    # App icon, made with the Mac's own tools from AppIcon.png (a ready-made one is the fallback).
    ICONSET="$BUILD/AppIcon.iconset"
    mkdir -p "$ICONSET"
    ICON_OK=1
    for SIZE in 16 32 128 256 512; do
        DOUBLE=$((SIZE * 2))
        sips -z "$SIZE" "$SIZE" AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null 2>&1 || ICON_OK=0
        sips -z "$DOUBLE" "$DOUBLE" AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null 2>&1 || ICON_OK=0
    done
    if [ "$ICON_OK" = 1 ] && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
        :
    else
        cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    fi
    rm -rf "$ICONSET"

    xattr -cr "$APP"
    codesign --force --sign - "$APP" || return 1

    echo
    echo "Installing..."
    if pkill -x Ding 2>/dev/null; then sleep 1; fi
    DEST="/Applications"
    if [ ! -w "$DEST" ]; then
        DEST="$HOME/Applications"
        mkdir -p "$DEST"
    fi
    rm -rf "$DEST/Ding.app"
    ditto "$APP" "$DEST/Ding.app" || return 1
    rm -rf "$BUILD"

    open "$DEST/Ding.app"
    echo
    echo "Done! Ding is in $DEST, and its bell is in your menu bar."
    echo "If your Mac asks whether Ding can send notifications, click Allow."
}

build 2>&1 | tee "$LOG"
exit "${PIPESTATUS[0]}"
