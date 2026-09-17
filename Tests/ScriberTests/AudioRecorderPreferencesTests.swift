import Foundation
import Testing
@testable import Scriber

struct AudioRecorderPreferencesTests {
    @Test @MainActor func remembersSelectionButNeverPersistsAnEmptySourceSet() async throws {
        let name = "scriber-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AudioRecorder(defaults: defaults)
        #expect(first.sources == [.system, .microphone])
        #expect(await first.setSources([.microphone]))
        let restored = AudioRecorder(defaults: defaults)
        #expect(restored.sources == [.microphone])
        #expect(!(await restored.setSources([])))
        #expect(restored.controlMessage == "至少保留一路声音。")
        #expect(restored.state == .idle)
        #expect(AudioRecorder(defaults: defaults).sources == [.microphone])
        defaults.set(0, forKey: "recordingSources")
        #expect(AudioRecorder(defaults: defaults).sources == [.system, .microphone])
    }
}
