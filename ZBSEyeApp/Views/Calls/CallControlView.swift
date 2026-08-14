import AppKit
import SwiftUI

struct CallControlView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @State private var evidence: CallEvidencePage?
    @State private var choosingOneCallMode = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Call recording", selection: callModeBinding) {
                ForEach(CallRecordingMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(env.calls.snapshot.phase == .starting || env.calls.snapshot.phase == .finalizing)

            HStack(spacing: 8) {
                status
                    .frame(maxWidth: .infinity, alignment: .leading)
                controls
            }
        }
        .padding(compact ? 7 : 9)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .task(id: refreshKey) { await monitorEvidence() }
        .confirmationDialog(
            "Record this Call",
            isPresented: $choosingOneCallMode,
            titleVisibility: .visible
        ) {
            Button("Audio only") { env.calls.start(mode: .audio) }
            Button("Audio and video") { env.calls.start(mode: .audioVideo) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This one-time choice does not change the default in Settings.")
        }
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
        case .finalizing:
            Label("Saving call…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .pendingTranscription, .ready, .readyDegraded, .failed:
            if let evidence {
                let presentation = CallPresentationState.resolve(
                    evidence: evidence,
                    modelState: env.speechModel.effectiveState
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
        case .pendingTranscription, .ready, .readyDegraded, .failed:
            if evidence != nil || env.calls.snapshot.callID != nil {
                Button("Open") { openDetail() }
                    .controlSize(.small)
            }
            Button { startCall() } label: {
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
            Button("Start") { startCall() }
                .controlSize(.small)
                .disabled(env.storageSettings.relocationInProgress)
        }
    }

    private var callModeBinding: Binding<CallRecordingMode> {
        Binding(
            get: {
                env.calls.isActive
                    ? env.calls.snapshot.recordingMode
                    : env.audioSettings.callRecordingMode
            },
            set: { mode in
                if env.calls.isActive {
                    env.calls.setRecordingMode(mode)
                } else {
                    env.audioSettings.callRecordingMode = mode
                }
            }
        )
    }

    private func startCall() {
        if env.audioSettings.callRecordingMode == .off {
            choosingOneCallMode = true
        } else {
            env.calls.start()
        }
    }

    private var refreshKey: CallControlRefreshKey {
        CallControlRefreshKey(
            phase: env.calls.snapshot.phase,
            callID: env.calls.snapshot.callID,
            modelState: env.speechModel.effectiveState,
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
                modelState: env.speechModel.effectiveState
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
