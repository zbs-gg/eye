import SwiftUI
import AppKit

/// «День в активностях» — вертикальный список блоков-сцен.
/// Клик по сцене → переход на таймлайн к startTs.
struct ActivitiesView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let store = env.sceneStore, let timelineStore = env.timelineStore {
                ActivitiesBody(store: store, timelineStore: timelineStore)
                    .environment(env)
                    .task {
                        AchievementCounters.bump(.activitiesOpened)   // ачивка «Хронист дня»
                        await store.load()
                        await env.achievements?.refresh()
                    }
            } else if let err = env.dataError {
                ContentUnavailableView("Ошибка БД",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else {
                ProgressView("Инициализация…")
            }
        }
    }
}

private struct ActivitiesBody: View {
    @Bindable var store: SceneStore
    @Bindable var timelineStore: TimelineStore
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("День в активностях")
                .font(.headline)
            Spacer()
            Button("Сегодня") {
                store.selectedDay = Calendar.current.startOfDay(for: Date())
                Task { await store.load() }
            }
            .controlSize(.small)
            DatePicker("", selection: $store.selectedDay, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                .controlSize(.small)
                .onChange(of: store.selectedDay) { _, _ in Task { await store.load() } }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading {
            ProgressView("Сегментирую…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = store.error {
            // Ошибка РАНЬШЕ «пусто»: при ошибке scenes тоже пуст, иначе ошибка маскировалась бы
            // под «нет активности» (ревью Pro #11).
            ContentUnavailableView("Ошибка", systemImage: "exclamationmark.triangle",
                                   description: Text(err))
        } else if store.scenes.isEmpty {
            ContentUnavailableView {
                Label("Нет активности", systemImage: "calendar.badge.clock")
            } description: {
                Text("За этот день нет записанных кадров. Выбери другой день.")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let totalTime = totalDurationLabel(store.scenes)
                    HStack {
                        Text("\(store.scenes.count) активностей · \(totalTime)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    ForEach(store.scenes) { scene in
                        SceneCard(scene: scene) {
                            // Клик → переходим на таймлайн к startTs сцены.
                            env.selectedSection = .timeline
                            Task { await timelineStore.seek(to: scene.startTs) }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    private func totalDurationLabel(_ scenes: [ActivityScene]) -> String {
        let total = scenes.reduce(0) { $0 + $1.durationSec }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        if hours > 0 { return "\(hours) ч \(minutes) мин" }
        return "\(minutes) мин"
    }
}

// MARK: - карточка сцены

private struct SceneCard: View {
    let scene: ActivityScene
    let onTap: () -> Void

    @State private var appIcon: NSImage?

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // Иконка приложения
                Group {
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "app.dashed")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32)
                .cornerRadius(7)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(scene.appName ?? scene.bundleId ?? "Приложение")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        Text(timeRangeLabel(scene))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let title = scene.repWindowTitle,
                       !title.isEmpty,
                       title != scene.appName {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(scene.summary)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Label(durationLabel(scene.durationSec), systemImage: "clock")
                        Label("\(scene.frameCount) кадров", systemImage: "photo")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .task(id: scene.bundleId) {
            appIcon = await loadIcon(bundleId: scene.bundleId)
        }
    }

    private func timeRangeLabel(_ scene: ActivityScene) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "\(fmt.string(from: scene.startTs))–\(fmt.string(from: scene.endTs))"
    }

    private func durationLabel(_ sec: Double) -> String {
        let s = Int(sec)
        if s < 60 { return "\(s) с" }
        if s < 3600 { return "\(s / 60) мин" }
        return "\(s / 3600) ч \((s % 3600) / 60) мин"
    }

    /// Иконка через NSWorkspace по bundleId. Async-friendly: не блокирует main actor надолго.
    private func loadIcon(bundleId: String?) async -> NSImage? {
        guard let bid = bundleId else { return nil }
        return await Task.detached(priority: .userInitiated) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return nil
        }.value
    }
}

// MARK: - карточка-саммари сцены для правой панели таймлайна

/// Встраивается в `detailPanel` TimelineView вместо RAW OCR-дампа когда известна текущая сцена.
struct SceneSummaryCard: View {
    let scene: ActivityScene
    let onJump: () -> Void      // «Перейти к началу» — seek(startTs)

    @State private var appIcon: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable().frame(width: 20, height: 20).cornerRadius(4)
                }
                Text("Сцена")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onJump()
                } label: {
                    Label("Начало", systemImage: "arrow.left.to.line")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }

            Text(scene.summary)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Label(durationLabel(scene.durationSec), systemImage: "clock")
                Label("\(scene.frameCount) кадров", systemImage: "photo")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .task(id: scene.bundleId) {
            appIcon = await loadIcon(bundleId: scene.bundleId)
        }
    }

    private func durationLabel(_ sec: Double) -> String {
        let s = Int(sec)
        if s < 60 { return "\(s) с" }
        if s < 3600 { return "\(s / 60) мин" }
        return "\(s / 3600) ч \((s % 3600) / 60) мин"
    }

    private func loadIcon(bundleId: String?) async -> NSImage? {
        guard let bid = bundleId else { return nil }
        return await Task.detached(priority: .userInitiated) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return nil
        }.value
    }
}
