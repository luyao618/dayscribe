import Darwin
import Foundation

enum MediaRecoveryError: LocalizedError {
    case noCheckpoint, invalidMedia, sourceChanged, unsafePath
    var errorDescription: String? {
        switch self {
        case .noCheckpoint: "没有找到完整的录制索引，原始文件已保留。"
        case .invalidMedia: "录制片段无法完整读取，原始文件已保留。"
        case .sourceChanged: "恢复期间原始文件发生变化，请稍后重试。"
        case .unsafePath: "恢复文件的位置无效。"
        }
    }
}

struct MovieFilePrefix: Sendable {
    let sourceBytes: UInt64
    let copiedBytes: UInt64
    let indexedThrough: UInt64

    /// Caller owns the inactive session. Copy only complete top-level boxes,
    /// preserving the original. Box completeness is not decoder validation.
    static func copy(from source: URL, to target: URL) throws -> Self {
        guard source.isFileURL, target.isFileURL, !source.path.contains("\0"), !target.path.contains("\0") else {
            throw MediaRecoveryError.unsafePath
        }
        let descriptor = source.withUnsafeFileSystemRepresentation { open($0!, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0 else { throw posixError() }
        guard initial.st_mode & S_IFMT == S_IFREG, initial.st_size > 0 else { throw MediaRecoveryError.invalidMedia }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let prefix = try scan(input, length: UInt64(initial.st_size))
        let destination = target.withUnsafeFileSystemRepresentation {
            open($0!, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard destination >= 0 else { throw posixError() }
        defer { close(destination) }
        let output = FileHandle(fileDescriptor: destination, closeOnDealloc: false)
        try input.seek(toOffset: 0)
        var remaining = prefix.copiedBytes
        while remaining > 0 {
            try Task.checkCancellation()
            // FileHandle creates autoreleased Foundation buffers. A detached
            // Swift task need not drain a pool between reads, so scope those
            // objects to one chunk instead of retaining the entire movie.
            let copied = try autoreleasepool {
                let data = try input.read(upToCount: Int(min(remaining, 1024 * 1024))) ?? Data()
                guard !data.isEmpty else { throw MediaRecoveryError.sourceChanged }
                try output.write(contentsOf: data)
                return UInt64(data.count)
            }
            remaining -= copied
        }
        var final = stat(), current = stat()
        guard fstat(descriptor, &final) == 0,
              source.withUnsafeFileSystemRepresentation({ lstat($0!, &current) }) == 0,
              current.st_dev == initial.st_dev, current.st_ino == initial.st_ino,
              current.st_mode & S_IFMT == S_IFREG,
              final.st_size == initial.st_size,
              final.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec else { throw MediaRecoveryError.sourceChanged }
        return prefix
    }

    private static func scan(_ file: FileHandle, length: UInt64) throws -> Self {
        var offset: UInt64 = 0
        var indexed: UInt64 = 0
        var hasMovie = false
        var count = 0
        while length - offset >= 8 {
            try Task.checkCancellation()
            guard count < 1_000_000 else { throw MediaRecoveryError.invalidMedia }
            count += 1
            try file.seek(toOffset: offset)
            guard let header = try file.read(upToCount: 8), header.count == 8 else { throw MediaRecoveryError.sourceChanged }
            var size = integer(header.prefix(4))
            let type = String(decoding: header.suffix(4), as: UTF8.self)
            if offset == 0 && type != "ftyp" { throw MediaRecoveryError.noCheckpoint }
            var headerBytes: UInt64 = 8
            if size == 1 {
                guard length - offset >= 16 else { break }
                guard let extended = try file.read(upToCount: 8), extended.count == 8 else { throw MediaRecoveryError.sourceChanged }
                size = integer(extended); headerBytes = 16
            }
            if size == 0 { size = length - offset }
            guard size >= headerBytes, size <= length - offset else { break }
            offset += size
            if type == "moov" { hasMovie = true; indexed = offset }
            if type == "moof", hasMovie { indexed = offset }
        }
        guard hasMovie, indexed > 0 else { throw MediaRecoveryError.noCheckpoint }
        // An unindexed trailing mdat may be copied; AVFoundation only exports
        // indexed samples. A torn moov/moof tail itself must not reach the parser.
        return Self(sourceBytes: length, copiedBytes: offset, indexedThrough: indexed)
    }

    private static func integer(_ bytes: Data.SubSequence) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
