import SwiftUI

struct StatusPill: View {
    let text: String
    let color: Color
    var system: String?

    init(text: String, color: Color, system: String? = nil) {
        self.text = text
        self.color = color
        self.system = system
    }

    var body: some View {
        HStack(spacing: 4) {
            if let system { Image(systemName: system) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.18), in: Capsule())
        .foregroundStyle(color)
    }
}
