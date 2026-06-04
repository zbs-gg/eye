import SwiftUI

struct SidebarView: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var selection: SidebarSection

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarSection.allCases) { section in
                Label(section.rawValue, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .navigationTitle("Slishu")
        .safeAreaInset(edge: .bottom) {
            StatusFooter()
        }
    }
}

private struct StatusFooter: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !env.permissions.allCriticalGranted {
                StatusPill(text: "Нужны разрешения", color: .orange, system: "lock.shield")
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(env.recording.isCapturing ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(env.recording.isCapturing ? "Запись идёт" : "На паузе")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial)
    }
}
