import Foundation

enum RecordingMode: String, CaseIterable, Sendable {
    case audio, video
    var title: String { self == .audio ? L10n.text("录音") : L10n.text("录屏") }
    var symbol: String { self == .audio ? "mic" : "display" }
    var directoryPreferenceKey: String { "recordingDirectory.\(rawValue)" }
}

enum RecordingDestination {
    static func defaultURL(for mode: RecordingMode) -> URL {
        // These are existing on-disk locations, independent of the display language.
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Movies/Scriber/\(mode == .audio ? "录音" : "录屏")", directoryHint: .isDirectory)
    }

    static func restored(from defaults: UserDefaults?, for mode: RecordingMode) -> URL {
        guard let path = defaults?.string(forKey: mode.directoryPreferenceKey),
              path.hasPrefix("/"), !path.contains("\0") else { return defaultURL(for: mode) }
        // Do not silently substitute the default if a configured path disappears.
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    static func validate(_ url: URL) throws -> URL {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: L10n.text("请选择一个可用的文件夹。")])
        }
        return URL(fileURLWithPath: url.path, isDirectory: true).standardizedFileURL
    }
}
