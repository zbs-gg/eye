import SwiftUI

struct StatusPill: View {
    // LocalizedStringKey (not a plain String) so the pill's text is actually looked up in the catalog —
    // a String is rendered verbatim, which silently dropped the RU translations (Pro l10n #7).
    let text: LocalizedStringKey
    let color: Color
    var system: String?

    init(text: LocalizedStringKey, color: Color, system: String? = nil) {
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
