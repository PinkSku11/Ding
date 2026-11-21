"""Writes alarms that ring over the next few minutes, for the build machine's live test.

    live-alarms.py PATH   writes the alarms file and prints the time of the first ring (seconds since 1970),
                          or nothing if it's too close to midnight to run the test.
"""
import json
import sys
import time

now = time.time()
local = time.localtime(now)
minute_now = local.tm_hour * 60 + local.tm_min
first_minute = minute_now + (2 if local.tm_sec > 40 else 1)   # leave Ding time to start
if first_minute + 4 >= 24 * 60:
    sys.exit(0)
first_epoch = (int(now) // 60 + (first_minute - minute_now)) * 60
apple_epoch = now - 978307200                                    # dates are saved as seconds since 2001

base = {"isOn": True, "fromMinute": 0, "untilMinute": 0, "every": 1, "everyUnit": "minutes", "timeMinute": 0,
        "days": [1, 2, 3, 4, 5, 6, 7], "sound": "Glass", "plays": 1, "playUnit": "times", "volume": 0.3,
        "ringWhenMuted": True, "keepAwake": False}
alarms = [
    dict(base, id="00000000-0000-4000-8000-0000000000A1", name="Every minute", kind="repeating",
         fromMinute=first_minute, untilMinute=first_minute + 4),
    dict(base, id="00000000-0000-4000-8000-0000000000B2", name="One-off", kind="once",
         timeMinute=first_minute + 1, days=[], oneOffDay=apple_epoch),
    dict(base, id="00000000-0000-4000-8000-0000000000C3", name="Same minute", kind="once",
         timeMinute=first_minute + 2),
    dict(base, id="00000000-0000-4000-8000-0000000000D4", name="Switched off", kind="repeating",
         fromMinute=first_minute, untilMinute=first_minute + 4, isOn=False),
    dict(base, id="00000000-0000-4000-8000-0000000000E5", name="Silent", kind="once",
         timeMinute=first_minute + 3, sound=""),
]
json.dump(alarms, open(sys.argv[1], "w"), indent=2)
print(first_epoch)
