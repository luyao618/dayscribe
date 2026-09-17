import Foundation
import Synchronization
import Testing
@testable import Scriber

struct AudioDevicesTests {
    private static let builtIn = AudioDevice(id: 1, uid: "built-in", name: "Built-in", hasInput: true,
        hasOutput: false, isAlive: true, sampleRate: 48_000, transport: 0)
    private static let headset = AudioDevice(id: 2, uid: "headset", name: "Headset", hasInput: true,
        hasOutput: true, isAlive: true, sampleRate: 16_000, transport: 0)

    @Test func selectedMicrophoneDoesNotFollowANewDefaultUntilReconnected() {
        var snapshot = AudioDeviceSnapshot(devices: [Self.builtIn, Self.headset], defaultInputID: 1, defaultOutputID: 2)
        #expect(snapshot.microphone(uid: nil) == Self.builtIn)
        snapshot.defaultInputID = 2
        #expect(snapshot.microphone(uid: nil) == Self.headset)
        #expect(snapshot.microphone(uid: "built-in") == Self.builtIn)
        snapshot.devices.removeAll { $0.uid == "built-in" }
        #expect(snapshot.microphone(uid: "built-in") == nil)
        #expect(snapshot.defaultInput == Self.headset)
        #expect(snapshot.defaultOutput == Self.headset)
    }

    @Test func deadMissingAndWrongDirectionDevicesAreUnavailable() {
        let dead = AudioDevice(id: 3, uid: "dead", name: "Disconnected", hasInput: true,
            hasOutput: true, isAlive: false, sampleRate: 48_000, transport: 0)
        var snapshot = AudioDeviceSnapshot(devices: [Self.builtIn, dead], defaultInputID: 3, defaultOutputID: 1)
        #expect(snapshot.defaultInput == nil && snapshot.defaultOutput == nil)
        #expect(snapshot.microphone(uid: "dead") == nil)
        snapshot.defaultInputID = 99
        #expect(snapshot.defaultInput == nil && snapshot.microphone(uid: "missing") == nil)
        snapshot.defaultInputID = 1
        #expect(snapshot.defaultInput == Self.builtIn)
    }

    @Test @MainActor func monitorReportsChangesAndErrorsRecoversAndStopsOnRelease() async throws {
        let initial = AudioDeviceSnapshot(devices: [Self.builtIn], defaultInputID: 1)
        let input = Mutex<AudioDeviceMonitor.Reading>(.success(initial))
        var events: [AudioDeviceMonitor.Reading] = []
        var monitor: AudioDeviceMonitor? = AudioDeviceMonitor(interval: .milliseconds(10), read: {
            try input.withLock { try $0.get() }
        }, onChange: { events.append($0) })
        weak var weakMonitor = monitor
        func waitForEvents(_ count: Int) async throws {
            for _ in 0..<100 {
                if events.count >= count { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(events.count == count)
        }
        try await waitForEvents(1)
        try await Task.sleep(for: .milliseconds(40))
        #expect(events == [.success(initial)])
        input.withLock { $0 = .failure(.property(-1)) }
        try await waitForEvents(2)
        let changed = AudioDeviceSnapshot(devices: [Self.headset], defaultInputID: 2, defaultOutputID: 2)
        input.withLock { $0 = .success(changed) }
        try await waitForEvents(3)
        #expect(events == [.success(initial), .failure(.property(-1)), .success(changed)])
        monitor = nil
        #expect(weakMonitor == nil)
        input.withLock { $0 = .success(initial) }
        try await Task.sleep(for: .milliseconds(40))
        #expect(events.count == 3)
    }
}
