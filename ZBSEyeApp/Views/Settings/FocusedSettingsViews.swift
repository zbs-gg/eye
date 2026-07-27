import AppKit
import SwiftUI

struct PermissionsSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup("Permissions") {
                    PermissionSettingsRow(
                        title: "Screen Recording",
                        status: env.permissions.snapshot.screenRecording,
                        request: PermissionChecker.requestScreenRecording,
                        openSettings: { PermissionChecker.openSettings("Privacy_ScreenCapture") }
                    )
                    Divider()
                    PermissionSettingsRow(
                        title: "Accessibility",
                        status: env.permissions.snapshot.accessibility,
                        request: PermissionChecker.requestAccessibility,
                        openSettings: { PermissionChecker.openSettings("Privacy_Accessibility") }
                    )
                    Divider()
                    PermissionSettingsRow(
                        title: "Microphone",
                        status: env.permissions.snapshot.microphone,
                        request: { Task { await env.permissions.requestMicrophone() } },
                        openSettings: { PermissionChecker.openSettings("Privacy_Microphone") }
                    )
                    Divider()
                    PermissionSettingsRow(
                        title: "Speech Recognition",
                        status: env.permissions.snapshot.speech,
                        request: { Task { await env.permissions.requestSpeech() } },
                        openSettings: { PermissionChecker.openSettings("Privacy_SpeechRecognition") }
                    )
                    Divider()
                    Button("Re-check permissions") {
                        Task { await env.permissions.refreshAll() }
                    }
                }

                audioGroup
                privacyGroup
            }
            .padding(24)
            .frame(maxWidth: 720)
        }
        .navigationTitle("Permissions")
        .task {
            await env.permissions.refreshAll()
            await env.audioSettings.refreshHealth(env.audio)
        }
    }

    private var audioGroup: some View {
        @Bindable var audio = env.audioSettings
        return SettingsGroup("Audio") {
            Picker("Record audio", selection: $audio.audioMode) {
                ForEach(AudioMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(audioModeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Toggle("System audio outside calls", isOn: $audio.recordSystemAudio)
            Text("Turn this off to keep ordinary playback out of Timeline and avoid waking meeting tools. A confirmed or manually started call still records separate microphone and system tracks; Audio Off disables both.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if audio.systemEngineFailed {
                Label("System Audio did not start. Check Screen Recording access.", systemImage: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if audio.micEngineFailed {
                Label("The microphone was unavailable at the last start.", systemImage: "mic.slash.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var audioModeSummary: String {
        switch env.audioSettings.audioMode {
        case .off: String(localized: "Audio is off. Screen capture continues.")
        case .meetingsOnly: String(localized: "Audio engines run only during detected meetings.")
        case .always: String(localized: "Audio follows recording continuously.")
        }
    }

    private var privacyGroup: some View {
        SettingsGroup("Private apps") {
            if env.privacy.ignoredBundleIds.isEmpty {
                Text("No excluded apps.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(env.privacy.ignoredBundleIds, id: \.self) { bundleID in
                    HStack {
                        Image(systemName: "eye.slash")
                        VStack(alignment: .leading) {
                            Text(env.privacy.displayNames[bundleID] ?? bundleID)
                            Text(bundleID).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            env.privacy.remove(bundleID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Divider()
            Button("Exclude an app…") { env.privacy.addAppViaPanel() }
        }
    }
}

struct AISettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var pendingAutomaticConsent: AIConsumer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsGroup("Active") {
                    HStack(spacing: 12) {
                        Image(systemName: env.ai.activeProvider == nil
                              ? "pause.circle" : "checkmark.circle.fill")
                            .foregroundStyle(env.ai.activeProvider == nil
                                             ? Color.secondary : Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activeLabel).font(.headline)
                            Text("AI is optional. Timeline, capture, and local search work without it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Divider()
                    Button("Add or switch AI…") {
                        env.aiSetup.present(origin: .settings)
                    }
                    .buttonStyle(.borderedProminent)
                    if env.ai.activeProvider != nil {
                        Button("Turn AI off", role: .destructive) { env.ai.deactivate() }
                    }
                }
                SettingsGroup("Call processing") {
                    WhisperModelSettingsView()
                    Divider()
                    SpeakerDiarizationModelSettingsView()
                }
                if let provider = env.ai.activeProvider, provider.isCloud {
                    SettingsGroup("Background AI") {
                        automaticConsumerToggle(
                            .scheduledSummary,
                            title: "Scheduled summaries",
                            detail: "Create scheduled summaries from relevant text excerpts."
                        )
                        Divider()
                        automaticConsumerToggle(
                            .generatedLabels,
                            title: "Activity labels",
                            detail: "Generate short labels for captured activity from text excerpts."
                        )
                    }
                }
                Label(
                    "Cloud providers receive only approved text excerpts. Raw screenshots, audio, and file paths are not sent.",
                    systemImage: "hand.raised.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 720)
        }
        .navigationTitle("AI")
        .alert(
            "Allow background AI?",
            isPresented: Binding(
                get: { pendingAutomaticConsent != nil },
                set: { if !$0 { pendingAutomaticConsent = nil } }
            ),
            presenting: pendingAutomaticConsent
        ) { consumer in
            Button("Allow") {
                guard let provider = env.ai.activeProvider else { return }
                _ = env.ai.setAutomaticConsumerConsent(consumer, enabled: true, for: provider)
                pendingAutomaticConsent = nil
            }
            Button("Cancel", role: .cancel) { pendingAutomaticConsent = nil }
        } message: { consumer in
            Text(automaticConsentMessage(for: consumer))
        }
    }

    private var activeLabel: String {
        AISetupPresentation.activeLabel(
            provider: env.ai.activeProvider,
            modelID: env.ai.activeModelID
        )
    }

    @ViewBuilder
    private func automaticConsumerToggle(
        _ consumer: AIConsumer,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        Toggle(isOn: Binding(
            get: {
                guard let provider = env.ai.activeProvider else { return false }
                return env.ai.hasConsent(provider, for: consumer)
            },
            set: { enabled in
                guard let provider = env.ai.activeProvider else { return }
                if enabled {
                    pendingAutomaticConsent = consumer
                } else {
                    _ = env.ai.setAutomaticConsumerConsent(
                        consumer,
                        enabled: false,
                        for: provider
                    )
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func automaticConsentMessage(for consumer: AIConsumer) -> String {
        let recipient = env.ai.activeProvider
            .flatMap { env.ai.recipientDisclosure(for: $0) }
            ?? String(localized: "the active cloud provider")
        let purpose = consumer == .scheduledSummary
            ? String(localized: "scheduled summaries")
            : String(localized: "activity labels")
        return String(localized: "ZBS Eye will automatically send only the text excerpts needed for \(purpose) to \(recipient). Raw screenshots, audio, and file paths are not sent.")
    }
}

struct DataStorageSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sliderValue = 0.0
    @State private var applyingPolicy = false
    @State private var keepMediaError: String?
    @State private var keepMediaConfirmation: AppEnvironment.KeepMediaConfirmation?
    @State private var confirmDelete: TimeInterval?
    @AppStorage("zbseye.browserHistory.enabled") private var browserHistoryEnabled = true

    private let policies = KeepMediaPolicy.allCases

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                storageOverview
                keepMediaGroup
                storageLocationGroup
                privacyOperationsGroup
                backupGroup
                importGroup
            }
            .padding(24)
            .frame(maxWidth: 720)
        }
        .navigationTitle("Data Storage")
        .task {
            syncSlider()
            env.backupSettings.refresh()
            await env.storageSettings.refresh(storage: env.storage)
        }
        .confirmationDialog(
            keepMediaConfirmationTitle,
            isPresented: Binding(
                get: { keepMediaConfirmation != nil },
                set: { if !$0 { keepMediaConfirmation = nil; syncSlider() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Apply limit and remove oldest media", role: .destructive) {
                guard let confirmation = keepMediaConfirmation else { return }
                keepMediaConfirmation = nil
                applyPolicy(
                    confirmation.policy,
                    confirmedRemovalBytes: confirmation.bytesToRemove
                )
            }
            Button("Cancel", role: .cancel) { keepMediaConfirmation = nil; syncSlider() }
        } message: {
            if let confirmation = keepMediaConfirmation {
                Text("Eye would need to remove about \(StorageSettingsStore.format(confirmation.bytesToRemove)) of the oldest captured media. Search text and newer media stay available.")
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) { startDelete() }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
        .alert(
            "History deletion",
            isPresented: Binding(
                get: { env.storageOperations.deleteOutcome != nil },
                set: { if !$0 { env.storageOperations.clearDeleteOutcome() } }
            )
        ) {
            Button("OK") { env.storageOperations.clearDeleteOutcome() }
        } message: {
            Text(env.storageOperations.deleteOutcome ?? "")
        }
    }

    private var storageOverview: some View {
        SettingsGroup("On this Mac") {
            LabeledContent("Captured media", value: StorageSettingsStore.format(env.storageSettings.mediaBytes))
            LabeledContent("Search index", value: StorageSettingsStore.format(env.storageSettings.databaseBytes))
            LabeledContent("Free on disk", value: StorageSettingsStore.format(env.storageSettings.freeBytes))
            if env.recording.lowDiskPaused {
                Label(
                    "Capture is paused because disk space is low. Eye will not delete history to self-heal.",
                    systemImage: "externaldrive.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var keepMediaGroup: some View {
        SettingsGroup("Keep Media") {
            Slider(
                value: $sliderValue,
                in: 0...Double(policies.count - 1),
                step: 1
            ) { editing in
                if !editing {
                    let index = min(max(Int(sliderValue.rounded()), 0), policies.count - 1)
                    applyPolicy(policies[index])
                }
            }
            .disabled(applyingPolicy)
            HStack {
                ForEach(policies, id: \.self) { policy in
                    Text(policy.settingsLabel)
                        .font(.caption)
                        .foregroundStyle(policy == env.storageSettings.keepMediaPolicy
                                         ? .primary : .secondary)
                    if policy != policies.last { Spacer() }
                }
            }
            if applyingPolicy { ProgressView().controlSize(.small) }
            if let keepMediaError {
                Text(keepMediaError).font(.caption).foregroundStyle(.orange)
            } else if env.storageSettings.keepMediaPolicy == .forever {
                Label("Media is kept forever. Low disk still pauses capture.", systemImage: "infinity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("When the cap is reached, Eye removes the oldest captured media first. Choosing a smaller cap asks before any deletion can begin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var storageLocationGroup: some View {
        SettingsGroup("Location") {
            Text(env.storageSettings.dataRootDisplay)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if env.storageSettings.relocationInProgress {
                ProgressView(value: env.storageSettings.relocationProgress)
                Text(env.storageSettings.relocationStatus)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Move…", action: chooseRelocateFolder)
                    if env.storageSettings.isRelocated {
                        Button("Use default location", action: relocateToDefault)
                    }
                    Spacer()
                    if let directory = env.storage?.mediaDirectory {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([directory])
                        }
                    }
                }
            }
            if let error = env.storageSettings.relocationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var privacyOperationsGroup: some View {
        SettingsGroup("Your data") {
            DisclosureGroup("Export or delete") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        if env.storageOperations.exporting { ProgressView().controlSize(.small) }
                        Menu("Export…") {
                            Button("Today · text") { chooseExport(days: 1, media: false) }
                            Button("Today · text + media") { chooseExport(days: 1, media: true) }
                            Divider()
                            Button("All history · text") { chooseExport(days: nil, media: false) }
                            Button("All history · text + media") { chooseExport(days: nil, media: true) }
                        }
                        .disabled(env.storageOperations.exporting)
                        Spacer()
                        Menu("Delete…") {
                            Button("Last 15 minutes") { confirmDelete = 15 * 60 }
                            Button("Last hour") { confirmDelete = 3_600 }
                            Button("Last 24 hours") { confirmDelete = 86_400 }
                            Divider()
                            Button("All history", role: .destructive) { confirmDelete = -1 }
                        }
                        .disabled(env.storageOperations.deleting)
                    }
                    if let result = env.storageOperations.exportResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var backupGroup: some View {
        @Bindable var backup = env.backupSettings
        return SettingsGroup("Backup") {
            if backup.iCloudAvailable {
                Toggle("iCloud database snapshots", isOn: $backup.enabled)
                HStack {
                    Button("Back up now") { Task { await backup.backupNow() } }
                        .disabled(backup.busy || !backup.enabled)
                    if backup.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    if let last = backup.lastBackupAt {
                        Text(last.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Snapshots include the database and index, not captured media. The live SQLite database never goes into iCloud Drive.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("iCloud Drive is unavailable. Local recording is unaffected.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var importGroup: some View {
        SettingsGroup("Import") {
            DisclosureGroup("Browser and prior history") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Import browser history", isOn: $browserHistoryEnabled)
                    Button(env.storageOperations.browserImporting ? "Importing browsers…" : "Import browsers now") {
                        startBrowserImport()
                    }
                    .disabled(!browserHistoryEnabled || env.storageOperations.browserImporting)
                    if let status = env.storageOperations.browserImportStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    if HistoryImporter.sourceExists {
                        Divider()
                        Button(env.storageOperations.importing ? "Importing prior history…" : "Import prior history") {
                            startHistoryImport()
                        }
                        .disabled(env.storageOperations.importing)
                        if let status = env.storageOperations.importStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var keepMediaConfirmationTitle: String {
        guard let confirmation = keepMediaConfirmation else { return "" }
        return "Keep only \(confirmation.policy.settingsLabel) of media?"
    }

    private func syncSlider() {
        sliderValue = Double(policies.firstIndex(of: env.storageSettings.keepMediaPolicy) ?? 0)
    }

    private func applyPolicy(
        _ policy: KeepMediaPolicy,
        confirmedRemovalBytes: Int64? = nil
    ) {
        guard !applyingPolicy else { return }
        applyingPolicy = true
        keepMediaError = nil
        Task {
            let result = await env.changeKeepMediaPolicy(
                policy,
                confirmedRemovalBytes: confirmedRemovalBytes
            )
            applyingPolicy = false
            switch result {
            case .applied:
                syncSlider()
            case .confirmationRequired(let confirmation):
                keepMediaConfirmation = confirmation
            case .unavailable(let error):
                keepMediaError = error
                syncSlider()
            }
        }
    }

    private func chooseRelocateFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Move here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await env.relocate(to: url) }
    }

    private func relocateToDefault() {
        Task {
            await env.relocate(to: StorageLocation.legacyRoot().deletingLastPathComponent())
        }
    }

    private func chooseExport(days: Int?, media: Bool) {
        guard let export = env.export else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export here"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let from = days.map {
            Calendar.current.startOfDay(
                for: Date().addingTimeInterval(-Double($0 - 1) * 86_400)
            )
        } ?? Date(timeIntervalSince1970: 0)
        env.storageOperations.startExport {
            do {
                let report = try await export.export(
                    from: from,
                    to: Date(),
                    into: destination,
                    includeMedia: media
                )
                var parts = ["Done", "\(report.days) days", "\(report.calls) calls"]
                if media { parts.append("\(report.mediaFiles) media files") }
                if report.mediaErrors > 0 {
                    parts.append("\(report.mediaErrors) copy errors")
                }
                return parts.joined(separator: " · ") + " · \(report.path)"
            } catch {
                return String(localized: "Export failed: \(error.localizedDescription)")
            }
        }
    }

    private var deleteTitle: String {
        guard let seconds = confirmDelete else { return "" }
        if seconds < 0 { return String(localized: "Delete ALL history? This is permanent.") }
        if seconds >= 86_400 { return String(localized: "Delete the last 24 hours permanently?") }
        if seconds >= 3_600 { return String(localized: "Delete the last hour permanently?") }
        return String(localized: "Delete the last 15 minutes permanently?")
    }

    private func startDelete() {
        let seconds = confirmDelete
        confirmDelete = nil
        env.storageOperations.startDelete {
            let report = await env.deleteHistory(
                lastSeconds: (seconds ?? 0) > 0 ? seconds : nil
            )
            guard let report else {
                return String(localized: "Couldn't delete. Check diagnostics and try again.")
            }
            return String(localized: "Deleted: moments \(report.framesDeleted), audio segments \(report.audioDeleted).")
        }
    }

    private func startHistoryImport() {
        guard let importer = env.historyImporter else { return }
        env.storageOperations.startImport { update in
            do {
                let report = try await importer.run { frames, audio in
                    Task { @MainActor in update("Moments \(frames) · audio \(audio)…") }
                }
                await env.storageSettings.refresh(storage: env.storage)
                await env.timelineStore?.load()
                return "Done · +\(report.frames) moments · +\(report.audio) audio"
            } catch {
                return "Import interrupted · \(error.localizedDescription)"
            }
        }
    }

    private func startBrowserImport() {
        env.storageOperations.startBrowserImport {
            guard let report = try? await env.browserHistoryImporter?.run() else {
                return String(localized: "Import failed")
            }
            return String(localized: "Imported \(report.imported) new visits from \(report.sources) browser(s)")
        }
    }
}

struct MCPToolsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var readiness: MCPReadinessState?
    @State private var profile = MCPAccessProfile.memoryReadOnly
    @State private var checking = false
    @State private var readinessCheckRevision: UInt64 = 0

    private var presentation: MCPSetupPresentation? {
        guard case .readyToConnect(let path) = readiness else { return nil }
        return try? MCPSetupPresentation(
            executableURL: URL(fileURLWithPath: path),
            profile: profile
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsGroup("MCP") {
                    readinessContent
                }
                SettingsGroup("Advanced") {
                    DisclosureGroup("Local REST API") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(env.server.baseURL).monospaced().textSelection(.enabled)
                            if let token = env.server.token {
                                Button("Copy bearer token") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(token, forType: .string)
                                }
                                Text("Use only for clients that cannot speak MCP. MCP setup never needs this token.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720)
        }
        .navigationTitle("MCP & AI Tools")
        .task(id: profile) { await checkReadiness(force: false) }
    }

    @ViewBuilder
    private var readinessContent: some View {
        if checking || readiness == nil {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking the installed helper…")
                    .foregroundStyle(.secondary)
            }
        } else if case .readyToConnect = readiness, let presentation {
            Label(presentation.statusLabel, systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(presentation.accessSummary)
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Access", selection: $profile) {
                Text("Memory · read only").tag(MCPAccessProfile.memoryReadOnly)
                Text("Advanced · full access").tag(MCPAccessProfile.advancedFull)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Text("Codex").font(.headline)
                CopyableSetupValue(value: presentation.codexCommand)
                Text("Claude Code").font(.headline)
                CopyableSetupValue(value: presentation.claudeCodeCommand)
                Text("Claude Desktop").font(.headline)
                CopyableSetupValue(value: presentation.claudeJSON)
                Text("Merge the zbs-eye entry into \(presentation.claudeDesktopConfigurationPath). Keep every MCP server already in that file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(presentation.restartInstruction)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if case .notReady(let failure) = readiness {
            Label("Not ready", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(failure.correctiveAction)
                .font(.callout)
            Button("Check again") { Task { await checkReadiness(force: true) } }
        }
    }

    private func checkReadiness(force: Bool) async {
        readinessCheckRevision &+= 1
        let revision = readinessCheckRevision
        checking = true
        let result = await env.mcpReadiness.check(profile: profile, force: force)
        guard !Task.isCancelled, readinessCheckRevision == revision else { return }
        readiness = result
        checking = false
    }
}

private struct CopyableSetupValue: View {
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct PermissionSettingsRow: View {
    let title: LocalizedStringKey
    let status: PermissionStatus
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status == .granted
                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status == .granted ? Color.green : Color.orange)
            Text(title)
            Spacer()
            switch status {
            case .granted:
                Text("Granted").foregroundStyle(.secondary)
            case .needsRestart:
                Button("Restart Eye") { try? AppRelauncher.relaunch() }
            case .denied:
                Button("Settings", action: openSettings)
            case .notDetermined:
                Button("Request", action: request).buttonStyle(.borderedProminent)
            }
        }
    }
}
