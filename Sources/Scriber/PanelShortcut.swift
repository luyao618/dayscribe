import Carbon
import Combine
import Foundation

struct PanelShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    static let defaultValue = Self(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(optionKey))
    static let modifierChoices: [(UInt32, String)] = [
        (UInt32(controlKey), "⌃ Control"), (UInt32(optionKey), "⌥ Option"),
        (UInt32(shiftKey), "⇧ Shift"), (UInt32(cmdKey), "⌘ Command")
    ]
    static let keys: [(UInt32, String)] = [
        (0,"A"),(11,"B"),(8,"C"),(2,"D"),(14,"E"),(3,"F"),(5,"G"),(4,"H"),(34,"I"),
        (38,"J"),(40,"K"),(37,"L"),(46,"M"),(45,"N"),(31,"O"),(35,"P"),(12,"Q"),(15,"R"),
        (1,"S"),(17,"T"),(32,"U"),(9,"V"),(13,"W"),(7,"X"),(16,"Y"),(6,"Z"),
        (29,"0"),(18,"1"),(19,"2"),(20,"3"),(21,"4"),(23,"5"),(22,"6"),(26,"7"),(28,"8"),(25,"9"),
        (122,"F1"),(120,"F2"),(99,"F3"),(118,"F4"),(96,"F5"),(97,"F6"),(98,"F7"),
        (100,"F8"),(101,"F9"),(109,"F10"),(103,"F11"),(111,"F12")
    ]
    var isValid: Bool {
        let allowed = Self.modifierChoices.reduce(UInt32(0)) { $0 | $1.0 }
        return Self.keys.contains { $0.0 == keyCode } && modifiers & ~allowed == 0
            && modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }
    var label: String {
        Self.modifierChoices.filter { modifiers & $0.0 != 0 }.map { String($0.1.prefix(1)) }.joined()
            + (Self.keys.first { $0.0 == keyCode }?.1 ?? "?")
    }
}

@MainActor
final class GlobalPanelShortcut: ObservableObject {
    @Published private(set) var shortcut = PanelShortcut.defaultValue
    @Published private(set) var enabled = true
    @Published private(set) var isRegistered = false
    @Published private(set) var isStarted = false
    @Published private(set) var errorMessage: String?
    var onUpdate: (() -> Void)?
    private let defaults: UserDefaults?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var activeID: UInt32 = 0
    private var keyIsDown = false
    private var onInvoke: (() -> Void)?
    private static var nextID: UInt32 = 1
    private static let signature: OSType = 0x53435242 // SCRB
    static let preferenceKey = "panelShortcut"
    private struct Preference: Codable {
        var version = 1
        let enabled: Bool
        let shortcut: PanelShortcut
    }

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if defaults?.object(forKey: Self.preferenceKey) != nil {
            if let data = defaults?.data(forKey: Self.preferenceKey),
               let saved = try? JSONDecoder().decode(Preference.self, from: data), saved.version == 1, saved.shortcut.isValid {
                shortcut = saved.shortcut
                enabled = saved.enabled
            } else {
                enabled = false
                errorMessage = L10n.text("快捷键设置无法读取，请重新设置；原设置已保留。")
            }
        }
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func start(onInvoke: @escaping () -> Void) {
        self.onInvoke = onInvoke
        isStarted = true
        if enabled { _ = apply(shortcut, enabled: true, persist: false) }
    }

    @discardableResult
    func apply(_ candidate: PanelShortcut, enabled desiredEnabled: Bool, persist: Bool = true) -> Bool {
        defer { onUpdate?() }
        let candidate = !desiredEnabled && !candidate.isValid ? shortcut : candidate
        guard candidate.isValid else {
            errorMessage = L10n.text("请至少选择 ⌘、⌥ 或 ⌃ 中的一个组合键。")
            return false
        }
        var replacement: EventHotKeyRef?
        var replacementID = activeID
        if desiredEnabled && (!isRegistered || shortcut != candidate) {
            guard installHandler() else { return false }
            replacementID = Self.nextID
            Self.nextID &+= 1
            let status = RegisterEventHotKey(candidate.keyCode, candidate.modifiers,
                EventHotKeyID(signature: Self.signature, id: replacementID), GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &replacement)
            guard status == noErr, replacement != nil else {
                errorMessage = L10n.text("这个组合无法启用，可能已被占用。") + (isRegistered ? L10n.text("原快捷键仍然生效。") : L10n.text("请换一个组合。"))
                return false
            }
        }
        if let old = hotKey, replacement != nil || !desiredEnabled {
            let status = UnregisterEventHotKey(old)
            guard status == noErr else {
                if let replacement { UnregisterEventHotKey(replacement) }
                errorMessage = L10n.text("无法更改当前快捷键，请重试。")
                return false
            }
            hotKey = nil
        }
        if let replacement { hotKey = replacement; activeID = replacementID }
        keyIsDown = false
        shortcut = candidate
        enabled = desiredEnabled
        isRegistered = hotKey != nil
        errorMessage = nil
        if persist, let data = try? JSONEncoder().encode(Preference(enabled: enabled, shortcut: shortcut)) {
            defaults?.set(data, forKey: Self.preferenceKey)
        }
        return true
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
        onInvoke = nil
        isRegistered = false
        isStarted = false
        keyIsDown = false
    }

    private func installHandler() -> Bool {
        if eventHandler != nil { return true }
        var eventTypes = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context, Thread.isMainThread else { return OSStatus(eventNotHandledErr) }
            var identity = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &identity) == noErr else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalPanelShortcut>.fromOpaque(context).takeUnretainedValue()
            let kind = GetEventKind(event)
            return MainActor.assumeIsolated {
                guard owner.isRegistered, owner.enabled, identity.signature == GlobalPanelShortcut.signature,
                      identity.id == owner.activeID else {
                    return OSStatus(eventNotHandledErr)
                }
                if kind == UInt32(kEventHotKeyReleased) { owner.keyIsDown = false; return noErr }
                guard !owner.keyIsDown else { return noErr }
                owner.keyIsDown = true
                owner.onInvoke?()
                return noErr
            }
        }, eventTypes.count, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if status != noErr { errorMessage = L10n.text("无法启用快捷键，请重试。") }
        return status == noErr
    }
}
