import Combine
import Foundation

@MainActor
final class RecordingHistoryModel: ObservableObject {
    @Published private(set) var entries: [RecordingHistoryEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var discoveryMessage: String?
    private let store: RecordingHistoryStore?
    private var pendingDirectories = Set<URL>()
    private var reloadRequested = false
    var isAvailable: Bool { store != nil }

    init(store: RecordingHistoryStore? = nil) { self.store = store }

    func refresh(discovering directories: [URL] = []) async {
        guard let store else { return }
        pendingDirectories.formUnion(directories)
        if isLoading { reloadRequested = true; return }
        isLoading = true
        defer { isLoading = false }
        repeat {
            reloadRequested = false
            let folders = Array(pendingDirectories)
            pendingDirectories.removeAll()
            do {
                if !folders.isEmpty {
                    let issues = try await store.discover(in: folders)
                    discoveryMessage = issues.isEmpty ? nil : L10n.text("有 \(issues.count) 项旧记录未能读取，可检查文件夹后重试。")
                }
                let loaded = try await store.load()
                entries = loaded
                errorMessage = nil
            } catch {
                errorMessage = L10n.text("无法读取历史记录：\(error.localizedDescription)")
                // Keep the last good snapshot; a read error is not an empty history.
            }
        } while reloadRequested
    }

    func filesForReveal(_ id: UUID) async -> [URL] {
        guard let store else { return [] }
        do {
            let latest = try await store.load()
            entries = latest
            guard let entry = latest.first(where: { $0.id == id }) else {
                errorMessage = L10n.text("这条录制记录已不可用。")
                return []
            }
            let files = RecordingFileKind.allCases.compactMap { kind -> URL? in
                guard entry.fileStates[kind] == .available || entry.fileStates[kind] == .unfinished else { return nil }
                return entry.urls[kind]
            }
            errorMessage = files.isEmpty ? L10n.text("文件已移动、删除或无法访问，请检查保存目录。") : nil
            return files
        } catch {
            errorMessage = L10n.text("无法定位文件：\(error.localizedDescription)")
            return []
        }
    }

    static func durationText(_ duration: Double?) -> String {
        guard let duration, duration.isFinite, duration >= 0,
              let seconds = Int(exactly: duration.rounded(.down)) else { return "—" }
        return String(format: "%02ld:%02ld:%02ld", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    static func dateText(_ date: Date) -> String { dateFormatter.string(from: date) }
}
