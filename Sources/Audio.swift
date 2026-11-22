import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox

// MARK: - The Mac's audio devices

enum SystemAudio {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var addr = address(selector)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    /// Where sound plays right now: the speakers, headphones, a display…
    static var outputDevice: AudioObjectID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }
    private static var inputDevice: AudioObjectID? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

    private static func readUInt32(_ object: AudioObjectID,
                                   _ selector: AudioObjectPropertySelector,
                                   _ scope: AudioObjectPropertyScope) -> UInt32? {
        var addr = address(selector, scope)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func isSettable(_ device: AudioObjectID, _ addr: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    /// A device's output volume, 0…1, or nil if it has no volume control.
    static func volume(of device: AudioObjectID) -> Float? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? Float(value) : nil
    }

    /// Whether Ding can change a device's volume. Some displays and speakers have a fixed volume.
    static func canSetVolume(of device: AudioObjectID) -> Bool {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        return isSettable(device, &addr)
    }

    static func setVolume(_ level: Float, of device: AudioObjectID) {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard isSettable(device, &addr) else { return }
        var value = Float32(max(0, min(1, level)))
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        readUInt32(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput).map { $0 != 0 } ?? false
    }

    static func setMuted(_ muted: Bool, _ device: AudioObjectID) {
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard isSettable(device, &addr) else { return }
        var value = UInt32(muted ? 1 : 0)
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// True while another app is recording from a microphone, which usually means a call.
    static func isMicrophoneInUse() -> Bool {
        if #available(macOS 14.2, *), let processes = audioProcesses() {
            // Asks each app that uses sound whether it's recording, so playing music doesn't count.
            let me = UInt32(bitPattern: ProcessInfo.processInfo.processIdentifier)
            return processes.contains { process in
                readUInt32(process, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal) == 1
                    && readUInt32(process, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal) != me
            }
        }
        // Older systems: is the microphone running? Not when it's the same device as the output
        // (AirPods, USB headsets), because playing music runs that too.
        guard let input = inputDevice, input != outputDevice,
              let running = readUInt32(input, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal)
        else { return false }
        return running != 0
    }

    /// Every app connected to the Mac's sound system.
    @available(macOS 14.2, *)
    private static func audioProcesses() -> [AudioObjectID]? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        guard AudioObjectHasProperty(system, &addr) else { return nil }
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        if count == 0 { return [] }
        var list = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &list) == noErr else { return nil }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// True when sound goes to something worn: AirPods and other Bluetooth audio, wired headphones,
    /// or a USB headset.
    static func isHeadphones() -> Bool {
        guard let device = outputDevice else { return false }
        if let transport = readUInt32(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) {
            if transport == UInt32(kAudioDeviceTransportTypeBluetooth) || transport == UInt32(kAudioDeviceTransportTypeBluetoothLE) {
                return true
            }
            if transport == UInt32(kAudioDeviceTransportTypeBuiltIn),
               readUInt32(device, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput) == 0x6864_706E {
                return true   // 'hdpn': headphones in the jack, on Macs that switch the speakers over
            }
        }
        if outputIsWorn(device) { return true }
        // By name, as a last check: "External Headphones" (the jack on newer Macs), "… Headset", "AirPods".
        let name = deviceName(device).lowercased()
        return ["headphone", "headset", "airpods", "earbuds", "earphones"].contains { name.contains($0) }
    }

    /// Whether the device says its output is headphones or a headset.
    private static func outputIsWorn(_ device: AudioObjectID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr else { return false }
        let worn: Set<UInt32> = [
            0x6864_7068,                // 'hdph': headphones
            0x0302, 0x0303,             // USB: headphones, head-mounted audio
            0x0401, 0x0402,             // USB: handset, headset
        ]
        return streams.contains { stream in
            readUInt32(stream, kAudioStreamPropertyTerminalType, kAudioObjectPropertyScopeGlobal).map(worn.contains) ?? false
        }
    }

    /// The output's name, such as "MacBook Pro Speakers" or "AirPods Pro".
    static var outputName: String { outputDevice.map(deviceName) ?? "none" }

    private static func deviceName(_ device: AudioObjectID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, pointer)
        }
        guard status == noErr, let value = name?.takeRetainedValue() else { return "" }
        return value as String
    }
}

// MARK: - Playing alarms

/// Plays rings one after another, each at its own volume, then puts the Mac's volume back.
final class Ringer: NSObject, AVAudioPlayerDelegate {
    static let shared = Ringer()

    /// Highest output volume used with AirPods, headphones or a headset.
    private let headphoneCap: Float = 0.3

    private(set) var isRinging = false
    var onChange: (() -> Void)?

    private var queue: [Ring] = []
    private var current: Ring?
    private var notificationID: String?
    private var player: AVAudioPlayer?
    private var pending: DispatchWorkItem?
    private var saved: [AudioObjectID: (volume: Float?, muted: Bool)] = [:]   // each device as it was before ringing
    private var previewDone: (() -> Void)?
    private static let testSnooze = UserDefaults.standard.string(forKey: "DingTestSnooze").flatMap(UUID.init(uuidString:))
    private var testSnoozed = false

    private override init() {
        super.init()
    }

    func enqueue(_ rings: [Ring]) {
        if previewDone != nil { stopPreview() }
        for ring in rings {
            // Still ringing from last time (a sound longer than the gap between rings): let that one finish,
            // rather than piling up rings that would play on and on.
            if current?.alarm.id == ring.alarm.id || queue.contains(where: { $0.alarm.id == ring.alarm.id }) {
                RingLog.write("busy \(ring.alarm.id.uuidString) due \(ring.time.timeIntervalSince1970)")
                continue
            }
            queue.append(ring)
        }
        if current == nil { playNext() }
    }

    /// Stops the sound right away and clears the notification (a click on the notification or on the blue bell,
    /// or quitting Ding), and puts the volume back.
    func stopAll() {
        if previewDone != nil { stopPreview() }
        queue.removeAll()
        cancelPending()
        player?.stop()
        player = nil
        finishNotification(after: 0)
        current = nil
        restoreVolume()
        setRinging(false)
    }

    private func playNext() {
        guard !queue.isEmpty else {
            restoreVolume()
            setRinging(false)
            return
        }
        let ring = queue.removeFirst()
        current = ring
        setRinging(true)
        notificationID = Notifier.shared.post(ring)
        let played = startSound(for: ring.alarm)
        RingLog.write("ring \(ring.alarm.id.uuidString) due \(ring.time.timeIntervalSince1970) sound \(played ? "played" : "silent")")
        if let test = Ringer.testSnooze, test == ring.alarm.id, !testSnoozed {
            // The build machine's live test: press "Snooze 5 min" on this alarm's first ring, as a click would.
            testSnoozed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Engine.shared.snoozeNow(test) }
        }
        if !played {
            // No sound this time (Sound is None, a call, or the Mac is muted): just show the notification.
            schedule(after: 5) { [weak self] in self?.ringFinished() }
        }
    }

    private func ringFinished() {
        cancelPending()
        player?.stop()
        player = nil
        finishNotification(after: 4)
        current = nil
        playNext()
    }

    /// After a ring: clear its notification, unless the alarm keeps it in Notification Center.
    private func finishNotification(after seconds: TimeInterval) {
        guard let id = notificationID, let ring = current else { return }
        notificationID = nil
        if ring.alarm.keepNotification {
            RingLog.write("keep \(ring.alarm.id.uuidString)")
        } else {
            RingLog.write("clear \(ring.alarm.id.uuidString)")
            Notifier.shared.remove(id, after: seconds)
        }
    }

    /// Starts an alarm's sound following its settings. Returns false when it should stay silent.
    private func startSound(for alarm: Alarm) -> Bool {
        if alarm.sound.isEmpty || alarm.plays <= 0 || alarm.volume <= 0 { return false }
        if SystemAudio.isMicrophoneInUse() { return false }
        let device = SystemAudio.outputDevice
        let muted = device.map(SystemAudio.isMuted) ?? false
        if muted && !alarm.ringWhenMuted { return false }
        guard let url = SoundLibrary.url(for: alarm.sound),
              let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return false }

        var level = Float(alarm.volume)
        let worn = SystemAudio.isHeadphones()
        if worn { level = min(level, headphoneCap) }
        RingLog.write("sound \(alarm.id.uuidString) to \(SystemAudio.outputName.replacingOccurrences(of: " ", with: "_")) worn \(worn) level \(level)")
        newPlayer.delegate = self
        newPlayer.volume = 1
        if let device {
            if saved[device] == nil {
                saved[device] = (SystemAudio.volume(of: device), muted)
            }
            if muted { SystemAudio.setMuted(false, device) }
            if SystemAudio.canSetVolume(of: device) {
                SystemAudio.setVolume(level, of: device)
            } else {
                newPlayer.volume = level   // a fixed-volume output: turn the sound itself down instead
            }
        } else {
            newPlayer.volume = level
        }

        let length: TimeInterval
        switch alarm.playUnit {
        case .times:
            newPlayer.numberOfLoops = alarm.plays - 1
            length = newPlayer.duration * Double(alarm.plays) + 2   // safety stop, a little after it should end
        case .seconds:
            newPlayer.numberOfLoops = -1
            length = TimeInterval(alarm.plays)
        }
        newPlayer.prepareToPlay()
        guard newPlayer.play() else { return false }
        player = newPlayer
        schedule(after: length) { [weak self] in self?.soundEnded() }
        return true
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, player === self.player else { return }
            self.soundEnded()
        }
    }

    private func soundEnded() {
        if previewDone != nil {
            stopPreview()
        } else {
            ringFinished()
        }
    }

    /// Puts back the volume and mute of every device Ding changed, even if you've since switched to another one.
    private func restoreVolume() {
        for (device, state) in saved {
            if let volume = state.volume { SystemAudio.setVolume(volume, of: device) }
            if state.muted { SystemAudio.setMuted(true, device) }
        }
        saved = [:]
    }

    private func setRinging(_ ringing: Bool) {
        guard isRinging != ringing else { return }
        isRinging = ringing
        onChange?()
    }

    private func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) {
        cancelPending()
        let work = DispatchWorkItem(block: block)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    // MARK: Preview in the editor

    /// Plays an alarm exactly as it will ring. `done` runs when it stops.
    func preview(_ alarm: Alarm, done: @escaping () -> Void) {
        guard current == nil else {   // a real alarm is ringing
            done()
            return
        }
        stopPreview()
        previewDone = done
        if !startSound(for: alarm) {
            stopPreview()
        }
    }

    func stopPreview() {
        guard let done = previewDone else { return }
        previewDone = nil
        cancelPending()
        player?.stop()
        player = nil
        restoreVolume()
        done()
    }
}
