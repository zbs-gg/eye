import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled
    @State private var confirmDelete: TimeInterval?   // seconds; -1 = everything
    @State private var deleting = false
    @State private var deleteOutcome: String?          // delete report/error — via alert
    @State private var exporting = false
    @State private var exportResult: String?
    @State private var importing = false
    @State private var importStatus: String?
    @State private var pendingLang: AppLanguage?
    @AppStorage("zbseye.browserHistory.enabled") private var browserHistoryEnabled = true
    @State private var browserImportStatus: String?
    @State private var problemText = ""
    @State private var repairCopied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings").font(.largeTitle.bold())
                permissionsCard
                languageCard
                launchCard
                storageCard
                backupCard
                privacyCard
                browserHistoryCard
                if HistoryImporter.sourceExists { importCard }
                transcriptionCard
                serverCard
                supportCard
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task {
            await env.permissions.refreshAll()
            await env.audioSettings.refreshHealth(env.audio)
        }
        .confirmationDialog("Restart ZBS Eye to change the language?",
                            isPresented: Binding(get: { pendingLang != nil },
                                                 set: { if !$0 { pendingLang = nil } }),
                            titleVisibility: .visible) {
            Button("Restart now") { if let l = pendingLang { LanguageManager.set(l) } }
            Button("Cancel", role: .cancel) { pendingLang = nil }
        } message: {
            Text("The interface language is applied after a restart.")
        }
    }

    private var languageCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Language").font(.headline)
                Picker("Interface language", selection: Binding(
                    get: { LanguageManager.current },
                    set: { if $0 != LanguageManager.current { pendingLang = $0 } })) {
                    Text("System").tag(AppLanguage.system)
                    Text(verbatim: "English").tag(AppLanguage.en)
                    Text(verbatim: "Русский").tag(AppLanguage.ru)
                }
                Text("Changing the language restarts ZBS Eye.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var permissionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Permissions and diagnostics").font(.headline)
                Text("ZBS Eye reads the screen via Accessibility (precise and easy on the battery), OCR — only where AX is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)

                PermissionRow(title: "Screen Recording",
                              status: env.permissions.snapshot.screenRecording,
                              request: { PermissionChecker.requestScreenRecording() },
                              openSettings: { PermissionChecker.openSettings("Privacy_ScreenCapture") })
                PermissionRow(title: "Accessibility",
                              status: env.permissions.snapshot.accessibility,
                              request: { PermissionChecker.requestAccessibility() },
                              openSettings: { PermissionChecker.openSettings("Privacy_Accessibility") })
                PermissionRow(title: "Microphone",
                              status: env.permissions.snapshot.microphone,
                              request: { Task { await env.permissions.requestMicrophone() } },
                              openSettings: { PermissionChecker.openSettings("Privacy_Microphone") })
                PermissionRow(title: "Speech Recognition (for audio search)",
                              status: env.permissions.snapshot.speech,
                              request: { Task { await env.permissions.requestSpeech() } },
                              openSettings: { PermissionChecker.openSettings("Privacy_SpeechRecognition") })

                Button("Re-check") {
                    Task { await env.permissions.refreshAll() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var launchCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Launch").font(.headline)
                Toggle("Launch ZBS Eye at login", isOn: $loginItemEnabled)
                    .onChange(of: loginItemEnabled) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            // registration failed (for example, disabled in System Settings) — roll back the UI
                            loginItemEnabled = SMAppService.mainApp.status == .enabled
                        }
                    }
                Text("Eternal memory lives as long as ZBS Eye is running: together with recording autostart this covers "
                     + "reboots and crashes. Also managed in System Settings → General → Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var storageCard: some View {
        @Bindable var st = env.storageSettings
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Storage").font(.headline)
                HStack {
                    Text("Used")
                    Spacer()
                    Text("\(StorageSettingsStore.format(st.mediaBytes)) media + \(StorageSettingsStore.format(st.databaseBytes)) index")
                        .foregroundStyle(.secondary).font(.callout)
                    if let dir = env.storage?.mediaDirectory {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([dir]) } label: {
                            Image(systemName: "folder")
                        }.buttonStyle(.borderless).help("Show in Finder")
                    }
                }
                Divider()
                HStack {
                    Text("Data folder")
                    Spacer()
                    Text(st.dataRootDisplay)
                        .foregroundStyle(.secondary).font(.callout)
                        .lineLimit(1).truncationMode(.middle)
                }
                if st.relocationInProgress {
                    HStack(spacing: 10) {
                        ProgressView(value: st.relocationProgress).frame(maxWidth: 180)
                        Text(st.relocationStatus).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        Button("Move…") { chooseRelocateFolder() }
                        if st.isRelocated {
                            Button("Return to the default folder") { relocateToLegacy() }
                                .buttonStyle(.link)
                        }
                        Spacer()
                    }
                    Text("Moves all of memory (database + media) to the chosen folder, for example an external SSD. "
                         + "The old location isn't deleted until you confirm. The app will restart.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let err = st.relocationError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if let bd = st.breakdown {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("Frames").foregroundStyle(.secondary)
                            Text("\(bd.framesTotal)  ·  live \(bd.framesLive), imported \(bd.framesImport)")
                        }
                        GridRow {
                            Text("Audio").foregroundStyle(.secondary)
                            Text("\(bd.audioTotal)")
                        }
                        if let o = bd.oldestTs, let n = bd.newestTs {
                            GridRow {
                                Text("Period").foregroundStyle(.secondary)
                                Text("\(Date(timeIntervalSince1970: Double(o)/1000).formatted(date: .abbreviated, time: .omitted)) — \(Date(timeIntervalSince1970: Double(n)/1000).formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                        GridRow {
                            Text("Free on disk").foregroundStyle(.secondary)
                            Text(StorageSettingsStore.format(st.freeBytes))
                        }
                    }
                    .font(.callout)
                    if !bd.topApps.isEmpty {
                        Text("Most of all: " + bd.topApps.prefix(4).map { "\($0.name) (\($0.frames))" }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Keep history", selection: $st.retentionDays) {
                    ForEach(StorageSettingsStore.dayOptions, id: \.self) { d in
                        Text(d == 0 ? "Forever" : "\(d) d.").tag(d)
                    }
                }
                Picker("Media limit", selection: $st.maxGB) {
                    ForEach(StorageSettingsStore.gbOptions, id: \.self) { g in
                        Text(g == 0 ? "No limit" : "\(g) GB").tag(g)
                    }
                }
                Text("Old data is deleted automatically when the limit is exceeded (every 30 minutes). The limit covers frames and audio; "
                     + "the search index grows separately and is cleaned along with history. \"Forever\" — at your own risk: the disk is finite.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Delete from memory").font(.callout)
                    Spacer()
                    Menu("Delete…") {
                        Button("Last 15 minutes") { confirmDelete = 15 * 60 }
                        Button("Last hour") { confirmDelete = 3600 }
                        Button("Last 24 hours") { confirmDelete = 86_400 }
                        Divider()
                        Button("All history", role: .destructive) { confirmDelete = -1 }
                    }
                    .fixedSize()
                }
                Text("An accidentally recorded password or a sensitive conversation can be wiped forever (files, text, indexes).")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Export").font(.callout)
                    Spacer()
                    if exporting { ProgressView().controlSize(.small) }
                    Menu("Export…") {
                        Button("Today (markdown)") { runExport(days: 1, media: false) }
                        Button("Today (markdown + media)") { runExport(days: 1, media: true) }
                        Divider()
                        Button("All history (markdown)") { runExport(days: nil, media: false) }
                        Button("All history (markdown + media)") { runExport(days: nil, media: true) }
                    }
                    .fixedSize()
                    .disabled(exporting)
                }
                Text("Take your memory with you: markdown by day (activity + conversations), optionally frames and audio.")
                    .font(.caption).foregroundStyle(.secondary)
                if let r = exportResult {
                    Label(r, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                let seconds = confirmDelete
                confirmDelete = nil
                Task {
                    deleting = true
                    let r = await env.deleteHistory(lastSeconds: (seconds ?? 0) > 0 ? seconds : nil)
                    deleting = false
                    // a failed "wipe forever" must not be indistinguishable from success
                    deleteOutcome = r.map { "Deleted: frames \($0.framesDeleted), audio segments \($0.audioDeleted)." }
                        ?? "Couldn't delete — history is untouched or only partially touched. Try again."
                }
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        }
        .alert("History deletion", isPresented: Binding(get: { deleteOutcome != nil },
                                                        set: { if !$0 { deleteOutcome = nil } })) {
            Button("OK") { deleteOutcome = nil }
        } message: {
            Text(deleteOutcome ?? "")
        }
        .overlay(alignment: .topTrailing) {
            if deleting { ProgressView().controlSize(.small).padding() }
        }
        .task {
            env.backupSettings.refresh()
            await env.storageSettings.refresh(storage: env.storage, db: env.db)
        }
    }

    /// Export: choose a folder → ExportService. days=nil → all history.
    private func runExport(days: Int?, media: Bool) {
        guard let export = env.export else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export here"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        exporting = true
        exportResult = nil
        let from: Date
        if let days {
            from = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(days - 1) * 86_400))
        } else {
            from = Date(timeIntervalSince1970: 0)
        }
        Task {
            let report = try? await export.export(from: from, to: Date(), into: dest, includeMedia: media)
            exporting = false
            exportResult = report.map {
                var s = "Done: \($0.days) d." + (media ? ", \($0.mediaFiles) media files" : "")
                if $0.mediaErrors > 0 { s += ", copy errors: \($0.mediaErrors)" }
                return s + " → \($0.path)"
            } ?? "Export failed"
        }
    }

    private var deleteTitle: String {
        guard let s = confirmDelete else { return "" }
        if s < 0 { return "Delete ALL history? This is permanent." }
        let label = s >= 86_400 ? "the last 24 hours" : (s >= 3600 ? "the last hour" : "the last 15 minutes")
        return "Delete \(label) of history? This is permanent."
    }
    private var deleteBinding: Binding<Bool> {
        Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
    }

    private func chooseRelocateFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Move here"
        panel.message = "Choose a folder for your \"eternal memory\" (a ZBS Eye subfolder will be created). The app will restart."
        if panel.runModal() == .OK, let url = panel.url {
            Task { await env.relocate(to: url) }
        }
    }

    private func relocateToLegacy() {
        Task { await env.relocate(to: StorageLocation.legacyRoot().deletingLastPathComponent()) }
    }

    private var backupCard: some View {
        @Bindable var bk = env.backupSettings
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("iCloud backup").font(.headline)
                    Spacer()
                    if bk.busy { ProgressView().controlSize(.small) }
                }
                if bk.iCloudAvailable {
                    Toggle("Auto-backup to iCloud Drive", isOn: $bk.enabled)
                    Text("A compressed snapshot of memory (database, text, search index — without the HEIC media) goes to "
                         + "iCloud Drive every 6 hours and on exit. The live database stays local — it must not be placed in "
                         + "iCloud Drive (corruption).")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Keep copies", selection: $bk.keepN) {
                        ForEach(BackupSettingsStore.keepOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                    HStack {
                        Button("Back up now") { Task { await bk.backupNow() } }
                            .disabled(bk.busy || !bk.enabled)
                        Spacer()
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([BackupManager.backupsDirectory()])
                        } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Backups folder in Finder")
                    }
                    if let last = bk.lastBackupAt {
                        Text("Last: \(last.formatted(date: .abbreviated, time: .shortened))"
                             + (bk.lastResult.map { " · \($0)" } ?? "") + " · copies: \(bk.backupCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let err = bk.error {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                } else {
                    Text("iCloud Drive is off or not signed in. Turn on iCloud Drive in System Settings — "
                         + "and memory will start backing up to the cloud automatically (compressed, without uploading the live database).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var importCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Import prior history").font(.headline)
                Text("Prior history found (~/.screenpipe). It will move text and metadata (frames, "
                     + "windows, URLs, transcripts with speakers) into ZBS Eye's memory — search will work across all "
                     + "your old history. Media files stay where they are. You can interrupt and continue later.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        runImport()
                    } label: {
                        Label(importing ? "Importing…" : "Import", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importing)
                    if importing { ProgressView().controlSize(.small) }
                    if let s = importStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func runImport() {
        guard let importer = env.historyImporter else { return }
        importing = true
        importStatus = nil
        Task {
            do {
                let report = try await importer.run { f, a in
                    Task { @MainActor in
                        importStatus = "frames \(f), audio \(a)…"
                    }
                }
                importStatus = "Done: +\(report.frames) frames, +\(report.audio) audio. Semantics are indexing in the background."
                await env.storageSettings.refresh(storage: env.storage, db: env.db)
                await env.timelineStore?.load()
            } catch {
                importStatus = "Import interrupted: \(error.localizedDescription)"
            }
            importing = false
        }
    }

    private var privacyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Privacy").font(.headline)
                Text("By default ZBS Eye records everything. Exclude apps that shouldn't end up "
                     + "in memory (password manager, bank) — their windows are cut out of frames and text. "
                     + "AUDIO is not silenced by an exclusion (it isn't tied to windows): for a sensitive conversation "
                     + "use \"Don't record for 15 minutes\" in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
                if env.privacy.ignoredBundleIds.isEmpty {
                    Text("No exclusions.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(env.privacy.ignoredBundleIds, id: \.self) { id in
                        HStack {
                            Image(systemName: "eye.slash").foregroundStyle(.secondary)
                            Text(env.privacy.displayNames[id] ?? id)
                            Text(id).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button { env.privacy.remove(id) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Button {
                    env.privacy.addAppViaPanel()
                } label: {
                    Label("Exclude an app…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var browserHistoryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Browser history").font(.headline)
                Toggle("Import browser history", isOn: $browserHistoryEnabled)
                Text("Pulls the real URLs and visit times from your browsers' own history "
                     + "(Dia, Arc, Chrome, Edge, Brave, Safari). Dia and Arc don't expose the URL on screen, so "
                     + "this is the only way to attribute and search them. On-device only — nothing leaves your "
                     + "Mac. Safari needs Full Disk Access.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Import now") {
                        browserImportStatus = "Importing…"
                        Task {
                            guard let r = try? await env.browserHistoryImporter?.run() else {
                                browserImportStatus = "Import failed"; return
                            }
                            var msg = "Imported \(r.imported) new visits from \(r.sources) browser(s)"
                            if let first = r.errors.first { msg += " · " + first }
                            browserImportStatus = msg
                        }
                    }
                    .font(.callout)
                    .disabled(!browserHistoryEnabled || env.recording.pausedUntil != nil)
                    if let s = browserImportStatus {
                        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }

    private var supportCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Something not working?").font(.headline)
                Text("ZBS Eye is open to read and yours to fix. Describe what's wrong — Eye collects the "
                     + "diagnostics and hands your own AI agent a ready-to-run repair prompt (it reads the "
                     + "source and fixes it). If that doesn't do it, file a GitHub issue with one click.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("What went wrong? (e.g. audio doesn't record during calls)",
                          text: $problemText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .onChange(of: problemText) { _, _ in repairCopied = false }
                HStack(spacing: 10) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(buildRepairPrompt(), forType: .string)
                        repairCopied = true
                    } label: {
                        Label(repairCopied ? "Copied — paste into your agent" : "Ask your agent to fix it",
                              systemImage: repairCopied ? "checkmark" : "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { openGitHubIssue() } label: {
                        Label("Open a GitHub issue", systemImage: "ladybug")
                    }
                }
                .font(.callout)
            }
        }
    }

    /// A ready-to-paste prompt for the user's own coding agent (Claude Code / Codex): read the public
    /// source, reproduce, fix. Includes auto-collected on-device diagnostics + the user's description.
    private func buildRepairPrompt() -> String {
        """
        You are my coding agent. Something isn't working in ZBS Eye — a local macOS app I run. The full \
        source is public: https://github.com/zbs-gg/eye . Please read the repo, reproduce, and fix it.

        ## What's wrong (my words)
        \(problemText.isEmpty ? "(describe the problem here)" : problemText)

        ## Diagnostics (auto-collected, on-device)
        \(diagnosticsBlock())

        ## Do this
        1. Open github.com/zbs-gg/eye — read README.md, AGENTS.md, BUILD.md (written for agents).
        2. Reproduce and fix the issue above. Keep it local-first (no cloud/egress), Swift 6 strict concurrency.
        3. Rebuild: `bash scripts/build-notarized.sh` (or `scripts/build-release.sh` for a self-signed dev build).
        4. If you can't fix it, open a GitHub issue at github.com/zbs-gg/eye/issues/new with this whole message.
        """
    }

    private func diagnosticsBlock() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let p = env.permissions.snapshot
        let rec = env.recording
        return """
        - App: ZBS Eye \(v) · \(ProcessInfo.processInfo.operatingSystemVersionString)
        - Permissions: screen=\(p.screenRecording) accessibility=\(p.accessibility) mic=\(p.microphone) speech=\(p.speech)
        - Recording: capturing=\(rec.isCapturing) blocked=\(rec.blockedReason ?? "—") degraded=\(rec.degradedReason ?? "—")
        - Audio mode: \(env.audioSettings.audioMode.rawValue) · frames this session: \(rec.screenFrameCount)
        """
    }

    private func openGitHubIssue() {
        let title = problemText.isEmpty ? "Bug report" : String(problemText.prefix(70))
        let body = "## What's wrong\n\(problemText)\n\n## Diagnostics\n\(diagnosticsBlock())"
        var comps = URLComponents(string: "https://github.com/zbs-gg/eye/issues/new")!
        comps.queryItems = [.init(name: "title", value: title), .init(name: "body", value: body)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    private var transcriptionCard: some View {
        @Bindable var settings = env.audioSettings
        let audioCaption: String = switch settings.audioMode {
        case .off:
            "Audio is never recorded (the screen still is). Transcription and audio search are off."
        case .meetingsOnly:
            "Records audio only during detected calls/meetings — the engine is fully off otherwise, "
            + "so no files and no disk are used. On-device (Apple Speech, ru+en); VAD cuts silence; nothing goes to the cloud."
        case .always:
            "Records audio continuously while recording is on. On-device (Apple Speech, ru+en); "
            + "VAD cuts silence; nothing goes to the cloud."
        }
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Audio and transcription").font(.headline)
                Picker("Audio capture", selection: $settings.audioMode) {
                    ForEach(AudioMode.allCases, id: \.self) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: settings.audioMode) { _, _ in
                    settings.migrationNudgeSeen = true
                    env.recording.syncAudio()
                }
                Text(audioCaption)
                    .font(.caption).foregroundStyle(.secondary)
                if !settings.migrationNudgeSeen {
                    Label("New: audio now records only during calls by default — to save disk. Choose “Always” for continuous, or “Off” for none.",
                          systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                }
                if settings.audioMode != .off {
                    Toggle("Record system audio (calls, video, meetings)", isOn: $settings.recordSystemAudio)
                        .onChange(of: settings.recordSystemAudio) { _, _ in env.recording.syncAudio() }
                        .font(.callout)
                    Text("System audio — the other people's voices and anything playing (only needs Screen "
                         + "Recording access). The microphone — your voice. You can record one without the other.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if settings.recordSystemAudio {
                        Label("System audio is NOT highlighted by the orange macOS indicator (it goes through Screen "
                              + "Recording, not the microphone). Recording other people is your responsibility.",
                              systemImage: "exclamationmark.shield").font(.caption2).foregroundStyle(.secondary)
                    }

                    if env.permissions.snapshot.speech != .granted {
                        Label("No speech recognition — audio is recorded, but without text for search (you'll find it by time and play it back).",
                              systemImage: "exclamationmark.bubble").font(.caption).foregroundStyle(.orange)
                    }
                    if env.permissions.snapshot.microphone != .granted {
                        Label("No microphone access — only system audio is recorded.",
                              systemImage: "mic.slash").font(.caption).foregroundStyle(.orange)
                    }
                    if settings.micEngineFailed {
                        Label("The microphone didn't start (the device was unavailable at the last launch).",
                              systemImage: "mic.slash.fill").font(.caption).foregroundStyle(.orange)
                    }
                    if settings.systemEngineFailed {
                        Label("System audio didn't start — check Screen Recording access.",
                              systemImage: "speaker.slash.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                if let h = settings.health, h.failed > 0, h.transcribed == 0,
                   h.lastErrorKind == "onDeviceUnavailable" {
                    Label("Recognition isn't working: no on-device ru-RU model. Turn on Dictation in "
                          + "System Settings → Keyboard → Dictation. Audio is recorded, but without text.",
                          systemImage: "waveform.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var serverCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Local API").font(.headline)
                HStack {
                    Text("Address")
                    Spacer()
                    Text(env.server.baseURL).foregroundStyle(.secondary).monospaced().textSelection(.enabled)
                }
                if let token = env.server.token {
                    HStack {
                        Text("Token")
                        Spacer()
                        Text(token.prefix(14) + "…").monospaced().foregroundStyle(.secondary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy token")
                    }
                    Text("curl -H 'Authorization: Bearer <token>' '\(env.server.baseURL)/v1/search?q=test'")
                        .font(.caption2).monospaced().foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2)
                } else {
                    Text("Server is starting…").font(.caption).foregroundStyle(.secondary)
                }
                Text("Auth on everything except /health (token in Keychain), bind 127.0.0.1. MCP — the next step.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let status: PermissionStatus
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(status == .granted ? Color.green : Color.orange)
            Text(title)
            Spacer()
            switch status {
            case .granted:
                StatusPill(text: "Granted", color: .green)
            case .needsRestart:
                // permission granted, but TCC will apply it only to a new process (-3801)
                StatusPill(text: "Restart needed", color: .orange)
                Button("Restart ZBS Eye") { AppRelauncher.relaunch() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .denied:
                StatusPill(text: "No access", color: .red)
                Button("Settings", action: openSettings).buttonStyle(.borderless)
            case .notDetermined:
                Button("Request", action: request)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }
}
