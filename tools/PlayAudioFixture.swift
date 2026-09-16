import AVFoundation
import CoreAudio
import Foundation

// Routes only this test player's output; never changes the system or Teams device.
func devices() throws -> [[String: Any]] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
        throw NSError(domain: "AudioFixture", code: 1)
    }
    guard size >= MemoryLayout<AudioObjectID>.size else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status = ids.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr else { throw NSError(domain: "AudioFixture", code: 2) }
    return ids.map { id in
        func string(_ selector: AudioObjectPropertySelector) -> String {
            var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, &value) == noErr,
                  let value else { return "" }
            return value.takeRetainedValue() as String
        }
        func hasStreams(_ scope: AudioObjectPropertyScope) -> Bool {
            var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                     mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &property, 0, nil, &bytes) == noErr && bytes > 0
        }
        return ["id": id, "name": string(kAudioObjectPropertyName), "uid": string(kAudioDevicePropertyDeviceUID),
                "input": hasStreams(kAudioDevicePropertyScopeInput), "output": hasStreams(kAudioDevicePropertyScopeOutput)]
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func run() throws {
    let arguments = CommandLine.arguments
    if arguments.count == 2, arguments[1] == "--devices" {
        print(String(decoding: try JSONSerialization.data(withJSONObject: devices(), options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    } else {
        guard arguments.count == 3,
              try devices().contains(where: { $0["uid"] as? String == arguments[2] && $0["output"] as? Bool == true }) else {
            fail("Usage: PlayAudioFixture --devices | /absolute/fixture.wav output-device-UID")
        }
        let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: arguments[1]))
        player.currentDevice = arguments[2]
        guard player.prepareToPlay(), player.play() else { fail("Unable to play fixture") }
        print("Fixture output device: \(player.currentDevice ?? "unknown")")
        while player.isPlaying { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05)) }
    }
}

do { try run() }
catch { fail(error.localizedDescription) }
