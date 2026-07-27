import SwiftUI

struct WhisperModelSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let model = env.speechModel
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisper")
                        .font(.callout.weight(.semibold))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                action
            }
            if !model.usesHandy
                && (model.snapshot.state == .downloading || model.snapshot.state == .verifying) {
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
        let model = env.speechModel
        if model.snapshot.state == .absent, model.handySnapshot.state == .checking {
            ProgressView().controlSize(.small)
        } else if model.usesHandy {
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
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
    }

    private var statusText: String {
        let model = env.speechModel
        if model.snapshot.state == .absent, model.handySnapshot.state == .checking {
            return String(localized: "Checking Handy for an existing compatible local Whisper model…")
        }
        if model.usesHandy {
            return String(localized: "Using \(model.effectiveModelName ?? "Whisper") from Handy. Eye stores no second model copy.")
        }
        let snapshot = model.snapshot
        return switch snapshot.state {
        case .absent:
            "Optional local Whisper. The base app stays small; recordings wait safely without it."
        case .downloading:
            "Downloading \(formatted(snapshot.receivedBytes)) of \(formatted(snapshot.expectedBytes))…"
        case .paused:
            "Download paused at \(formatted(snapshot.receivedBytes))."
        case .verifying:
            "Verifying the model locally…"
        case .ready:
            "Whisper Large V3 Turbo · local · \(modelSize) on disk"
        case .failed:
            "The recording is safe. The model can be retried."
        }
    }

    private var modelSize: String {
        formatted(WhisperModelManifest.largeV3Turbo.expectedBytes)
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
