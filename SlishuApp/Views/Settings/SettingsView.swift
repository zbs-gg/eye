import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled
    @State private var confirmDelete: TimeInterval?   // секунды; -1 = всё
    @State private var deleting = false
    @State private var deleteOutcome: String?          // отчёт/ошибка удаления — алертом
    @State private var exporting = false
    @State private var exportResult: String?
    @State private var importing = false
    @State private var importStatus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Настройки").font(.largeTitle.bold())
                permissionsCard
                launchCard
                storageCard
                backupCard
                privacyCard
                if ScreenpipeImporter.sourceExists { importCard }
                transcriptionCard
                serverCard
            }
            .padding(28)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .task {
            await env.permissions.refreshAll()
            await env.audioSettings.refreshHealth(env.audio)
        }
    }

    private var permissionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Разрешения и диагностика").font(.headline)
                Text("Slishu читает экран через Accessibility (точно и легко для батареи), OCR — только где AX недоступен.")
                    .font(.caption).foregroundStyle(.secondary)

                PermissionRow(title: "Запись экрана",
                              status: env.permissions.snapshot.screenRecording,
                              request: { PermissionChecker.requestScreenRecording() },
                              openSettings: { PermissionChecker.openSettings("Privacy_ScreenCapture") })
                PermissionRow(title: "Универсальный доступ (Accessibility)",
                              status: env.permissions.snapshot.accessibility,
                              request: { PermissionChecker.requestAccessibility() },
                              openSettings: { PermissionChecker.openSettings("Privacy_Accessibility") })
                PermissionRow(title: "Микрофон",
                              status: env.permissions.snapshot.microphone,
                              request: { Task { await env.permissions.requestMicrophone() } },
                              openSettings: { PermissionChecker.openSettings("Privacy_Microphone") })
                PermissionRow(title: "Распознавание речи (для аудио-поиска)",
                              status: env.permissions.snapshot.speech,
                              request: { Task { await env.permissions.requestSpeech() } },
                              openSettings: { PermissionChecker.openSettings("Privacy_SpeechRecognition") })

                Button("Повторить проверку") {
                    Task { await env.permissions.refreshAll() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var launchCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Запуск").font(.headline)
                Toggle("Запускать Slishu при входе в систему", isOn: $loginItemEnabled)
                    .onChange(of: loginItemEnabled) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            // регистрация не удалась (например, выключено в Системных настройках) — откат UI
                            loginItemEnabled = SMAppService.mainApp.status == .enabled
                        }
                    }
                Text("Вечная память живёт, пока Slishu запущен: вместе с автостартом записи это закрывает "
                     + "ребуты и краши. Управляется и в Системных настройках → Основные → Объекты входа.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var storageCard: some View {
        @Bindable var st = env.storageSettings
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Хранилище").font(.headline)
                HStack {
                    Text("Занято")
                    Spacer()
                    Text("\(StorageSettingsStore.format(st.mediaBytes)) медиа + \(StorageSettingsStore.format(st.databaseBytes)) индекс")
                        .foregroundStyle(.secondary).font(.callout)
                    if let dir = env.storage?.mediaDirectory {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([dir]) } label: {
                            Image(systemName: "folder")
                        }.buttonStyle(.borderless).help("Показать в Finder")
                    }
                }
                Divider()
                HStack {
                    Text("Папка данных")
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
                        Button("Переместить…") { chooseRelocateFolder() }
                        if st.isRelocated {
                            Button("Вернуть в стандартную папку") { relocateToLegacy() }
                                .buttonStyle(.link)
                        }
                        Spacer()
                    }
                    Text("Перенесёт всю память (база + медиа) в выбранную папку, например на внешний SSD. "
                         + "Старое место не удаляется до подтверждения. Приложение перезапустится.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let err = st.relocationError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                if let bd = st.breakdown {
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("Кадры").foregroundStyle(.secondary)
                            Text("\(bd.framesTotal)  ·  живых \(bd.framesLive), импорт \(bd.framesImport)")
                        }
                        GridRow {
                            Text("Аудио").foregroundStyle(.secondary)
                            Text("\(bd.audioTotal)")
                        }
                        if let o = bd.oldestTs, let n = bd.newestTs {
                            GridRow {
                                Text("Период").foregroundStyle(.secondary)
                                Text("\(Date(timeIntervalSince1970: Double(o)/1000).formatted(date: .abbreviated, time: .omitted)) — \(Date(timeIntervalSince1970: Double(n)/1000).formatted(date: .abbreviated, time: .omitted))")
                            }
                        }
                        GridRow {
                            Text("Свободно на диске").foregroundStyle(.secondary)
                            Text(StorageSettingsStore.format(st.freeBytes))
                        }
                    }
                    .font(.callout)
                    if !bd.topApps.isEmpty {
                        Text("Больше всего: " + bd.topApps.prefix(4).map { "\($0.name) (\($0.frames))" }.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Хранить историю", selection: $st.retentionDays) {
                    ForEach(StorageSettingsStore.dayOptions, id: \.self) { d in
                        Text(d == 0 ? "Вечно" : "\(d) дн.").tag(d)
                    }
                }
                Picker("Лимит медиа", selection: $st.maxGB) {
                    ForEach(StorageSettingsStore.gbOptions, id: \.self) { g in
                        Text(g == 0 ? "Без лимита" : "\(g) ГБ").tag(g)
                    }
                }
                Text("Старое удаляется автоматически при превышении (раз в 30 минут). Лимит — для кадров и аудио; "
                     + "поисковый индекс растёт отдельно и чистится вместе с историей. «Вечно» — на свой страх: диск конечен.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Удалить из памяти").font(.callout)
                    Spacer()
                    Menu("Удалить…") {
                        Button("Последние 15 минут") { confirmDelete = 15 * 60 }
                        Button("Последний час") { confirmDelete = 3600 }
                        Button("Последние 24 часа") { confirmDelete = 86_400 }
                        Divider()
                        Button("Всю историю", role: .destructive) { confirmDelete = -1 }
                    }
                    .fixedSize()
                }
                Text("Случайно записанный пароль или чувствительный разговор можно стереть навсегда (файлы, текст, индексы).")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                HStack {
                    Text("Экспорт").font(.callout)
                    Spacer()
                    if exporting { ProgressView().controlSize(.small) }
                    Menu("Экспортировать…") {
                        Button("Сегодня (markdown)") { runExport(days: 1, media: false) }
                        Button("Сегодня (markdown + медиа)") { runExport(days: 1, media: true) }
                        Divider()
                        Button("Вся история (markdown)") { runExport(days: nil, media: false) }
                        Button("Вся история (markdown + медиа)") { runExport(days: nil, media: true) }
                    }
                    .fixedSize()
                    .disabled(exporting)
                }
                Text("Забрать память с собой: markdown по дням (активность + разговоры), опционально кадры и аудио.")
                    .font(.caption).foregroundStyle(.secondary)
                if let r = exportResult {
                    Label(r, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                }
            }
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
            Button("Удалить безвозвратно", role: .destructive) {
                let seconds = confirmDelete
                confirmDelete = nil
                Task {
                    deleting = true
                    let r = await env.deleteHistory(lastSeconds: (seconds ?? 0) > 0 ? seconds : nil)
                    deleting = false
                    // провал «стереть навсегда» не должен быть неотличим от успеха
                    deleteOutcome = r.map { "Удалено: кадров \($0.framesDeleted), аудио-сегментов \($0.audioDeleted)." }
                        ?? "Не удалось удалить — история не тронута или тронута частично. Попробуй ещё раз."
                }
            }
            Button("Отмена", role: .cancel) { confirmDelete = nil }
        }
        .alert("Удаление истории", isPresented: Binding(get: { deleteOutcome != nil },
                                                        set: { if !$0 { deleteOutcome = nil } })) {
            Button("Ок") { deleteOutcome = nil }
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

    /// Экспорт: выбор папки → ExportService. days=nil → вся история.
    private func runExport(days: Int?, media: Bool) {
        guard let export = env.export else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Экспортировать сюда"
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
                var s = "Готово: \($0.days) дн." + (media ? ", \($0.mediaFiles) медиа-файлов" : "")
                if $0.mediaErrors > 0 { s += ", ошибок копирования: \($0.mediaErrors)" }
                return s + " → \($0.path)"
            } ?? "Экспорт не удался"
        }
    }

    private var deleteTitle: String {
        guard let s = confirmDelete else { return "" }
        if s < 0 { return "Удалить ВСЮ историю? Это безвозвратно." }
        let label = s >= 86_400 ? "последние 24 часа" : (s >= 3600 ? "последний час" : "последние 15 минут")
        return "Удалить \(label) истории? Это безвозвратно."
    }
    private var deleteBinding: Binding<Bool> {
        Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })
    }

    private func chooseRelocateFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Перенести сюда"
        panel.message = "Выбери папку для «вечной памяти» (создастся подпапка Slishu). Приложение перезапустится."
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
                    Text("Бэкап в iCloud").font(.headline)
                    Spacer()
                    if bk.busy { ProgressView().controlSize(.small) }
                }
                if bk.iCloudAvailable {
                    Toggle("Автобэкап в iCloud Drive", isOn: $bk.enabled)
                    Text("Сжатый снимок памяти (база, текст, поисковый индекс — без HEIC-медиа) уезжает в "
                         + "iCloud Drive каждые 6 часов и при выходе. Живая база остаётся локальной — в iCloud "
                         + "Drive её класть нельзя (corruption).")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Хранить копий", selection: $bk.keepN) {
                        ForEach(BackupSettingsStore.keepOptions, id: \.self) { Text("\($0)").tag($0) }
                    }
                    HStack {
                        Button("Сделать бэкап сейчас") { Task { await bk.backupNow() } }
                            .disabled(bk.busy || !bk.enabled)
                        Spacer()
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([BackupManager.backupsDirectory()])
                        } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Папка бэкапов в Finder")
                    }
                    if let last = bk.lastBackupAt {
                        Text("Последний: \(last.formatted(date: .abbreviated, time: .shortened))"
                             + (bk.lastResult.map { " · \($0)" } ?? "") + " · копий: \(bk.backupCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let err = bk.error {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                } else {
                    Text("iCloud Drive выключен или не залогинен. Включи iCloud Drive в Системных настройках — "
                         + "и память начнёт автоматически бэкапиться в облако (сжатой, без выгрузки живой базы).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var importCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Импорт из screenpipe").font(.headline)
                Text("Найдена история screenpipe (~/.screenpipe). Перенесёт текст и метаданные (кадры, "
                     + "окна, URL, транскрипты со спикерами) в память Slishu — поиск заработает по всей "
                     + "старой истории. Медиа-файлы остаются у screenpipe. Можно прервать и продолжить позже.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button {
                        runImport()
                    } label: {
                        Label(importing ? "Импортирую…" : "Импортировать", systemImage: "square.and.arrow.down.on.square")
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
        guard let importer = env.screenpipeImporter else { return }
        importing = true
        importStatus = nil
        Task {
            do {
                let report = try await importer.run { f, a in
                    Task { @MainActor in
                        importStatus = "кадров \(f), аудио \(a)…"
                    }
                }
                importStatus = "Готово: +\(report.frames) кадров, +\(report.audio) аудио. Семантика доиндексируется фоном."
                await env.storageSettings.refresh(storage: env.storage, db: env.db)
                await env.timelineStore?.load()
            } catch {
                importStatus = "Импорт прервался: \(error.localizedDescription)"
            }
            importing = false
        }
    }

    private var privacyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Приватность").font(.headline)
                Text("По умолчанию Slishu записывает всё. Исключи приложения, которые не должны попадать "
                     + "в память (менеджер паролей, банк) — их окна вырезаются из кадров и текста. "
                     + "ЗВУК исключение не гасит (он не привязан к окнам): для чувствительного разговора "
                     + "используй «Не записывать 15 минут» в меню-баре.")
                    .font(.caption).foregroundStyle(.secondary)
                if env.privacy.ignoredBundleIds.isEmpty {
                    Text("Исключений нет.").font(.callout).foregroundStyle(.secondary)
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
                    Label("Исключить приложение…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var transcriptionCard: some View {
        @Bindable var settings = env.audioSettings
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Аудио и транскрипция").font(.headline)
                Toggle("Записывать и транскрибировать звук", isOn: $settings.transcriptionEnabled)
                    .onChange(of: settings.transcriptionEnabled) { _, _ in env.recording.syncAudio() }
                Text("Локально, on-device (Apple Speech, ru+en auto-detect). VAD отсекает тишину — пишутся "
                     + "только сегменты речи, затем они ищутся по словам. Звук не уходит в облако.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.transcriptionEnabled {
                    Toggle("Записывать системный звук (звонки, видео, встречи)", isOn: $settings.recordSystemAudio)
                        .onChange(of: settings.recordSystemAudio) { _, _ in env.recording.syncAudio() }
                        .font(.callout)
                    Text("Системный звук — голоса собеседников и всё, что играет (нужен только доступ к записи "
                         + "экрана). Микрофон — твой голос. Можно писать одно без другого.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if settings.recordSystemAudio {
                        Label("Системный звук НЕ подсвечивается оранжевым индикатором macOS (идёт через запись "
                              + "экрана, не микрофон). Запись собеседников — под твою ответственность.",
                              systemImage: "exclamationmark.shield").font(.caption2).foregroundStyle(.secondary)
                    }

                    if env.permissions.snapshot.speech != .granted {
                        Label("Нет распознавания речи — звук пишется, но без текста для поиска (найдёшь по времени и прослушаешь).",
                              systemImage: "exclamationmark.bubble").font(.caption).foregroundStyle(.orange)
                    }
                    if env.permissions.snapshot.microphone != .granted {
                        Label("Нет доступа к микрофону — пишется только системный звук.",
                              systemImage: "mic.slash").font(.caption).foregroundStyle(.orange)
                    }
                    if settings.micEngineFailed {
                        Label("Микрофон не запустился (устройство недоступно при последнем старте).",
                              systemImage: "mic.slash.fill").font(.caption).foregroundStyle(.orange)
                    }
                    if settings.systemEngineFailed {
                        Label("Системный звук не запустился — проверь доступ к Записи экрана.",
                              systemImage: "speaker.slash.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                if let h = settings.health, h.failed > 0, h.transcribed == 0,
                   h.lastErrorKind == "onDeviceUnavailable" {
                    Label("Распознавание не работает: нет on-device модели ru-RU. Включи диктовку в "
                          + "Системных настройках → Клавиатура → Диктовка. Звук пишется, но без текста.",
                          systemImage: "waveform.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var serverCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Локальный API").font(.headline)
                HStack {
                    Text("Адрес")
                    Spacer()
                    Text(env.server.baseURL).foregroundStyle(.secondary).monospaced().textSelection(.enabled)
                }
                if let token = env.server.token {
                    HStack {
                        Text("Токен")
                        Spacer()
                        Text(token.prefix(14) + "…").monospaced().foregroundStyle(.secondary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Скопировать токен")
                    }
                    Text("curl -H 'Authorization: Bearer <токен>' '\(env.server.baseURL)/v1/search?q=test'")
                        .font(.caption2).monospaced().foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2)
                } else {
                    Text("Сервер запускается…").font(.caption).foregroundStyle(.secondary)
                }
                Text("Auth на всё кроме /health (токен в Keychain), bind 127.0.0.1. MCP — следующий шаг.")
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
                StatusPill(text: "Выдано", color: .green)
            case .needsRestart:
                // право выдано, но TCC применит его только к новому процессу (-3801)
                StatusPill(text: "Нужен перезапуск", color: .orange)
                Button("Перезапустить Slishu") { AppRelauncher.relaunch() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            case .denied:
                StatusPill(text: "Нет доступа", color: .red)
                Button("Настройки", action: openSettings).buttonStyle(.borderless)
            case .notDetermined:
                Button("Запросить", action: request)
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }
}
