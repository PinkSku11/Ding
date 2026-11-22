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
echo "== Experiment: the Mac's time box on a Mac set to 24-hour time, asked for AM/PM in different ways"
if xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$SDK" \
        -o "$WORK/timepicker" ci/experiments/timepicker.swift; then
    defaults write -g AppleICUForce24HourTime -bool true
    for S in components pref-launch pref-launch-components pref-late pref-late-notify; do
        defaults delete timepicker 2>/dev/null
        "$WORK/timepicker" "$S" "$OUT/exp-$S" &
        EXP=$!
        sleep 3
        WID=$(cat "$OUT/exp-$S.wid" 2>/dev/null)
        [ -n "$WID" ] && screencapture -x -l "$WID" "$OUT/exp-$S.png"
        wait "$EXP"
        cat "$OUT/exp-$S.txt" 2>/dev/null
        rm -f "$OUT/exp-$S.wid"
    done
    defaults delete timepicker 2>/dev/null
    defaults delete -g AppleICUForce24HourTime
else
    echo "(the experiment didn't build)"
fi

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
python3 ci/click.py tripleclick 960 101 # select the alarm's name
python3 ci/click.py type "Morning stretch"
sleep 0.5
screencapture -x "$OUT/click-typed.png"
python3 ci/click.py click 958 144       # the "Once" button
sleep 1.5
screencapture -x "$OUT/click-after.png"
python3 ci/click.py key return          # Return saves
sleep 1.5
screencapture -x "$OUT/click-saved.png"
pgrep -x Ding >/dev/null || echo "Ding stopped running in the click test"
pkill -x Ding
sleep 1
python3 - "$SUPPORT/alarms.json" <<'PY' || TEST_OK=0
import json, sys
alarm = next(a for a in json.load(open(sys.argv[1])) if a["id"].endswith("000000000001"))
print(f"Saved by typing and pressing Return: name {alarm['name']!r}, rings {alarm['kind']}")
if alarm["name"] != "Morning stretch" or alarm["kind"] != "once":
    print("CLICK TEST PROBLEM: the edit wasn't saved as typed")
    sys.exit(1)
PY
cp ci/sample-alarms.json "$SUPPORT/alarms.json"

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
    open -n "$APP" --args -DingRingLog /tmp/ding-rings.log \
        -DingTestSnooze 00000000-0000-4000-8000-0000000000B2 -DingSnoozeSeconds 60
    WAIT=$(python3 -c "import time; print(max(0, int($FIRST + 5 * 60 + 20 - time.time())))")
    echo "First ring at $FIRST, waiting $WAIT s"
    sleep "$WAIT"
    pkill -x Ding
    sleep 1
    cp /tmp/ding-rings.log "$OUT/ring-log.txt" 2>/dev/null
    echo "Output and volume for the first ring: $(grep -m1 ' sound ' /tmp/ding-rings.log | cut -d' ' -f4-)"
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
echo "== One of your sounds deleted: the editor shows Glass, which plays instead"
python3 - "$SUPPORT/alarms.json" <<'PY'
import json, sys
alarms = json.load(open(sys.argv[1]))
alarms[0]["sound"] = "custom:A sound that was deleted.m4a"
json.dump(alarms, open(sys.argv[1], "w"))
PY
shoot editor blue-editor-missing-sound dark || TEST_OK=0
cp ci/sample-alarms.json "$SUPPORT/alarms.json"

echo
echo "== A snoozed alarm that's off (a one-time alarm switches itself off): the Next line shows it"
defaults write com.shriya.Ding snoozes -dict 6F1C1D2E-0000-4000-8000-000000000004 -float "$(( $(date +%s) + 30 ))"
shoot menu blue-menu-snoozed dark || TEST_OK=0
defaults delete com.shriya.Ding snoozes 2>/dev/null

echo
echo "== Duplicate: the editor becomes an unsaved copy named \"Water break copy\"; Return saves it"
cp ci/sample-alarms.json "$SUPPORT/alarms.json"
pkill -x Ding 2>/dev/null; sleep 1
open -n "$APP" --args -DingShow editor-duplicate -DingDark YES
sleep 6
screencapture -x "$OUT/blue-editor-duplicate.png"
python3 ci/click.py click 560 55        # the window's title, to be sure it has the keyboard
python3 ci/click.py key return
sleep 1.5
pgrep -x Ding >/dev/null || echo "Ding stopped running in the duplicate test"
pkill -x Ding; sleep 1
python3 - "$SUPPORT/alarms.json" ci/sample-alarms.json <<'PY' || TEST_OK=0
import json, sys
saved, sample = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
fields = ["kind", "fromMinute", "untilMinute", "every", "everyUnit", "timeMinute", "sound", "plays", "playUnit",
          "volume", "ringWhenMuted", "keepAwake"]
def same(a, b):
    return all(a.get(f) == b.get(f) for f in fields) and set(a.get("days", [])) == set(b.get("days", []))
original = next(a for a in sample if a["name"] == "Water break")
kept = next((a for a in saved if a["id"] == original["id"]), None)
copies = [a for a in saved if a["name"] == "Water break copy"]
print(f"After Duplicate and Return: {len(saved)} alarms (was {len(sample)}), copies named 'Water break copy': {len(copies)}")
problems = []
if len(saved) != len(sample) + 1 or len(copies) != 1:
    problems.append("expected exactly one new alarm, the copy")
elif copies[0]["id"] == original["id"] or not same(copies[0], original) or not copies[0]["isOn"]:
    problems.append("the copy doesn't have its own id and the same settings, switched on")
if kept is None or kept["name"] != "Water break" or not same(kept, original):
    problems.append("the original changed")
for problem in problems:
    print("DUPLICATE TEST PROBLEM:", problem)
sys.exit(1 if problems else 0)
PY
cp ci/sample-alarms.json "$SUPPORT/alarms.json"

echo
echo "== A Mac set to 24-hour time: Ding follows it, and AM/PM can still be picked"
defaults write -g AppleICUForce24HourTime -bool true
shoot options blue-options-mac24 dark || TEST_OK=0
shoot menu blue-menu-mac24 dark || TEST_OK=0
shoot editor-switch blue-editor-switched dark || TEST_OK=0   # AM/PM picked while Ding runs
echo "Ding's own setting after picking AM/PM: timeFormat=$(defaults read com.shriya.Ding timeFormat 2>/dev/null)"
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
