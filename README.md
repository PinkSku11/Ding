# Ding

A small alarm for the Mac menu bar. Each alarm rings either repeatedly (every few minutes or hours, from one time until another) or once at a set time, on the days you pick, with its own sound and volume. With no days picked, it rings one time and then switches itself off.

## Installing

1. Open `Ding.zip`. It unpacks to Ding.
2. Drag Ding into your Applications folder, then open it.
3. The first time, macOS says it can't check Ding for malware, because Ding isn't from the App Store. Click Done, go to System Settings → Privacy & Security, scroll down and click Open Anyway.

Ding is the bell in the menu bar. Click it for your alarms, and click an alarm to change it or duplicate it. Right-click the bell to choose 24-hour or AM/PM times, to have Ding open at login, or to quit.

When an alarm rings, click its notification or the bell to stop it, or click Snooze 5 min on the notification to hear it again five minutes later. Ding clears each notification after the ring, unless that alarm has "Keep in Notification Center" on; then its latest notification stays there.

For a timer, click the bell, then 5, 10, 15 or 30 min. For another length, click Custom, type the minutes (up to 999) and press Return. The time left shows next to the bell, and the menu shows when it rings, with a Stop button. When the time is up it rings like an alarm, with Glass for 30 seconds; click its notification or the bell to stop it sooner. While a timer runs, Ding keeps the Mac from going to sleep.

## Updating

1. Quit Ding: right-click the bell and click Quit Ding.
2. Open the new `Ding.zip`, drag Ding into your Applications folder and click Replace.
3. Open Ding. macOS may ask about it again, as it did the first time.

If Ding doesn't open (nothing happens, or Finder says Ding isn't responding), macOS got stuck checking the new download. Open Terminal, paste this line and press Return. It closes Ding, removes the download flag that macOS checks, and opens Ding again. If Terminal says no matching processes were found, that's fine.

```
killall -9 Ding; xattr -dr com.apple.quarantine /Applications/Ding.app; open /Applications/Ding.app
```

If the bell still doesn't appear after that, restart the Mac.

## Good to know

- Ding rings only while it's open, so turn on Open at login if you want it there after a restart.
- On a MacBook with a notch, menu bar icons that don't fit hide behind the notch. If you can't see the bell, go to System Settings → Menu Bar, check that Ding is on under Allow in the Menu Bar, and turn off icons you don't need to make room.
- Alarms can't ring while the Mac is asleep. Turn on "Keep Mac awake for this alarm" for the alarms that matter; it can't help when the lid is closed. If the Mac sleeps through an alarm that rings Once, or through a snooze, a notification says so when it wakes up.
- Ding stays quiet, and shows only the notification, while an app is using the microphone (a call; Siri listening for "Hey Siri" doesn't count), when the alarm's sound is None or its volume is 0, and when the Mac is muted, unless "Ring even when muted" is on. When an app using the microphone or a muted Mac keeps an alarm quiet, its notification says so.
- When you pick a sound or let go of the volume slider, Ding plays it for you. If it stays quiet because an app is using the microphone, the Mac is muted or an alarm is ringing, a note next to the sound says so.
- With AirPods, headphones or a headset, alarms play at 30% volume at most.
- A Focus such as Do Not Disturb hides Ding's notifications unless Ding is one of its allowed apps, but the alarm sound still plays.

## How it's built

Every push builds Ding on GitHub's Mac build machines: the app for Apple silicon and Intel Macs, the scheduling tests, a live test with real alarms, and screenshots. `Ding.zip`, `Ding.dmg`, the build log and the screenshots go to the `build` branch.
