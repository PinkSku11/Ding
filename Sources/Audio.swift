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

    /// What's recording from a microphone right now (usually a call), or nil if nothing is.
    /// The app's name, a background program's name, or "" when it can't be told.
    static func microphoneUser() -> String? {
        if #available(macOS 14.2, *), let processes = audioProcesses() {
            // Asks each app that uses sound whether it's recording, so playing music doesn't count.
            let me = ProcessInfo.processInfo.processIdentifier
            for process in processes
            where readUInt32(process, kAudioProcessPropertyIsRunningInput, kAudioObjectPropertyScopeGlobal) == 1 {
                let pid = readUInt32(process, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal)
                    .map { pid_t(bitPattern: $0) }
                if pid == me { continue }
                guard let pid else { return "" }
                if let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
                var buffer = [CChar](repeating: 0, count: 256)
                return proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
            }
            return nil
        }
        // Older systems: is the microphone running? Not when it's the same device as the output
        // (AirPods, USB headsets), because playing music runs that too.
        guard let input = inputDevice, input != outputDevice,
              let running = readUInt32(input, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal),
              running != 0
        else { return nil }
        return ""
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

/// What happened when Ding tried to play an alarm's sound.
enum SoundResult: Equatable {
    case played
    case nothingToPlay           // Sound is None, or Play sound or Volume is 0
    case muted                   // the Mac is muted, and this alarm doesn't ring when muted
    case microphone(String)      // something is recording, usually a call: its name, or "" if unknown
    case failed                  // macOS couldn't play the file

    /// Why you can't hear the sound you're trying in the editor. Nil when it played or there's nothing to play.
    var note: String? {
        switch self {
        case .played, .nothingToPlay: return nil
        case .muted: return "No sound: the Mac is muted"
        case .microphone(let name): return name.isEmpty ? "No sound: the mic is in use" : "No sound: \(name) is using the mic"
        case .failed: return "No sound: couldn't play it"
        }
    }

    /// One word for the build machine's log.
    var logWord: String {
        switch self {
        case .played: return "played"
        case .nothingToPlay: return "silent-nothing-to-play"
        case .muted: return "silent-muted"
        case .microphone(let name): return "silent-mic:" + name.replacingOccurrences(of: " ", with: "_")
        case .failed: return "silent-failed"
        }
    }
}

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
    private var postedWhileRinging: Set<String> = []   // the notifications of what's ringing now
    private var player: AVAudioPlayer?
    private var pending: DispatchWorkItem?
    private var saved: [AudioObjectID: (volume: Float?, muted: Bool)] = [:]   // each device as it was before ringing
    private var previewing = false
    private var playerStarted = Date()
    private static let testSnooze = UserDefaults.standard.string(forKey: "DingTestSnooze").flatMap(UUID.init(uuidString:))
    private var testSnoozed = false

    private override init() {
        super.init()
    }

    func enqueue(_ rings: [Ring]) {
        if previewing { stopPreview(because: "an alarm rang") }
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

    /// A click on a notification of what's ringing now stops it all. An older notification kept in
    /// Notification Center doesn't stop a different alarm that happens to be ringing.
    func notificationClicked(_ id: String) {
        if postedWhileRinging.contains(id) { stopAll() }
    }

    /// Stops the sound right away and clears the notification (a click on the notification or on the blue bell,
    /// or quitting Ding), and puts the volume back.
    func stopAll() {
        if previewing { stopPreview(because: "stopped") }
        queue.removeAll()
        cancelPending()
        player?.stop()
        player = nil
        finishNotification(after: 0)
        current = nil
        restoreVolume()
        setRinging(false)
    }

    /// Stops one alarm (Snooze). Another alarm that rang at the same time still gets its turn.
    func stop(_ id: UUID) {
        queue.removeAll { $0.alarm.id == id }
        guard current?.alarm.id == id else { return }
        cancelPending()
        player?.stop()
        player = nil
        finishNotification(after: 0)
        current = nil
        playNext()   // with nothing else waiting, this puts the volume back and the bell stops ringing
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
        let posted = Notifier.shared.post(ring)
        notificationID = posted
        postedWhileRinging.insert(posted)
        let result = startSound(for: ring.alarm)
        let played = result == .played
        RingLog.write("ring \(ring.alarm.id.uuidString) due \(ring.time.timeIntervalSince1970) sound \(played ? "played" : "silent") \(result.logWord)")
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

    /// Starts an alarm's sound following its settings, or says why it stays silent.
    private func startSound(for alarm: Alarm) -> SoundResult {
        if alarm.sound.isEmpty || alarm.plays <= 0 || alarm.volume <= 0 { return .nothingToPlay }
        if let user = SystemAudio.microphoneUser() { return .microphone(user) }
        let device = SystemAudio.outputDevice
        let muted = device.map(SystemAudio.isMuted) ?? false
        if muted && !alarm.ringWhenMuted { return .muted }
        guard let url = SoundLibrary.url(for: alarm.sound),
              let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return .failed }

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
        guard newPlayer.play() else { return .failed }
        player = newPlayer
        playerStarted = Date()
        schedule(after: length) { [weak self] in self?.soundEnded() }
        return .played
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let current = player === self.player
            RingLog.write("player finished \(flag ? "ok" : "with-error") after \(self.elapsed) \(current ? "" : "(an earlier one)")")
            guard current else { return }
            self.soundEnded()
        }
    }

    /// Seconds since the current sound started, for the build machine's log.
    private var elapsed: String {
        String(format: "%.2fs", Date().timeIntervalSince(playerStarted))
    }

    private func soundEnded() {
        if previewing {
            stopPreview(because: "it ended")
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
        if !ringing { postedWhileRinging = [] }
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

    /// Plays an alarm's sound in the editor, as it will ring. Returns why you can't hear it, if you can't.
    @discardableResult
    func preview(_ alarm: Alarm) -> String? {
        guard current == nil else {
            RingLog.write("preview silent-alarm-ringing sound \(alarm.sound)")
            return "No sound: an alarm is ringing"
        }
        stopPreview(because: "a new one started")
        previewing = true
        let result = startSound(for: alarm)
        RingLog.write("preview \(result.logWord) sound \(alarm.sound) volume \(String(format: "%.2f", alarm.volume)) plays \(alarm.plays) \(alarm.playUnit.rawValue)")
        if result != .played { stopPreview(because: "silent") }
        return result.note
    }

    func stopPreview(because reason: String = "the editor closed") {
        guard previewing else { return }
        previewing = false
        cancelPending()
        if player != nil { RingLog.write("preview stopped (\(reason)) after \(elapsed)") }
        player?.stop()
        player = nil
        restoreVolume()
    }
}
