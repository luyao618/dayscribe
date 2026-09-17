import Darwin
import Foundation

@main
struct RecoverSession {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 2 || (args.count == 4 && args[2] == "--exit-at" && SessionRecovery.Checkpoint(rawValue: args[3]) != nil),
                  args[1].hasPrefix("/") else {
                throw MediaRecoveryError.unsafePath
            }
            let crash = CommandLine.arguments.count == 4 && CommandLine.arguments[2] == "--exit-at" ? CommandLine.arguments[3] : nil
            let result = try await SessionRecovery.recover(manifestURL: URL(fileURLWithPath: CommandLine.arguments[1]), checkpoint: { point in
                // Deliberate process exit only in this offline validation tool.
                if point.rawValue == crash { _exit(77) }
            })
            let report: [String: Any] = ["changed": result.changed, "id": result.manifest.id.uuidString,
                "newlyPublished": result.newlyPublished.map(\.rawValue).sorted(),
                "title": result.manifest.title, "paths": result.manifest.paths, "published": result.manifest.published,
                "issues": result.manifest.recovery?.issues ?? [:]]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
}
