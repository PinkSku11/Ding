"""Checks the live test's ring log: check-live.py RING_LOG ALARMS_FILE FIRST_RING_TIME"""
import json
import sys

log_path, alarms_path, first = sys.argv[1], sys.argv[2], float(sys.argv[3])
A, B, C, D, E, F, G = ("00000000-0000-4000-8000-0000000000" + s for s in ("A1", "B2", "C3", "D4", "E5", "F6", "A7"))
names = {A: "Every minute", B: "One-off", C: "Same minute", D: "Switched off", E: "Silent", F: "Long sound",
         G: "After a snooze"}

rings, offs, skipped, busy, snoozes, kept, cleared = {}, set(), [], {}, {}, set(), set()
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
    elif kind == "busy":
        busy.setdefault(alarm, []).append(round((float(parts[4]) - first) / 60))
    elif kind == "snooze":   # snooze ID for N min until T
        snoozes[alarm] = int(parts[4]) if len(parts) > 4 and parts[3] == "for" else None
    elif kind == "keep":
        kept.add(alarm)
    elif kind == "clear":
        cleared.add(alarm)

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


expect(A, [0, 1, 2, 3, 4], sounds=("played",))
# The one-off's first ring is snoozed, as a click on "Snooze 15 min" would (60 seconds in this test).
# It rings once more about a minute later, even though a one-time alarm switches itself off after it rings.
b_rings = rings.get(B, [])
rings[B] = b_rings[:1]
expect(B, [1], sounds=("played",))
if B not in snoozes:
    problems.append("the one-off alarm wasn't snoozed")
elif snoozes[B] != 15:
    problems.append(f"the one-off was snoozed for {snoozes[B]} min, expected 15 (the Snooze 15 min button)")
else:
    print("  The one-off was snoozed with the Snooze 15 min button: snooze for 15 min")
if len(b_rings) != 2:
    problems.append(f"the snoozed alarm rang {len(b_rings)} times, expected 2")
else:
    actual, due, sound = b_rings[1]
    gap = due - b_rings[0][1]
    print(f"  {'Snoozed':<13} due {gap:.0f} s after its first ring, started {actual - due:4.1f} s after, sound {sound}")
    if not 61 <= gap <= 75:
        problems.append(f"the snoozed ring was due {gap:.0f} s after the first, expected a minute and a few seconds")
    if not 0 <= actual - due <= 8:
        problems.append(f"the snoozed ring started {actual - due:.1f} s after it was due")
    if sound != "played":
        problems.append(f"the snoozed ring's sound was {sound}")
expect(C, [2], sounds=("played",))
expect(G, [1], sounds=("played",))   # was waiting behind the one-off when it was snoozed
expect(D, [])
expect(E, [3], sounds=("silent",))
expect(F, [4], sounds=("played",))
print(f"  {names[F]:<13} due +5 min while still playing: {'let the first finish' if busy.get(F) == [5] else 'NOT handled'}")
if busy.get(F) != [5]:
    problems.append(f"the long sound's second ring should have been let go while the first played; busy: {busy.get(F)}")
if set(busy) - {F}:
    problems.append(f"other alarms were let go as busy: {[names.get(a, a) for a in set(busy) - {F}]}")
print(f"  Notifications left in Notification Center: {[names.get(a, a) for a in kept]}; cleared: {sorted(names.get(a, a) for a in cleared)}")
if kept != {C}:
    problems.append(f"kept notifications for {[names.get(a, a) for a in kept]}, expected only {names[C]}")
if C in cleared or not {A, B, E, F} <= cleared:
    problems.append(f"cleared notifications for {[names.get(a, a) for a in cleared]}")
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
print("Live test: every ring came on time, the one-off switched itself off, the switched-off alarm stayed quiet,")
print("a sound longer than its gap finished without piling up rings, and a snoozed alarm rang again on time.")
