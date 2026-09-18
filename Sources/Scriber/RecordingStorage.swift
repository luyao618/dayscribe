import Darwin
import Foundation

struct RecordingStorage: Equatable, Sendable {
    let availableBytes: UInt64
    let volumeID: String

    static func read(_ directory: URL) throws -> Self {
        guard directory.isFileURL, !directory.path.contains("\0") else { throw StorageError.unavailable }
        var info = statfs()
        guard directory.withUnsafeFileSystemRepresentation({ statfs($0!, &info) }) == 0 else {
            throw StorageError.unavailable
        }
        let (bytes, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        guard !overflow, info.f_bsize > 0 else { throw StorageError.unavailable }
        return Self(availableBytes: bytes, volumeID: "\(info.f_fsid.val.0):\(info.f_fsid.val.1)")
    }

    // Allow final container indexes, pending encoder buffers and metadata to be
    // written after Stop. This is headroom, not a duration estimate or guarantee
    // against another process consuming the disk between checks.
    static func reserve(video: Bool) -> UInt64 { UInt64(video ? 256 : 64) * 1024 * 1024 }

    func validate(video: Bool, expectedVolume: String? = nil) throws {
        if let expectedVolume, volumeID != expectedVolume { throw StorageError.changedVolume }
        guard availableBytes > Self.reserve(video: video) else { throw StorageError.lowSpace }
    }
}

enum StorageError: LocalizedError, Equatable {
    case lowSpace, unavailable, changedVolume
    var errorDescription: String? {
        switch self {
        case .lowSpace: L10n.text("保存磁盘剩余空间不足。请释放空间或更改保存位置后重试。")
        case .unavailable: L10n.text("无法读取保存磁盘。请检查保存位置是否仍可用。")
        case .changedVolume: L10n.text("保存位置所在的磁盘已变化。请重新选择保存位置。")
        }
    }
}
