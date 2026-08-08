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

                captureRepairGroup
                audioGroup
                autoCallExclusionsGroup
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

    @ViewBuilder
    private var captureRepairGroup: some View {
        let presentation = CaptureRepairPresentation(snapshot: env.captureHealth)
        if presentation.state != .hidden {
            SettingsGroup("Capture") {
                HStack(spacing: 10) {
                    Image(systemName: presentation.state == .recovering
                          ? "arrow.triangle.2.circlepath"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(presentation.state == .recovering
                                         ? Color.secondary : Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.title)
                        if !presentation.affectedLabel.isEmpty {
                            Text(presentation.affectedLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let actionTitle = presentation.actionTitle {
                    Divider()
                    Button(actionTitle) {
                        Task { await env.repairCapture() }
                    }
                    .buttonStyle(.borderedProminent)
                    ForEach(presentation.guidance, id: \.self) { item in
                        Text("• \(item)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
            Text("Turn this off to keep ordinary playback out of Timeline. An automatically detected or manually started Call still records separate microphone and system tracks; Audio Off disables both.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        case .meetingsOnly: String(localized: "Eligible microphone use starts a Call even while screen recording is stopped. Audio Off or privacy pause disables it.")
        case .always: String(localized: "Audio follows recording continuously.")
        }
    }

    private var autoCallExclusionsGroup: some View {
        SettingsGroup("Don’t auto-record these apps") {
            Text("These apps can still appear in screen history. This list only prevents them from automatically starting a Call when they use the microphone.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if env.audioSettings.autoCallExcludedBundleIDs.isEmpty {
                Text("No excluded apps.")
                    .foregroundStyle(.secondary)
            } else {
                Divider()
                ForEach(env.audioSettings.autoCallExcludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Image(systemName: "mic.slash")
                        VStack(alignment: .leading) {
                            Text(env.audioSettings.autoCallExcludedDisplayNames[bundleID] ?? bundleID)
                            Text(bundleID).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            env.audioSettings.removeAutoCallExcludedApp(bundleID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Allow automatic Calls for \(bundleID)")
                    }
                }
            }
            Divider()
            Button("Add an app…") { env.audioSettings.addAutoCallExcludedAppViaPanel() }
        }
    }

    private var privacyGroup: some View {
        SettingsGroup("Private apps") {
            Text("Their screen and text aren't recorded. This setting does not change automatic Call recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
    @State private var pendingConsent: PendingConsent?
    @State private var activitySummaryRouteError: String?
    @State private var aiActionError: String?

    private enum PendingConsent: Identifiable {
        case automatic(AIConsumer)
        case activitySummary(provider: AIProvider, modelID: String)

        var id: String {
            switch self {
            case .automatic(let consumer):
                return "automatic:\(consumer.rawValue)"
            case .activitySummary(let provider, let modelID):
                return "activity-summary:\(provider.rawValue):\(modelID)"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsGroup("Primary AI") {
                    HStack(spacing: 12) {
                        Image(systemName: env.ai.selectionSnapshot == nil
                              ? "pause.circle" : "checkmark.circle.fill")
                            .foregroundStyle(env.ai.selectionSnapshot == nil
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
                    if env.ai.selectionSnapshot != nil || activitySummaryRouteIsActive {
                        Button("Turn AI off", role: .destructive) {
                            let acknowledged = env.ai.deactivateAll()
                            aiActionError = acknowledged
                                ? nil
                                : env.ai.persistenceWarning ?? String(
                                    localized: "Eye couldn't confirm the saved AI setting. Try again."
                                )
                            activitySummaryRouteDidChange()
                        }
                    }
                    if let warning = aiActionError ?? env.ai.persistenceWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                SettingsGroup("Activity summaries") {
                    HStack(spacing: 12) {
                        Image(systemName: activitySummaryRouteIsActive
                              ? "text.page.fill" : "text.page")
                            .foregroundStyle(activitySummaryRouteIsActive
                                             ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activitySummaryRouteLabel).font(.headline)
                            Text("Show a factual 3–6 item recap at the top of Activities. This can use a separate model without changing Ask.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Divider()
                    if env.ai.activitySummaryRouteCandidates.isEmpty {
                        Text("Connect and check a provider above before choosing an Activity summary model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Add or check a provider…") {
                            env.aiSetup.present(origin: .settings)
                        }
                    } else {
                        activitySummaryModelMenu
                    }
                    if activitySummaryRouteIsActive {
                        Button("Turn Activity summaries off", role: .destructive) {
                            let acknowledged = env.ai.disableActivitySummaryRoute()
                            activitySummaryRouteError = acknowledged
                                ? nil
                                : env.ai.persistenceWarning ?? String(
                                    localized: "Eye couldn't confirm the saved Activity summaries setting. Try again."
                                )
                            activitySummaryRouteDidChange()
                        }
                    }
                    if let activitySummaryRouteError {
                        Text(activitySummaryRouteError)
                            .font(.caption)
                            .foregroundStyle(.red)
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
                get: { pendingConsent != nil },
                set: { if !$0 { pendingConsent = nil } }
            ),
            presenting: pendingConsent
        ) { pending in
            Button("Allow") {
                commitConsent(pending)
            }
            Button("Cancel", role: .cancel) { pendingConsent = nil }
        } message: { pending in
            Text(consentMessage(for: pending))
        }
    }

    private var activeLabel: String {
        AISetupPresentation.activeLabel(
            provider: env.ai.selectionSnapshot.flatMap {
                AIProvider(rawValue: $0.providerID)
            },
            modelID: env.ai.selectionSnapshot?.modelID
        )
    }

    private var activitySummaryRouteIsActive: Bool {
        !env.ai.allProcessingDisabledByUser && env.ai.activitySummaryRoute.enabled
    }

    private var activitySummaryRouteLabel: String {
        let route = env.ai.activitySummaryRoute
        guard activitySummaryRouteIsActive,
              let providerID = route.providerID,
              let provider = AIProvider(rawValue: providerID),
              let modelID = route.modelID else {
            return String(localized: "Activity summaries are off")
        }
        return "\(provider.displayName) · \(modelID)"
    }

    private var activitySummaryModelMenu: some View {
        Menu {
            ForEach(env.ai.activitySummaryRouteCandidates) { candidate in
                Menu(candidate.provider.displayName) {
                    let recommended = candidate.provider.recommendedModel(in: candidate.modelIDs)
                    ForEach(candidate.modelIDs, id: \.self) { modelID in
                        Button {
                            chooseActivitySummaryRoute(
                                provider: candidate.provider,
                                modelID: modelID
                            )
                        } label: {
                            if recommended == modelID {
                                Label("\(modelID) — Recommended", systemImage: "sparkles")
                            } else {
                                Text(modelID)
                            }
                        }
                    }
                }
            }
        } label: {
            Label(
                activitySummaryRouteIsActive
                    ? String(localized: "Change model…")
                    : String(localized: "Choose model…"),
                systemImage: "cpu"
            )
        }
    }

    private func chooseActivitySummaryRoute(provider: AIProvider, modelID: String) {
        activitySummaryRouteError = nil
        if provider.isCloud,
           !env.ai.hasConsent(provider, for: .activitySummary) {
            pendingConsent = .activitySummary(provider: provider, modelID: modelID)
            return
        }
        guard env.ai.commitActivitySummaryRoute(provider: provider, modelID: modelID) else {
            activitySummaryRouteError = String(
                localized: "That model is no longer available. Check the provider and try again."
            )
            return
        }
        activitySummaryRouteDidChange()
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
                    pendingConsent = .automatic(consumer)
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

    private func commitConsent(_ pending: PendingConsent) {
        switch pending {
        case .automatic(let consumer):
            guard let provider = env.ai.activeProvider else { break }
            _ = env.ai.setAutomaticConsumerConsent(consumer, enabled: true, for: provider)
        case .activitySummary(let provider, let modelID):
            if env.ai.commitActivitySummaryRoute(
                provider: provider,
                modelID: modelID,
                grantCloudConsent: true
            ) {
                activitySummaryRouteDidChange()
            } else {
                activitySummaryRouteError = String(
                    localized: "That model is no longer available. Check the provider and try again."
                )
            }
        }
        pendingConsent = nil
    }

    private func consentMessage(for pending: PendingConsent) -> String {
        let provider: AIProvider?
        let purpose: String
        switch pending {
        case .automatic(let consumer):
            provider = env.ai.activeProvider
            purpose = consumer == .scheduledSummary
                ? String(localized: "scheduled summaries")
                : String(localized: "activity labels")
        case .activitySummary(let selectedProvider, _):
            provider = selectedProvider
            purpose = String(localized: "activity summaries")
        }
        let recipient = provider
            .flatMap { env.ai.recipientDisclosure(for: $0) }
            ?? String(localized: "the selected cloud provider")
        return String(localized: "ZBS Eye will automatically send only the bounded text excerpts needed for \(purpose) to \(recipient). Raw screenshots, audio, full URLs, and file paths are not sent.")
    }

    private func activitySummaryRouteDidChange() {
        guard let store = env.activityDaySummaryStore else { return }
        let day = store.selectedDay
        store.reset()
        Task { await store.load(day: day) }
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
                Text("Hermes").font(.headline)
                CopyableSetupValue(value: presentation.hermesCommand)
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
