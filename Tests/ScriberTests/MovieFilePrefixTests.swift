import Foundation
import Testing
@testable import Scriber

struct MovieFilePrefixTests {
    @Test func tornIndexTailKeepsEarlierCompleteBoxesAndOriginalBytes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let complete = box("ftyp", Data("mp42isom".utf8)) + box("mdat", Data(repeating: 7, count: 20)) + box("moov", Data([1, 2]))
        let body = complete + box("mdat", Data(repeating: 8, count: 12))
        let original = body + integer(80, bytes: 4) + Data("moofbroken".utf8)
        let source = root.appendingPathComponent("source.mp4"), target = root.appendingPathComponent("prefix.mp4")
        try original.write(to: source)
        let result = try MovieFilePrefix.copy(from: source, to: target)
        #expect(result.indexedThrough == complete.count && result.copiedBytes == body.count)
        #expect(try Data(contentsOf: target) == body)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func extendedSizesAndOpenEndedMediaAreBoundedAndNotMistakenForAnIndex() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = box("ftyp", Data("mp42isom".utf8))
        let data = start + integer(1, bytes: 4) + Data("mdat".utf8) + integer(32, bytes: 8) + Data(repeating: 1, count: 16)
            + box("moov", Data()) + integer(0, bytes: 4) + Data("mdatpayload-moof-is-not-an-index".utf8)
        let source = root.appendingPathComponent("source.m4a"), target = root.appendingPathComponent("prefix.m4a")
        try data.write(to: source)
        let result = try MovieFilePrefix.copy(from: source, to: target)
        #expect(result.copiedBytes == data.count && result.indexedThrough == start.count + 32 + 8)
        #expect(try Data(contentsOf: source) == data)
        let oversized = start + integer(1, bytes: 4) + Data("mdat".utf8) + integer(UInt64.max, bytes: 8)
        let bad = root.appendingPathComponent("bad.m4a")
        try oversized.write(to: bad)
        #expect(throws: (any Error).self) { try MovieFilePrefix.copy(from: bad, to: root.appendingPathComponent("absent")) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
    }

    @Test func missingIndexLinkedSourcesAndOccupiedDestinationsAreRefused() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.m4a"), target = root.appendingPathComponent("target.m4a")
        try (box("ftyp", Data("mp42isom".utf8)) + box("mdat", Data([1]))).write(to: source)
        #expect(throws: (any Error).self) { try MovieFilePrefix.copy(from: source, to: target) }
        try (box("ftyp", Data("mp42isom".utf8)) + box("mdat", Data([1])) + box("moov", Data())).write(to: source)
        try Data("keep".utf8).write(to: target)
        #expect(throws: (any Error).self) { try MovieFilePrefix.copy(from: source, to: target) }
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        let linked = root.appendingPathComponent("linked.m4a")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
        #expect(throws: (any Error).self) { try MovieFilePrefix.copy(from: linked, to: root.appendingPathComponent("unused")) }
    }

    private func box(_ type: String, _ data: Data) -> Data { integer(UInt64(data.count + 8), bytes: 4) + Data(type.utf8) + data }
    private func integer(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
