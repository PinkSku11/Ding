#!/bin/bash
# Builds Ding.app for Apple silicon and Intel Macs, test-runs it, and packs it into Ding.dmg.
# Runs on GitHub's Mac build machines (see .github/workflows/build.yml).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
OUT="$ROOT/out"
WORK="$ROOT/.ci-work"
rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK"

fail() {
    echo
    echo "FAILED: $*"
    echo "failure" > "$OUT/status.txt"
    exit 1
}

echo "== Machine"
sw_vers
xcodebuild -version | head -n 2
echo "SDK $(xcrun --sdk macosx --show-sdk-version)"
xcrun swiftc --version 2>&1 | head -n 1

SDK="$(xcrun --sdk macosx --show-sdk-path)"
for ARCH in arm64 x86_64; do
    echo
    echo "== Compiling for $ARCH"
    xcrun swiftc -O -swift-version 5 \
        -target "$ARCH-apple-macos14.0" \
        -sdk "$SDK" \
        -module-name Ding \
        -o "$WORK/Ding-$ARCH" \
        Sources/*.swift || fail "compiling for $ARCH"
done

echo
echo "== Scheduling tests"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$SDK" \
    -o "$WORK/schedule-tests" Sources/Models.swift Sources/Schedule.swift ci/tests/main.swift || fail "building the tests"
TZ=Asia/Kolkata "$WORK/schedule-tests" || fail "scheduling tests"

echo
echo "== Putting Ding.app together"
APP="$WORK/Ding.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/Ding" "$WORK/Ding-arm64" "$WORK/Ding-x86_64" || fail "lipo"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" || fail "Info.plist"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    DOUBLE=$((SIZE * 2))
    sips -z "$SIZE" "$SIZE" AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null || fail "icon"
    sips -z "$DOUBLE" "$DOUBLE" AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null || fail "icon"
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || fail "iconutil"

xattr -cr "$APP"
codesign --force --sign - "$APP" || fail "codesign"
codesign --verify --strict --verbose=2 "$APP" || fail "codesign check"
lipo -info "$APP/Contents/MacOS/Ding"
du -sh "$APP"

# A clean copy for packaging, made before the test runs touch anything.
RELEASE="$WORK/release"
mkdir -p "$RELEASE"
ditto "$APP" "$RELEASE/Ding.app"
xattr -cr "$RELEASE/Ding.app"

echo
echo "== Test run, with screenshots"
SUPPORT="$HOME/Library/Application Support/Ding"
mkdir -p "$SUPPORT"
cp ci/sample-alarms.json "$SUPPORT/alarms.json"
defaults write com.shriya.Ding launchedBefore -bool true
defaults write -g NSMenuEnableActionImages -bool NO

shoot() {   # $1: what Ding should show, $2: screenshot name, $3: "dark" for dark mode
    pkill -x Ding 2>/dev/null
    sleep 1
    if [ "${3:-}" = dark ]; then
        open -n "$APP" --args -DingShow "$1" -DingDark YES
    else
        open -n "$APP" --args -DingShow "$1"
    fi
    sleep 8
    if ! pgrep -x Ding >/dev/null; then
        echo "Ding stopped running while showing: $1"
        for REPORT in $(ls -t "$HOME/Library/Logs/DiagnosticReports" 2>/dev/null | grep -i ding | head -n 2); do
            cp "$HOME/Library/Logs/DiagnosticReports/$REPORT" "$OUT/"
        done
        return 1
    fi
    screencapture -x "$OUT/$2.png" || echo "(screenshot failed for $2)"
    pkill -x Ding
    sleep 1
    echo "OK: $2"
    return 0
}

TEST_OK=1
shoot menu menu dark || TEST_OK=0
shoot editor editor dark || TEST_OK=0
shoot new new-alarm dark || TEST_OK=0
shoot menu-plus new-from-menu dark || TEST_OK=0
shoot menu menu-light || TEST_OK=0
shoot options options dark || TEST_OK=0

echo
echo "== Switch test: film the menu while an alarm is switched off"
pkill -x Ding 2>/dev/null
sleep 1
open -n "$APP" --args -DingShow menu
sleep 5
screencapture -v -V 2 -x -R 930,100,72,42 "$OUT/switch.mov" >/dev/null 2>&1 &
sleep 0.6
python3 ci/click.py click 965 120       # the first alarm's switch
sleep 2.6
ls -la "$OUT/switch.mov" 2>/dev/null || echo "(no switch video)"
screencapture -x "$OUT/switch-after.png"   # the "Next:" line and the details update while the menu stays open
pkill -x Ding
sleep 1
cp ci/sample-alarms.json "$SUPPORT/alarms.json"

echo
echo "== Click test: another app in front; open the editor, close it, open it again, then use it"
pkill -x Ding 2>/dev/null
sleep 1
open -n "$APP" --args -DingShow editor-cycle
sleep 9
FRONT=$(osascript -e 'tell application "System Events" to name of first process whose frontmost is true' 2>/dev/null)
echo "Front app while the editor is open: $FRONT"
screencapture -x "$OUT/click-before.png"
python3 ci/click.py click 980 101       # the alarm's name
python3 ci/click.py key end             # to the end of it
python3 ci/click.py type " test"
python3 ci/click.py click 958 144       # the "Once" button
sleep 2
screencapture -x "$OUT/click-after.png"
pgrep -x Ding >/dev/null || echo "Ding stopped running in the click test"
pkill -x Ding
sleep 1

rm -f "$SUPPORT/alarms.json"
shoot menu empty dark || TEST_OK=0
[ "$TEST_OK" = 1 ] || fail "test run"

echo
echo "== Ring test: an alarm set two minutes ahead should ring on time"
EPOCH=$(date +%s)
NOW_H=$(date -r "$EPOCH" +%H)
NOW_M=$(date -r "$EPOCH" +%M)
NOW_S=$(date -r "$EPOCH" +%S)
RING_MIN=$(( (10#$NOW_H * 60 + 10#$NOW_M + 2) % 1440 ))
TARGET=$(( EPOCH - 10#$NOW_S + 123 ))   # 3 seconds after the alarm is due
cat > "$SUPPORT/alarms.json" <<JSON
[{"id": "6F1C1D2E-0000-4000-8000-0000000000AA", "name": "Test ring", "isOn": true, "kind": "once",
  "fromMinute": 540, "untilMinute": 1380, "every": 15, "everyUnit": "minutes", "timeMinute": $RING_MIN,
  "days": [1, 2, 3, 4, 5, 6, 7], "sound": "Glass", "plays": 10, "playUnit": "seconds", "volume": 0.5,
  "ringWhenMuted": true}]
JSON
pkill -x Ding 2>/dev/null
sleep 1
open -n "$APP"
echo "Alarm due at minute $RING_MIN of the day; waiting..."
sleep $(( TARGET - $(date +%s) ))
screencapture -x "$OUT/ringing.png" || echo "(screenshot failed for ringing)"
pgrep -x Ding >/dev/null || fail "Ding stopped running during the ring test"
pkill -x Ding
rm -f "$SUPPORT/alarms.json"
echo "OK: ringing"

echo
echo "== Live test: real alarms over the next few minutes"
pkill -x Ding 2>/dev/null
sleep 1
FIRST=$(python3 ci/live-alarms.py "$SUPPORT/alarms.json")
if [ -n "$FIRST" ]; then
    rm -f /tmp/ding-rings.log
    open -n "$APP" --args -DingRingLog /tmp/ding-rings.log
    WAIT=$(python3 -c "import time; print(max(0, int($FIRST + 5 * 60 + 20 - time.time())))")
    echo "First ring at $FIRST, waiting $WAIT s"
    sleep "$WAIT"
    pkill -x Ding
    sleep 1
    cp /tmp/ding-rings.log "$OUT/ring-log.txt" 2>/dev/null
    python3 ci/check-live.py /tmp/ding-rings.log "$SUPPORT/alarms.json" "$FIRST" || fail "live test"
else
    echo "(live test skipped: too close to midnight)"
fi
rm -f "$SUPPORT/alarms.json"

echo
echo "== Over a blue desktop: the editor and the menu"
python3 ci/solid-png.py /tmp/ding-blue.png 1024 768 74 106 222
osascript -e 'tell application "System Events" to tell every desktop to set picture to POSIX file "/tmp/ding-blue.png"' \
    || echo "(could not set the desktop picture)"
sleep 2
cp ci/sample-alarms.json "$SUPPORT/alarms.json"
shoot editor blue-editor dark || TEST_OK=0
shoot new blue-new dark || TEST_OK=0
shoot menu blue-menu dark || TEST_OK=0
defaults write com.shriya.Ding timeFormat 24
shoot editor blue-editor-24h dark || TEST_OK=0
shoot menu blue-menu-24h dark || TEST_OK=0
shoot options blue-options-24h dark || TEST_OK=0
defaults delete com.shriya.Ding timeFormat

echo
echo "== A Mac set to 24-hour time: Ding follows it, and AM/PM can still be picked"
defaults write -g AppleICUForce24HourTime -bool true
shoot options blue-options-mac24 dark || TEST_OK=0
shoot menu blue-menu-mac24 dark || TEST_OK=0
defaults write com.shriya.Ding timeFormat 12
shoot editor blue-editor-ampm dark || TEST_OK=0
shoot menu blue-menu-ampm dark || TEST_OK=0
defaults delete com.shriya.Ding timeFormat
defaults delete -g AppleICUForce24HourTime
rm -f "$SUPPORT/alarms.json"
[ "$TEST_OK" = 1 ] || fail "test run"

echo
echo "== Making Ding.dmg"
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
ditto "$RELEASE/Ding.app" "$STAGE/Ding.app"
ln -s /Applications "$STAGE/Applications"
MADE=0
for TRY in 1 2 3; do
    if hdiutil create -volname "Ding" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Ding.dmg"; then
        MADE=1
        break
    fi
    echo "hdiutil failed (try $TRY), trying again"
    sleep 5
done
[ "$MADE" = 1 ] || fail "making the dmg"
hdiutil verify "$OUT/Ding.dmg" || fail "checking the dmg"

echo
echo "== Making Ding.zip"
ditto -c -k --keepParent "$RELEASE/Ding.app" "$OUT/Ding.zip" || fail "making the zip"
CHECK="$WORK/zip-check"
mkdir -p "$CHECK"
ditto -x -k "$OUT/Ding.zip" "$CHECK" || fail "unpacking the zip"
codesign --verify --strict --verbose=2 "$CHECK/Ding.app" || fail "signature of the unzipped app"
pkill -x Ding 2>/dev/null
open -n "$CHECK/Ding.app"
sleep 5
pgrep -x Ding >/dev/null || fail "the unzipped app did not start"
pkill -x Ding
echo "OK: unzipped app starts"
ls -la "$OUT"

echo "success" > "$OUT/status.txt"
echo
echo "BUILD SUCCEEDED"
