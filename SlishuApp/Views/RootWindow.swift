import SwiftUI

struct RootWindow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var env = env
        NavigationSplitView {
            SidebarView(selection: $env.selectedSection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                switch env.selectedSection {
                case .timeline:    TimelineView()
                case .pipes:       PipesView()
                case .connections: ConnectionsView()
                case .settings:    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
