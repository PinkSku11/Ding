import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct SoundOption: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
}

/// The Mac's built-in alert sounds, plus sound files you add.
enum SoundLibrary {
    static let addFileTag = "__add_sound_file__"
    static let fileTypes = ["aiff", "aif", "wav", "mp3", "m4a", "caf", "aac", "flac"]

    static var customFolder: URL {
        let folder = AppPaths.supportFolder.appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func system() -> [SoundOption] {
        sounds(in: URL(fileURLWithPath: "/System/Library/Sounds"), custom: false)
    }

    static func custom() -> [SoundOption] {
        sounds(in: customFolder, custom: true)
    }

    private static func sounds(in folder: URL, custom: Bool) -> [SoundOption] {
        let types = Set(fileTypes)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { types.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let name = url.deletingPathExtension().lastPathComponent
                return SoundOption(id: custom ? "custom:" + url.lastPathComponent : name, name: name, url: url)
            }
    }

    /// The file for a sound id. "None" (an empty id) has no file; a missing file falls back to Glass.
    static func url(for id: String) -> URL? {
        if id.isEmpty { return nil }
        if let match = (custom() + system()).first(where: { $0.id == id }) {
            return match.url
        }
        let builtIn = system()
        let fallback = fallbackID(in: builtIn)
        return builtIn.first(where: { $0.id == fallback })?.url
    }

    /// What plays when an alarm's sound file is gone (one of your sounds that you've since deleted): Glass.
    static func fallbackID(in system: [SoundOption]) -> String {
        system.first(where: { $0.id == "Glass" })?.id ?? system.first?.id ?? ""
    }

    /// Asks for an audio file, copies it into Ding's sounds folder and returns its sound id.
    static func addFile() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = fileTypes.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a sound for your alarm"
        panel.prompt = "Choose"
        NSApp.activate()
        guard panel.runModal() == .OK, let source = panel.url else { return nil }

        // A file Ding can't play would make the alarm silent, so check it first.
        guard let player = try? AVAudioPlayer(contentsOf: source), player.duration > 0 else {
            tell("Ding can't play “\(source.lastPathComponent)”",
                 "The file may be damaged, or in a format Ding can't read. Try a different sound file.")
            return nil
        }

        let folder = customFolder
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var destination = folder.appendingPathComponent(source.lastPathComponent)
        var copy = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(base) \(copy).\(ext)")
            copy += 1
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            tell("Ding couldn't add “\(source.lastPathComponent)”", error.localizedDescription)
            return nil
        }
        return "custom:" + destination.lastPathComponent
    }

    private static func tell(_ message: String, _ details: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = details
        alert.runModal()
    }
}
