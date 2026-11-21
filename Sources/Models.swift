import Foundation

// MARK: - Alarm

enum AlarmKind: String, Codable {
    case repeating   // Rings "Repeatedly": every few minutes or hours, from one time until another
    case once        // Rings "Once": at one time
}

enum IntervalUnit: String, Codable {
    case minutes
    case hours
}

enum PlayUnit: String, Codable {
    case times
    case seconds
}

struct Alarm: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var isOn: Bool
    var kind: AlarmKind
    var fromMinute: Int          // repeating: first ring, minutes after midnight
    var untilMinute: Int         // repeating: last ring (inclusive); earlier than `fromMinute` runs past midnight
    var every: Int
    var everyUnit: IntervalUnit
    var timeMinute: Int          // once: ring time, minutes after midnight
    var days: Set<Int>           // Calendar weekdays, 1 = Sunday … 7 = Saturday. Empty = one-off.
    var oneOffDay: Date?         // the day a one-off alarm rings on
    var sound: String            // system sound name, or "custom:<file name>"
    var plays: Int
    var playUnit: PlayUnit
    var volume: Double           // 0…1, the Mac's output volume while the alarm plays
    var ringWhenMuted: Bool
    var keepAwake: Bool          // keep the Mac from sleeping while this alarm is running

    init(id: UUID = UUID(),
         name: String = "",
         isOn: Bool = true,
         kind: AlarmKind = .once,
         fromMinute: Int = 9 * 60,
         untilMinute: Int = 23 * 60,
         every: Int = 15,
         everyUnit: IntervalUnit = .minutes,
         timeMinute: Int = 21 * 60,
         days: Set<Int> = [],
         oneOffDay: Date? = nil,
         sound: String = "Glass",
         plays: Int = 2,
         playUnit: PlayUnit = .times,
         volume: Double = 0.8,
         ringWhenMuted: Bool = false,
         keepAwake: Bool = false) {
        self.id = id
        self.name = name
        self.isOn = isOn
        self.kind = kind
        self.fromMinute = fromMinute
        self.untilMinute = untilMinute
        self.every = every
        self.everyUnit = everyUnit
        self.timeMinute = timeMinute
        self.days = days
        self.oneOffDay = oneOffDay
        self.sound = sound
        self.plays = plays
        self.playUnit = playUnit
        self.volume = volume
        self.ringWhenMuted = ringWhenMuted
        self.keepAwake = keepAwake
    }

    enum CodingKeys: String, CodingKey {
        case id, name, isOn, kind, fromMinute, untilMinute, every, everyUnit, timeMinute
        case days, oneOffDay, sound, plays, playUnit, volume, ringWhenMuted, keepAwake
    }

    // Tolerant decoding, so alarms saved by an older version still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Alarm()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? d.isOn
        kind = try c.decodeIfPresent(AlarmKind.self, forKey: .kind) ?? d.kind
        fromMinute = try c.decodeIfPresent(Int.self, forKey: .fromMinute) ?? d.fromMinute
        untilMinute = try c.decodeIfPresent(Int.self, forKey: .untilMinute) ?? d.untilMinute
        every = try c.decodeIfPresent(Int.self, forKey: .every) ?? d.every
        everyUnit = try c.decodeIfPresent(IntervalUnit.self, forKey: .everyUnit) ?? d.everyUnit
        timeMinute = try c.decodeIfPresent(Int.self, forKey: .timeMinute) ?? d.timeMinute
        days = try c.decodeIfPresent(Set<Int>.self, forKey: .days) ?? d.days
        oneOffDay = try c.decodeIfPresent(Date.self, forKey: .oneOffDay)
        sound = try c.decodeIfPresent(String.self, forKey: .sound) ?? d.sound
        plays = try c.decodeIfPresent(Int.self, forKey: .plays) ?? d.plays
        playUnit = try c.decodeIfPresent(PlayUnit.self, forKey: .playUnit) ?? d.playUnit
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? d.volume
        ringWhenMuted = try c.decodeIfPresent(Bool.self, forKey: .ringWhenMuted) ?? d.ringWhenMuted
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? d.keepAwake
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Alarm" : trimmed
    }

    var isOneOff: Bool { days.isEmpty }

    var intervalMinutes: Int { max(1, every) * (everyUnit == .hours ? 60 : 1) }
}

// MARK: - Storage

enum AppPaths {
    static var supportFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let folder = base.appendingPathComponent("Ding", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

final class AlarmStore {
    static let shared = AlarmStore()

    private(set) var alarms: [Alarm] = []
    var onChange: (() -> Void)?
    private let fileURL: URL

    private init() {
        fileURL = AppPaths.supportFolder.appendingPathComponent("alarms.json")
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let list = try? JSONDecoder().decode([Alarm].self, from: data) {
            alarms = list
        } else {
            // The file can't be read: keep it aside instead of overwriting it with the next save.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("alarms (unreadable \(stamp)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
        }
    }

    func alarm(_ id: UUID) -> Alarm? {
        alarms.first { $0.id == id }
    }

    func save(_ alarm: Alarm) {
        var updated = alarm
        arm(&updated)
        if let index = alarms.firstIndex(where: { $0.id == updated.id }) {
            alarms[index] = updated
        } else {
            alarms.append(updated)
        }
        persist()
    }

    func delete(_ id: UUID) {
        alarms.removeAll { $0.id == id }
        persist()
    }

    func setOn(_ id: UUID, _ on: Bool) {
        guard let index = alarms.firstIndex(where: { $0.id == id }), alarms[index].isOn != on else { return }
        alarms[index].isOn = on
        arm(&alarms[index])
        persist()
    }

    /// Switches off one-off alarms that have finished, without another round of change callbacks.
    func switchOff(_ ids: [UUID]) {
        var changed = false
        for id in ids {
            if let index = alarms.firstIndex(where: { $0.id == id }), alarms[index].isOn {
                alarms[index].isOn = false
                changed = true
            }
        }
        if changed { write() }
    }

    /// A one-off alarm belongs to the next day it can still ring on.
    private func arm(_ alarm: inout Alarm) {
        if alarm.isOn && alarm.isOneOff {
            alarm.oneOffDay = Schedule.oneOffDay(for: alarm, now: Date())
        }
    }

    /// "Keep Mac awake" used to be one option in the right-click menu. It now lives in each alarm;
    /// if it was on, switch it on for every existing alarm, once.
    func moveKeepAwakeIntoAlarms() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "keepAwakeMoved") else { return }
        defaults.set(true, forKey: "keepAwakeMoved")
        guard defaults.bool(forKey: "keepAwake") else { return }
        for index in alarms.indices {
            alarms[index].keepAwake = true
        }
        write()
    }

    private func persist() {
        write()
        onChange?()
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(alarms) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Settings

enum TimeFormat: String {
    case system                      // follow the Mac, until you pick one in the right-click menu
    case twelveHour = "12"           // 9:00 PM
    case twentyFourHour = "24"       // 21:00
}

enum Settings {
    static var timeFormat: TimeFormat {
        get { TimeFormat(rawValue: UserDefaults.standard.string(forKey: "timeFormat") ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "timeFormat")
            applyHourStyle()
        }
    }

    /// The Mac's time boxes (in the editor) follow only the Mac's own 24-hour switch, whatever Ding asks for.
    /// So Ding keeps its own copy of that switch, set to the choice in its right-click menu;
    /// it applies to Ding alone. Following the Mac removes it. Also run at launch.
    static func applyHourStyle() {
        let defaults = UserDefaults.standard
        switch timeFormat {
        case .system:
            defaults.removeObject(forKey: "AppleICUForce24HourTime")
            defaults.removeObject(forKey: "AppleICUForce12HourTime")
        case .twentyFourHour:
            defaults.set(true, forKey: "AppleICUForce24HourTime")
            defaults.set(false, forKey: "AppleICUForce12HourTime")
        case .twelveHour:
            defaults.set(false, forKey: "AppleICUForce24HourTime")
            defaults.set(true, forKey: "AppleICUForce12HourTime")
        }
    }

    /// Whether times show as 21:00 rather than 9:00 PM.
    static var uses24Hour: Bool {
        switch timeFormat {
        case .twentyFourHour: return true
        case .twelveHour: return false
        case .system:
            // The way the Mac itself shows a time, including the 24-hour switch in Date & Time settings.
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return is24Hour(pattern: formatter.dateFormat ?? "")
        }
    }

    /// Whether a time pattern such as "HH:mm" or "h:mm a" shows a 24-hour clock.
    static func is24Hour(pattern: String) -> Bool {
        var quoted = false
        for character in pattern {
            if character == "'" { quoted.toggle(); continue }   // 'text in quotes' is printed as it is
            if quoted { continue }
            if character == "H" || character == "k" { return true }    // 0–23 or 1–24
            if character == "h" || character == "K" { return false }   // 1–12 or 0–11
        }
        return false
    }

    /// Your locale, with the hour style you picked.
    static var timeLocale: Locale {
        guard timeFormat != .system else { return .autoupdatingCurrent }
        var components = Locale.Components(locale: .current)
        components.hourCycle = uses24Hour ? .zeroToTwentyThree : .oneToTwelve
        return Locale(components: components)
    }

    static var launchedBefore: Bool {
        get { UserDefaults.standard.bool(forKey: "launchedBefore") }
        set { UserDefaults.standard.set(newValue, forKey: "launchedBefore") }
    }
}
