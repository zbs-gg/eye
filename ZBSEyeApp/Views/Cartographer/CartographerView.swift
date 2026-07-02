import SwiftUI

/// "Cartographer" — AI insights for the day: what actually took up time and concrete advice.
/// Fully on-device (localhost LLM). Writes no files — insights live only in the UI.
struct CartographerView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let err = env.dataError {
                // Honest-state: the DB didn't come up — this is a hard error, not "still loading".
                ContentUnavailableView {
                    Label("Memory unavailable", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(err)
                }
            } else if let store = env.cartographer {
                CartographerBody(store: store)
            } else {
                ContentUnavailableView("Initializing…", systemImage: "map")
            }
        }
        .navigationTitle("Daily Insights")
    }
}

// MARK: — main body

private struct CartographerBody: View {
    @Bindable var store: CartographerStore
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !store.llmReady {
                    noLLMCard
                } else if !store.hasConsent {
                    consentCard
                } else {
                    controlsCard
                    if let ins = store.insights { insightsCard(ins) }
                    if let e = store.errorText, store.phase == .failed { errorCard(e) }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: blocks

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Daily Insights", systemImage: "map")
                .font(.title2).bold()
            Text("Looks at your activity for the day and gives 2–3 concrete observations: "
                 + "where your time goes, where you could focus better. "
                 + "Daily fragments go only into your local LLM (localhost-only endpoint) — "
                 + "no cloud.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var noLLMCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("A local LLM is required", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.headline)
                Text("Set an endpoint (Ollama / LM Studio / mlx_lm.server) and a model in Connections — "
                     + "Daily Insights works strictly on-device, your history never goes to the cloud.")
                    .foregroundStyle(.secondary)
                Button("Open Connections") { env.selectedSection = .connections }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    /// One-time explicit consent (Pro #13): before it, screen fragments don't go to the LLM.
    private var consentCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("One-time consent", systemImage: "hand.raised.fill")
                    .foregroundStyle(.tint).font(.headline)
                Text("To produce insights, Daily Insights will send compact fragments of activity for the chosen day "
                     + "(app names, window titles, short snippets of on-screen text) to your local "
                     + "LLM — a localhost-only endpoint. No cloud; nothing is written to disk — only "
                     + "a request to the model on this Mac.")
                    .foregroundStyle(.secondary)
                Button {
                    store.grantConsentAndGenerate()
                } label: {
                    Label("Got it — analyze the day", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var controlsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("Day", selection: $store.selectedDay, in: ...Date(),
                           displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .disabled(store.isBusy)

                HStack(spacing: 12) {
                    Button {
                        store.generate()
                    } label: {
                        Label("Get insights", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)

                    if store.isBusy {
                        ProgressView().controlSize(.small)
                        Text("analyzing the day…").foregroundStyle(.secondary)
                        Button("Cancel") { store.cancel() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func insightsCard(_ ins: CartographerService.Insights) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                // Header with metadata
                HStack(spacing: 10) {
                    Label("Insights of the day", systemImage: "lightbulb.fill")
                        .font(.headline)
                    Spacer()
                    Text(ins.model)
                        .font(.caption).foregroundStyle(.secondary)
                }

                // Insight lines
                if ins.lines.isEmpty {
                    Text("The model returned no insights — try again or switch the model.")
                        .foregroundStyle(.secondary).font(.callout)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(ins.lines.enumerated()), id: \.offset) { _, line in
                            InsightRow(text: line)
                        }
                    }
                }

                if ins.truncated {
                    Label("The model's response was truncated by the token limit.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }

                Divider()

                // Day's activity — mini summary
                ActivitySummaryView(activity: ins.activity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func errorCard(_ msg: String) -> some View {
        GroupBox {
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
    }
}

// MARK: — insight row

private struct InsightRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.callout)
                .padding(.top, 1)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: — activity mini summary

private struct ActivitySummaryView: View {
    let activity: CartographerService.DayActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Day's activity")
                .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                .padding(.bottom, 2)

            HStack(spacing: 20) {
                statBadge(value: "\(activity.totalCaptures)", label: "frames")
                statBadge(value: "\(activity.contextSwitches)", label: "switches")
            }

            if !activity.topApps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(activity.topApps.prefix(5).enumerated()), id: \.offset) { i, u in
                        CartographerAppRow(rank: i + 1, usage: u,
                                           maxMinutes: activity.topApps.first?.minutes ?? 1)
                    }
                }
            }
        }
    }

    private func statBadge(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3).bold().monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct CartographerAppRow: View {
    let rank: Int
    let usage: CartographerService.DayActivity.AppUsage
    let maxMinutes: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("\(rank)").font(.caption2).foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing).monospacedDigit()
            Text(usage.app).font(.callout).lineLimit(1)
            Spacer()
            GeometryReader { geo in
                let fraction = maxMinutes > 0 ? CGFloat(usage.minutes) / CGFloat(maxMinutes) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary).frame(height: 6)
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.7))
                        .frame(width: geo.size.width * fraction, height: 6)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 80, height: 16)
            Text("~\(usage.minutes) min")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 60, alignment: .trailing)
        }
    }
}
