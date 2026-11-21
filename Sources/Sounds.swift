import AppKit
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
        return builtIn.first(where: { $0.id == "Glass" })?.url ?? builtIn.first?.url
    }

    /// Asks for an audio file, copies it into Ding's sounds folder and returns its sound id.
    static func addFile() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = fileTypes.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a sound for your alarm"
        NSApp.activate()
        guard panel.runModal() == .OK, let source = panel.url else { return nil }

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
            return nil
        }
        return "custom:" + destination.lastPathComponent
    }
}
