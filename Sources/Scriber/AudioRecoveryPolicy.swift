import Foundation

struct AudioSourceConnectionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Two attempts per outage. Stable capture or a changed device allows a fresh
/// attempt; permanently failed hardware must not cause an endless restart loop.
struct AudioRecoveryPolicy {
    private var attempts: [AudioSource: Int] = [:]
    private var nextAttempt: [AudioSource: Double] = [:]
    private var healthySince: [AudioSource: Double] = [:]

    func canAttempt(_ source: AudioSource, at now: Double) -> Bool {
        attempts[source, default: 0] < 2 && now >= nextAttempt[source, default: 0]
    }

    mutating func beginAttempt(_ source: AudioSource, at now: Double) -> Bool {
        guard canAttempt(source, at: now) else { return false }
        attempts[source, default: 0] += 1
        nextAttempt[source] = now + 0.4
        healthySince[source] = nil
        return true
    }

    func exhausted(_ source: AudioSource) -> Bool { attempts[source, default: 0] >= 2 }

    mutating func received(_ source: AudioSource, at now: Double) {
        if healthySince[source] == nil { healthySince[source] = now }
        if now - healthySince[source, default: now] >= 2 { reset(source) }
    }

    mutating func reset(_ source: AudioSource) {
        attempts[source] = nil
        nextAttempt[source] = nil
        healthySince[source] = nil
    }

    static func microphoneTarget(snapshot: AudioDeviceSnapshot, selected: String?, followsDefault: Bool) -> String? {
        if followsDefault { return snapshot.defaultInput?.uid }
        return snapshot.microphone(uid: selected)?.uid ?? snapshot.defaultInput?.uid
    }
}
