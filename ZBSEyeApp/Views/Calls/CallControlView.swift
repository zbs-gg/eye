import AppKit
import SwiftUI

struct CallControlView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @State private var evidence: CallEvidencePage?
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            status
                .frame(maxWidth: .infinity, alignment: .leading)
            controls
        }
        .padding(compact ? 7 : 9)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .task(id: refreshKey) { await monitorEvidence() }
    }

    @ViewBuilder
    private var status: some View {
        let snapshot = env.calls.snapshot
        switch snapshot.phase {
        case .starting:
            Label("Starting call…", systemImage: "waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .recording:
            Label(
                snapshot.bookmarkCount == 0
                    ? "Recording call"
                    : "Recording · \(snapshot.bookmarkCount) bookmarks",
                systemImage: "record.circle.fill"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(.red)
        case .recoveryTail:
            Label("Call ended · recovery tail", systemImage: "arrow.uturn.backward.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .finalizing:
            Label("Saving call…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .pendingTranscription, .ready, .readyDegraded, .failed:
            if let evidence {
                let presentation = CallPresentationState.resolve(
                    evidence: evidence,
                    modelState: env.speechModel.snapshot.state
                )
                Label(presentation.title, systemImage: icon(for: presentation.kind))
                    .font(.caption)
                    .foregroundStyle(color(for: presentation.kind))
                    .lineLimit(2)
            } else {
                Label("Call saved", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .idle:
            Label("Call recording", systemImage: "phone.badge.waveform")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch env.calls.snapshot.phase {
        case .starting, .finalizing:
            ProgressView().controlSize(.small)
        case .recording:
            Button { env.calls.bookmark() } label: {
                Image(systemName: "bookmark")
            }
            .help("Bookmark and transcribe this part without stopping the call")
            .accessibilityLabel("Bookmark call")
            Button(role: .destructive) { env.calls.end() } label: {
                Image(systemName: "stop.fill")
            }
            .help("End call")
            .accessibilityLabel("End call")
        case .recoveryTail:
            Button("Undo") { env.undoDetectedCallEnd() }
                .controlSize(.small)
                .help("Continue the same call without losing the boundary")
        case .pendingTranscription, .ready, .readyDegraded, .failed:
            if evidence != nil || env.calls.snapshot.callID != nil {
                Button("Open") { openDetail() }
                    .controlSize(.small)
            }
            Button { env.calls.start() } label: {
                Image(systemName: "plus")
            }
            .help("Start another call")
            .accessibilityLabel("Start another call")
            .disabled(env.storageSettings.relocationInProgress)
        case .idle:
            if evidence != nil {
                Button { openDetail() } label: {
                    Image(systemName: "clock")
                }
                .help("Open the latest call")
                .accessibilityLabel("Open the latest call")
            }
            Button("Start") { env.calls.start() }
                .controlSize(.small)
                .disabled(env.storageSettings.relocationInProgress)
        }
    }

    private var refreshKey: CallControlRefreshKey {
        CallControlRefreshKey(
            phase: env.calls.snapshot.phase,
            callID: env.calls.snapshot.callID,
            modelState: env.speechModel.snapshot.state,
            serviceReady: env.callEvidenceQueryService != nil
        )
    }

    private func monitorEvidence() async {
        guard let service = env.callEvidenceQueryService else { return }
        while !Task.isCancelled {
            do {
                if let callID = env.calls.snapshot.callID {
                    evidence = try await service.call(id: callID, segmentLimit: 1)
                } else {
                    evidence = try await service.latestCall(segmentLimit: 1)
                }
            } catch {
                return
            }
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

    private func openDetail() {
        env.presentedCallID = evidence?.call.id ?? env.calls.snapshot.callID
        openWindow(id: "call-detail")
        NSApp.activate(ignoringOtherApps: true)
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
