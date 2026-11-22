# Ding

A small alarm for the Mac menu bar. Each alarm rings either repeatedly (every few minutes or hours, from one time until another) or once at a set time, on the days you pick, with its own sound and volume. With no days picked, it rings one time and then switches itself off.

## Installing

1. Open `Ding.zip`. It unpacks to Ding.
2. Drag Ding into your Applications folder, then open it.
3. The first time, macOS says it can't check Ding for malware, because Ding isn't from the App Store. Click Done, go to System Settings → Privacy & Security, scroll down and click Open Anyway.

Ding is the bell in the menu bar. Click it for your alarms, and click an alarm to change it or duplicate it. Right-click the bell to choose 24-hour or AM/PM times, to have Ding open at login, or to quit.

When an alarm rings, click its notification or the bell to stop it, or click Snooze 5 min on the notification to hear it again five minutes later. Ding clears each notification after the ring, unless that alarm has "Keep in Notification Center" on; then its latest notification stays there.

## Good to know

- Ding rings only while it's open, so turn on Open at login if you want it there after a restart.
- Alarms can't ring while the Mac is asleep. Turn on "Keep Mac awake for this alarm" for the alarms that matter; it can't help when the lid is closed.
- Ding stays quiet, and shows only the notification, while an app is using the microphone (a call), when the alarm's sound is None or its volume is 0, and when the Mac is muted, unless "Ring even when muted" is on.
- When you pick a sound or let go of the volume slider, Ding plays it for you. If it stays quiet because an app is using the microphone, the Mac is muted or an alarm is ringing, a note next to the sound says so.
- With AirPods, headphones or a headset, alarms play at 30% volume at most.
- A Focus such as Do Not Disturb hides Ding's notifications unless Ding is one of its allowed apps, but the alarm sound still plays.

## How it's built

Every push builds Ding on GitHub's Mac build machines: the app for Apple silicon and Intel Macs, the scheduling tests, a live test with real alarms, and screenshots. `Ding.zip`, `Ding.dmg`, the build log and the screenshots go to the `build` branch.
