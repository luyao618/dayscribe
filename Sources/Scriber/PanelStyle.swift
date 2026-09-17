import SwiftUI

// Shared with the approved design/panel.css palette; keep the native panel in sync.
enum PanelPalette {
    static let pearl = Color(red: 246/255, green: 247/255, blue: 250/255)
    static let ink = Color(red: 38/255, green: 43/255, blue: 56/255)
    static let slate = Color(red: 113/255, green: 120/255, blue: 135/255)
    static let muted = Color(red: 152/255, green: 158/255, blue: 172/255)
    static let iris = Color(red: 112/255, green: 103/255, blue: 207/255)
    static let jade = Color(red: 57/255, green: 153/255, blue: 128/255)
    static let record = Color(red: 218/255, green: 102/255, blue: 106/255)
    static let track = Color(red: 232/255, green: 234/255, blue: 240/255)
    static let line = Color(red: 57/255, green: 65/255, blue: 85/255).opacity(0.09)
    static let stopInk = Color(red: 179/255, green: 77/255, blue: 84/255)
    static let stopBackground = Color(red: 245/255, green: 227/255, blue: 229/255)
}

struct PanelIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16))
            .foregroundStyle(PanelPalette.slate)
            .frame(width: 30, height: 30)
            .background(configuration.isPressed ? PanelPalette.track : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.46)
            .contentShape(Rectangle())
    }
}

struct PanelSourceRow: View {
    let name: String
    let symbol: String
    let tint: Color
    @Binding var enabled: Bool
    let status: String
    let powerDB: Float?
    let toggleHelp: String
    var deviceName: String = ""
    var deviceHelp: String = ""
    var canToggle = true

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(enabled ? tint : PanelPalette.muted)
                    .font(.system(size: 13)).frame(width: 16)
                Text(name).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(enabled ? PanelPalette.ink : PanelPalette.slate)
                    .fixedSize()
                if !deviceName.isEmpty {
                    Text(deviceName).font(.system(size: 9)).foregroundStyle(PanelPalette.slate)
                        .lineLimit(1).truncationMode(.middle)
                        .help(deviceHelp)
                        .accessibilityLabel("\(name)设备：\(deviceName)")
                }
                Spacer(minLength: 2)
                Text(status).font(.system(size: 10)).foregroundStyle(PanelPalette.slate).fixedSize()
                Toggle(name, isOn: $enabled)
                    .toggleStyle(SourceToggleStyle(tint: tint, name: name))
                    .disabled(!canToggle)
                    .help(toggleHelp)
            }
            HStack(spacing: 12) {
                AudioLevelMeter(powerDB: powerDB ?? -160, tint: tint, label: "\(name)真实电平")
                Text(powerDB.map { String(format: "%.0f dB", $0) } ?? "— dB")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(PanelPalette.slate)
                    .frame(width: 39, alignment: .trailing)
            }
            .padding(.leading, 24)
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
    }
}

private struct SourceToggleStyle: ToggleStyle {
    let tint: Color
    let name: String

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? tint : PanelPalette.track)
                .frame(width: 28, height: 17)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 13, height: 13).padding(2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityValue(configuration.isOn ? "已开启" : "已关闭")
    }
}
