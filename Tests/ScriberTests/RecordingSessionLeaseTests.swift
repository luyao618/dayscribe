import Darwin
import Foundation
import Testing
@testable import Scriber

struct RecordingSessionLeaseTests {
    @Test func ownedSessionRemainsExclusiveThroughFinalization() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = try RecordingSessionFiles.begin(directory: root, title: "owned", video: true)
        defer { owned.lease.release() }
        let session = owned.session
        let manifest = try RecordingSessionFiles.Manifest.read(from: session.manifestURL)
        #expect(manifest.id == session.id && manifest.closed.isEmpty)
        #expect(throws: RecordingSessionLeaseError.inUse) { try RecordingSessionLease.acquire(in: session.stagingDirectory) }
        for url in session.files.urls.values { try Data("closed fixture".utf8).write(to: url) }
        #expect(session.finalize(title: "owned", closed: [.audio, .video]).published == [.audio, .video])
        #expect(throws: RecordingSessionLeaseError.inUse) { try RecordingSessionLease.acquire(in: session.stagingDirectory) }
        owned.lease.release()
        let recovered = try RecordingSessionLease.acquire(in: session.stagingDirectory)
        recovered.release()
        #expect(FileManager.default.fileExists(atPath: session.stagingDirectory.appendingPathComponent("capture.lock").path))
    }

    @Test func releaseIsIdempotentAndDeinitializationReleasesOwnership() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try RecordingSessionLease.acquire(in: root)
        lease.release()
        let other = root.appendingPathComponent("other").withUnsafeFileSystemRepresentation { open($0!, O_CREAT | O_RDWR, 0o600) }
        try #require(other >= 0)
        defer { close(other) }
        lease.release()
        #expect(fcntl(other, F_GETFD) >= 0)
        do {
            let temporary = try RecordingSessionLease.acquire(in: root)
            withExtendedLifetime(temporary) {
                #expect(throws: RecordingSessionLeaseError.inUse) { try RecordingSessionLease.acquire(in: root) }
            }
        }
        let next = try RecordingSessionLease.acquire(in: root)
        next.release()
    }

    @Test func rejectsLinkedLockFilesAndLinkedSessionDirectories() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: outside)
        let stage = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let lock = stage.appendingPathComponent("capture.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try RecordingSessionLease.acquire(in: stage) }
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.linkItem(at: outside, to: lock)
        #expect(throws: RecordingSessionLeaseError.invalidLocation) { try RecordingSessionLease.acquire(in: stage) }
        try FileManager.default.removeItem(at: lock)
        #expect(lock.withUnsafeFileSystemRepresentation { mkfifo($0!, 0o600) } == 0)
        #expect(throws: RecordingSessionLeaseError.invalidLocation) { try RecordingSessionLease.acquire(in: stage) }
        try FileManager.default.removeItem(at: lock)
        let linked = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: stage)
        #expect(throws: (any Error).self) { try RecordingSessionLease.acquire(in: linked) }
        #expect(try Data(contentsOf: outside) == Data("keep".utf8))
    }

    @Test func independentProcessExcludesRecoveryAndDeathReleasesTheLease() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        let output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", """
        import fcntl,os,sys
        fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        print(os.getpid(),flush=True)
        sys.stdin.buffer.read(1)
        """, root.appendingPathComponent("capture.lock").path]
        process.standardOutput = output
        process.standardInput = input
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        var line = Data()
        while line.count < 32, let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            line.append(byte)
        }
        let ownerPID = try #require(Int32(String(decoding: line, as: UTF8.self)))
        #expect(throws: RecordingSessionLeaseError.inUse) { try RecordingSessionLease.acquire(in: root) }
        // PATH can contain a Python launcher that forks rather than execs.
        // Kill the actual helper holding the descriptor, not its launcher.
        #expect(ownerPID > 1 && kill(ownerPID, SIGKILL) == 0)
        process.waitUntilExit()
        #expect(!process.isRunning)
        let recovered = try RecordingSessionLease.acquire(in: root)
        recovered.release()
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
