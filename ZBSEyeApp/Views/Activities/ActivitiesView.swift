import SwiftUI
import AppKit

/// "Day in activities" — a vertical list of scene blocks.
/// Tapping a scene → jump to the timeline at startTs.
struct ActivitiesView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let store = env.sceneStore, let timelineStore = env.timelineStore {
                ActivitiesBody(store: store, timelineStore: timelineStore)
                    .environment(env)
                    .task {
                        AchievementCounters.bump(.activitiesOpened)   // "Day Chronicler" achievement
                        await store.load()
                        await env.achievements?.refresh()
                    }
            } else if let err = env.dataError {
                ContentUnavailableView("Database error",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(err))
            } else {
                ProgressView("Initializing…")
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
            Text("Day in activities")
                .font(.headline)
            Spacer()
            Button("Today") {
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
            ProgressView("Segmenting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = store.error {
            // Error BEFORE "empty": on error scenes is also empty, otherwise the error would be masked
            // as "no activity" (Pro review #11).
            ContentUnavailableView("Error", systemImage: "exclamationmark.triangle",
                                   description: Text(err))
        } else if store.scenes.isEmpty {
            ContentUnavailableView {
                Label("No activity", systemImage: "calendar.badge.clock")
            } description: {
                Text("No frames recorded for this day. Pick a different day.")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let totalTime = totalDurationLabel(store.scenes)
                    HStack {
                        Text("\(store.scenes.count) activities · \(totalTime)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    ForEach(store.scenes) { scene in
                        SceneCard(scene: scene) {
                            // Tap → jump to the timeline at the scene's startTs.
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
        if hours > 0 { return "\(hours) h \(minutes) min" }
        return "\(minutes) min"
    }
}

// MARK: - scene card

private struct SceneCard: View {
    let scene: ActivityScene
    let onTap: () -> Void

    @State private var appIcon: NSImage?

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                // App icon
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
                        Text(scene.appName ?? scene.bundleId ?? "App")
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
                        Label("\(scene.frameCount) frames", systemImage: "photo")
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
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    /// Icon via NSWorkspace by bundleId. Async-friendly: doesn't block the main actor for long.
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

// MARK: - scene summary card for the timeline's right panel

/// Embedded in TimelineView's `detailPanel` instead of a RAW OCR dump when the current scene is known.
struct SceneSummaryCard: View {
    let scene: ActivityScene
    let onJump: () -> Void      // "Jump to start" — seek(startTs)

    @State private var appIcon: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable().frame(width: 20, height: 20).cornerRadius(4)
                }
                Text("Scene")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onJump()
                } label: {
                    Label("Start", systemImage: "arrow.left.to.line")
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
                Label("\(scene.frameCount) frames", systemImage: "photo")
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
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
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
