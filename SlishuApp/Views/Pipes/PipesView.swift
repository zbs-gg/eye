import SwiftUI

/// Pipe v1: «Саммари дня». collect → локальная LLM → запись в файл/Obsidian. Поток preview-then-write.
struct PipesView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let store = env.pipes {
                PipeBody(store: store)
            } else {
                ContentUnavailableView("Инициализация…", systemImage: "powerplug")
            }
        }
        .navigationTitle("Плагины")
    }
}

private struct PipeBody: View {
    @Bindable var store: DaySummaryStore
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !store.isReady {
                    notReadyCard
                } else {
                    controls
                    scheduleCard
                    if let p = store.preview { previewCard(p) }
                    if let w = store.lastWrite { writeSuccess(w) }
                    if let e = store.errorText, store.phase == .failed { errorCard(e) }
                    auditSection
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await store.refreshAudit() }
    }

    // MARK: блоки

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Саммари дня", systemImage: "text.append")
                .font(.title2).bold()
            Text("Собирает активность за день из истории, прогоняет через локальную модель и пишет "
                 + "Markdown-конспект в выбранную папку. Ничего не уходит в облако.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var notReadyCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Нужно настроить подключения", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.headline)
                Text("Укажи локальную LLM и папку-назначение — без них pipe не запустится.")
                    .foregroundStyle(.secondary)
                Button("Открыть «Подключения»") { env.selectedSection = .connections }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var controls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("День", selection: $store.selectedDay, in: ...Date(),
                           displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .disabled(store.isBusy)

                HStack(spacing: 12) {
                    Button {
                        store.startPreview()
                    } label: {
                        Label("Собрать превью", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)

                    if store.phase == .summarizing {
                        ProgressView().controlSize(.small)
                        Text("собираю историю и суммирую…").foregroundStyle(.secondary)
                        Button("Отмена") { store.cancelPreview() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var scheduleCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Собирать конспект автоматически", isOn: $store.scheduleEnabled)
                if store.scheduleEnabled {
                    Picker("Время", selection: $store.scheduleHour) {
                        ForEach([17, 18, 19, 20, 21, 22, 23], id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .fixedSize()
                    Toggle("Сразу записывать без превью", isOn: $store.autoWriteEnabled)
                        .disabled(!store.hasWrittenManually)
                    Text(store.hasWrittenManually
                         ? "Готовый конспект придёт уведомлением. Авто-запись кладёт его в папку без подтверждения."
                         : "Авто-запись откроется после первой ручной записи — сначала проверь формат глазами (защита от мусора и инъекций из истории).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func previewCard(_ p: SummaryPreview) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Превью").font(.headline)
                    Spacer()
                    Text("\(p.sessions) сессий · \(p.totalCaptures) кадров · \(p.model)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if p.truncated {
                    Label("День длинный — в саммари вошли самые длинные сессии.",
                          systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                if p.outputTruncated {
                    Label("Ответ модели обрезан по лимиту токенов — конспект может быть неполным.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                ScrollView {
                    Text(p.markdown)
                        .font(.system(.callout, design: .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button {
                        Task { await store.writeApproved() }
                    } label: {
                        Label(writeButtonTitle, systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.phase == .writing || store.lastWrite != nil)   // не записать повторно тот же конспект

                    if store.phase == .writing {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var writeButtonTitle: String {
        let sub = store.connections.destination.subfolder
        let folder = sub.isEmpty ? "папку" : sub
        // Имя из preview.day, а не selectedDay — кнопка обязана обещать ровно то, что запишется.
        let day = store.preview?.day ?? store.selectedDay
        return "Записать в \(folder)/\(DailySummaryService.ymd(day)).md"
    }

    private func writeSuccess(_ w: WriteResult) -> some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.overwritten ? "Перезаписано" : "Записано").font(.headline)
                    Text(w.path).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2)
                }
                Spacer()
                Button("Показать в Finder") { store.revealLastWrite() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func errorCard(_ msg: String) -> some View {
        GroupBox {
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
    }

    private var auditSection: some View {
        DisclosureGroup("История запусков (\(store.audit.count))") {
            if store.audit.isEmpty {
                Text("Пока пусто.").foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.audit) { e in
                        HStack(spacing: 8) {
                            Image(systemName: e.ok ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(e.ok ? .green : .red)
                            Text(e.action == "write" ? "запись" : "превью").bold()
                            Text(e.day).foregroundStyle(.secondary)
                            Text("· \(e.sessions) сессий")
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
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM, HH:mm"
        return f.string(from: d)
    }
}
