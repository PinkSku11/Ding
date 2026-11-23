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
    var keepNotification: Bool   // leave the notification in Notification Center after the ring

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
         plays: Int = 1,
         playUnit: PlayUnit = .times,
         volume: Double = 0.5,
         ringWhenMuted: Bool = false,
         keepAwake: Bool = false,
         keepNotification: Bool = false) {
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
        self.keepNotification = keepNotification
    }

    enum CodingKeys: String, CodingKey {
        case id, name, isOn, kind, fromMinute, untilMinute, every, everyUnit, timeMinute
        case days, oneOffDay, sound, plays, playUnit, volume, ringWhenMuted, keepAwake, keepNotification
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
        keepNotification = try c.decodeIfPresent(Bool.self, forKey: .keepNotification) ?? d.keepNotification
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Alarm" : trimmed
    }

    /// A duplicate's name: "Water break copy", then "Water break copy 2", like Finder.
    /// A copy of a copy doesn't become "copy copy".
    static func copyName(of name: String, taken: Set<String>) -> String {
        var base = name
        if let suffix = base.range(of: #" copy( [0-9]+)?$"#, options: .regularExpression) {
            base.removeSubrange(suffix)
        }
        var candidate = base + " copy"
        var number = 2
        while taken.contains(candidate) {
            candidate = "\(base) copy \(number)"
            number += 1
        }
        return candidate
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

enum Settings {
    static var launchedBefore: Bool {
        get { UserDefaults.standard.bool(forKey: "launchedBefore") }
        set { UserDefaults.standard.set(newValue, forKey: "launchedBefore") }
    }

    /// Settings older versions kept that Ding no longer uses: the timer, Ding's own 24-hour / AM/PM choice
    /// (with its copy of the Mac's 24-hour switch, which would otherwise still apply to Ding alone), and the
    /// old "Keep Mac awake" option, long since moved into each alarm. Run at launch, before any time shows.
    static func forgetOldSettings() {
        let defaults = UserDefaults.standard
        for key in ["timerEnd", "timerLength", "timerOtherMinutes", "timeFormat",
                    "AppleICUForce24HourTime", "AppleICUForce12HourTime", "keepAwake", "keepAwakeMoved"] {
            defaults.removeObject(forKey: key)
        }
    }
}
