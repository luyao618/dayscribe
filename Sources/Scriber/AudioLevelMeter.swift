import SwiftUI

struct AudioLevelMeter: View {
    let powerDB: Float
    var tint = Color(red: 0.22, green: 0.60, blue: 0.50)
    var label = "麦克风真实电平"
    private let segments = 28

    private var activeSegments: Int {
        guard powerDB.isFinite else { return 0 }
        return Int((min(0, max(-60, powerDB)) + 60) / 60 * Float(segments))
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<segments, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(index < activeSegments ? tint : Color.primary.opacity(0.08))
                    .frame(height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.0f dBFS", powerDB))
    }
}
