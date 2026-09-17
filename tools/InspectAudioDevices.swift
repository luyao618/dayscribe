import Foundation

// Read-only production inventory probe; no device selection or capture changes.
@main
enum InspectAudioDevices {
    static func main() throws {
        let snapshot = try AudioDevices.read()
        let report: [String: Any] = [
            "defaultInputUID": snapshot.defaultInput?.uid ?? "",
            "defaultOutputUID": snapshot.defaultOutput?.uid ?? "",
            "devices": snapshot.devices.map { device -> [String: Any] in
                ["id": device.id, "uid": device.uid, "name": device.name,
                 "input": device.hasInput, "output": device.hasOutput,
                 "alive": device.isAlive, "sampleRate": device.sampleRate, "transport": device.transport]
            }
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
