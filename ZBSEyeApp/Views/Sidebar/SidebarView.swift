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
        .navigationTitle("ZBS Eye")
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
                // Clickable pill → straight to Settings (used to be a dead-end label).
                Button { env.selectedSection = .settings } label: {
                    StatusPill(text: "Permissions needed", color: .orange, system: "lock.shield")
                }
                .buttonStyle(.plain)
            }
            RecordingStatusView(compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.ultraThinMaterial)
    }
}
