import Darwin
import Foundation

// Copy-only diagnostics for an inactive owned movie or generated box fixture.
// A complete box prefix is not a claim of decodable/recovered media.
@main
struct InspectPrefixCopyMemory {
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 3, args[1].hasPrefix("/"), args[2].hasPrefix("/") else {
                throw NSError(domain: "InspectPrefixCopyMemory", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "Usage: InspectPrefixCopyMemory /absolute/inactive/source /absolute/new/prefix"])
            }
            let source = URL(fileURLWithPath: args[1]), target = URL(fileURLWithPath: args[2])
            let result = try await Task.detached { try MovieFilePrefix.copy(from: source, to: target) }.value
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let report: [String: Any] = ["sourceBytes": result.sourceBytes, "copiedBytes": result.copiedBytes,
                                       "peakRSSBytes": usage.ru_maxrss, "scope": "prefix copy only"]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
