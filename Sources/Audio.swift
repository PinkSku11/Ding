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

    private static var outputDevice: AudioObjectID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }
    private static var inputDevice: AudioObjectID? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

    private static func readUInt32(_ device: AudioObjectID,
                                   _ selector: AudioObjectPropertySelector,
                                   _ scope: AudioObjectPropertyScope) -> UInt32? {
        var addr = address(selector, scope)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// The Mac's output volume, 0…1.
    static func volume() -> Float? {
        guard let device = outputDevice else { return nil }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? Float(value) : nil
    }

    static func setVolume(_ level: Float) {
        guard let device = outputDevice else { return }
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return }
        var value = Float32(max(0, min(1, level)))
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func isMuted() -> Bool {
        guard let device = outputDevice,
              let value = readUInt32(device, kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput) else { return false }
        return value != 0
    }

    static func setMuted(_ muted: Bool) {
        guard let device = outputDevice else { return }
        var addr = address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return }
        var value = UInt32(muted ? 1 : 0)
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// True while an app is using the microphone, which usually means a call.
    static func isMicrophoneInUse() -> Bool {
        guard let device = inputDevice,
              let running = readUInt32(device, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal) else { return false }
        return running != 0
    }

    /// True when sound goes to headphones: AirPods and other Bluetooth audio, or wired headphones.
    static func isHeadphones() -> Bool {
        guard let device = outputDevice,
              let transport = readUInt32(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal) else { return false }
        if transport == UInt32(kAudioDeviceTransportTypeBluetooth) || transport == UInt32(kAudioDeviceTransportTypeBluetoothLE) {
            return true
        }
        if transport == UInt32(kAudioDeviceTransportTypeBuiltIn),
           let source = readUInt32(device, kAudioDevicePropertyDataSource, kAudioDevicePropertyScopeOutput) {
            return source == 0x6864_706E   // 'hdpn', the headphone jack
        }
        return false
    }
}

// MARK: - Playing alarms

/// Plays rings one after another, each at its own volume, then puts the Mac's volume back.
final class Ringer: NSObject, AVAudioPlayerDelegate {
    static let shared = Ringer()

    /// Highest output volume used when headphones are connected.
    private let headphoneCap: Float = 0.5

    private(set) var isRinging = false
    var onChange: (() -> Void)?

    private var queue: [Ring] = []
    private var current: Ring?
    private var notificationID: String?
    private var player: AVAudioPlayer?
    private var pending: DispatchWorkItem?
    private var savedVolume: Float?
    private var savedMuted: Bool?
    private var previewDone: (() -> Void)?

    private override init() {
        super.init()
    }

    func enqueue(_ rings: [Ring]) {
        if previewDone != nil { stopPreview() }
        queue.append(contentsOf: rings)
        if current == nil { playNext() }
    }

    /// Stops the sound right away and clears the notification (a click on the notification or on the blue bell).
    func stopAll() {
        queue.removeAll()
        cancelPending()
        player?.stop()
        player = nil
        if let id = notificationID { Notifier.shared.remove(id, after: 0) }
        notificationID = nil
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
        if !played {
            // No sound this time (a call, the Mac is muted, or a missing file): just show the notification.
            schedule(after: 5) { [weak self] in self?.ringFinished() }
        }
    }

    private func ringFinished() {
        cancelPending()
        player?.stop()
        player = nil
        if let id = notificationID { Notifier.shared.remove(id, after: 4) }
        notificationID = nil
        current = nil
        playNext()
    }

    /// Starts an alarm's sound following its settings. Returns false when it should stay silent.
    private func startSound(for alarm: Alarm) -> Bool {
        if alarm.sound.isEmpty || alarm.plays <= 0 || alarm.volume <= 0 { return false }
        if SystemAudio.isMicrophoneInUse() { return false }
        let muted = SystemAudio.isMuted()
        if muted && !alarm.ringWhenMuted { return false }
        guard let url = SoundLibrary.url(for: alarm.sound),
              let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return false }

        if savedVolume == nil && savedMuted == nil {
            savedVolume = SystemAudio.volume()
            savedMuted = muted
        }
        var level = Float(alarm.volume)
        if SystemAudio.isHeadphones() { level = min(level, headphoneCap) }
        if muted { SystemAudio.setMuted(false) }
        SystemAudio.setVolume(level)

        newPlayer.delegate = self
        newPlayer.volume = 1
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

    private func restoreVolume() {
        if let volume = savedVolume { SystemAudio.setVolume(volume) }
        if savedMuted == true { SystemAudio.setMuted(true) }
        savedVolume = nil
        savedMuted = nil
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
