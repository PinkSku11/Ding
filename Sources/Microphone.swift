import Foundation

/// Telling a call apart from other things that use the microphone.
enum Microphone {
    /// Whether a program recording from a mic means a call is going on. `program` is its file name,
    /// such as "zoom.us". macOS's speech service, corespeechd (and corespeechd_system beside it),
    /// listens for "Siri" and "Hey Siri" and does Dictation: that's not a call.
    static func meansCall(_ program: String) -> Bool {
        !program.hasPrefix("corespeechd")
    }

    /// A running program's file name, such as "corespeechd", or "" if it can't be told.
    /// Works for programs macOS runs as other users too.
    static func programName(_ pid: pid_t) -> String {
        var path = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            return (String(cString: path) as NSString).lastPathComponent
        }
        var name = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &name, UInt32(name.count)) > 0 ? String(cString: name) : ""
    }
}
