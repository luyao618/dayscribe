import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Scriber

@MainActor
struct RecordingPowerSessionTests {
    @Test func actualAssertionsMatchModeAndAreReleased() throws {
        for video in [false, true] {
            let session = try RecordingPowerSession(video: video, onSleep: {})
            defer { session.end() }
            #expect(session.isRegistered)
            let systemID = try #require(session.systemAssertion)
            let properties = try #require(IOPMAssertionCopyProperties(systemID)?.takeRetainedValue() as? [String: Any])
            #expect(properties[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleSystemSleep)
            #expect(properties[kIOPMAssertionLevelKey] as? Int == Int(kIOPMAssertionLevelOn))
            #expect((session.displayAssertion != nil) == video)
            if let displayID = session.displayAssertion {
                let display = try #require(IOPMAssertionCopyProperties(displayID)?.takeRetainedValue() as? [String: Any])
                #expect(display[kIOPMAssertionTypeKey] as? String == kIOPMAssertionTypePreventUserIdleDisplaySleep)
            }
            let displayID = session.displayAssertion
            session.end()
            session.end()
            #expect(!session.isRegistered && session.systemAssertion == nil && session.displayAssertion == nil)
            #expect(IOPMAssertionCopyProperties(systemID) == nil)
            if let displayID { #expect(IOPMAssertionCopyProperties(displayID) == nil) }
        }
    }

    @Test func explicitSleepWaitsForFinalizationAndKeepsConnectionUntilAcknowledged() async throws {
        var events: [String] = []
        var finish: CheckedContinuation<Void, Never>?
        let session = try RecordingPowerSession(video: false, onSleep: {
            events.append("stop")
            await withCheckedContinuation { finish = $0 }
            events.append("saved")
        }, respond: { _, id, allow in events.append("\(allow ? "allow" : "deny"):\(id)") })
        defer { session.end(); finish?.resume() }
        session.receive(RecordingPowerSession.canSystemSleep, notificationID: 1)
        #expect(events == ["deny:1"])
        session.receive(RecordingPowerSession.systemWillSleep, notificationID: 2)
        session.receive(RecordingPowerSession.systemWillSleep, notificationID: 2)
        for _ in 0..<100 where finish == nil { await Task.yield() }
        #expect(events == ["deny:1", "stop"])
        // Recorder releases protection at the end of its stop operation, before
        // the asynchronous onSleep call returns to this coordinator.
        session.end()
        #expect(session.isRegistered && session.systemAssertion == nil)
        finish?.resume(); finish = nil
        for _ in 0..<100 where session.isRegistered { await Task.yield() }
        #expect(events == ["deny:1", "stop", "saved", "allow:2"])
        #expect(!session.isRegistered)
    }

    @Test func wakeMessagesDoNotAcknowledgeAndScopeReleaseRemovesAssertion() throws {
        var replies = 0
        var session: RecordingPowerSession? = try RecordingPowerSession(video: false, onSleep: {},
            respond: { _, _, _ in replies += 1 })
        weak var weakSession = session
        let id = try #require(session?.systemAssertion)
        session?.receive(0xe0000300, notificationID: 1) // kIOMessageSystemHasPoweredOn
        session?.receive(0xe0000290, notificationID: 2) // kIOMessageSystemWillNotSleep
        #expect(replies == 0)
        session = nil
        #expect(weakSession == nil && IOPMAssertionCopyProperties(id) == nil)
    }
}
