import SwiftUI

/// Automation v1: "Day summary". collect → local LLM → write to a file/Obsidian. A preview-then-write flow.
struct AutomationsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if let store = env.automations {
                AutomationBody(store: store)
            } else {
                ContentUnavailableView("Initializing…", systemImage: "powerplug")
            }
        }
        .navigationTitle("Automations")
    }
}

private struct AutomationBody: View {
    @Bindable var store: DaySummaryStore
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !store.isReady {
                    notReadyCard
                } else {
                    controls
                    scheduleCard
                    if let p = store.preview { previewCard(p) }
                    if let w = store.lastWrite { writeSuccess(w) }
                    if let e = store.errorText, store.phase == .failed { errorCard(e) }
                    auditSection
                }
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await store.refreshAudit() }
    }

    // MARK: blocks

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Day summary", systemImage: "text.append")
                .font(.title2).bold()
            Text("Collects the day's activity from your history, runs it through a local model, and writes "
                 + "a Markdown digest to a folder of your choice. Nothing leaves for the cloud.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var notReadyCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Connections need to be set up", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.headline)
                Text("Set a local LLM and a destination folder — the automation won't run without them.")
                    .foregroundStyle(.secondary)
                Button("Open Connections") { env.selectedSection = .connections }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var controls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("Day", selection: $store.selectedDay, in: ...Date(),
                           displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .disabled(store.isBusy)

                HStack(spacing: 12) {
                    Button {
                        store.startPreview()
                    } label: {
                        Label("Build preview", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy)

                    if store.phase == .summarizing {
                        ProgressView().controlSize(.small)
                        Text("collecting history and summarizing…").foregroundStyle(.secondary)
                        Button("Cancel") { store.cancelPreview() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var scheduleCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Build the digest automatically", isOn: $store.scheduleEnabled)
                if store.scheduleEnabled {
                    Picker("Time", selection: $store.scheduleHour) {
                        ForEach([17, 18, 19, 20, 21, 22, 23], id: \.self) { h in
                            Text(String(format: "%02d:00", h)).tag(h)
                        }
                    }
                    .fixedSize()
                    Toggle("Write immediately without a preview", isOn: $store.autoWriteEnabled)
                        .disabled(!store.hasWrittenManually)
                    Text(store.hasWrittenManually
                         ? "The finished digest will arrive as a notification. Auto-write drops it into the folder without confirmation."
                         : "Auto-write unlocks after the first manual write — check the format by eye first (protection against junk and injections from history).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private func previewCard(_ p: SummaryPreview) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Preview").font(.headline)
                    Spacer()
                    Text("\(p.sessions) sessions · \(p.totalCaptures) frames · \(p.model)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if p.truncated {
                    Label("Long day — only the longest sessions made it into the summary.",
                          systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                if p.outputTruncated {
                    Label("The model's answer was cut off by the token limit — the digest may be incomplete.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                ScrollView {
                    Text(p.markdown)
                        .font(.system(.callout, design: .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button {
                        Task { await store.writeApproved() }
                    } label: {
                        Label(writeButtonTitle, systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.phase == .writing || store.lastWrite != nil)   // don't write the same digest twice

                    if store.phase == .writing {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var writeButtonTitle: String {
        let sub = store.connections.destination.subfolder
        let folder = sub.isEmpty ? "folder" : sub
        // Name from preview.day, not selectedDay — the button must promise exactly what gets written.
        let day = store.preview?.day ?? store.selectedDay
        return "Write to \(folder)/\(DailySummaryService.ymd(day)).md"
    }

    private func writeSuccess(_ w: WriteResult) -> some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.overwritten ? "Overwritten" : "Written").font(.headline)
                    Text(w.path).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2)
                }
                Spacer()
                Button("Show in Finder") { store.revealLastWrite() }
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

    private var auditSection: some View {
        DisclosureGroup("Run history (\(store.audit.count))") {
            if store.audit.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.audit) { e in
                        HStack(spacing: 8) {
                            Image(systemName: e.ok ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(e.ok ? .green : .red)
                            Text(e.action == "write" ? "write" : "preview").bold()
                            Text(e.day).foregroundStyle(.secondary)
                            Text("· \(e.sessions) sessions")
                                .foregroundStyle(.secondary).font(.caption)
                            Spacer()
                            Text(auditTime(e.at)).font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func auditTime(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "d MMM, HH:mm"
        return f.string(from: d)
    }
}
