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
    @State private var speakerRevision: CallEvidenceSpeakerRevision?
    @State private var speakerStatus: CallSpeakerEvidenceStatus = .unavailable
    @State private var speakerNameDraft = ""
    @State private var speakerKeyToRename: String?
    @State private var intervalForNewSpeaker: CallEvidenceSpeakerInterval?
    @State private var trimStartSeconds: Double = 0
    @State private var trimEndSeconds: Double = 0
    @State private var trimInitialized = false
    @State private var trimInProgress = false
    @State private var showTrimConfirmation = false
    @State private var playback = CallPlaybackStore()
    @State private var waveform = CallWaveformStore()
    @State private var waveformLoaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let evidence {
                    header(evidence)
                    sourceSection(evidence)
                    bookmarkSection(evidence)
                    speakerSection(evidence)
                    transcriptSection(evidence)
                    trimSection(evidence)
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
            .frame(maxWidth: 1_040, alignment: .leading)
        }
        .navigationTitle("Call")
        .task(id: CallDetailRefreshKey(
            callID: callID,
            modelState: env.speechModel.effectiveState,
            speakerModelState: env.speakerModel.snapshot.state,
            retryGeneration: retryGeneration
        )) {
            await monitor()
        }
        .onDisappear { playback.stop() }
        .alert("Name this speaker", isPresented: Binding(
            get: { speakerKeyToRename != nil },
            set: { if !$0 { speakerKeyToRename = nil } }
        )) {
            TextField("Speaker name", text: $speakerNameDraft)
            Button("Cancel", role: .cancel) { speakerKeyToRename = nil }
            Button("Save") {
                guard let key = speakerKeyToRename else { return }
                speakerKeyToRename = nil
                Task { await renameSpeaker(key: key, name: speakerNameDraft) }
            }
        } message: {
            Text("The name applies only to this call. Eye does not create a reusable voiceprint.")
        }
        .alert("Create a speaker", isPresented: Binding(
            get: { intervalForNewSpeaker != nil },
            set: { if !$0 { intervalForNewSpeaker = nil } }
        )) {
            TextField("Speaker name", text: $speakerNameDraft)
            Button("Cancel", role: .cancel) { intervalForNewSpeaker = nil }
            Button("Create & assign") {
                guard let interval = intervalForNewSpeaker else { return }
                intervalForNewSpeaker = nil
                Task { await reassign(interval, target: .newNamedSpeaker(speakerNameDraft)) }
            }
        } message: {
            Text("Only the selected interval moves. The original microphone/system source stays unchanged.")
        }
        .alert("Delete the selected audio?", isPresented: $showTrimConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete permanently", role: .destructive) {
                if let evidence { Task { await trim(evidence: evidence) } }
            }
        } message: {
            Text("\(clock(trimStartSeconds))–\(clock(trimEndSeconds)) (\(clock(trimEndSeconds - trimStartSeconds))) will be physically removed, including derived transcript and speaker evidence. This cannot be undone.")
        }
    }

    private func header(_ evidence: CallEvidencePage) -> some View {
        let presentation = CallPresentationState.resolve(
            evidence: evidence,
            modelState: env.speechModel.effectiveState
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
                Button {
                    env.workspace.returnToTimeline(
                        moment: dateFromMs(evidence.call.startTs)
                    )
                } label: {
                    Label("Open in Timeline", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
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
            if let playbackError = playback.errorMessage {
                Label(playbackError, systemImage: "exclamationmark.triangle")
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
        let title = source == .me
            ? String(localized: "Microphone")
            : String(localized: "System audio")
        let status = hasGap
            ? String(localized: "Recorded with gaps")
            : (available ? String(localized: "Recorded") : String(localized: "Not recorded"))
        return HStack {
            Label(title, systemImage: source == .me ? "mic" : "speaker.wave.2")
            Spacer()
            Text(status)
                .font(.caption)
                .foregroundStyle(hasGap ? Color.orange : Color.secondary)
            if available,
               let service = env.callEvidenceQueryService,
               let mediaRoot = env.storage?.mediaDirectory {
                Button {
                    playback.toggle(
                        callID: callID,
                        source: source,
                        service: service,
                        mediaRoot: mediaRoot
                    )
                } label: {
                    Image(systemName: playback.source == source && playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(playback.source == source && playback.isPlaying ? "Pause" : "Play this source")
            }
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
                        Text(segment.source == .me
                             ? String(localized: "Mic")
                             : String(localized: "System"))
                            .font(.caption.weight(.semibold))
                            .frame(width: 54, alignment: .leading)
                        Text(segment.text)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
                if hasMoreSegments {
                    Button(loadingMore
                           ? String(localized: "Loading…")
                           : String(localized: "Load more")) {
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

    @ViewBuilder
    private func speakerSection(_ evidence: CallEvidencePage) -> some View {
        if let speakerRevision, !speakerRevision.speakers.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Speakers").font(.headline)
                    Spacer()
                    if speakerRevision.canUndoCorrection {
                        Button("Undo speaker edit") {
                            Task { await undoSpeakerCorrection() }
                        }
                        .buttonStyle(.borderless)
                    }
                    Text("LOCAL · THIS CALL ONLY")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                Text("Click a name to correct the whole speaker. Use an interval menu to move only that piece.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(speakerRevision.speakers.enumerated()), id: \.element.clusterKey) { index, speaker in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            speakerNameDraft = speaker.label
                            speakerKeyToRename = speaker.clusterKey
                        } label: {
                            HStack(spacing: 7) {
                                Circle().fill(speakerColor(index)).frame(width: 8, height: 8)
                                Text(speaker.label).font(.callout.weight(.semibold))
                                Image(systemName: "pencil").font(.caption2)
                            }
                        }
                        .buttonStyle(.plain)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(Array(speaker.intervals.enumerated()), id: \.offset) { _, interval in
                                Menu {
                                    ForEach(speakerRevision.speakers, id: \.clusterKey) { target in
                                        if target.clusterKey != speaker.clusterKey {
                                            Button("Assign to \(target.label)") {
                                                Task { await reassign(interval, target: .existingCluster(clusterKey: target.clusterKey)) }
                                            }
                                        }
                                    }
                                    Divider()
                                    Button("Create speaker…") {
                                        speakerNameDraft = ""
                                        intervalForNewSpeaker = interval
                                    }
                                } label: {
                                    Label(
                                        "\(offset(interval.startMs, from: evidence.call.startTs))–\(offset(interval.endMs, from: evidence.call.startTs))",
                                        systemImage: interval.source == .me ? "mic" : "speaker.wave.2"
                                    )
                                    .font(.caption.monospacedDigit())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(speakerColor(index).opacity(0.13), in: Capsule())
                                }
                                .menuStyle(.borderlessButton)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                if speakerRevision.intervalsTruncated {
                    Text("Some speaker intervals are omitted from this view; agent/API reads report the truncation honestly.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else if evidence.call.state != .recording {
            VStack(alignment: .leading, spacing: 8) {
                Text("Speakers").font(.headline)
                Text(speakerStatusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if speakerStatus == .degraded {
                    Button("Retry speaker processing") {
                        Task {
                            actionErrorMessage = await env.retryCallSpeakerProcessing(callID: callID)
                            retryGeneration &+= 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else if env.speakerModel.snapshot.state == .absent {
                    Button("Separate speakers · \(speakerModelSize)") {
                        env.speakerModel.install()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(env.speakerModel.busy)
                } else if env.speakerModel.snapshot.state == .paused
                            || env.speakerModel.snapshot.state == .failed {
                    Button("Retry speaker model") { env.speakerModel.install() }
                        .buttonStyle(.borderedProminent)
                        .disabled(env.speakerModel.busy)
                }
                if env.speakerModel.busy { ProgressView().controlSize(.small) }
            }
        }
    }

    private var speakerStatusText: String {
        if speakerStatus == .degraded {
            return String(localized: "Eye could not separate speakers for this call. The transcript and source labels remain available.")
        }
        switch env.speakerModel.snapshot.state {
        case .absent:
            return String(localized: "Install the small local model once to separate anonymous speakers. The transcript already works without it.")
        case .downloading, .paused, .verifying:
            return String(localized: "Preparing the local speaker model. Recording and transcripts remain available.")
        case .ready:
            return String(localized: "Finding speakers locally. Unknown voices stay anonymous until you name them.")
        case .failed:
            return String(localized: "Speaker processing is unavailable. The transcript remains available without invented names.")
        }
    }

    private var speakerModelSize: String {
        StorageSettingsStore.format(SpeakerDiarizationModelManifest.fluidAudio0155.expectedBytes)
    }

    @ViewBuilder
    private func trimSection(_ evidence: CallEvidencePage) -> some View {
        if let endTs = evidence.call.endTs {
            let total = max(1, Double(endTs - evidence.call.startTs) / 1_000)
            let microphoneAvailable = sourceAvailable(.me, in: evidence)
            let systemAvailable = sourceAvailable(.system, in: evidence)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Edit recording").font(.headline)
                    Spacer()
                    if trimEndSeconds - trimStartSeconds >= 0.5 {
                        Text("Selected \(clock(trimStartSeconds))–\(clock(trimEndSeconds)) · \(clock(trimEndSeconds - trimStartSeconds))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Drag across the waveform, then refine either edge. Only audio inside the blue range is deleted; the rest of the call keeps its original time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if waveform.loading {
                    ProgressView("Building a lightweight preview…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 92)
                } else {
                    CallRangeWaveformView(
                        totalSeconds: total,
                        microphone: waveform.snapshot.microphone,
                        system: waveform.snapshot.system,
                        startSeconds: $trimStartSeconds,
                        endSeconds: $trimEndSeconds
                    )
                    HStack(spacing: 14) {
                        if microphoneAvailable {
                            Label("You", systemImage: "mic.fill")
                                .foregroundStyle(.red)
                        }
                        if systemAvailable {
                            Label("Others", systemImage: "speaker.wave.2.fill")
                                .foregroundStyle(.blue)
                        }
                        if let waveformError = waveform.errorMessage {
                            Label(waveformError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                }

                HStack(spacing: 8) {
                    Button("Last minute") { selectTail(seconds: 60, total: total) }
                    if total > 5 * 60 {
                        Button("Last 5 minutes") { selectTail(seconds: 5 * 60, total: total) }
                    }
                    Spacer()
                    if trimEndSeconds - trimStartSeconds >= 0.5,
                       let service = env.callEvidenceQueryService,
                       let mediaRoot = env.storage?.mediaDirectory {
                        if playback.isPlaying {
                            Button("Stop preview", systemImage: "stop.fill") { playback.stop() }
                        } else {
                            if microphoneAvailable {
                                Button("Preview you", systemImage: "mic.fill") {
                                    playback.playRange(
                                        callID: callID,
                                        source: .me,
                                        startSeconds: trimStartSeconds,
                                        endSeconds: trimEndSeconds,
                                        service: service,
                                        mediaRoot: mediaRoot
                                    )
                                }
                            }
                            if systemAvailable {
                                Button("Preview others", systemImage: "speaker.wave.2.fill") {
                                    playback.playRange(
                                        callID: callID,
                                        source: .system,
                                        startSeconds: trimStartSeconds,
                                        endSeconds: trimEndSeconds,
                                        service: service,
                                        mediaRoot: mediaRoot
                                    )
                                }
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Delete selected audio…", role: .destructive) {
                        playback.stop()
                        showTrimConfirmation = true
                    }
                }
                .buttonStyle(.bordered)
                .disabled(trimInProgress || trimEndSeconds - trimStartSeconds < 0.5)
            }
            .onAppear {
                guard !trimInitialized else { return }
                trimStartSeconds = 0
                trimEndSeconds = 0
                trimInitialized = true
            }
        }
    }

    private func sourceAvailable(_ source: CallAudioSource, in evidence: CallEvidencePage) -> Bool {
        evidence.sourceSpans.contains { $0.source == source && $0.availability == .available }
    }

    private func selectTail(seconds: Double, total: Double) {
        playback.stop()
        trimStartSeconds = max(0, total - min(seconds, total))
        trimEndSeconds = total
    }

    private func monitor() async {
        while !Task.isCancelled {
            await refresh(resetSegments: false)
            guard let evidence else { return }
            let presentation = CallPresentationState.resolve(
                evidence: evidence,
                modelState: env.speechModel.effectiveState
            )
            let waitingForSpeakers = env.speakerModel.snapshot.state == .ready
                && evidence.call.state != .recording
                && [.unavailable, .processing].contains(speakerStatus)
            guard waitingForSpeakers
                    || [.finalizing, .transcribing, .provisional].contains(presentation.kind) else {
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func refresh(resetSegments: Bool) async {
        guard let service = env.callEvidenceQueryService else { return }
        do {
            guard let page = try await service.call(id: callID, segmentLimit: 80) else {
                errorMessage = String(localized: "This call no longer exists.")
                return
            }
            let revisionChanged = evidence?.preferredRevision?.id != page.preferredRevision?.id
            evidence = page
            if !waveformLoaded,
               let endTs = page.call.endTs,
               let mediaRoot = env.storage?.mediaDirectory {
                waveformLoaded = true
                await waveform.load(
                    callID: callID,
                    durationSeconds: max(1, Double(endTs - page.call.startTs) / 1_000),
                    service: service,
                    mediaRoot: mediaRoot
                )
            }
            if let envelope = try await service.envelope(callID: callID) {
                speakerRevision = envelope.preferredSpeakerRevision
                speakerStatus = envelope.speakerStatus
            }
            if resetSegments || revisionChanged {
                segments = page.segments
                hasMoreSegments = page.hasMoreSegments
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renameSpeaker(key: String, name: String) async {
        guard let repository = env.callRepository else { return }
        do {
            _ = try await repository.renameSpeakerCluster(
                callID: callID,
                clusterKey: key,
                displayName: name,
                nowMs: nowMs()
            )
            await refresh(resetSegments: false)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func reassign(
        _ interval: CallEvidenceSpeakerInterval,
        target: CallSpeakerCorrectionTarget
    ) async {
        guard let repository = env.callRepository else { return }
        do {
            _ = try await repository.reassignSpeakerInterval(
                callID: callID,
                selection: .init(source: interval.source, startMs: interval.startMs, endMs: interval.endMs),
                target: target,
                nowMs: nowMs()
            )
            await refresh(resetSegments: false)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func undoSpeakerCorrection() async {
        guard let repository = env.callRepository else { return }
        do {
            _ = try await repository.undoSpeakerCorrection(callID: callID, nowMs: nowMs())
            await refresh(resetSegments: false)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func trim(evidence: CallEvidencePage) async {
        guard let service = env.callEvidenceDeletionService else { return }
        trimInProgress = true
        defer { trimInProgress = false }
        do {
            let from = evidence.call.startTs + Int64(trimStartSeconds * 1_000)
            let to = evidence.call.startTs + Int64(trimEndSeconds * 1_000)
            _ = try await service.redact(callID: callID, fromMs: from, toMs: to, nowMs: nowMs())
            trimInitialized = false
            waveformLoaded = false
            waveform = CallWaveformStore()
            retryGeneration &+= 1
            await refresh(resetSegments: true)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    private func nowMs() -> Int64 { msFromDate(Date()) }

    private func clock(_ seconds: Double) -> String {
        let value = max(0, Int64(seconds))
        return String(format: "%02lld:%02lld", value / 60, value % 60)
    }

    private func speakerColor(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal]
        return colors[index % colors.count]
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
        dateFromMs(milliseconds)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func duration(_ call: CallRow) -> String {
        let end = call.endTs ?? msFromDate(Date())
        let totalSeconds = max(0, end - call.startTs) / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        let value = if hours > 0 {
            "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            "\(minutes)m \(seconds)s"
        } else {
            "\(seconds)s"
        }
        return String(localized: "\(value) · local recording")
    }

    private func offset(_ milliseconds: Int64, from start: Int64) -> String {
        let seconds = max(0, milliseconds - start) / 1_000
        return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
    }

    private func bookmarkLabel(_ state: CallBookmarkState) -> String {
        switch state {
        case .preparing, .pending: String(localized: "Transcribing")
        case .deferredCapacity: String(localized: "Queued")
        case .ready: String(localized: "Ready")
        case .readyDegraded: String(localized: "Ready · gap")
        case .failed: String(localized: "Retry needed")
        case .satisfiedByFinal: String(localized: "Included in final")
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
