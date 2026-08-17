import SwiftUI

/// Automation v1: "Day summary". collect → the active optional AI → write to a
/// file/Obsidian. A preview-then-write flow. The destination-folder card lives here too (it belongs
/// to export, not to agent access).
struct AutomationsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let store = env.automations {
                AutomationBody(store: store)
            } else {
                ContentUnavailableView("Initializing…", systemImage: "powerplug")
            }
        }
        .navigationTitle("Automations")
    }
}

private struct AutomationBody: View {
    @Bindable var store: DaySummaryStore
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let callAutomation = env.callAutomation {
                    AfterCallAutomationCard(store: callAutomation)
                }
                header
                destinationCard
                auditSection
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await store.refreshAudit() }
    }

    // MARK: blocks

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Review export", systemImage: "sparkles.rectangle.stack")
                .font(.title2).bold()
            Text("Build and schedule Reviews from the Timeline. This page keeps the optional Markdown/Obsidian destination and run audit.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Where summaries land. This belongs to the automation, not agent access.
    private var destinationCard: some View {
        GroupBox {
            @Bindable var conn = env.connections
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Destination", systemImage: "folder").font(.headline)
                    Spacer()
                    if conn.destination.isConfigured {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                HStack {
                    Button {
                        conn.pickDestination()
                    } label: {
                        Label("Choose folder…", systemImage: "folder.badge.plus")
                    }
                    if let path = conn.destination.displayPath {
                        Text(verbatim: path).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                }
                TextField("Subfolder", text: $conn.destination.subfolder, prompt: Text(verbatim: "ZBS Eye"))
                    .autocorrectionDisabled()
                Text("Where to write summaries. For Obsidian, pick the vault folder — files land in "
                     + "`<vault>/<subfolder>/YYYY-MM-DD.md`.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var auditSection: some View {
        DisclosureGroup("Run history (\(store.audit.count))") {
            if store.audit.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.audit) { e in
                        HStack(spacing: 8) {
                            Image(systemName: e.ok ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(e.ok ? .green : .red)
                            Text(e.action == "write" ? "write" : "preview").bold()
                            Text(e.day).foregroundStyle(.secondary)
                            Text("· \(e.sessions) sessions")
                                .foregroundStyle(.secondary).font(.caption)
                            Spacer()
                            Text(auditTime(e.at)).font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func auditTime(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "d MMM, HH:mm"
        return f.string(from: d)
    }
}

private struct AfterCallAutomationCard: View {
    @Bindable var store: CallAutomationStore

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button {
                        store.isExpanded.toggle()
                    } label: {
                        Label("After a call", systemImage: "phone.arrow.up.right")
                            .font(.headline)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("After a call automation details")
                    Spacer()
                    Toggle("Enable after-call webhook", isOn: Binding(
                        get: { store.isEnabled },
                        set: { enabled in Task { await store.setEnabled(enabled) } }
                    ))
                    .labelsHidden()
                    .disabled(
                        store.isBusy || store.phase == .suspended
                            || (!store.isEnabled && !store.canEnable)
                    )
                }

                Label(statusPresentation.text, systemImage: statusPresentation.icon)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("After a call status: \(statusPresentation.text)")

                if store.isExpanded {
                    Text("Send a signed event to a service on this Mac when a call ends or its transcript is ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(
                        "Local receiver URL",
                        text: $store.draftEndpoint,
                        prompt: Text(verbatim: "http://127.0.0.1:8765/hooks/call")
                    )
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Local after-call receiver URL")

                    if store.phase == .invalidDraft {
                        Label(
                            "Use http://127.0.0.1 with an explicit port of 1024 or higher.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button("Save receiver") { Task { await store.saveReceiver() } }
                            .disabled(!store.canSave)
                        Button("Cancel") { store.cancelDraft() }
                            .disabled(!store.hasDraftChanges || store.isBusy)
                        Spacer()
                        Button("Test") { Task { await store.testReceiver() } }
                            .disabled(
                                store.persistedEndpoint.isEmpty || store.isBusy
                                    || store.phase == .suspended
                            )
                        Button("Copy secret") { store.copySecret() }
                            .disabled(
                                store.persistedEndpoint.isEmpty || store.isBusy
                                    || store.phase == .suspended
                            )
                    }

                    if store.blockedCount > 0 {
                        HStack {
                            Text("\(store.blockedCount) blocked")
                                .font(.caption)
                            Button("Retry") { Task { await store.retryBlocked() } }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .confirmationDialog(
            "Change local receiver?",
            isPresented: Binding(
                get: { store.endpointChangeConfirmationCount != nil },
                set: { if !$0 { store.cancelDraft() } }
            )
        ) {
            Button("Change and discard pending events", role: .destructive) {
                Task { await store.confirmEndpointChange() }
            }
            Button("Cancel", role: .cancel) { store.cancelDraft() }
        } message: {
            Text("Pending events belong to the old receiver and cannot be sent to the new one.")
        }
    }

    private var statusPresentation: (text: String, icon: String) {
        switch store.phase {
        case .disabled: ("Off", "pause.circle")
        case .invalidDraft: ("Enter a valid local receiver", "exclamationmark.circle")
        case .ready:
            (
                store.pendingCount > 0 ? "On · \(store.pendingCount) pending" : "On · Ready",
                "checkmark.circle"
            )
        case .saving: ("Saving receiver…", "clock")
        case .testing: ("Testing receiver…", "clock")
        case .testSucceeded: ("Test delivered", "checkmark.circle")
        case .testFailed:
            ("Test failed · \(store.statusCode ?? "receiver unavailable")", "exclamationmark.circle")
        case .keychainUnavailable: ("Signing secret unavailable", "exclamationmark.circle")
        case .suspended: ("Paused while storage is moving", "clock")
        case .blocked:
            ("Delivery blocked · \(store.blockedCount) waiting", "exclamationmark.circle")
        case .failed: ("Automation status unavailable", "exclamationmark.circle")
        }
    }
}
