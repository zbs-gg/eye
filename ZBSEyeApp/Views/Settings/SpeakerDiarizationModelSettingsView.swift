import SwiftUI

struct SpeakerDiarizationModelSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let model = env.speakerModel
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Separate speakers")
                        .font(.callout.weight(.semibold))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                action
            }
            if model.snapshot.state == .downloading || model.snapshot.state == .verifying {
                ProgressView(
                    value: Double(model.snapshot.receivedBytes),
                    total: Double(max(1, model.snapshot.expectedBytes))
                )
                .progressViewStyle(.linear)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task { await model.refresh() }
    }

    @ViewBuilder
    private var action: some View {
        let model = env.speakerModel
        switch model.snapshot.state {
        case .absent:
            Button("Install · \(modelSize)") { model.install() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.busy)
        case .paused, .failed:
            Button("Retry") { model.install() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.busy)
        case .ready:
            HStack(spacing: 8) {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("Remove") { model.remove() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(model.busy)
            }
        case .downloading, .verifying:
            ProgressView().controlSize(.small)
        }
    }

    private var statusText: String {
        let snapshot = env.speakerModel.snapshot
        return switch snapshot.state {
        case .absent:
            String(localized: "Optional local model. Installs only when you choose; no voiceprints leave this call.")
        case .downloading:
            String(localized: "Downloading \(StorageSettingsStore.format(snapshot.receivedBytes)) of \(StorageSettingsStore.format(snapshot.expectedBytes))…")
        case .paused:
            String(localized: "Download paused at \(StorageSettingsStore.format(snapshot.receivedBytes)).")
        case .verifying:
            String(localized: "Verifying every model file locally…")
        case .ready:
            String(localized: "FluidAudio · local · \(modelSize) on disk")
        case .failed:
            String(localized: "Calls and transcripts are safe. The model can be retried.")
        }
    }

    private var modelSize: String {
        StorageSettingsStore.format(SpeakerDiarizationModelManifest.fluidAudio0155.expectedBytes)
    }
}
