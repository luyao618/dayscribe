import Darwin
import Foundation

enum RecordingFileKind: String, CaseIterable, Codable, Sendable {
    case audio = "m4a"
    case video = "mp4"
}

enum RecordingFilename {
    /// A basename, not a path. Leave room for a collision suffix and extension.
    static func validated(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !name.isEmpty, !name.hasPrefix("."), name.utf8.count <= 200,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !name.contains(where: { "/\\:".contains($0) }) else {
            throw RecordingFileError.invalidName
        }
        return name
    }
}

private enum RecordingFileError: LocalizedError {
    case invalidName, invalidFiles, tooManyCollisions

    var errorDescription: String? {
        switch self {
        case .invalidName: "名称不能为空、以点开头或包含斜杠、冒号、换行等字符；名称过长时请缩短。"
        case .invalidFiles: "录制文件不存在、不是普通文件，或文件列表无效。"
        case .tooManyCollisions: "同名文件过多，请换一个文件名。"
        }
    }
}

struct RecordingFileMoveResult: Sendable {
    /// Tracks each member even if rollback fails. A missing input remains missing;
    /// these locations alone are not proof of successful encoding or playback.
    let files: RecordingFileSet
    let title: String?
    let errorMessage: String?
    var succeeded: Bool { errorMessage == nil }
}

/// Only closed, app-owned files belong here. Call off the capture/UI queue.
/// One member move is atomic and exclusive; an MP4/M4A pair is NOT a filesystem
/// transaction. Roll back on failure and report exact locations if rollback fails.
/// No file or staging directory is deleted by this type.
struct RecordingFileSet: Sendable {
    let urls: [RecordingFileKind: URL]

    func relocate(to directory: URL, title: String,
                  move: (URL, URL) throws -> Void = RecordingFileSet.moveExclusively) -> RecordingFileMoveResult {
        var locations = urls.mapValues { $0.standardizedFileURL }
        do {
            let base = try RecordingFilename.validated(title)
            guard directory.isFileURL, !urls.isEmpty, urls.values.allSatisfy(\.isFileURL) else {
                throw RecordingFileError.invalidFiles
            }
            // Reject missing files, symlinks and aliases of the same source before
            // moving anything. lstat avoids mistaking a dangling link for absence.
            var identities = Set<String>()
            for url in locations.values {
                var info = stat()
                guard url.withUnsafeFileSystemRepresentation({ lstat($0!, &info) }) == 0,
                      info.st_mode & S_IFMT == S_IFREG,
                      identities.insert("\(info.st_dev):\(info.st_ino)").inserted else {
                    throw RecordingFileError.invalidFiles
                }
            }
            let directory = directory.standardizedFileURL
            for number in 1...1000 {
                let candidate = number == 1 ? base : "\(base) (\(number))"
                let destinations = Dictionary(uniqueKeysWithValues: locations.keys.map { kind in
                    (kind, directory.appendingPathComponent(candidate).appendingPathExtension(kind.rawValue))
                })
                // This is an optimization only. RENAME_EXCL is the collision guard
                // even if a different process creates a target after this check.
                if destinations.contains(where: { kind, url in
                    url != locations[kind] && Self.entryExists(url)
                }) { continue }
                let originals = locations
                var moved: [RecordingFileKind] = []
                do {
                    for kind in RecordingFileKind.allCases {
                        guard let source = locations[kind], let target = destinations[kind], source != target else { continue }
                        try move(source, target)
                        locations[kind] = target
                        moved.append(kind)
                    }
                    return .init(files: .init(urls: locations), title: candidate, errorMessage: nil)
                } catch {
                    var rollbackErrors: [String] = []
                    for kind in moved.reversed() {
                        do {
                            try move(locations[kind]!, originals[kind]!)
                            locations[kind] = originals[kind]
                        } catch {
                            rollbackErrors.append("\(locations[kind]!.path)：\(error.localizedDescription)")
                        }
                    }
                    if !rollbackErrors.isEmpty {
                        return .init(files: .init(urls: locations), title: nil,
                                     errorMessage: "保存或改名未完成：\(error.localizedDescription)；部分文件未能移回原位置：\(rollbackErrors.joined(separator: "；"))")
                    }
                    let failure = error as NSError
                    if failure.domain == NSPOSIXErrorDomain && failure.code == Int(EEXIST) { continue }
                    throw error
                }
            }
            throw RecordingFileError.tooManyCollisions
        } catch {
            return .init(files: .init(urls: locations), title: nil,
                         errorMessage: "保存或改名未完成：\(error.localizedDescription)")
        }
    }

    /// Same-volume rename: never fall back to a copy/delete on EXDEV. Session
    /// staging lives in its destination so a full disk needs no second media copy.
    static func moveExclusively(_ source: URL, _ target: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { from in
            target.withUnsafeFileSystemRepresentation { to in
                renamex_np(from!, to!, UInt32(RENAME_EXCL))
            }
        }
        if result != 0 {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSFilePathErrorKey: target.path])
        }
    }

    private static func entryExists(_ url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { lstat($0!, &info) } == 0
    }
}
