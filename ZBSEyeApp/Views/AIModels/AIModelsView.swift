import SwiftUI

/// Temporary compatibility route until the Timeline-first shell removes the
/// old sidebar destination in U5. It opens the same compact app-wide setup.
struct AIModelsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ContentUnavailableView {
            Label("AI is optional", systemImage: "sparkles")
        } description: {
            Text("Eye works without AI. Setup now uses one compact flow.")
        } actions: {
            Button("Open AI Setup") { env.aiSetup.present(origin: .settings) }
                .buttonStyle(.borderedProminent)
        }
    }
}
