import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var pendingLanguage: AppLanguage?
    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SettingsRoute.allCases) { route in
                        NavigationLink(value: route) {
                            SettingsRouteRow(
                                route: route,
                                summary: summary(for: route),
                                attention: route == .permissions && permissionIssueCount > 0
                            )
                        }
                    }
                }

                Section {
                    resourceLine
                }
            }
            .listStyle(.inset)
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .permissions: PermissionsSettingsView()
                case .ai: AISettingsView()
                case .dataStorage: DataStorageSettingsView()
                case .browserCapture: BrowserCaptureSettingsView()
                case .mcpTools: MCPToolsSettingsView()
                }
            }
            .toolbar { moreMenu }
        }
        .onAppear { env.resourceUsage.start() }
        .task {
            await env.permissions.refreshAll()
            await env.storageSettings.refresh(storage: env.storage)
        }
        .onDisappear { env.resourceUsage.stop() }
        .confirmationDialog(
            "Restart ZBS Eye to change the language?",
            isPresented: Binding(
                get: { pendingLanguage != nil },
                set: { if !$0 { pendingLanguage = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restart now") {
                if let pendingLanguage { LanguageManager.set(pendingLanguage) }
            }
            Button("Cancel", role: .cancel) { pendingLanguage = nil }
        } message: {
            Text("The interface language is applied after a restart.")
        }
    }

    private var resourceLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf")
                .foregroundStyle(.green)
            Text(resourceSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityLabel("Current resource use: \(resourceSummary)")
    }

    private var resourceSummary: String {
        let cpu = env.resourceUsage.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—"
        let memory = env.resourceUsage.physicalFootprintBytes
            .map(StorageSettingsStore.format) ?? "—"
        let data = StorageSettingsStore.format(env.resourceUsage.dataBytes)
        return "CPU \(cpu) · Memory \(memory) · Data \(data)"
    }

    private var permissionIssueCount: Int {
        let snapshot = env.permissions.snapshot
        return [snapshot.screenRecording, snapshot.accessibility,
                snapshot.microphone, snapshot.speech].filter { $0 != .granted }.count
    }

    private func summary(for route: SettingsRoute) -> String {
        switch route {
        case .permissions:
            return permissionIssueCount == 0
                ? String(localized: "Ready · screen, microphone, sound")
                : String(localized: "\(permissionIssueCount) need attention")
        case .ai:
            if let provider = env.ai.activeProvider, let model = env.ai.activeModelID {
                return AISetupPresentation.activeLabel(provider: provider, modelID: model)
            }
            return String(localized: "Off · optional")
        case .dataStorage:
            return "\(StorageSettingsStore.format(env.storageSettings.totalBytes)) · Keep \(env.storageSettings.keepMediaPolicy.settingsLabel)"
        case .browserCapture:
            if !env.recording.isCapturing { return String(localized: "Paused with recording") }
            switch env.server.browserConnectionStatus() {
            case .connected: return String(localized: "Connected · active tab only")
            case .stale: return String(localized: "Waiting for the active tab")
            case .disconnected: return String(localized: "Off until you enable the extension")
            }
        case .mcpTools:
            return String(localized: "Give Codex or Claude read-only Timeline access")
        }
    }

    @ToolbarContentBuilder
    private var moreMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Menu("Language") {
                    Button("System") { chooseLanguage(.system) }
                    Button { chooseLanguage(.en) } label: { Text(verbatim: "English") }
                    Button { chooseLanguage(.ru) } label: { Text(verbatim: "Русский") }
                }
                Toggle("Open at login", isOn: $loginItemEnabled)
                    .onChange(of: loginItemEnabled) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            loginItemEnabled = SMAppService.mainApp.status == .enabled
                        }
                    }
                Divider()
                Button("Repair & Diagnostics…") { env.showSelfRepair = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    private func chooseLanguage(_ language: AppLanguage) {
        guard language != LanguageManager.current else { return }
        pendingLanguage = language
    }
}

private struct SettingsRouteRow: View {
    let route: SettingsRoute
    let summary: String
    let attention: Bool

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: route.systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(attention ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.title).font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 5)
    }
}
