import SwiftUI

/// «Картограф» — AI-инсайты дня: что реально занимало время и конкретные советы.
/// Полностью on-device (localhost LLM). Не пишет файлы — инсайты только в UI.
struct CartographerView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let store = env.cartographer {
                CartographerBody(store: store)
            } else {
                ContentUnavailableView("Инициализация…", systemImage: "map")
            }
        }
        .navigationTitle("Картограф")
    }
}

// MARK: — основное тело

private struct CartographerBody: View {
    @Bindable var store: CartographerStore
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !store.llmReady {
                    noLLMCard
                } else {
                    controlsCard
                    if let ins = store.insights { insightsCard(ins) }
                    if let e = store.errorText, store.phase == .failed { errorCard(e) }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: блоки

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Картограф", systemImage: "map")
                .font(.title2).bold()
            Text("Смотрит на твою активность за день и даёт 2–3 конкретных наблюдения: "
                 + "на что уходит время, где можно фокусироваться лучше. "
                 + "Всё на устройстве — никакого облака.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var noLLMCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Нужна локальная LLM", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.headline)
                Text("Укажи endpoint (Ollama / LM Studio / mlx_lm.server) и модель в «Подключениях» — "
                     + "Картограф работает строго on-device, история не уходит в облако.")
                    .foregroundStyle(.secondary)
                Button("Открыть «Подключения»") { env.selectedSection = .connections }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var controlsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("День", selection: $store.selectedDay, in: ...Date(),
                           displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .disabled(store.isBusy)

                HStack(spacing: 12) {
                    Button {
                        store.generate()
                    } label: {
                        Label("Получить инсайты", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)

                    if store.isBusy {
                        ProgressView().controlSize(.small)
                        Text("анализирую день…").foregroundStyle(.secondary)
                        Button("Отмена") { store.cancel() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func insightsCard(_ ins: CartographerService.Insights) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                // Заголовок с мета-данными
                HStack(spacing: 10) {
                    Label("Инсайты дня", systemImage: "lightbulb.fill")
                        .font(.headline)
                    Spacer()
                    Text(ins.model)
                        .font(.caption).foregroundStyle(.secondary)
                }

                // Строки инсайтов
                if ins.lines.isEmpty {
                    Text("Модель не вернула инсайтов — попробуй ещё раз или смени модель.")
                        .foregroundStyle(.secondary).font(.callout)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(ins.lines.enumerated()), id: \.offset) { _, line in
                            InsightRow(text: line)
                        }
                    }
                }

                if ins.truncated {
                    Label("Ответ модели обрезан по лимиту токенов.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }

                Divider()

                // Активность дня — мини-сводка
                ActivitySummaryView(activity: ins.activity)
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
}

// MARK: — строка инсайта

private struct InsightRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.callout)
                .padding(.top, 1)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: — мини-сводка активности

private struct ActivitySummaryView: View {
    let activity: CartographerService.DayActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Активность дня")
                .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                .padding(.bottom, 2)

            HStack(spacing: 20) {
                statBadge(value: "\(activity.totalCaptures)", label: "кадров")
                statBadge(value: "\(activity.contextSwitches)", label: "переключений")
            }

            if !activity.topApps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(activity.topApps.prefix(5).enumerated()), id: \.offset) { i, u in
                        CartographerAppRow(rank: i + 1, usage: u,
                                           maxMinutes: activity.topApps.first?.minutes ?? 1)
                    }
                }
            }
        }
    }

    private func statBadge(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3).bold().monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct CartographerAppRow: View {
    let rank: Int
    let usage: CartographerService.DayActivity.AppUsage
    let maxMinutes: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank)").font(.caption2).foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing).monospacedDigit()
            Text(usage.app).font(.callout).lineLimit(1)
            Spacer()
            GeometryReader { geo in
                let fraction = maxMinutes > 0 ? CGFloat(usage.minutes) / CGFloat(maxMinutes) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.7))
                        .frame(width: geo.size.width * fraction, height: 6)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 80, height: 16)
            Text("~\(usage.minutes) мин")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
    }
}
