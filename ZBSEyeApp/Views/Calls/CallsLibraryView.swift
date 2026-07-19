import SwiftUI

struct CallsLibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var store: CallsStore

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Calls")
                .searchable(
                    text: $store.query,
                    placement: .toolbar,
                    prompt: "Search calls, people, apps, and transcripts"
                )
                .navigationDestination(isPresented: detailPresented) {
                    if let callID = store.selectedCallID {
                        CallDetailView(callID: callID)
                    }
                }
        }
        .task(id: store.query) {
            if !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            await store.reload()
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.calls.isEmpty {
            emptyContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(store.calls, id: \.callId) { call in
                    Button {
                        store.open(call)
                    } label: {
                        CallLibraryRow(call: call)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Open call")
                }

                if store.hasMore {
                    HStack {
                        Spacer()
                        if store.isLoadingMore {
                            ProgressView("Loading more calls…")
                                .controlSize(.small)
                        } else {
                            Button("Load more") {
                                Task { await store.loadMore() }
                            }
                            .buttonStyle(.borderless)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }

                if case .failed(let message) = store.phase {
                    HStack(spacing: 10) {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                        Spacer()
                        Button("Try again") { Task { await store.reload() } }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.inset)
            .overlay(alignment: .top) {
                if store.phase == .loading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .accessibilityLabel("Refreshing calls")
                }
            }
        }
    }

    @ViewBuilder
    private var emptyContent: some View {
        switch store.phase {
        case .idle, .loading:
            ProgressView("Loading calls…")
        case .failed(let message):
            ContentUnavailableView {
                Label("Calls unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await store.reload() } }
            }
        case .ready:
            if store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label("No calls yet", systemImage: "phone.badge.waveform")
                } description: {
                    Text("Detected calls and calls you start manually will appear here.")
                } actions: {
                    Button("Start a call") { env.calls.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(env.calls.isActive || env.storageSettings.relocationInProgress)
                }
            } else {
                ContentUnavailableView.search(text: store.query)
            }
        }
    }

    private var detailPresented: Binding<Bool> {
        Binding(
            get: { store.selectedCallID != nil },
            set: { shown in
                if !shown { store.closeDetail() }
            }
        )
    }
}

private struct CallLibraryRow: View {
    let call: CallEvidenceSummary

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(date)
                    Text("·")
                    Text(duration)
                    if let source = call.sourceApp, !source.isEmpty {
                        Text("·")
                        Text(source)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if !call.participants.isEmpty {
                    Text(call.participants.prefix(4).joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if call.bookmarkCount > 0 {
                    Label("\(call.bookmarkCount)", systemImage: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .accessibilityLabel("\(call.bookmarkCount) bookmarks")
                }
                Label(statusTitle, systemImage: statusIcon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var displayTitle: String {
        if let title = call.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return String(localized: "Call · \(date)")
    }

    private var date: String {
        dateFromMs(call.startTs)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private var duration: String {
        guard let endTs = call.endTs else { return String(localized: "In progress") }
        let seconds = max(0, endTs - call.startTs) / 1_000
        if seconds >= 3_600 {
            return String(format: "%lldh %lldm", seconds / 3_600, (seconds % 3_600) / 60)
        }
        if seconds >= 60 {
            return String(format: "%lldm", seconds / 60)
        }
        return String(format: "%llds", seconds)
    }

    private var statusTitle: String {
        if call.status == .ready, call.speakerStatus == .processing {
            return String(localized: "Finding speakers")
        }
        if call.status == .ready, call.speakerStatus == .degraded {
            return String(localized: "Ready · source labels")
        }
        switch call.status {
        case .recording: return String(localized: "Recording")
        case .processing: return String(localized: "Processing")
        case .retryable: return String(localized: "Retry needed")
        case .ready: return String(localized: "Ready")
        case .degraded: return String(localized: "Ready · gaps")
        }
    }

    private var statusIcon: String {
        switch call.status {
        case .recording: "record.circle.fill"
        case .processing: "waveform"
        case .retryable: "arrow.clockwise.circle"
        case .ready where call.speakerStatus == .processing: "person.2.wave.2"
        case .ready: "checkmark.circle.fill"
        case .degraded: "exclamationmark.circle"
        }
    }

    private var statusColor: Color {
        switch call.status {
        case .recording: .red
        case .retryable, .degraded: .orange
        case .ready where call.speakerStatus == .degraded: .orange
        case .ready: .green
        case .processing: .secondary
        }
    }

    private var accessibilityLabel: String {
        var parts = [displayTitle, date, duration, statusTitle]
        if !call.participants.isEmpty {
            parts.append(call.participants.prefix(4).joined(separator: ", "))
        }
        if call.bookmarkCount > 0 {
            parts.append(String(localized: "\(call.bookmarkCount) bookmarks"))
        }
        return parts.joined(separator: ", ")
    }
}
