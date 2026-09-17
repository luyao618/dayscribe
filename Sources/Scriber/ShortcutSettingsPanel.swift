import SwiftUI

struct ShortcutSettingsPanel: View {
    @ObservedObject var shortcut: GlobalPanelShortcut
    let onBack: () -> Void
    @State private var keyCode = PanelShortcut.defaultValue.keyCode
    @State private var modifiers = PanelShortcut.defaultValue.modifiers
    @State private var enabled = true
    private var draft: PanelShortcut { .init(keyCode: keyCode, modifiers: modifiers) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .buttonStyle(PanelIconButtonStyle()).accessibilityLabel("返回录制面板")
                Text("呼出快捷键").font(.system(size: 18, weight: .semibold))
                Spacer()
            }
            Text("在其他应用中，也能随时打开录制面板。")
                .font(.system(size: 12)).foregroundStyle(PanelPalette.slate)
            Toggle("启用快捷键", isOn: $enabled).toggleStyle(.switch).font(.system(size: 12))
                .tint(PanelPalette.iris).accessibilityLabel("启用快捷键")
            VStack(spacing: 16) {
                Text(draft.label).font(.system(size: 27, weight: .medium, design: .monospaced))
                    .frame(maxWidth: .infinity).accessibilityLabel("快捷键组合").accessibilityValue(draft.label)
                HStack(spacing: 7) {
                    ForEach(PanelShortcut.modifierChoices, id: \.0) { bit, name in
                        Button { modifiers ^= bit } label: {
                            Text(String(name.prefix(1))).font(.system(size: 18))
                                .frame(maxWidth: .infinity).frame(height: 34)
                                .foregroundStyle(modifiers & bit != 0 ? PanelPalette.iris : PanelPalette.slate)
                                .background(modifiers & bit != 0 ? PanelPalette.iris.opacity(0.1) : PanelPalette.track,
                                            in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain).accessibilityLabel(name)
                        .accessibilityValue(modifiers & bit != 0 ? "已选择" : "未选择")
                    }
                }
                Picker("按键", selection: $keyCode) {
                    ForEach(PanelShortcut.keys, id: \.0) { key, name in Text(name).tag(key) }
                }
                .pickerStyle(.menu).font(.system(size: 12)).accessibilityLabel("快捷键按键")
            }
            .padding(16).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            if let error = shortcut.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(PanelPalette.record)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if shortcut.apply(draft, enabled: enabled) { onBack() }
            } label: {
                Text("保存快捷键").font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 42).foregroundStyle(.white)
                    .background(PanelPalette.iris, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            Text("录制范围或文件夹选择窗口打开时，请先完成选择。")
                .font(.system(size: 10)).foregroundStyle(PanelPalette.slate)
        }
        .padding(20)
        .onAppear { keyCode = shortcut.shortcut.keyCode; modifiers = shortcut.shortcut.modifiers; enabled = shortcut.enabled }
    }
}
