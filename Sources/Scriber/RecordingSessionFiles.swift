import Darwin
import Foundation

/// Owns immutable writer paths on the destination volume. The small manifest is
/// retained after saving; it describes this session only, never unrelated media.
struct RecordingSessionFiles: Sendable {
    struct Manifest: Codable, Sendable {
        let id: UUID
        let startedAt: Date
        let title: String
        let paths: [String: String]
        let closed: [String]
        let published: [String]
        let error: String?
    }

    struct Finalization: Sendable {
        let files: RecordingFileSet
        let title: String
        let published: Set<RecordingFileKind>
        let errorMessage: String?
    }

    let id: UUID
    let startedAt: Date
    let directory: URL
    let stagingDirectory: URL
    let files: RecordingFileSet
    var manifestURL: URL { stagingDirectory.appendingPathComponent("session.json") }

    /// Run filesystem work away from the main actor and the media writer queue.
    static func create(directory: URL, title: String, video: Bool) throws -> Self {
        let title = try RecordingFilename.validated(title)
        guard directory.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let directory = URL(fileURLWithPath: directory.path, isDirectory: true).standardizedFileURL
        let id = UUID()
        let staging = directory.appendingPathComponent(".scriber-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Do not reuse a preexisting staging directory, even for a UUID collision.
        if staging.withUnsafeFileSystemRepresentation({ mkdir($0!, 0o700) }) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let kinds: [RecordingFileKind] = video ? [.audio, .video] : [.audio]
        let session = Self(id: id, startedAt: Date(), directory: directory, stagingDirectory: staging,
                           files: .init(urls: Dictionary(uniqueKeysWithValues: kinds.map {
                               ($0, staging.appendingPathComponent("capture").appendingPathExtension($0.rawValue))
                           })))
        try session.checkpoint(title: title, files: session.files, closed: [], published: [], error: nil)
        return session
    }

    func finalize(title: String, closed: Set<RecordingFileKind>) -> Finalization {
        var locations = files.urls
        var published = Set<RecordingFileKind>()
        var resolvedTitle = title
        var message: String?
        do {
            // Never move an open, failed or unverified encoder output as success.
            try checkpoint(title: title, files: files, closed: closed, published: [], error: nil)
            let ready = RecordingFileSet(urls: files.urls.filter { closed.contains($0.key) })
            if !ready.urls.isEmpty {
                let result = ready.relocate(to: directory, title: title)
                locations.merge(result.files.urls) { _, new in new }
                resolvedTitle = result.title ?? title
                message = result.errorMessage
                published = Set(result.files.urls.compactMap { kind, url in
                    url.deletingLastPathComponent() == directory ? kind : nil
                })
            }
            if closed != Set(files.urls.keys) {
                message = [message, "部分录制文件未完成写入，原始数据保留在：\(stagingDirectory.path)"]
                    .compactMap { $0 }.joined(separator: "\n")
            }
            try checkpoint(title: resolvedTitle, files: .init(urls: locations), closed: closed,
                           published: published, error: message)
        } catch {
            message = [message, "录制记录未能写入：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
        }
        return .init(files: .init(urls: locations), title: resolvedTitle,
                     published: published, errorMessage: message)
    }

    /// The caller supplies this session's current, closed published paths, since
    /// previous renames may already have changed them from the staging paths.
    func renamePublished(_ current: RecordingFileSet, title: String) -> Finalization {
        var locations = current
        var resolvedTitle = (current.urls[.video] ?? current.urls[.audio])?.deletingPathExtension().lastPathComponent ?? title
        let kinds = Set(current.urls.keys)
        var message: String?
        do {
            _ = try RecordingFilename.validated(title)
            try checkpoint(title: resolvedTitle, files: current, closed: kinds, published: kinds, error: nil)
            let result = current.relocate(to: directory, title: title)
            locations = result.files
            resolvedTitle = result.title ?? (locations.urls[.video] ?? locations.urls[.audio])?.deletingPathExtension().lastPathComponent ?? resolvedTitle
            message = result.errorMessage
            try checkpoint(title: resolvedTitle, files: locations, closed: kinds, published: kinds, error: message)
        } catch {
            message = [message, "改名记录未能写入：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
        }
        return .init(files: locations, title: resolvedTitle, published: kinds, errorMessage: message)
    }

    private func checkpoint(title: String, files: RecordingFileSet, closed: Set<RecordingFileKind>,
                            published: Set<RecordingFileKind>, error: String?) throws {
        let manifest = Manifest(id: id, startedAt: startedAt, title: title,
                                paths: Dictionary(uniqueKeysWithValues: files.urls.map { ($0.key.rawValue, $0.value.path) }),
                                closed: closed.map(\.rawValue).sorted(), published: published.map(\.rawValue).sorted(), error: error)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
    }
}
