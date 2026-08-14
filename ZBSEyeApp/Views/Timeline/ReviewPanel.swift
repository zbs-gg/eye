import AppKit
import SwiftUI

struct ReviewPanel: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var store: DaySummaryStore
    let timelineDay: Date
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                periodControls
                modelCard
                scheduleCard
                runControls
                if let error = store.errorText, store.phase == .failed {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                if let preview = store.preview { review(preview) }
            }
            .padding(14)
        }
        .task {
            store.selectedDay = Calendar.current.startOfDay(for: timelineDay)
            await store.loadSavedSummary()
            await env.ai.connect(.codex)
            await env.ai.connect(.claudeCode)
        }
    }

    private var header: some View {
        HStack {
            Label("Review", systemImage: "sparkles.rectangle.stack")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Close Review")
        }
    }

    private var periodControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Period", selection: $store.selectedPeriodKind) {
                ForEach(ReviewPeriodKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(store.isBusy)
            DatePicker(
                "Ending",
                selection: $store.selectedDay,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .disabled(store.isBusy)
        }
    }

    private var modelCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Review model", selection: modelSelection) {
                    Text("Use main subscription model").tag("inherit")
                    ForEach(modelChoices) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
                .disabled(store.isBusy)

                Text("Review uses only Codex or Claude Code through your existing subscription login. API-key providers are never used here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(preRunEstimate)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if selectedModelID == "gpt-5.4-mini" {
                    Label("Best value · usually about 0.06–0.14 Codex credits", systemImage: "leaf")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if !store.llmReady {
                    Label("Connect Codex or Claude Code, then choose an available subscription model.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(4)
        }
    }

    private var scheduleCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Toggle("Run automatically", isOn: scheduleEnabled)
                if store.scheduleEnabled {
                    Picker("Frequency", selection: $store.scheduleFrequency) {
                        ForEach(ReviewScheduleFrequency.allCases) { frequency in
                            Text(frequency.displayName).tag(frequency)
                        }
                    }
                    Picker("Time", selection: $store.scheduleHour) {
                        ForEach(0..<24, id: \.self) { hour in
                            Text(String(format: "%02d:00", hour)).tag(hour)
                        }
                    }
                    if store.scheduleFrequency == .weekly {
                        Picker("Day", selection: $store.weeklyWeekday) {
                            Text("Monday").tag(2)
                            Text("Tuesday").tag(3)
                            Text("Wednesday").tag(4)
                            Text("Thursday").tag(5)
                            Text("Friday").tag(6)
                            Text("Saturday").tag(7)
                            Text("Sunday").tag(1)
                        }
                    }
                    Toggle("Also export automatically", isOn: $store.autoWriteEnabled)
                        .disabled(!store.hasWrittenManually || !store.canExport)
                    Text("If the Mac was asleep, Eye runs only the latest missed Review. Background access is a separate permission from the button above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    private var runControls: some View {
        HStack(spacing: 8) {
            Button {
                store.startPreview()
            } label: {
                Label(store.preview == nil ? "Build Review" : "Run again", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy || !store.llmReady)

            if store.phase == .summarizing {
                ProgressView().controlSize(.small)
                Button("Cancel") { store.cancelPreview() }
            }
        }
    }

    private func review(_ preview: SummaryPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if preview.coverageIncomplete {
                Label(
                    "Capture was incomplete in this period. Missing history does not prove inactivity.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if preview.contextTruncated || preview.outputTruncated {
                Label(
                    preview.outputTruncated
                        ? "The model answer hit its output limit."
                        : "The model context limit reduced the included sessions.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(preview.markdown)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            usageLine(preview)

            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    let coverage = preview.coverageIncomplete
                        ? "⚠️ Capture was incomplete in this period. Missing history does not prove inactivity.\n\n"
                        : ""
                    NSPasteboard.general.setString(
                        coverage + preview.markdown,
                        forType: .string
                    )
                }
                if store.canExport {
                    Button("Save to folder") { Task { await store.writeApproved() } }
                        .disabled(store.phase == .writing)
                } else {
                    Button("Choose folder…") { env.connections.pickDestination() }
                }
            }
            .buttonStyle(.bordered)

            if let write = store.lastWrite {
                Button(write.overwritten ? "Saved · Show in Finder" : "Saved · Show in Finder") {
                    store.revealLastWrite()
                }
                .buttonStyle(.link)
            }
        }
    }

    @ViewBuilder
    private func usageLine(_ preview: SummaryPreview) -> some View {
        let usage = preview.usage
        HStack(spacing: 5) {
            Image(systemName: "gauge.with.dots.needle.50percent")
            if let usage {
                Text("in \(usage.inputTokens.map(String.init) ?? "—")")
                Text("· cache \(usage.cachedInputTokens.map(String.init) ?? "—")")
                Text("· out \(usage.outputTokens.map(String.init) ?? "—")")
                if let reasoning = usage.reasoningOutputTokens {
                    Text("· reasoning \(reasoning)")
                }
            } else {
                Text("Token usage was not reported")
            }
            if let billing = preview.billing {
                Text("· \(billing.amount.formatted(.number.precision(.fractionLength(3)))) credits")
                Text("(rate \(billing.rateCardDate))")
            } else if preview.provenance.providerID == AIProvider.claudeCode.rawValue {
                Text("· included in Claude subscription")
            } else {
                Text("· subscription price unavailable")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var scheduleEnabled: Binding<Bool> {
        Binding(
            get: { store.scheduleEnabled },
            set: { enabled in
                guard enabled else {
                    if let provider = selectedProvider {
                        _ = env.ai.setAutomaticConsumerConsent(
                            .scheduledSummary, enabled: false, for: provider
                        )
                    }
                    store.scheduleEnabled = false
                    return
                }
                guard let provider = selectedProvider,
                      env.ai.setAutomaticConsumerConsent(
                          .scheduledSummary, enabled: true, for: provider
                      ) else {
                    store.errorText = "Choose an authenticated subscription model before enabling the schedule."
                    store.phase = .failed
                    return
                }
                store.scheduleEnabled = true
            }
        )
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: {
                guard let selection = env.ai.reviewSelection else { return "inherit" }
                return "\(selection.providerID)|\(selection.modelID)"
            },
            set: { value in
                if store.scheduleEnabled {
                    if let provider = selectedProvider {
                        _ = env.ai.setAutomaticConsumerConsent(
                            .scheduledSummary, enabled: false, for: provider
                        )
                    }
                    store.scheduleEnabled = false
                }
                if value == "inherit" {
                    env.ai.inheritMainModelForReview()
                } else if let choice = modelChoices.first(where: { $0.id == value }) {
                    _ = env.ai.commitReviewSelection(
                        provider: choice.provider,
                        modelID: choice.modelID
                    )
                }
                Task { await store.loadSavedSummary() }
            }
        )
    }

    private var modelChoices: [ReviewModelChoice] {
        [AIProvider.codex, .claudeCode].flatMap { provider in
            env.ai.availableModels(for: provider).map {
                ReviewModelChoice(provider: provider, modelID: $0)
            }
        }
    }

    private var selectedProvider: AIProvider? {
        env.ai.settings.selectionSnapshot(for: .manualSummary)
            .flatMap { AIProvider(rawValue: $0.providerID) }
    }

    private var selectedModelID: String? {
        env.ai.settings.selectionSnapshot(for: .manualSummary)?.modelID
    }

    private var preRunEstimate: String {
        guard let selection = env.ai.settings.selectionSnapshot(for: .manualSummary) else {
            return "Before the run: up to about 24k input tokens and 800 output tokens."
        }
        if let estimate = ReviewRateCard.billing(
            providerID: selection.providerID,
            modelID: selection.modelID,
            usage: LLMUsage(inputTokens: 24_000, outputTokens: 800)
        ) {
            let credits = estimate.amount.formatted(
                .number.precision(.fractionLength(3))
            )
            return "Before the run: up to about 24k input + 800 output tokens, about \(credits) credits at the \(estimate.rateCardDate) rate. Actual usage appears after completion."
        }
        if selection.providerID == AIProvider.claudeCode.rawValue {
            return "Before the run: up to about 24k input + 800 output tokens, included in the Claude subscription. Actual usage appears after completion."
        }
        return "Before the run: up to about 24k input tokens and 800 output tokens. Exact subscription cost is unavailable."
    }
}

private struct ReviewModelChoice: Identifiable, Hashable {
    let provider: AIProvider
    let modelID: String
    var id: String { "\(provider.rawValue)|\(modelID)" }
    var label: String {
        let recommended = modelID == "gpt-5.4-mini" ? " · Best value" : ""
        return "\(provider.displayName) · \(modelID)\(recommended)"
    }
}
