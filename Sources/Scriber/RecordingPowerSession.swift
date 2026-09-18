import Foundation
import IOKit
import IOKit.pwr_mgt

/// Owns power protection until capture and file publication have both finished.
/// Notifications run on the main run loop; explicit sleep is acknowledged only
/// after the asynchronous recorder shutdown completes. macOS still imposes its
/// own 30-second deadline, so interrupted fragments remain the fallback.
@MainActor
final class RecordingPowerSession {
    // IOMessage.h defines these with iokit_common_msg(), a function-like C
    // macro that Swift cannot import: sys_iokit | sub_iokit_common | code.
    static let canSystemSleep: UInt32 = 0xe0000270
    static let systemWillSleep: UInt32 = 0xe0000280
    private var connection: io_connect_t = 0
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private(set) var systemAssertion: IOPMAssertionID?
    private(set) var displayAssertion: IOPMAssertionID?
    private var ended = false
    private var sleepTask: Task<Void, Never>?
    private var pendingSleep = Set<Int>()
    private let onSleep: @MainActor () async -> Void
    private let respond: (io_connect_t, Int, Bool) -> Void

    var isRegistered: Bool { connection != 0 }

    init(video: Bool, onSleep: @escaping @MainActor () async -> Void,
         respond: @escaping (io_connect_t, Int, Bool) -> Void = { connection, id, allow in
             if allow { IOAllowPowerChange(connection, id) }
             else { IOCancelPowerChange(connection, id) }
         }) throws {
        self.onSleep = onSleep
        self.respond = respond
        do {
            connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &notificationPort, {
                context, _, message, argument in
                guard let context else { return }
                MainActor.assumeIsolated {
                    let session = Unmanaged<RecordingPowerSession>.fromOpaque(context).takeUnretainedValue()
                    session.receive(message, notificationID: Int(bitPattern: argument))
                }
            }, &notifier)
            guard connection != 0, let notificationPort,
                  let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() else {
                throw RecordingPowerError.registration
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            systemAssertion = try Self.assertion(kIOPMAssertionTypePreventUserIdleSystemSleep,
                                                reason: L10n.text("Scriber 正在录制并保存文件"))
            if video {
                displayAssertion = try Self.assertion(kIOPMAssertionTypePreventUserIdleDisplaySleep,
                                                     reason: L10n.text("Scriber 正在录制屏幕"))
            }
        } catch {
            end()
            throw error
        }
    }

    isolated deinit { end() }

    /// Idempotent. Keep the notification connection alive while an explicit
    /// sleep acknowledgment is pending, including when the recorder releases us.
    func end() {
        ended = true
        if let systemAssertion { IOPMAssertionRelease(systemAssertion); self.systemAssertion = nil }
        if let displayAssertion { IOPMAssertionRelease(displayAssertion); self.displayAssertion = nil }
        if sleepTask == nil { closeNotifications() }
    }

    func receive(_ message: UInt32, notificationID: Int) {
        guard connection != 0 else { return }
        switch message {
        case Self.canSystemSleep:
            respond(connection, notificationID, ended)
        case Self.systemWillSleep:
            if ended, sleepTask == nil {
                respond(connection, notificationID, true)
                return
            }
            pendingSleep.insert(notificationID)
            guard sleepTask == nil else { return }
            sleepTask = Task {
                await onSleep()
                for id in pendingSleep { respond(connection, id, true) }
                pendingSleep.removeAll()
                sleepTask = nil
                if ended { closeNotifications() }
            }
        default:
            // Wake and will-not-sleep messages must not be acknowledged.
            break
        }
    }

    private func closeNotifications() {
        if notifier != 0 { IODeregisterForSystemPower(&notifier); notifier = 0 }
        if let notificationPort {
            if let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if connection != 0 { IOServiceClose(connection); connection = 0 }
    }

    private static func assertion(_ type: String, reason: String) throws -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               reason as CFString, &id)
        guard status == kIOReturnSuccess else { throw RecordingPowerError.assertion(status) }
        return id
    }
}

enum RecordingPowerError: LocalizedError {
    case registration, assertion(IOReturn)
    var errorDescription: String? {
        switch self {
        case .registration: L10n.text("无法监听系统睡眠状态，请重新启动 Scriber 后再录制。")
        case .assertion(let code): L10n.text("无法在录制期间保持系统唤醒（\(code)），请重试。")
        }
    }
}
