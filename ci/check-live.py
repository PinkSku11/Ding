"""Checks the live test's ring log: check-live.py RING_LOG ALARMS_FILE FIRST_RING_TIME"""
import json
import sys

log_path, alarms_path, first = sys.argv[1], sys.argv[2], float(sys.argv[3])
A, B, C, D, E = ("00000000-0000-4000-8000-0000000000" + s for s in ("A1", "B2", "C3", "D4", "E5"))
names = {A: "Every minute", B: "One-off", C: "Same minute", D: "Switched off", E: "Silent"}

rings, offs, skipped = {}, set(), []
for line in open(log_path):
    parts = line.split()
    if len(parts) < 3:
        continue
    stamp, kind, alarm = float(parts[0]), parts[1], parts[2]
    if kind == "ring":
        rings.setdefault(alarm, []).append((stamp, float(parts[4]), parts[6]))
    elif kind == "off":
        offs.add(alarm)
    elif kind == "skipped":
        skipped.append(names.get(alarm, alarm))

problems = []


def expect(alarm, minutes, sounds=("played", "silent")):
    got = rings.get(alarm, [])
    due = [round(d) for _, d, _ in got]
    want = [int(first + 60 * m) for m in minutes]
    if due != want:
        problems.append(f"{names[alarm]}: rang for {[(d - first) / 60 for d in due]} min, expected {minutes}")
    for actual, d, sound in got:
        late = actual - d
        print(f"  {names[alarm]:<13} due +{(d - first) / 60:.0f} min, started {late:4.1f} s after, sound {sound}")
        if not 0 <= late <= 8:   # a second alarm in the same minute waits for the first to finish
            problems.append(f"{names[alarm]} started {late:.1f} s after it was due")
        if sound not in sounds:
            problems.append(f"{names[alarm]}: sound {sound}, expected {sounds}")


expect(A, [0, 1, 2, 3, 4])
expect(B, [1])
expect(C, [2])
expect(D, [])
expect(E, [3], sounds=("silent",))
if B not in offs:
    problems.append("the one-off alarm didn't switch itself off")
saved = {a["id"]: a for a in json.load(open(alarms_path))}
if saved[B]["isOn"]:
    problems.append("the one-off alarm is still on in the saved file")
if saved[A]["isOn"] is not True or saved[C]["isOn"] is not True:
    problems.append("an alarm that should stay on was switched off")
if skipped:
    problems.append(f"rings were skipped: {skipped}")

if problems:
    print("LIVE TEST PROBLEMS:")
    for problem in problems:
        print("  -", problem)
    sys.exit(1)
print("Live test: every ring came on time, the one-off switched itself off, the switched-off alarm stayed quiet.")
