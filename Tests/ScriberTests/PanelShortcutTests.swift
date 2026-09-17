import Carbon
import Foundation
import Testing
@testable import Scriber

struct PanelShortcutTests {
    @Test func validatesModifiersAndDisplaysTheChosenPhysicalKey() {
        #expect(PanelShortcut.defaultValue.label == "⌥R")
        #expect(PanelShortcut.defaultValue.isValid)
        #expect(!PanelShortcut(keyCode: 15, modifiers: 0).isValid)
        #expect(!PanelShortcut(keyCode: 15, modifiers: UInt32(shiftKey)).isValid)
        #expect(!PanelShortcut(keyCode: 65535, modifiers: UInt32(optionKey)).isValid)
        #expect(!PanelShortcut(keyCode: 15, modifiers: UInt32(optionKey) | 0x80000000).isValid)
        #expect(PanelShortcut(keyCode: 18, modifiers: UInt32(controlKey | optionKey | cmdKey)).label == "⌃⌥⌘1")
    }

    @Test @MainActor func persistsDisabledChoiceAndPreservesInvalidPreferencesUntilEdited() throws {
        let name = "scriber-shortcut-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let chosen = PanelShortcut(keyCode: 18, modifiers: UInt32(controlKey | optionKey))
        let model = GlobalPanelShortcut(defaults: defaults)
        #expect(model.apply(chosen, enabled: false))
        let restored = GlobalPanelShortcut(defaults: defaults)
        #expect(restored.shortcut == chosen && !restored.enabled && !restored.isRegistered)
        let saved = defaults.data(forKey: GlobalPanelShortcut.preferenceKey)
        #expect(!restored.apply(.init(keyCode: 15, modifiers: 0), enabled: true))
        #expect(defaults.data(forKey: GlobalPanelShortcut.preferenceKey) == saved)
        defaults.set("invalid preference type", forKey: GlobalPanelShortcut.preferenceKey)
        let invalid = GlobalPanelShortcut(defaults: defaults)
        #expect(!invalid.enabled && invalid.errorMessage != nil)
        #expect(defaults.string(forKey: GlobalPanelShortcut.preferenceKey) == "invalid preference type")
        #expect(invalid.apply(.defaultValue, enabled: false))
        #expect(GlobalPanelShortcut(defaults: defaults).errorMessage == nil)
    }

    @Test @MainActor func exclusiveConflictKeepsTheOldBindingAndDisableReleasesIt() throws {
        let name = "scriber-shortcut-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = GlobalPanelShortcut()
        let second = GlobalPanelShortcut(defaults: defaults)
        let probe = GlobalPanelShortcut()
        defer { first.stop(); second.stop(); probe.stop() }
        // Use unused four-modifier keys briefly; never override a registered key.
        func reserve(_ service: GlobalPanelShortcut, excluding: PanelShortcut? = nil) throws -> PanelShortcut {
            for (key, _) in PanelShortcut.keys.reversed() {
                let candidate = PanelShortcut(keyCode: key, modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
                if candidate != excluding, service.apply(candidate, enabled: true) { return candidate }
            }
            throw CocoaError(.featureUnsupported)
        }
        let occupied = try reserve(first)
        let original = try reserve(second, excluding: occupied)
        let saved = defaults.data(forKey: GlobalPanelShortcut.preferenceKey)
        #expect(!second.apply(occupied, enabled: true))
        #expect(second.shortcut == original && second.isRegistered && second.errorMessage != nil)
        #expect(defaults.data(forKey: GlobalPanelShortcut.preferenceKey) == saved)
        #expect(!probe.apply(original, enabled: true))
        #expect(second.apply(original, enabled: false))
        #expect(!second.isRegistered)
        #expect(probe.apply(original, enabled: true))
    }
}
