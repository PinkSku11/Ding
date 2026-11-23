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
    -o "$WORK/schedule-tests" Sources/Models.swift Sources/Schedule.swift Sources/Microphone.swift ci/tests/main.swift || fail "building the tests"
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
clear_timer() {   # no timer left running from an earlier test
    defaults delete com.shriya.Ding timerEnd 2>/dev/null
    defaults delete com.shriya.Ding timerLength 2>/dev/null
    defaults delete com.shriya.Ding timerOtherMinutes 2>/dev/null
    return 0
}
clear_timer

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
echo "== Opening Ding again while it runs (as a click on its notification does): macOS gets its answer at once,"
echo "   and the alarm list shows, without the options"
reopen_check() {   # $1: the app. Opens it, then opens it again and leaves the list it shows open.
    pkill -x Ding 2>/dev/null; sleep 1
    open -n "$1" --args -DingDark YES
    sleep 4
    python3 - "$1" <<'PY'
import subprocess, sys, time
start = time.time()
try:
    result = subprocess.run(["open", sys.argv[1]], capture_output=True, text=True, timeout=45)
    print(f"answered after {time.time() - start:.1f} s (exit {result.returncode}) {result.stderr.strip()}")
except subprocess.TimeoutExpired:
    print("no answer after 45 s")
PY
}
rm -rf /tmp/previous /tmp/previous.zip; mkdir -p /tmp/previous
if git fetch -q --depth 1 origin build 2>/dev/null && git show FETCH_HEAD:Ding.zip > /tmp/previous.zip 2>/dev/null \
   && ditto -x -k /tmp/previous.zip /tmp/previous 2>/dev/null && [ -d /tmp/previous/Ding.app ]; then
    echo "The build before this one: $(reopen_check /tmp/previous/Ding.app)"
    pkill -x Ding; sleep 1
fi
REOPEN=$(reopen_check "$APP")
echo "This build: $REOPEN"
sleep 1
screencapture -x "$OUT/reopen.png"
python3 ci/click.py key escape; sleep 1
pkill -x Ding; sleep 1
case "$REOPEN" in
    "answered after "[0-2].*"(exit 0)"*) echo "OK: opening Ding again is answered at once, and the list still shows" ;;
    *) echo "FAIL: opening Ding again wasn't answered at once"; TEST_OK=0 ;;
esac

echo
echo "== Switch test: film the menu while an alarm is switched off"
pkill -x Ding 2>/dev/null
sleep 1
open -n "$APP" --args -DingShow menu
sleep 5
screencapture -v -V 2 -x -R 930,172,72,42 "$OUT/switch.mov" >/dev/null 2>&1 &
sleep 0.6
python3 ci/click.py click 965 192       # the first alarm's switch (below the timer row)
sleep 2.6
ls -la "$OUT/switch.mov" 2>/dev/null || echo "(no switch video)"
screencapture -x "$OUT/switch-after.png"   # the "Next:" line and the details update while the menu stays open
pkill -x Ding
sleep 1
cp ci/sample-alarms.json "$SUPPORT/alarms.json"

echo
echo "== Timer: 5 min, the countdown next to the bell, the running timer in the menu, Stop, Custom"
front_app() { osascript -e 'tell application "System Events" to name of first process whose frontmost is true' 2>/dev/null; }
show_log() { awk 'NR == 1 { t0 = $1 } { printf "  %6.2f s  %s\n", $1 - t0, substr($0, index($0, " ") + 1) }' "$1" 2>/dev/null || echo "(no log)"; }
clear_timer
rm -f /tmp/ding-timer.log
open -n "$APP" --args -DingShow menu -DingDark YES -DingRingLog /tmp/ding-timer.log
sleep 5
screencapture -x "$OUT/timer-menu.png"
python3 ci/click.py click 712 112          # "5 min"
sleep 1.5
screencapture -x "$OUT/timer-menubar.png"  # the menu has closed; the time left is next to the bell
pkill -x Ding; sleep 1
open -n "$APP" --args -DingShow menu -DingDark YES -DingRingLog /tmp/ding-timer.log   # still running after a restart
sleep 5
screencapture -x "$OUT/timer-running.png"
python3 ci/click.py click 961 121          # Stop
sleep 1.5
screencapture -x "$OUT/timer-stopped.png"
pkill -x Ding; sleep 1
open -n "$APP" --args -DingShow menu -DingDark YES -DingRingLog /tmp/ding-timer.log
sleep 5
python3 ci/click.py click 971 112; sleep 1       # Custom
python3 ci/click.py type "8"; sleep 0.3
for i in 1 2 3 4; do screencapture -x -R 670,130,140,36 "$OUT/timer-caret-$i.png"; sleep 0.2; done
python3 ci/click.py key return; sleep 1.5        # 8 minutes
python3 ci/click.py click 795 12; sleep 1.2      # the bell
python3 ci/click.py click 961 121; sleep 1.2     # Stop
pkill -x Ding; sleep 1

echo "-- Custom with another app in front, as when you click the bell"
open -n "$APP" --args -DingDark YES -DingRingLog /tmp/ding-timer.log
sleep 4
open -a Finder; sleep 2
echo "Front app before: $(front_app)"
python3 ci/click.py click 795 12; sleep 1.2      # the bell
python3 ci/click.py click 971 112; sleep 1       # Custom: a row with the minutes box opens under the lengths
screencapture -x "$OUT/timer-custom.png"
python3 ci/click.py type "37"; sleep 0.3
for i in 1 2 3 4; do screencapture -x -R 670,130,140,36 "$OUT/timer-caret-front-$i.png"; sleep 0.2; done
screencapture -x "$OUT/timer-custom-typed.png"
python3 ci/click.py key return; sleep 1.5        # Return starts it
CUSTOM_FRONT=$(front_app)
echo "Front app after Return: $CUSTOM_FRONT"
python3 ci/click.py click 795 12; sleep 1.2
python3 ci/click.py click 961 121; sleep 1.2     # Stop
python3 ci/click.py click 795 12; sleep 1.2
python3 ci/click.py click 971 112; sleep 1       # Custom: 37 is there, selected
python3 ci/click.py type "1x2"; sleep 0.6        # the x doesn't go in
python3 ci/click.py key delete; sleep 0.3        # Delete takes the 2 out
python3 ci/click.py type "5"; sleep 0.6
screencapture -x "$OUT/timer-custom-typed-again.png"
python3 ci/click.py click 965 148; sleep 1.5     # Start
python3 ci/click.py click 795 12; sleep 1.2
python3 ci/click.py click 961 121; sleep 1.2     # Stop
python3 ci/click.py click 795 12; sleep 1.2
python3 ci/click.py click 971 112; sleep 0.8     # Custom opens the row
python3 ci/click.py click 971 112; sleep 0.8     # and a second click closes it
screencapture -x "$OUT/timer-custom-closed.png"
python3 ci/click.py click 712 112; sleep 1.5     # 5 min
python3 ci/click.py click 795 12; sleep 1.2
python3 ci/click.py click 961 121; sleep 1.2     # Stop
pkill -x Ding; sleep 1
clear_timer
show_log /tmp/ding-timer.log
python3 - /tmp/ding-timer.log "$CUSTOM_FRONT" <<'PY2' || TEST_OK=0
import sys
lines = [line.split(" ", 1)[1].strip() for line in open(sys.argv[1]) if " " in line]
steps = [l.split(" ends ")[0] for l in lines
         if l.startswith(("timer started", "timer stopped", "timer custom"))]
want = ["timer started 300", "timer stopped",
        "timer custom", "timer started 480", "timer stopped",
        "timer custom", "timer started 2220", "timer stopped",
        "timer custom", "timer started 900", "timer stopped",
        "timer custom", "timer custom closed", "timer started 300", "timer stopped"]
typed = [l for l in lines if l.startswith("timer typed ")]
problems = []
if steps != want:
    problems.append(f"expected {want}, got {steps}")
if any("x" in l for l in typed):
    problems.append(f"a letter went into the box: {typed}")
if sys.argv[2] != "Finder":
    problems.append(f"Ding took the keyboard: the app in front is {sys.argv[2]!r}, not Finder")
if problems:
    print("FAIL: " + "; ".join(problems)); sys.exit(1)
print("OK: 5 min and Stop work; Custom with 8 and Return started 8 minutes; with Finder in front, 37 and Return")
print("    started 37, 1x2, Delete, 5 and Start started 15, a second click on Custom closed the row, and Finder kept")
print("    the keyboard")
PY2

echo "-- a 20-second timer rings like an alarm, and a click on the blue bell stops it"
rm -f /tmp/ding-timer-ring.log
open -n "$APP" --args -DingTestTimer 20 -DingDark YES -DingRingLog /tmp/ding-timer-ring.log
sleep 6
screencapture -x "$OUT/timer-countdown.png"
sleep 19
screencapture -x "$OUT/timer-ringing.png"
python3 ci/click.py click 795 12           # the blue bell
sleep 1.5
pkill -x Ding; sleep 1
clear_timer
show_log /tmp/ding-timer-ring.log
python3 - /tmp/ding-timer-ring.log <<'PY' || TEST_OK=0
import sys
TIMER = "7D1A3E52-0000-4000-8000-00000000D1E7"
lines = [(float(l.split(" ", 1)[0]), l.split(" ", 1)[1].strip()) for l in open(sys.argv[1]) if " " in l]
started = [t for t, l in lines if l.startswith("timer started 20 ")]
rang = [(t, l) for t, l in lines if l.startswith(f"ring {TIMER} ")]
named = [l for _, l in lines if l.startswith("notification ding.") and "| 20 s timer |" in l]
cleared = [t for t, l in lines if l.startswith(f"clear {TIMER}")]
problems = []
if not started:
    problems.append("the timer didn't start")
if len(rang) != 1:
    problems.append(f"rang {len(rang)} times")
elif started:
    late = rang[0][0] - started[0] - 20
    print(f"   rang {late:.1f} s after its 20 seconds were up: {rang[0][1]}")
    if not -0.5 <= late <= 2:
        problems.append(f"rang {late:.1f} s late")
    if " sound played " not in rang[0][1] + " ":
        problems.append("no sound")
if not named:
    problems.append("no notification named \"20 s timer\"")
if not cleared or (rang and cleared[0] - rang[0][0] > 25):
    problems.append("the click on the blue bell didn't stop it")
if problems:
    print("FAIL: " + "; ".join(problems)); sys.exit(1)
print("OK: the timer rang on time with its sound and a notification named \"20 s timer\"; the blue bell stopped it")
PY

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

echo
echo "== Arrows in the editor: From, Until, Every and Play sound; then typing, Tab and Return"
arrow() {   # $1: the box, $2: up, down or text; prints the point to click, from where Ding says its arrows are
    python3 - "$1" "$2" /tmp/ding-arrows.log <<'PY'
import sys
name, part, log = sys.argv[1], sys.argv[2], sys.argv[3]
for line in open(log):
    words = line.split()
    if len(words) >= 7 and words[1] == "arrows" and words[2] == name:
        x, y, w, h = map(float, words[3:7])
        if part == "text":
            print(int(x - 20), int(y + h / 2))
        else:
            print(int(x + w / 2), int(y + h / 2 + (-5 if part == "up" else 5)))
        break
PY
}
rm -f /tmp/ding-arrows.log
pkill -x Ding 2>/dev/null; sleep 1
open -n "$APP" --args -DingShow editor-arrows -DingDark YES -DingRingLog /tmp/ding-arrows.log
sleep 5
grep " arrows " /tmp/ding-arrows.log || echo "(Ding didn't say where its arrows are)"
screencapture -x "$OUT/arrows-before.png"
python3 ci/click.py click $(arrow From up); sleep 0.5          # 9:00 becomes 10:00
python3 ci/click.py click $(arrow Until down); sleep 0.5       # 23:00 becomes 22:00
python3 ci/click.py click $(arrow Every up); sleep 0.4         # 15 becomes 16
python3 ci/click.py click $(arrow Every up); sleep 0.4         # and 17
python3 ci/click.py click $(arrow Play_sound down); sleep 0.5  # 2 becomes 1
screencapture -x "$OUT/arrows-after.png"
python3 ci/click.py key return; sleep 1.5                      # Return saves
pkill -x Ding 2>/dev/null; sleep 1
python3 - "$SUPPORT/alarms.json" <<'PY' || TEST_OK=0
import json, sys
alarm = next(a for a in json.load(open(sys.argv[1])) if a["name"] == "Water break")
got = (alarm["fromMinute"], alarm["untilMinute"], alarm["every"], alarm["plays"])
print(f"After the arrows: from {got[0]}, until {got[1]}, every {got[2]}, plays {got[3]}")
if got != (600, 1320, 17, 1):
    print("ARROWS TEST PROBLEM: expected from 600 (10:00), until 1320 (22:00), every 17 and plays 1")
    sys.exit(1)
print("OK: the arrows moved the hours and the numbers by one")
PY
rm -f /tmp/ding-arrows.log
open -n "$APP" --args -DingShow editor-arrows -DingDark YES -DingRingLog /tmp/ding-arrows.log
sleep 5
python3 ci/click.py tripleclick $(arrow Every text); sleep 0.3   # select what's in Every
python3 ci/click.py type "2x0"; sleep 0.3                       # the x doesn't go in
python3 ci/click.py key tab; sleep 0.3                          # on to Play sound
python3 ci/click.py type "5"; sleep 0.3
python3 ci/click.py key up; sleep 0.3                           # the up arrow key counts up: 6
screencapture -x "$OUT/arrows-typed.png"
python3 ci/click.py key return; sleep 1.5
pkill -x Ding 2>/dev/null; sleep 1
python3 - "$SUPPORT/alarms.json" <<'PY' || TEST_OK=0
import json, sys
alarm = next(a for a in json.load(open(sys.argv[1])) if a["name"] == "Water break")
print(f"After typing: every {alarm['every']}, plays {alarm['plays']}")
if (alarm["every"], alarm["plays"]) != (20, 6):
    print("ARROWS TEST PROBLEM: expected every 20 (typed) and plays 6 (Tab, 5, then the up arrow key)")
    sys.exit(1)
print("OK: typing, Tab to the next box and the up arrow key work")
PY
cp ci/sample-alarms.json "$SUPPORT/alarms.json"

echo
echo "== Done in the editor opened from the list: the list comes back"
rm -f /tmp/ding-back.log
pkill -x Ding 2>/dev/null; sleep 1
open -n "$APP" --args -DingShow menu -DingDark YES -DingRingLog /tmp/ding-back.log
sleep 5
python3 ci/click.py click 760 193; sleep 2     # the first alarm: its editor opens
python3 ci/click.py key escape; sleep 2        # Escape closes the editor, and the list comes back
screencapture -x "$OUT/back-after-escape.png"
python3 ci/click.py click 760 193; sleep 2     # the first alarm again
python3 ci/click.py key return; sleep 2        # Save, and the list comes back
screencapture -x "$OUT/back-after-save.png"
python3 ci/click.py key escape; sleep 1        # the list closes
pkill -x Ding 2>/dev/null; sleep 1
show_log /tmp/ding-back.log
SHOWN=$(grep -c " list shown" /tmp/ding-back.log 2>/dev/null)
BACK=$(grep -c " editor done, back to the list" /tmp/ding-back.log 2>/dev/null)
if [ "$SHOWN" = 3 ] && [ "$BACK" = 2 ]; then
    echo "OK: after Escape and after Save, the list came back"
else
    echo "BACK TO THE LIST PROBLEM: the list was shown $SHOWN times (expected 3), back after the editor $BACK times (expected 2)"
    TEST_OK=0
fi
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
echo "== Preview experiment: pick sounds and move the volume like a person would, and log every step"
cp ci/sample-alarms.json "$SUPPORT/alarms.json"
rm -f /tmp/ding-preview.log
pkill -x Ding 2>/dev/null; sleep 1
osascript -e 'set volume output volume 30'   # the Mac's own volume, which Ding must put back afterwards
VOLUME_BEFORE=$(osascript -e 'output volume of (get volume settings)' 2>&1)
open -n "$APP" --args -DingShow editor -DingDark YES -DingRingLog /tmp/ding-preview.log
sleep 4
POPUP_X=973; POPUP_Y=358            # the Sound box in the editor for the first sample alarm
echo "-- the same sound again (Glass, already picked)"
python3 ci/click.py click $POPUP_X $POPUP_Y; sleep 0.8
screencapture -x "$OUT/preview-popup-open.png"
python3 ci/click.py click $POPUP_X $POPUP_Y; sleep 2
echo "-- the next sound, then quickly the ones after it"
for GAP in 2.5 0.4 1.2 0.6 0.3 2.0; do
    python3 ci/click.py click $POPUP_X $POPUP_Y; sleep 0.6
    python3 ci/click.py key down; sleep 0.15
    python3 ci/click.py key return; sleep $GAP
done
echo "-- the volume slider: drags, and a click on the bar"
python3 ci/click.py drag 910 441 800 441; sleep 2
python3 ci/click.py drag 800 441 880 441; sleep 2
python3 ci/click.py click 850 441; sleep 2
python3 ci/click.py drag 850 441 760 441; sleep 2
screencapture -x "$OUT/preview-after.png"
pkill -x Ding; sleep 1
echo "-- what Ding did:"
awk 'NR == 1 { t0 = $1 } { printf "  %6.2f s  %s\n", $1 - t0, substr($0, index($0, " ") + 1) }' /tmp/ding-preview.log 2>/dev/null || echo "(no log)"
cp /tmp/ding-preview.log "$OUT/preview-log.txt" 2>/dev/null
cp ci/sample-alarms.json "$SUPPORT/alarms.json"
VOLUME_AFTER=$(osascript -e 'output volume of (get volume settings)' 2>&1)
echo "-- the Mac's own volume: $VOLUME_BEFORE before, $VOLUME_AFTER after"
python3 - /tmp/ding-preview.log "$VOLUME_BEFORE" "$VOLUME_AFTER" <<'PY' || TEST_OK=0
import sys
log, before, after = sys.argv[1], sys.argv[2], sys.argv[3]
lines = [line.split(" ", 1)[1].strip() for line in open(log) if " " in line]
volume = [line for line in lines if line.startswith("volume ")]
replaced, bad = 0, []
for i, line in enumerate(lines):
    if line.startswith("preview stopped (a new one started)"):
        replaced += 1
        following = next((l for l in lines[i + 1:] if l.startswith("volume ")), "")
        if not following.startswith("volume kept"):
            bad.append(following or "nothing")
saved = sum(l.startswith("volume saved") for l in volume)
restored = sum(l.startswith("volume restored") for l in volume)
print(f"   saved {saved} times, put back {restored} times, kept {len(volume) - saved - restored} times; "
      f"{replaced} sounds replaced another")
ok = True
if bad:
    print(f"FAIL: a sound that replaced another read the volume again: {bad}"); ok = False
if saved != restored:
    print(f"FAIL: saved {saved} times but put back {restored} times"); ok = False
if before.isdigit() and after.isdigit() and before != after:
    print(f"FAIL: the Mac's volume was {before} and is now {after}"); ok = False
if ok:
    print("OK: one sound replacing another keeps the Mac's own volume, which is put back at the end")
sys.exit(0 if ok else 1)
PY

echo
echo "== The note next to the sound: why a sound you try stays silent"
rm -f /tmp/ding-note.log
osascript -e 'set volume with output muted'
echo "Mac muted: $(osascript -e 'output muted of (get volume settings)' 2>&1)"
open -n "$APP" --args -DingShow editor -DingDark YES -DingRingLog /tmp/ding-note.log
sleep 4
python3 ci/click.py click $POPUP_X $POPUP_Y; sleep 0.6   # the next sound, on a muted Mac (Water break doesn't ring when muted)
python3 ci/click.py key down; sleep 0.15
python3 ci/click.py key return; sleep 1.5
screencapture -x "$OUT/preview-note-muted.png"
osascript -e 'set volume without output muted'
echo "Mac muted: $(osascript -e 'output muted of (get volume settings)' 2>&1)"
sleep 6
screencapture -x "$OUT/preview-note-gone.png"
pkill -x Ding; sleep 1
awk 'NR == 1 { t0 = $1 } { printf "  %6.2f s  %s\n", $1 - t0, substr($0, index($0, " ") + 1) }' /tmp/ding-note.log 2>/dev/null || echo "(no log)"
if grep -q "preview silent-muted" /tmp/ding-note.log 2>/dev/null; then
    echo "OK: a sound tried on a muted Mac stays silent, and the note says why"
else
    echo "NOTE: the muted case didn't happen (this Mac's sound device may not mute)"
fi
echo "-- an alarm that rings on a muted Mac: its notification says why it's silent"
rm -f /tmp/ding-silent.log
osascript -e 'set volume with output muted'
open -n "$APP" --args -DingShow ring -DingRingLog /tmp/ding-silent.log
sleep 4
osascript -e 'set volume without output muted'
pkill -x Ding; sleep 1
awk 'NR == 1 { t0 = $1 } { printf "  %6.2f s  %s\n", $1 - t0, substr($0, index($0, " ") + 1) }' /tmp/ding-silent.log 2>/dev/null || echo "(no log)"
if grep -q "silent-muted" /tmp/ding-silent.log 2>/dev/null; then
    if grep -q "^[0-9.]* notification ding\.[^ ]* | Water break | No sound: the Mac is muted | " /tmp/ding-silent.log; then
        echo "OK: the notification of a silent ring says \"No sound: the Mac is muted\""
    else
        echo "FAIL: the silent ring's notification doesn't say why"; TEST_OK=0
    fi
else
    echo "NOTE: the muted case didn't happen (this Mac's sound device may not mute)"
fi
echo "-- a long app name in the note"
open -n "$APP" --args -DingShow editor-note -DingTestNote "No sound: Microsoft Teams is using the mic" -DingDark YES
sleep 4
screencapture -x "$OUT/preview-note-long.png"
pkill -x Ding; sleep 1
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

echo
echo "== Microphone: a call keeps Ding quiet, Siri listening for \"Hey Siri\" doesn't"
cp ci/sample-alarms.json "$SUPPORT/alarms.json"
mkdir -p "$WORK/mic"
if xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" -sdk "$SDK" \
        -o "$WORK/mic/corespeechd" ci/recorder.swift; then
    cp "$WORK/mic/corespeechd" "$WORK/mic/Recorder"
    MIC_LOG=/tmp/ding-mic.log; rm -f "$MIC_LOG"
    open -n "$APP" --args -DingShow editor -DingDark YES -DingRingLog "$MIC_LOG"
    sleep 4
    "$WORK/mic/corespeechd" 12 > /tmp/mic-siri.txt 2>&1 &
    SIRI=$!
    sleep 3
    python3 ci/click.py click $POPUP_X $POPUP_Y; sleep 0.6   # the next sound, while "corespeechd" records
    python3 ci/click.py key down; sleep 0.15
    python3 ci/click.py key return; sleep 1.5
    screencapture -x "$OUT/mic-siri-listening.png"
    wait $SIRI
    "$WORK/mic/Recorder" 12 > /tmp/mic-call.txt 2>&1 &
    CALL=$!
    sleep 3
    python3 ci/click.py click $POPUP_X $POPUP_Y; sleep 0.6   # the next sound, while "Recorder" records
    python3 ci/click.py key down; sleep 0.15
    python3 ci/click.py key return; sleep 1.5
    screencapture -x "$OUT/mic-call.png"
    wait $CALL
    pkill -x Ding; sleep 1
    echo "\"corespeechd\": $(cat /tmp/mic-siri.txt)"
    echo "\"Recorder\": $(cat /tmp/mic-call.txt)"
    awk 'NR == 1 { t0 = $1 } { printf "  %6.2f s  %s\n", $1 - t0, substr($0, index($0, " ") + 1) }' "$MIC_LOG" 2>/dev/null
    FIRST=$(grep -E " preview (played|silent)" "$MIC_LOG" 2>/dev/null | sed -n 1p | awk '{ print $3 }')
    SECOND=$(grep -E " preview (played|silent)" "$MIC_LOG" 2>/dev/null | sed -n 2p | awk '{ print $3 }')
    if grep -q "^recorded [1-9]" /tmp/mic-siri.txt && grep -q "^recorded [1-9]" /tmp/mic-call.txt; then
        if [ "$FIRST" = played ] && [ "$SECOND" = "silent-mic:Recorder" ]; then
            echo "OK: the sound played while \"corespeechd\" recorded, and stayed quiet while \"Recorder\" did"
        else
            echo "FAIL: expected played, then silent-mic:Recorder; got '$FIRST', then '$SECOND'"
            TEST_OK=0
        fi
    else
        echo "NOTE: this Mac couldn't record from a microphone, so this check was skipped (got '$FIRST', then '$SECOND')"
    fi
else
    echo "NOTE: the microphone stand-in didn't build"
fi

echo
echo "== Missed while asleep: an alarm whose time passes while Ding can't run says so afterwards"
EPOCH=$(date +%s)
WAIT=$(( 60 - 10#$(date -r "$EPOCH" +%S) ))      # seconds until the next minute
[ "$WAIT" -lt 15 ] && WAIT=$(( WAIT + 60 ))      # far enough ahead that Ding is standing still by then
DUE=$(( EPOCH + WAIT ))
MISS_MIN=$(( 10#$(date -r "$DUE" +%H) * 60 + 10#$(date -r "$DUE" +%M) ))
cat > "$SUPPORT/alarms.json" <<JSON
[{"id": "6F1C1D2E-0000-4000-8000-0000000000C1", "name": "Morning walk", "isOn": true, "kind": "once",
  "fromMinute": 540, "untilMinute": 1380, "every": 15, "everyUnit": "minutes", "timeMinute": $MISS_MIN,
  "days": [1, 2, 3, 4, 5, 6, 7], "sound": "Glass", "plays": 1, "playUnit": "times", "volume": 0.3,
  "ringWhenMuted": false, "keepAwake": false},
 {"id": "6F1C1D2E-0000-4000-8000-0000000000C2", "name": "Every minute", "isOn": true, "kind": "repeating",
  "fromMinute": 0, "untilMinute": 0, "every": 1, "everyUnit": "minutes", "timeMinute": 0,
  "days": [1, 2, 3, 4, 5, 6, 7], "sound": "", "plays": 1, "playUnit": "times", "volume": 0.3,
  "ringWhenMuted": false, "keepAwake": false}]
JSON
rm -f /tmp/ding-missed.log
FREEZE=$(( WAIT + 75 ))
open -n "$APP" --args -DingTestFreeze $FREEZE -DingTestTimer 20 -DingRingLog /tmp/ding-missed.log
echo "Morning walk is due in $WAIT s; Ding stands still for $FREEZE s, as if the Mac were asleep..."
sleep $(( FREEZE + 6 ))
pkill -x Ding; sleep 1
awk 'NR == 1 { t0 = $1 } { printf "  %6.2f s  %s\n", $1 - t0, substr($0, index($0, " ") + 1) }' /tmp/ding-missed.log 2>/dev/null || echo "(no log)"
WALK=6F1C1D2E-0000-4000-8000-0000000000C1
if grep -q " missed $WALK " /tmp/ding-missed.log 2>/dev/null \
   && grep -q " notification ding\.missed\.$WALK | Morning walk |  | Missed at .* while your Mac was asleep" /tmp/ding-missed.log \
   && ! grep -q " ring $WALK " /tmp/ding-missed.log \
   && ! grep -q " missed 6F1C1D2E-0000-4000-8000-0000000000C2 " /tmp/ding-missed.log; then
    echo "OK: the missed alarm set for a time didn't ring late; a notification says it was missed, and the"
    echo "    alarm that rings every minute just carried on"
else
    echo "FAIL: the missed alarm wasn't reported as expected"; TEST_OK=0
fi
TIMER=7D1A3E52-0000-4000-8000-00000000D1E7
if grep -q " missed $TIMER " /tmp/ding-missed.log 2>/dev/null \
   && grep -q " notification ding\.missed\.$TIMER | 20 s timer |  | Missed at .* while your Mac was asleep" /tmp/ding-missed.log \
   && ! grep -q " ring $TIMER " /tmp/ding-missed.log; then
    echo "OK: a timer that ran out while Ding stood still didn't ring late; a notification says it was missed"
else
    echo "FAIL: the missed timer wasn't reported as expected"; TEST_OK=0
fi
clear_timer

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
