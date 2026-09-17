import Darwin
import Foundation

enum RecordingSessionLeaseError: LocalizedError, Equatable {
    case inUse, invalidLocation
    var errorDescription: String? {
        switch self {
        case .inUse: "这次录制仍在使用中。"
        case .invalidLocation: "录制会话位置无效。"
        }
    }
}

/// A lease survives UI closure but not process death. Keep the lock file in place:
/// unlinking it would let a second process lock a different inode at the same path.
final class RecordingSessionLease: @unchecked Sendable {
    enum Purpose: String { case capture = "capture.lock", rename = "rename.lock" }
    private let mutex = NSLock()
    private var descriptor: Int32?

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(in directory: URL, purpose: Purpose = .capture) throws -> RecordingSessionLease {
        guard directory.isFileURL, !directory.path.contains("\0") else { throw RecordingSessionLeaseError.invalidLocation }
        let parent = directory.withUnsafeFileSystemRepresentation {
            open($0!, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard parent >= 0 else { throw posixError() }
        defer { close(parent) }
        let descriptor = openat(parent, purpose.rawValue, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw posixError() }
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw RecordingSessionLeaseError.invalidLocation
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw RecordingSessionLeaseError.inUse }
                throw posixError()
            }
            var current = stat()
            guard fstatat(parent, purpose.rawValue, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == info.st_dev, current.st_ino == info.st_ino else {
                throw RecordingSessionLeaseError.invalidLocation
            }
            return RecordingSessionLease(descriptor: descriptor)
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Safe to call repeatedly and from different executors. Mark closed before
    /// releasing so a reused file descriptor can never be closed by a later call.
    func release() {
        mutex.lock()
        defer { mutex.unlock() }
        guard let descriptor else { return }
        self.descriptor = nil
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    deinit { release() }

    private static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
