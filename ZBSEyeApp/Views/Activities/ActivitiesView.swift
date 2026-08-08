import SwiftUI
import AppKit

/// "Day in activities" — a vertical list of activity BLOCKS ("what was I plausibly doing"),
/// each expandable into the underlying app sessions. System shells (loginwindow…) are hidden
/// behind a debug toggle. Tapping a session → jump to the timeline at startTs.
struct ActivitiesView: View {
    @Environment(AppEnvironment.self) private var env
    let onOpenMoment: (Date) -> Void

    init(onOpenMoment: @escaping (Date) -> Void) {
        self.onOpenMoment = onOpenMoment
    }

    var body: some View {
        Group {
            if let store = env.sceneStore {
                ActivitiesBody(store: store, onOpenMoment: onOpenMoment)
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

/// One row of the day list: a user-activity block or (debug toggle) a filtered system scene.
private enum ActivityRow: Identifiable {
    case block(ActivityBlock)
    case system(ActivityScene)

    var id: String {
        switch self {
        case .block(let b):  return "b-\(b.id)"
        case .system(let s): return "s-\(s.id)"
        }
    }
    var startTs: Date {
        switch self {
        case .block(let b):  return b.startTs
        case .system(let s): return s.startTs
        }
    }
}

private struct ActivitiesBody: View {
    @Bindable var store: SceneStore
    let onOpenMoment: (Date) -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
    }

    private var toolbar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Day in activities")
                    .font(.headline)
                Text("Your day grouped into what you were working on — expand an activity, then tap a session to replay it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Debug: reveal the filtered system shells (loginwindow, screen saver…) as dimmed cards.
            Toggle("Show idle / system time", isOn: $store.showSystemEvents)
                .toggleStyle(.checkbox)
                .controlSize(.small)
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

    /// Blocks + (when the toggle is on) system scenes, interleaved chronologically.
    private var rows: [ActivityRow] {
        var out: [ActivityRow] = store.blocks.map { .block($0) }
        if store.showSystemEvents { out += store.systemScenes.map { .system($0) } }
        return out.sorted { $0.startTs < $1.startTs }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading {
            ProgressView("Grouping your activity…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = store.error {
            // Error BEFORE "empty": on error scenes is also empty, otherwise the error would be masked
            // as "no activity" (Pro review #11).
            ContentUnavailableView("Error", systemImage: "exclamationmark.triangle",
                                   description: Text(err))
        } else if rows.isEmpty {
            ContentUnavailableView {
                Label("No activity", systemImage: "calendar.badge.clock")
            } description: {
                Text("No moments recorded for this day. Pick a different day.")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    let totalTime = totalDurationLabel(store.blocks)
                    HStack {
                        Text("\(store.blocks.count) activities · \(totalTime)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    ForEach(rows) { row in
                        Group {
                            switch row {
                            case .block(let block):
                                BlockCard(block: block,
                                          llmLabel: store.llmLabels[block.id]) { scene in
                                    jump(to: scene)
                                }
                            case .system(let scene):
                                SceneCard(scene: scene) { jump(to: scene) }
                                    .opacity(0.6)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 16)
            }
        }
    }

    /// Tap on a session → jump to the timeline at the scene's startTs.
    private func jump(to scene: ActivityScene) {
        onOpenMoment(scene.startTs)
    }

    private func totalDurationLabel(_ blocks: [ActivityBlock]) -> String {
        let total = blocks.reduce(0) { $0 + $1.durationSec }
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        if hours > 0 { return "\(hours) h \(minutes) min" }
        return "\(minutes) min"
    }
}

// MARK: - block card (top-level unit)

/// Collapsed: "14:00–15:30 · Working on X · Xcode, Chrome". Expanded: the underlying app sessions.
private struct BlockCard: View {
    @Environment(AppEnvironment.self) private var env
    let block: ActivityBlock
    let llmLabel: String?              // arrives async; heuristic label until (and unless) it does
    let onSelectScene: (ActivityScene) -> Void

    @State private var expanded = false
    @State private var appIcon: NSImage?
    @State private var visualImage: NSImage?
    @State private var appIconIdentity: String?
    @State private var visualImageIdentity: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(block.scenes) { scene in
                        SceneCard(scene: scene) { onSelectScene(scene) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
        .task(id: block.topApps.first?.bundleId) {
            let bundleID = block.topApps.first?.bundleId
            appIconIdentity = bundleID
            appIcon = nil
            let icon = await loadAppIcon(bundleId: bundleID)
            guard !Task.isCancelled, appIconIdentity == bundleID else { return }
            appIcon = icon
        }
        .task(id: block.representativeVisualPath) {
            let path = block.representativeVisualPath
            visualImageIdentity = path
            visualImage = nil
            guard let path,
                  let loader = env.visualFrameImageLoader else { return }
            let image = await loader.image(
                relativePath: path,
                maxPixel: 480,
                priority: .current
            )
            guard !Task.isCancelled, visualImageIdentity == path else { return }
            visualImage = image
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            leadingVisual

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(timeRangeLabel(start: block.startTs, end: block.endTs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Text(durationLabel(block.durationSec))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(llmLabel ?? block.heuristicLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Text(block.topAppsLine)
                        .lineLimit(1)
                    Text("· \(block.scenes.count) sessions")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .padding(.top, 4)
        }
        .padding(12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var leadingVisual: some View {
        if let visualImage {
            ZStack(alignment: .bottomLeading) {
                Image(nsImage: visualImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 160, height: 90)
                    .clipped()

                appIconView
                    .frame(width: 24, height: 24)
                    .padding(4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .padding(6)
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Representative screen from \(block.topApps.first?.name ?? "activity")")
        } else {
            appIconView
                .frame(width: 32, height: 32)
                .cornerRadius(7)
        }
    }

    @ViewBuilder
    private var appIconView: some View {
        if let icon = appIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "square.stack.3d.up")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }

    private func timeRangeLabel(start: Date, end: Date) -> String {
        "\(cardTimeFormatter.string(from: start))–\(cardTimeFormatter.string(from: end))"
    }
}

// MARK: - scene card (one app session)

private struct SceneCard: View {
    let scene: ActivityScene
    let onTap: () -> Void

    @State private var appIcon: NSImage?
    @State private var appIconIdentity: String?
    @State private var hovered = false

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
                        if scene.isSystem {
                            Text("System event")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                                .foregroundStyle(.secondary)
                        }
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
                        Label("\(scene.frameCount) moments", systemImage: "photo")
                        Spacer()
                        // Visible affordance: tapping a session jumps to that spot on the timeline.
                        HStack(spacing: 3) {
                            if hovered {
                                Text("Open in Timeline")
                                    .transition(.opacity)
                            }
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .foregroundStyle(.tint)
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
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
        .help("Open in Timeline")
        .task(id: scene.bundleId) {
            let bundleID = scene.bundleId
            appIconIdentity = bundleID
            appIcon = nil
            let icon = await loadAppIcon(bundleId: bundleID)
            guard !Task.isCancelled, appIconIdentity == bundleID else { return }
            appIcon = icon
        }
    }

    private func timeRangeLabel(_ scene: ActivityScene) -> String {
        "\(cardTimeFormatter.string(from: scene.startTs))–\(cardTimeFormatter.string(from: scene.endTs))"
    }
}

// MARK: - shared helpers

/// One shared "HH:mm" formatter for the card time ranges. A DateFormatter is relatively expensive to
/// build; allocating one per card per body evaluation shows up on the scroll hot path. Formatting is
/// read-only and we never mutate it after init, so a single reused instance is safe
/// (`nonisolated(unsafe)` — the cards read it from the MainActor render path).
nonisolated(unsafe) private let cardTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

private func durationLabel(_ sec: Double) -> String {
    let s = Int(sec)
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(s / 60) min" }
    return "\(s / 3600) h \((s % 3600) / 60) min"
}

/// Icon via NSWorkspace by bundleId. Async-friendly: doesn't block the main actor for long.
private func loadAppIcon(bundleId: String?) async -> NSImage? {
    guard let bid = bundleId else { return nil }
    return await Task.detached(priority: .userInitiated) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }.value
}

// MARK: - scene summary card for the timeline's right panel

/// Shared by the Timeline fallback and grouped-Scene forms.
struct SceneSummaryCard: View {
    let card: TimelineSceneCardPresentation
    let onJump: (() -> Void)?

    @State private var appIcon: NSImage?
    @State private var appIconIdentity: String?

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
                if let onJump {
                    Button(action: onJump) {
                        Label("Start", systemImage: "arrow.left.to.line")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Start of scene")
                }
            }

            Text(card.summary)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Label(durationLabel(card.durationSec), systemImage: "clock")
                if card.frameCount == 1 {
                    Label("1 moment", systemImage: "photo")
                } else {
                    Label("\(card.frameCount) moments", systemImage: "photo")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .task(id: card.bundleId) {
            let bundleID = card.bundleId
            appIconIdentity = bundleID
            appIcon = nil
            let icon = await loadAppIcon(bundleId: bundleID)
            guard !Task.isCancelled, appIconIdentity == bundleID else { return }
            appIcon = icon
        }
    }
}
