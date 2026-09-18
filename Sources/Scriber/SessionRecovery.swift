import Darwin
import Foundation
import AVFoundation

enum SessionRecovery {
    enum Checkpoint: String, Sendable { case mediaPrepared, manifestPrepared, mediaMoved, manifestCommitted }
    struct Result: Sendable {
        let changed: Bool
        let manifest: RecordingSessionFiles.Manifest
        var newlyPublished: Set<RecordingFileKind> = []
    }
    private enum Phase: String, Codable { case preparing, publishing, complete }
    private struct Stamp: Codable, Equatable, Sendable {
        let identity: RecordingFileIdentity
        let bytes: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        static func read(_ url: URL) -> Self? {
            var info = stat()
            guard let identity = RecordingFileIdentity.read(url),
                  url.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0 else { return nil }
            return Self(identity: identity, bytes: info.st_size, modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                        modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
        }
    }
    private struct Item: Codable, Sendable {
        let originalPath: String
        var originalStamp: Stamp?
        let wasClosed: Bool
        let wasPublished: Bool
        var sealed: Stamp?
        var duration: Double?
        var issue: String?
        var reusesOriginal: Bool { sealed != nil && sealed == originalStamp }
    }
    private struct Journal: Codable, Sendable {
        var version = 1
        let id: UUID
        let sessionID: UUID
        let startedAt: Date
        var phase: Phase = .preparing
        var items: [String: Item]
    }

    /// Both locks span preparation and publication. The journal seals candidate
    /// identities before any move; the manifest repeats them before publication.
    @concurrent static func recover(
        manifestURL: URL,
        checkpoint: @escaping @Sendable (Checkpoint) -> Void = { _ in },
        saveManifest: @escaping @Sendable (RecordingSessionFiles.Manifest, URL) throws -> Void = { try RecordingSessionFiles.writeManifest($0, $1) },
        move: @escaping @Sendable (URL, URL) throws -> Void = { try RecordingFileSet.moveExclusively($0, $1) }
    ) async throws -> Result {
        guard manifestURL.isFileURL, manifestURL.lastPathComponent == "session.json", !manifestURL.path.contains("\0") else {
            throw MediaRecoveryError.unsafePath
        }
        let stage = manifestURL.deletingLastPathComponent().standardizedFileURL
        guard stage.lastPathComponent.hasPrefix(".scriber-"),
              UUID(uuidString: String(stage.lastPathComponent.dropFirst(".scriber-".count))) != nil else {
            throw MediaRecoveryError.unsafePath
        }
        let directory = stage.deletingLastPathComponent()
        let capture = try RecordingSessionLease.acquire(in: stage)
        defer { capture.release() }
        let rename = try RecordingSessionLease.acquire(in: stage, purpose: .rename)
        defer { rename.release() }
        let manifest: RecordingSessionFiles.Manifest = try read(manifestURL, limit: 64 * 1024)
        try validate(manifest, stage: stage)
        // Missing user-deleted published files remain missing; recovery does not
        // silently recreate a recording that was already completely published.
        if Set(manifest.published) == Set(manifest.paths.keys) { return Result(changed: false, manifest: manifest) }
        let current = try manifest.resolvedFiles(in: stage)
        let journalURL = stage.appendingPathComponent("recovery.json")
        var journal: Journal
        do { journal = try read(journalURL) }
        catch let error as POSIXError where error.code == .ENOENT {
            journal = makeJournal(manifest, files: current)
        }
        guard journal.version == 1, journal.sessionID == manifest.id, journal.startedAt == manifest.startedAt,
              Set(journal.items.keys) == Set(manifest.paths.keys) else { throw MediaRecoveryError.invalidMedia }
        for (key, item) in journal.items {
            _ = try originalURL(item, key: key, stage: stage)
            guard !item.wasPublished || item.wasClosed else { throw MediaRecoveryError.invalidMedia }
            if item.sealed != nil {
                guard item.duration.map({ $0.isFinite && $0 > 0 }) == true else { throw MediaRecoveryError.invalidMedia }
            }
        }
        if journal.phase == .complete {
            let changed = try journal.items.contains { key, item in
                guard item.sealed == nil else { return false }
                return Stamp.read(try originalURL(item, key: key, stage: stage)) != item.originalStamp
            }
            guard changed else { return Result(changed: false, manifest: manifest) }
            journal = makeJournal(manifest, files: current)
        }
        try write(journal, to: journalURL)
        var ready: [RecordingFileKind: URL] = [:]
        for kind in RecordingFileKind.allCases {
            guard var item = journal.items[kind.rawValue] else { continue }
            let original = try originalURL(item, key: kind.rawValue, stage: stage)
            let candidate = stage.appendingPathComponent("recovered-\(journal.id.uuidString).\(kind.rawValue)")
            let work = stage.appendingPathComponent(".recovery-\(journal.id.uuidString)-\(kind.rawValue)", isDirectory: true)
            let exported = work.appendingPathComponent("recovered.\(kind.rawValue)")
            try Task.checkCancellation()
            if let sealed = item.sealed {
                let preferred = item.reusesOriginal ? [current.urls[kind], original].compactMap { $0 } : [candidate, exported]
                let actual = try resolve(sealed, preferred: preferred, directories: [stage, directory])
                if !item.reusesOriginal, actual == exported { try move(actual, candidate); ready[kind] = candidate }
                else { ready[kind] = actual }
                try cleanWork(work, kind: kind)
                continue
            }
            if !item.wasClosed, Stamp.read(original) != item.originalStamp {
                item.originalStamp = Stamp.read(original); item.issue = nil
                journal.items[kind.rawValue] = item
                try write(journal, to: journalURL)
            }
            if item.issue != nil { continue }
            do {
                guard let stamp = Stamp.read(original), stamp == item.originalStamp,
                      manifest.fileIdentities?[kind.rawValue].map({ $0 == stamp.identity }) ?? true else {
                    throw MediaRecoveryError.sourceChanged
                }
                if item.wasClosed {
                    let validation = try await MediaRecovery.validate(url: original, kind: kind)
                    guard Stamp.read(original) == stamp else { throw MediaRecoveryError.sourceChanged }
                    item.sealed = stamp; item.duration = validation.duration
                    journal.items[kind.rawValue] = item
                    try write(journal, to: journalURL)
                    ready[kind] = original
                } else {
                    try cleanWork(work, kind: kind)
                    guard work.withUnsafeFileSystemRepresentation({ mkdir($0!, 0o700) }) == 0 else { throw posixError() }
                    let restored = try await MediaRecovery.recover(source: original, kind: kind, workDirectory: work)
                    guard Stamp.read(original) == stamp, let sealed = Stamp.read(restored.url) else { throw MediaRecoveryError.sourceChanged }
                    item.sealed = sealed; item.duration = restored.duration
                    journal.items[kind.rawValue] = item
                    try write(journal, to: journalURL) // Durable BEFORE moving the sealed file.
                    try move(restored.url, candidate)
                    ready[kind] = candidate
                    try cleanWork(work, kind: kind)
                }
            } catch {
                if error is CancellationError { throw error }
                // A sealed candidate or failed journal write must be retried;
                // never turn publication/metadata failures into media rejection.
                guard item.sealed == nil, permanentMediaError(error) || Stamp.read(original) == nil else { throw error }
                item.originalStamp = Stamp.read(original)
                item.issue = error.localizedDescription
                journal.items[kind.rawValue] = item
                try write(journal, to: journalURL)
                try cleanWork(work, kind: kind)
            }
        }
        if var audio = journal.items[RecordingFileKind.audio.rawValue], audio.sealed == nil, !audio.wasPublished,
           let video = ready[.video] {
            let work = stage.appendingPathComponent(".recovery-\(journal.id.uuidString)-m4a", isDirectory: true)
            try cleanWork(work, kind: .audio)
            guard work.withUnsafeFileSystemRepresentation({ mkdir($0!, 0o700) }) == 0 else { throw posixError() }
            let output = work.appendingPathComponent("recovered.m4a")
            let validation = try await MediaRecovery.extractAudio(videoURL: video, outputURL: output)
            guard let stamp = Stamp.read(output) else { throw MediaRecoveryError.invalidMedia }
            audio.sealed = stamp; audio.duration = validation.duration; audio.issue = nil
            journal.items[RecordingFileKind.audio.rawValue] = audio
            try write(journal, to: journalURL)
            let candidate = stage.appendingPathComponent("recovered-\(journal.id.uuidString).m4a")
            try move(output, candidate)
            ready[.audio] = candidate
            try cleanWork(work, kind: .audio)
        }
        checkpoint(.mediaPrepared)
        try Task.checkCancellation()
        journal.phase = .publishing
        try write(journal, to: journalURL)
        let prepared = makeManifest(manifest, journal: journal, paths: current.urls.merging(ready) { _, new in new },
                                    published: Set(manifest.published), title: manifest.title)
        try saveManifest(prepared, manifestURL)
        checkpoint(.manifestPrepared)
        try Task.checkCancellation()
        let moved = ready.isEmpty ? nil
            : RecordingFileSet(urls: ready).relocate(to: directory, title: manifest.title, move: move)
        checkpoint(.mediaMoved)
        try Task.checkCancellation()
        let paths = prepared.paths.reduce(into: [RecordingFileKind: URL]()) { result, entry in
            if let kind = RecordingFileKind(rawValue: entry.key) { result[kind] = URL(fileURLWithPath: entry.value) }
        }.merging(moved?.files.urls ?? [:]) { _, new in new }
        var published = Set(manifest.published)
        for (kind, url) in moved?.files.urls ?? [:] where url.deletingLastPathComponent().standardizedFileURL == directory {
            if Stamp.read(url) == journal.items[kind.rawValue]?.sealed { published.insert(kind.rawValue) }
        }
        let committed = makeManifest(manifest, journal: journal, paths: paths, published: published,
                                     title: moved?.title ?? manifest.title, publicationError: moved?.errorMessage,
                                     committed: moved?.errorMessage == nil)
        try saveManifest(committed, manifestURL)
        checkpoint(.manifestCommitted)
        if let error = moved?.errorMessage { throw RecoveryPublicationError(message: error) }
        journal.phase = .complete
        try write(journal, to: journalURL)
        return Result(changed: true, manifest: committed,
                      newlyPublished: Set(published.subtracting(manifest.published).compactMap(RecordingFileKind.init(rawValue:))))
    }

    private static func makeJournal(_ manifest: RecordingSessionFiles.Manifest, files: RecordingFileSet) -> Journal {
        Journal(id: UUID(), sessionID: manifest.id, startedAt: manifest.startedAt,
                items: Dictionary(uniqueKeysWithValues: files.urls.map { kind, url in
                    (kind.rawValue, Item(originalPath: url.path, originalStamp: Stamp.read(url),
                                        wasClosed: manifest.closed.contains(kind.rawValue), wasPublished: manifest.published.contains(kind.rawValue)))
                }))
    }

    private static func makeManifest(_ basis: RecordingSessionFiles.Manifest, journal: Journal,
                                    paths: [RecordingFileKind: URL], published: Set<String>, title: String,
                                    publicationError: String? = nil, committed: Bool = false) -> RecordingSessionFiles.Manifest {
        let closed = Set(basis.closed).union(journal.items.compactMap { $0.value.sealed == nil ? nil : $0.key })
        let issues = journal.items.compactMapValues(\.issue)
        let durations = (basis.recovery?.durations ?? [:]).merging(journal.items.compactMapValues(\.duration)) { _, new in new }
        let originals = (basis.recovery?.originalPaths ?? [:]).merging(journal.items.compactMapValues {
            $0.wasClosed && ($0.sealed == nil || $0.reusesOriginal) ? nil : $0.originalPath
        }) { old, _ in old }
        let originalError: String?
        if let previous = basis.recovery { originalError = previous.originalCaptureError }
        else { originalError = basis.captureError ?? basis.error }
        let note = journal.items.values.contains(where: { !$0.reusesOriginal && $0.sealed != nil })
            ? L10n.text("已恢复中断录制，末尾未完整写入的内容可能缺失。") : L10n.text("已处理上次未完成的保存。")
        let message = ([originalError, note, publicationError].compactMap { $0 } + issues.keys.sorted().compactMap { issues[$0] }).joined(separator: "\n")
        var result = RecordingSessionFiles.Manifest(id: basis.id, startedAt: basis.startedAt, title: title,
            paths: Dictionary(uniqueKeysWithValues: paths.map { ($0.key.rawValue, $0.value.path) }),
            closed: closed.sorted(), published: published.sorted(), error: message,
            duration: durations.values.max() ?? basis.duration, captureError: message,
            fileIdentities: (basis.fileIdentities ?? [:]).merging(journal.items.compactMapValues { $0.sealed?.identity }) { _, new in new })
        result.recovery = .init(transactionID: journal.id, completedAt: committed ? Date() : nil, originalPaths: originals,
                                durations: durations, issues: issues, originalCaptureError: originalError)
        return result
    }

    private static func validate(_ manifest: RecordingSessionFiles.Manifest, stage: URL) throws {
        let keys = Set(manifest.paths.keys)
        guard stage.lastPathComponent == ".scriber-\(manifest.id.uuidString)", manifest.startedAt.timeIntervalSinceReferenceDate.isFinite,
              manifest.version == nil || manifest.version == 1, !keys.isEmpty,
              keys.isSubset(of: Set(RecordingFileKind.allCases.map(\.rawValue))),
              Set(manifest.closed).isSubset(of: keys), Set(manifest.published).isSubset(of: Set(manifest.closed)),
              manifest.duration.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw MediaRecoveryError.invalidMedia
        }
        _ = try RecordingFilename.validated(manifest.title)
        _ = try manifest.resolvedFiles(in: stage)
        if let recovery = manifest.recovery {
            guard Set(recovery.durations.keys).isSubset(of: keys), Set(recovery.issues.keys).isSubset(of: keys),
                  Set(recovery.originalPaths.keys).isSubset(of: keys),
                  recovery.durations.values.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw MediaRecoveryError.invalidMedia }
            for (key, path) in recovery.originalPaths {
                _ = try originalURL(Item(originalPath: path, originalStamp: nil, wasClosed: false, wasPublished: false), key: key, stage: stage)
            }
        }
    }

    private static func originalURL(_ item: Item, key: String, stage: URL) throws -> URL {
        guard item.originalPath.hasPrefix("/"), !item.originalPath.contains("\0") else { throw MediaRecoveryError.unsafePath }
        let url = URL(fileURLWithPath: item.originalPath).standardizedFileURL
        guard url.pathExtension == key, [stage, stage.deletingLastPathComponent()].contains(url.deletingLastPathComponent()) else {
            throw MediaRecoveryError.unsafePath
        }
        return url
    }

    private static func resolve(_ stamp: Stamp, preferred: [URL], directories: [URL]) throws -> URL {
        if let known = preferred.first(where: { Stamp.read($0) == stamp }) { return known }
        let matches = try directories.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { Stamp.read($0) == stamp }
        guard matches.count == 1 else { throw MediaRecoveryError.sourceChanged }
        return matches[0]
    }

    private static func cleanWork(_ work: URL, kind: RecordingFileKind) throws {
        var info = stat()
        guard work.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0 else {
            if errno == ENOENT { return }; throw posixError()
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw MediaRecoveryError.unsafePath }
        let files = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
        let allowed = Set(["prefix.\(kind.rawValue)", "recovered.\(kind.rawValue)"])
        guard files.allSatisfy({ allowed.contains($0.lastPathComponent) && RecordingFileIdentity.read($0) != nil }) else {
            throw MediaRecoveryError.unsafePath
        }
        for file in files { try FileManager.default.removeItem(at: file) }
        try FileManager.default.removeItem(at: work)
    }

    private static func read<T: Decodable>(_ url: URL, limit: Int = 128 * 1024) throws -> T {
        let fd = url.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw MediaRecoveryError.invalidMedia }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw MediaRecoveryError.invalidMedia }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private static func write(_ journal: Journal, to url: URL) throws {
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 128 * 1024 else { throw MediaRecoveryError.invalidMedia }
        try data.write(to: url, options: .atomic)
    }
    private static func permanentMediaError(_ error: any Error) -> Bool {
        if let media = error as? MediaRecoveryError {
            switch media {
            case .noCheckpoint, .invalidMedia: return true
            case .sourceChanged, .unsafePath: return false
            }
        }
        let error = error as NSError
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain { return false }
        return error.domain == AVFoundationErrorDomain && [AVError.Code.invalidSourceMedia.rawValue,
            AVError.Code.fileFailedToParse.rawValue, AVError.Code.decodeFailed.rawValue].contains(error.code)
    }
    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

private struct RecoveryPublicationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
