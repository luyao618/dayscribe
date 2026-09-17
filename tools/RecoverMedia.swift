import Foundation
import Darwin

// Offline native recovery of an app-owned media file. The lease excludes a live
// capture; the original and its session manifest are never modified by this tool.
@main
struct RecoverMedia {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1].hasPrefix("/"),
              CommandLine.arguments[2].hasPrefix("/") else { throw MediaRecoveryError.unsafePath }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let kind = RecordingFileKind(rawValue: source.pathExtension) else { throw MediaRecoveryError.invalidMedia }
        let lease = try RecordingSessionLease.acquire(in: source.deletingLastPathComponent())
        defer { lease.release() }
        let work = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        // The caller names a fresh directory, so failures leave inspectable work
        // without overwriting a previous recovery or an unrelated file.
        guard work.withUnsafeFileSystemRepresentation({ mkdir($0!, 0o700) }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let result = try await MediaRecovery.recover(source: source, kind: kind, workDirectory: work)
        let report: [String: Any] = ["path": result.url.path, "duration": result.duration,
                                   "audioFrames": result.audioFrames, "videoFrames": result.videoFrames,
                                   "sourceBytes": result.prefix.sourceBytes, "copiedBytes": result.prefix.copiedBytes,
                                   "indexedThrough": result.prefix.indexedThrough]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
