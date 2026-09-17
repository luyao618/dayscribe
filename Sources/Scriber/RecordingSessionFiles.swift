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
        var version: Int? = 1
        var duration: Double? = nil
        var captureError: String? = nil
        var fileIdentities: [String: RecordingFileIdentity]? = nil

        static func read(from url: URL) throws -> Self {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
            guard data.count <= 64 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            return try JSONDecoder().decode(Self.self, from: data)
        }

        /// Resolve only recorded identities within this session's own directories.
        /// Directory entries are stat'ed, never opened/imported as unrelated media.
        func resolvedFiles(in staging: URL) throws -> RecordingFileSet {
            let staging = staging.standardizedFileURL
            let directory = staging.deletingLastPathComponent()
            var candidates: [URL]?
            var result: [RecordingFileKind: URL] = [:]
            for (key, path) in paths {
                guard let kind = RecordingFileKind(rawValue: key), path.hasPrefix("/"), !path.contains("\0") else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let original = URL(fileURLWithPath: path).standardizedFileURL
                guard original.pathExtension == key, [staging, directory].contains(original.deletingLastPathComponent()) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                result[kind] = original
                guard let identity = fileIdentities?[key], RecordingFileIdentity.read(original) != identity else { continue }
                if candidates == nil {
                    candidates = try [directory, staging].flatMap {
                        try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
                    }
                }
                let matches = candidates!.filter { $0.pathExtension == key && RecordingFileIdentity.read($0) == identity }
                if matches.count == 1 { result[kind] = matches[0].standardizedFileURL }
            }
            return .init(urls: result)
        }
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

    func finalize(title: String, closed: Set<RecordingFileKind>, duration: Double? = nil,
                  captureError: String? = nil) -> Finalization {
        var locations = files.urls
        var published = Set<RecordingFileKind>()
        var resolvedTitle = title
        var message: String?
        do {
            // Never move an open, failed or unverified encoder output as success.
            try checkpoint(title: title, files: files, closed: closed, published: [], error: captureError,
                           duration: duration, captureError: captureError)
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
                           published: published, error: Self.combined(captureError, message),
                           duration: duration, captureError: captureError)
        } catch {
            message = [message, "录制记录未能写入：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
        }
        return .init(files: .init(urls: locations), title: resolvedTitle,
                     published: published, errorMessage: message)
    }

    /// Caller paths are a fallback only. Read authoritative paths while holding
    /// the shared session lock, including an earlier rename's actual locations.
    func renamePublished(_ current: RecordingFileSet, title: String,
                         save: (Manifest, URL) throws -> Void = RecordingSessionFiles.writeManifest) -> Finalization {
        var locations = current
        var resolvedTitle = (current.urls[.video] ?? current.urls[.audio])?.deletingPathExtension().lastPathComponent ?? title
        var published = Set(current.urls.keys)
        var message: String?
        do {
            _ = try RecordingFilename.validated(title)
            let lock = stagingDirectory.appendingPathComponent("rename.lock")
                .withUnsafeFileSystemRepresentation { open($0!, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600) }
            guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(lock) }
            guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { flock(lock, LOCK_UN) }
            let previous = try Manifest.read(from: manifestURL)
            guard previous.id == id, previous.startedAt == startedAt, previous.version == nil || previous.version == 1,
                  Set(previous.closed).isSubset(of: Set(previous.paths.keys)),
                  Set(previous.published).isSubset(of: Set(previous.closed)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            locations = try previous.resolvedFiles(in: stagingDirectory)
            published = Set(previous.published.compactMap(RecordingFileKind.init(rawValue:)))
            guard !published.isEmpty, Set(previous.published).isSubset(of: Set(previous.closed)),
                  published.allSatisfy({ kind in
                      guard let url = locations.urls[kind], let actual = RecordingFileIdentity.read(url) else { return false }
                      return previous.fileIdentities?[kind.rawValue].map { $0 == actual } ?? true
                  }) else { throw RecordingRenameError.unavailable }
            let captureError = previous.captureError ?? (previous.version == nil ? previous.error : nil)
            let closed = Set(previous.closed.compactMap(RecordingFileKind.init(rawValue:)))
            let primary: RecordingFileKind = published.contains(.video) ? .video : .audio
            resolvedTitle = locations.urls[primary]?.deletingPathExtension().lastPathComponent ?? previous.title
            // Persist identities BEFORE any move. A failed final metadata write
            // remains resolvable without trusting a stale caller or filename.
            var prepared = makeManifest(title: resolvedTitle, files: locations, closed: closed, published: published,
                                        error: captureError, duration: previous.duration, captureError: captureError)
            prepared.fileIdentities = (prepared.fileIdentities ?? [:]).merging(previous.fileIdentities ?? [:]) { _, recorded in recorded }
            try save(prepared, manifestURL)
            let result = RecordingFileSet(urls: locations.urls.filter { published.contains($0.key) })
                .relocate(to: directory, title: title)
            locations = .init(urls: locations.urls.merging(result.files.urls) { _, new in new })
            resolvedTitle = result.title ?? locations.urls[primary]?.deletingPathExtension().lastPathComponent ?? resolvedTitle
            message = result.errorMessage
            var updated = makeManifest(title: resolvedTitle, files: locations, closed: closed, published: published,
                                       error: Self.combined(captureError, message), duration: previous.duration,
                                       captureError: captureError)
            updated.fileIdentities = prepared.fileIdentities
            try save(updated, manifestURL)
        } catch {
            message = [message, "改名记录未能写入：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
        }
        return .init(files: locations, title: resolvedTitle, published: published, errorMessage: message)
    }

    private func checkpoint(title: String, files: RecordingFileSet, closed: Set<RecordingFileKind>,
                            published: Set<RecordingFileKind>, error: String?, duration: Double? = nil,
                            captureError: String? = nil) throws {
        try Self.writeManifest(makeManifest(title: title, files: files, closed: closed, published: published,
                                           error: error, duration: duration, captureError: captureError), manifestURL)
    }

    private func makeManifest(title: String, files: RecordingFileSet, closed: Set<RecordingFileKind>,
                              published: Set<RecordingFileKind>, error: String?, duration: Double?, captureError: String?) -> Manifest {
        Manifest(id: id, startedAt: startedAt, title: title,
                                paths: Dictionary(uniqueKeysWithValues: files.urls.map { ($0.key.rawValue, $0.value.path) }),
                                closed: closed.map(\.rawValue).sorted(), published: published.map(\.rawValue).sorted(),
                 error: error, duration: duration, captureError: captureError,
                 fileIdentities: Dictionary(uniqueKeysWithValues: files.urls.compactMap { kind, url in
                     guard closed.contains(kind), let identity = RecordingFileIdentity.read(url) else { return nil }
                     return (kind.rawValue, identity)
                 }))
    }

    static func writeManifest(_ manifest: Manifest, _ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private static func combined(_ first: String?, _ second: String?) -> String? {
        let messages = [first, second].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}

private enum RecordingRenameError: LocalizedError {
    case unavailable
    var errorDescription: String? { "文件尚未保存完成或无法唯一定位，请刷新或恢复文件后重试。" }
}
