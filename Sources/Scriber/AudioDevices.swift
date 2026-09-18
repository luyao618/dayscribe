import CoreAudio
import Foundation

struct AudioDevice: Equatable, Sendable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
    let isAlive: Bool
    let sampleRate: Double
    let transport: UInt32
}

struct AudioDeviceSnapshot: Equatable, Sendable {
    var devices: [AudioDevice] = []
    var defaultInputID: AudioObjectID = kAudioObjectUnknown
    var defaultOutputID: AudioObjectID = kAudioObjectUnknown

    var defaultInput: AudioDevice? {
        devices.first { $0.id == defaultInputID && $0.hasInput && $0.isAlive }
    }
    var defaultOutput: AudioDevice? {
        devices.first { $0.id == defaultOutputID && $0.hasOutput && $0.isAlive }
    }
    // A recording pins a microphone UID. Do not label a new default as the
    // captured device before the capture stream has actually been reconnected.
    func microphone(uid: String?) -> AudioDevice? {
        guard let uid else { return defaultInput }
        return devices.first { $0.uid == uid && $0.hasInput && $0.isAlive }
    }
}

enum AudioDeviceReadError: Error, LocalizedError, Equatable {
    case property(OSStatus)
    case invalidData

    var errorDescription: String? { L10n.text("无法读取声音设备，请检查系统声音设置。") }
}

enum AudioDevices {
    static func read() throws -> AudioDeviceSnapshot {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size))
        guard Int(size) % MemoryLayout<AudioObjectID>.size == 0 else { throw AudioDeviceReadError.invalidData }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if !ids.isEmpty {
            try ids.withUnsafeMutableBytes {
                try check(AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!))
            }
            guard Int(size) <= ids.count * MemoryLayout<AudioObjectID>.size,
                  Int(size) % MemoryLayout<AudioObjectID>.size == 0 else { throw AudioDeviceReadError.invalidData }
            ids = Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
        }
        let devices = try ids.map { id in
            AudioDevice(id: id, uid: try string(id, kAudioDevicePropertyDeviceUID),
                        name: try string(id, kAudioObjectPropertyName),
                        hasInput: try hasStreams(id, scope: kAudioDevicePropertyScopeInput),
                        hasOutput: try hasStreams(id, scope: kAudioDevicePropertyScopeOutput),
                        isAlive: try value(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) != 0,
                        sampleRate: try value(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)),
                        transport: try value(id, kAudioDevicePropertyTransportType, initial: UInt32(0)))
        }
        return AudioDeviceSnapshot(devices: devices,
            defaultInputID: try value(system, kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0)),
            defaultOutputID: try value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0)))
    }

    private static func property(_ selector: AudioObjectPropertySelector,
                                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw AudioDeviceReadError.property(status) }
    }
    private static func value<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = property(selector)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutableBytes(of: &result) {
            try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!))
        }
        guard size == MemoryLayout<T>.size else { throw AudioDeviceReadError.invalidData }
        return result
    }
    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        let result: Unmanaged<CFString>? = try value(id, selector, initial: Optional<Unmanaged<CFString>>.none)
        guard let result else { throw AudioDeviceReadError.invalidData }
        return result.takeRetainedValue() as String
    }
    private static func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Bool {
        var address = property(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size))
        return size > 0
    }
}

/// Reads off the main actor at a bounded cadence, including while the panel is
/// hidden. One in-flight read; a disappearing device is retried on the next tick.
@MainActor
final class AudioDeviceMonitor {
    typealias Reading = Result<AudioDeviceSnapshot, AudioDeviceReadError>
    private var task: Task<Void, Never>?

    init(interval: Duration = .seconds(1),
         read: @escaping @Sendable () throws -> AudioDeviceSnapshot = { try AudioDevices.read() },
         onChange: @escaping @MainActor (Reading) -> Void) {
        task = Task {
            var previous: Reading?
            while !Task.isCancelled {
                let reading = await Task.detached {
                    do { return Reading.success(try read()) }
                    catch { return Reading.failure(error as? AudioDeviceReadError ?? .invalidData) }
                }.value
                guard !Task.isCancelled else { return }
                if reading != previous { previous = reading; onChange(reading) }
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    isolated deinit { task?.cancel() }
}
