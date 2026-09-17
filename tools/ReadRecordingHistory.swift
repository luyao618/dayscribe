import Darwin
import Foundation

/// Read-only validation in a fresh process; no media playback or capture.
@main
enum ReadRecordingHistory {
    static func main() async {
        guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else {
            print("Usage: ReadRecordingHistory /absolute/history.json")
            exit(2)
        }
        do {
            let store = RecordingHistoryStore(indexURL: URL(fileURLWithPath: CommandLine.arguments[1]))
            let entries = try await store.load()
            let rows: [[String: Any]] = entries.map { entry in
                var row: [String: Any] = [
                    "id": entry.id.uuidString, "title": entry.title,
                    "manifestPath": entry.reference.manifestURL.path,
                    "paths": Dictionary(uniqueKeysWithValues: entry.urls.map { ($0.key.rawValue, $0.value.path) }),
                    "fileStates": Dictionary(uniqueKeysWithValues: entry.fileStates.map { ($0.key.rawValue, String(describing: $0.value)) }),
                    "issue": entry.issue ?? ""
                ]
                row["duration"] = entry.duration.map { $0 as Any } ?? NSNull()
                return row
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
