import Darwin
import Foundation

struct RecordingHistoryReference: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    let initialTitle: String
    let manifestURL: URL

    init(session: RecordingSessionFiles, title: String) {
        id = session.id
        startedAt = session.startedAt
        initialTitle = title
        manifestURL = session.manifestURL
    }

    init(manifestURL: URL, manifest: RecordingSessionFiles.Manifest) {
        id = manifest.id
        startedAt = manifest.startedAt
        initialTitle = manifest.title
        self.manifestURL = manifestURL
    }
}

struct RecordingHistoryEntry: Identifiable, Sendable {
    // Filesystem/encoder-close status, not a fresh media-decoder certification.
    enum FileState: Equatable, Sendable { case available, missing, unfinished, unavailable }
    let reference: RecordingHistoryReference
    let manifest: RecordingSessionFiles.Manifest?
    let urls: [RecordingFileKind: URL]
    let fileStates: [RecordingFileKind: FileState]
    let issue: String?
    var id: UUID { reference.id }
    var title: String {
        guard let manifest else { return reference.initialTitle }
        let published = RecordingFileKind.allCases.filter { manifest.published.contains($0.rawValue) && fileStates[$0] == .available }
        let names = Set(published.compactMap { urls[$0]?.deletingPathExtension().lastPathComponent })
        if names.count == 1, published.contains(where: { urls[$0]?.path != manifest.paths[$0.rawValue] }) {
            return names.first!
        }
        return manifest.title
    }
    var duration: Double? { manifest?.duration }
}

enum RecordingHistoryError: LocalizedError {
    case invalidIndex, invalidManifest, oversized
    var errorDescription: String? {
        switch self {
        case .invalidIndex: L10n.text("历史索引无法读取，原有记录已保留。")
        case .invalidManifest: L10n.text("这条录制记录无法读取。")
        case .oversized: L10n.text("录制记录文件过大，原文件已保留。")
        }
    }
}

/// The registry contains identities and stable manifest URLs, never a second
/// copy of media paths. Read current paths from the manifest after every rename.
actor RecordingHistoryStore {
    static let standard = RecordingHistoryStore(indexURL: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Scriber/history.json"))
    nonisolated let indexURL: URL
    private struct Index: Codable {
        var version = 1
        var recordings: [RecordingHistoryReference]
    }

    init(indexURL: URL) { self.indexURL = indexURL }

    /// Complete this before opening encoders. A failed index write must not let
    /// capture appear to start with no durable reference to its session.
    func register(_ reference: RecordingHistoryReference) throws {
        try registerAll([reference])
    }

    private func registerAll(_ references: [RecordingHistoryReference]) throws {
        guard indexURL.isFileURL else { throw RecordingHistoryError.invalidIndex }
        try references.forEach(Self.validate)
        let directory = indexURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent("history.lock")
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { open($0!, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw Self.posixError() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw Self.posixError() }
        defer { flock(descriptor, LOCK_UN) }
        // Read again under the file lock so separate app/store instances cannot
        // replace each other's registrations with a stale in-memory snapshot.
        var index = try readIndex()
        let originalCount = index.recordings.count
        for reference in references {
            if let existing = index.recordings.first(where: { $0.id == reference.id }) {
                guard existing.manifestURL == reference.manifestURL, existing.startedAt == reference.startedAt else {
                    throw RecordingHistoryError.invalidIndex
                }
            } else {
                index.recordings.append(reference)
            }
        }
        guard index.recordings.count != originalCount else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        guard data.count <= 8 * 1024 * 1024 else { throw RecordingHistoryError.oversized }
        try data.write(to: indexURL, options: .atomic)
    }

    /// Only inspect Scriber descriptors one level below explicitly known folders.
    /// Unrelated media, subdirectories and symlinked session directories are ignored.
    func discover(in directories: [URL]) async throws -> [String] {
        _ = try readIndex() // A damaged registry must never be rebuilt implicitly.
        let result = await Task.detached(priority: .utility) {
            var references: [RecordingHistoryReference] = []
            var issues: [String] = []
            for directory in Set(directories.map(\.standardizedFileURL)) where directory.isFileURL {
                do {
                    let children = try FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    for child in children where child.lastPathComponent.hasPrefix(".scriber-") {
                        do {
                            let name = child.lastPathComponent
                            guard let id = UUID(uuidString: String(name.dropFirst(9))), name == ".scriber-\(id.uuidString)" else { continue }
                            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                            let url = child.appendingPathComponent("session.json")
                            let manifest = try RecordingSessionFiles.Manifest.read(from: url)
                            let reference = RecordingHistoryReference(manifestURL: url, manifest: manifest)
                            try Self.validate(reference)
                            guard Self.readEntry(reference).manifest != nil else { throw RecordingHistoryError.invalidManifest }
                            references.append(reference)
                        } catch { issues.append(L10n.text("\(child.lastPathComponent)：\(error.localizedDescription)")) }
                    }
                } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                    continue
                } catch { issues.append(L10n.text("\(directory.path)：\(error.localizedDescription)")) }
            }
            return (references, issues)
        }.value
        try registerAll(result.0)
        return result.1
    }

    func load() async throws -> [RecordingHistoryEntry] {
        let references = try readIndex().recordings.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }
        // A slow media volume must not hold the registry actor while a new
        // recording is trying to register its local reference.
        return await Task.detached(priority: .utility) { references.map(Self.readEntry) }.value
    }

    func entry(_ id: UUID) async throws -> RecordingHistoryEntry? {
        guard let reference = try readIndex().recordings.first(where: { $0.id == id }) else { return nil }
        return await Task.detached(priority: .utility) { Self.readEntry(reference) }.value
    }

    func rename(_ id: UUID, title: String) async throws -> RecordingSessionFiles.Finalization {
        guard let reference = try readIndex().recordings.first(where: { $0.id == id }) else { throw RecordingHistoryError.invalidManifest }
        return try await Task.detached {
            let entry = Self.readEntry(reference)
            guard let manifest = entry.manifest else { throw RecordingHistoryError.invalidManifest }
            let staging = reference.manifestURL.deletingLastPathComponent().standardizedFileURL
            let session = RecordingSessionFiles(id: reference.id, startedAt: reference.startedAt,
                directory: staging.deletingLastPathComponent(), stagingDirectory: staging, files: .init(urls: entry.urls))
            let published = RecordingFileSet(urls: entry.urls.filter { manifest.published.contains($0.key.rawValue) })
            return session.renamePublished(published, title: title)
        }.value
    }

    private func readIndex() throws -> Index {
        guard indexURL.isFileURL else { throw RecordingHistoryError.invalidIndex }
        let data: Data
        do { data = try Self.read(indexURL, limit: 8 * 1024 * 1024) }
        catch let error as POSIXError where error.code == .ENOENT { return Index(recordings: []) }
        let index: Index
        do { index = try JSONDecoder().decode(Index.self, from: data) }
        catch { throw RecordingHistoryError.invalidIndex }
        guard index.version == 1, Set(index.recordings.map(\.id)).count == index.recordings.count,
              Set(index.recordings.map(\.manifestURL)).count == index.recordings.count else {
            throw RecordingHistoryError.invalidIndex
        }
        try index.recordings.forEach(Self.validate)
        return index
    }

    private static func validate(_ reference: RecordingHistoryReference) throws {
        let url = reference.manifestURL
        guard url.isFileURL, url.lastPathComponent == "session.json",
              url.deletingLastPathComponent().lastPathComponent == ".scriber-\(reference.id.uuidString)",
              reference.startedAt.timeIntervalSinceReferenceDate.isFinite else { throw RecordingHistoryError.invalidIndex }
    }

    private static func readEntry(_ reference: RecordingHistoryReference) -> RecordingHistoryEntry {
        do {
            let manifest = try RecordingSessionFiles.Manifest.read(from: reference.manifestURL)
            let staging = reference.manifestURL.deletingLastPathComponent().standardizedFileURL
            let kinds = Set(RecordingFileKind.allCases.map(\.rawValue))
            guard manifest.id == reference.id, manifest.startedAt == reference.startedAt,
                  manifest.version == nil || manifest.version == 1,
                  !manifest.paths.isEmpty, Set(manifest.paths.keys).isSubset(of: kinds),
                  Set(manifest.closed).isSubset(of: Set(manifest.paths.keys)),
                  Set(manifest.published).isSubset(of: Set(manifest.closed)),
                  manifest.duration.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw RecordingHistoryError.invalidManifest }
            var urls: [RecordingFileKind: URL] = [:]
            var states: [RecordingFileKind: RecordingHistoryEntry.FileState] = [:]
            let resolved = try manifest.resolvedFiles(in: staging)
            for (extensionName, path) in manifest.paths {
                guard path.hasPrefix("/"), !path.contains("\0"), let kind = RecordingFileKind(rawValue: extensionName) else {
                    throw RecordingHistoryError.invalidManifest
                }
                guard let url = resolved.urls[kind] else { throw RecordingHistoryError.invalidManifest }
                urls[kind] = url
                var info = stat()
                if url.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) != 0 {
                    states[kind] = errno == ENOENT ? .missing : .unavailable
                } else if info.st_mode & S_IFMT != S_IFREG {
                    states[kind] = .unavailable
                } else if let expected = manifest.fileIdentities?[extensionName], RecordingFileIdentity.read(url) != expected {
                    states[kind] = .unavailable
                } else {
                    states[kind] = manifest.closed.contains(extensionName) ? .available : .unfinished
                }
            }
            let moved = urls.contains { kind, url in url.path != manifest.paths[kind.rawValue] }
            let issues = [manifest.error, moved ? L10n.text("文件位置已变化，已定位到实际文件，改名记录待同步。") : nil].compactMap { $0 }
            return .init(reference: reference, manifest: manifest, urls: urls, fileStates: states,
                         issue: issues.isEmpty ? nil : issues.joined(separator: "\n"))
        } catch {
            return .init(reference: reference, manifest: nil, urls: [:], fileStates: [:], issue: error.localizedDescription)
        }
    }

    private static func read(_ url: URL, limit: Int) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw RecordingHistoryError.invalidIndex }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw RecordingHistoryError.oversized }
        return data
    }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
