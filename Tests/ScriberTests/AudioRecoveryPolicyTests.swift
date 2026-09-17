import Testing
@testable import Scriber

struct AudioRecoveryPolicyTests {
    @Test func retriesAreBoundedAndStableCaptureRearmsThem() {
        var policy = AudioRecoveryPolicy()
        #expect(policy.beginAttempt(.microphone, at: 10) == true)
        #expect(policy.beginAttempt(.microphone, at: 10.2) == false)
        #expect(policy.beginAttempt(.microphone, at: 10.5) == true)
        #expect(policy.exhausted(.microphone))
        #expect(policy.beginAttempt(.microphone, at: 30) == false)
        policy.received(.microphone, at: 31)
        policy.received(.microphone, at: 32)
        #expect(policy.beginAttempt(.microphone, at: 32) == false)
        policy.received(.microphone, at: 33.1)
        #expect(policy.beginAttempt(.microphone, at: 33.2) == true)
        #expect(policy.beginAttempt(.system, at: 33.2) == true)
    }

    @Test func deviceChangeRearmsOnlyItsSource() {
        var policy = AudioRecoveryPolicy()
        for source in AudioSource.allCases {
            #expect(policy.beginAttempt(source, at: 1) == true)
            #expect(policy.beginAttempt(source, at: 2) == true)
        }
        policy.reset(.microphone)
        #expect(policy.beginAttempt(.microphone, at: 3) == true)
        #expect(policy.beginAttempt(.system, at: 3) == false)
    }

    @Test func defaultChangesAndLostPinnedDeviceChooseAnAvailableInput() {
        let builtIn = AudioDevice(id: 1, uid: "built-in", name: "Built-in", hasInput: true,
                                  hasOutput: false, isAlive: true, sampleRate: 48_000, transport: 0)
        let usb = AudioDevice(id: 2, uid: "usb", name: "USB", hasInput: true,
                             hasOutput: false, isAlive: true, sampleRate: 16_000, transport: 0)
        var snapshot = AudioDeviceSnapshot(devices: [builtIn, usb], defaultInputID: 1)
        #expect(AudioRecoveryPolicy.microphoneTarget(snapshot: snapshot, selected: "usb", followsDefault: true) == "built-in")
        #expect(AudioRecoveryPolicy.microphoneTarget(snapshot: snapshot, selected: "usb", followsDefault: false) == "usb")
        snapshot.devices = [builtIn]
        #expect(AudioRecoveryPolicy.microphoneTarget(snapshot: snapshot, selected: "usb", followsDefault: false) == "built-in")
        snapshot.defaultInputID = 0
        #expect(AudioRecoveryPolicy.microphoneTarget(snapshot: snapshot, selected: "usb", followsDefault: true) == nil)
    }
}
