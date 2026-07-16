import SwiftUI

struct CallDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let callID: Int64
    @State private var evidence: CallEvidencePage?
    @State private var segments: [CallTranscriptSegmentRow] = []
    @State private var hasMoreSegments = false
    @State private var loadingMore = false
    @State private var errorMessage: String?
    @State private var actionErrorMessage: String?
    @State private var retryGeneration: UInt64 = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let evidence {
                    header(evidence)
                    sourceSection(evidence)
                    bookmarkSection(evidence)
                    transcriptSection(evidence)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Call unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView("Loading call…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .navigationTitle("Call")
        .task(id: CallDetailRefreshKey(
            callID: callID,
            modelState: env.speechModel.snapshot.state,
            retryGeneration: retryGeneration
        )) {
            await monitor()
        }
    }

    private func header(_ evidence: CallEvidencePage) -> some View {
        let presentation = CallPresentationState.resolve(
            evidence: evidence,
            modelState: env.speechModel.snapshot.state
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Call · \(date(evidence.call.startTs))")
                        .font(.title2.bold())
                    Text(duration(evidence.call))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(presentation.title, systemImage: icon(for: presentation.kind))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color(for: presentation.kind))
            }
            Text(presentation.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if presentation.canInstallModel {
                    Button("Install Whisper") { env.speechModel.install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(env.speechModel.busy)
                }
                if presentation.canRetry {
                    Button("Retry transcription") {
                        Task {
                            actionErrorMessage = await env.retryCallTranscription(callID: callID)
                            retryGeneration &+= 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                if env.speechModel.busy { ProgressView().controlSize(.small) }
            }
            if let actionErrorMessage {
                Label(actionErrorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func sourceSection(_ evidence: CallEvidencePage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Audio sources").font(.headline)
            sourceRow(.me, spans: evidence.sourceSpans, gaps: evidence.sourceGaps)
            sourceRow(.system, spans: evidence.sourceSpans, gaps: evidence.sourceGaps)
            if evidence.sourceSpansTruncated || evidence.sourceGapsTruncated {
                Text("Source history is summarized after \(CallEvidenceQueryService.maximumSourceSpans) changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceRow(
        _ source: CallAudioSource,
        spans: [CallSourceSpanRow],
        gaps: [CallSourceGapRow]
    ) -> some View {
        let matching = spans.filter { $0.source == source }
        let hasGap = matching.contains { $0.availability == .gap || $0.gapReason != nil }
            || gaps.contains { $0.source == source }
        let available = matching.contains { $0.availability == .available }
        let title = source == .me ? "You · microphone" : "Others · system audio"
        let status = hasGap ? "Recorded with gaps" : (available ? "Recorded" : "Not recorded")
        return HStack {
            Label(title, systemImage: source == .me ? "mic" : "speaker.wave.2")
            Spacer()
            Text(status)
                .font(.caption)
                .foregroundStyle(hasGap ? Color.orange : Color.secondary)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func bookmarkSection(_ evidence: CallEvidencePage) -> some View {
        if !evidence.bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bookmarks").font(.headline)
                ForEach(evidence.bookmarks, id: \.id) { bookmark in
                    HStack {
                        Label("Bookmark \(bookmark.ordinal)", systemImage: "bookmark")
                        Text(offset(bookmark.acceptedAtMs, from: evidence.call.startTs))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(bookmarkLabel(bookmark.state))
                            .font(.caption)
                            .foregroundStyle(bookmark.state == .failed ? Color.orange : Color.secondary)
                    }
                }
                if evidence.bookmarksTruncated {
                    Text("Showing the first \(CallEvidenceQueryService.maximumBookmarks) bookmarks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func transcriptSection(_ evidence: CallEvidencePage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                if evidence.preferredRevision?.kind == .projection {
                    Text("PROVISIONAL")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                } else if evidence.preferredRevision?.kind == .final {
                    Text("FINAL")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                }
            }
            if segments.isEmpty {
                Text("No transcript text yet. The recording and bookmarks are already safe.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(segments, id: \.id) { segment in
                    HStack(alignment: .top, spacing: 10) {
                        Text(offset(segment.startMs, from: evidence.call.startTs))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Text(segment.source == .me ? "You" : "System")
                            .font(.caption.weight(.semibold))
                            .frame(width: 54, alignment: .leading)
                        Text(segment.text)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                if hasMoreSegments {
                    Button(loadingMore ? "Loading…" : "Load more") {
                        Task { await loadMore() }
                    }
                    .disabled(loadingMore)
                }
            }
            if evidence.projectionGapsTruncated {
                Text("Showing the first \(CallEvidenceQueryService.maximumProjectionGaps) transcript gaps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func monitor() async {
        while !Task.isCancelled {
            await refresh(resetSegments: false)
            guard let evidence else { return }
            let presentation = CallPresentationState.resolve(
                evidence: evidence,
                modelState: env.speechModel.snapshot.state
            )
            guard [.finalizing, .transcribing, .provisional].contains(presentation.kind) else {
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func refresh(resetSegments: Bool) async {
        guard let service = env.callEvidenceQueryService else { return }
        do {
            guard let page = try await service.call(id: callID, segmentLimit: 80) else {
                errorMessage = "This call no longer exists."
                return
            }
            let revisionChanged = evidence?.preferredRevision?.id != page.preferredRevision?.id
            evidence = page
            if resetSegments || revisionChanged {
                segments = page.segments
                hasMoreSegments = page.hasMoreSegments
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !loadingMore, let service = env.callEvidenceQueryService else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            guard let page = try await service.call(
                id: callID,
                segmentOffset: segments.count,
                segmentLimit: 80
            ) else { return }
            segments.append(contentsOf: page.segments)
            hasMoreSegments = page.hasMoreSegments
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func date(_ milliseconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func duration(_ call: CallRow) -> String {
        let end = call.endTs ?? Int64(Date().timeIntervalSince1970 * 1_000)
        return "\(max(0, end - call.startTs) / 1_000) seconds · local recording"
    }

    private func offset(_ milliseconds: Int64, from start: Int64) -> String {
        let seconds = max(0, milliseconds - start) / 1_000
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }

    private func bookmarkLabel(_ state: CallBookmarkState) -> String {
        switch state {
        case .preparing, .pending: "Transcribing"
        case .deferredCapacity: "Queued"
        case .ready: "Ready"
        case .readyDegraded: "Ready · gap"
        case .failed: "Retry needed"
        case .satisfiedByFinal: "Included in final"
        }
    }

    private func icon(for kind: CallPresentationKind) -> String {
        switch kind {
        case .recording: "record.circle.fill"
        case .finalizing, .transcribing, .provisional: "waveform"
        case .modelRequired: "arrow.down.circle"
        case .ready: "checkmark.circle.fill"
        case .degraded: "exclamationmark.circle"
        case .failed: "arrow.clockwise.circle"
        }
    }

    private func color(for kind: CallPresentationKind) -> Color {
        switch kind {
        case .recording: .red
        case .ready: .green
        case .degraded, .failed, .modelRequired: .orange
        case .finalizing, .transcribing, .provisional: .secondary
        }
    }
}
