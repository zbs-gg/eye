# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Screen understanding evaluation

### Canonical Reference
A private, sealed description of directly observable screen facts and forbidden inferences against which candidate outputs are evaluated.

### Frontier Reference Oracle
The evaluation-only process in which frontier vision-language model sessions create, adjudicate, and audit Canonical References; it is never a shipping inference provider or product dependency.

### Concealed Mapper
A fresh evaluator that receives identity-blind candidate claims and a Canonical Reference, then records claim-level semantic matches without knowing the candidate method or other mappers' decisions.

### Reliability Qualification
The pre-registered agreement gate that permits a method's quality score to be published only when reference creation and claim mapping are sufficiently reproducible for every supported capability.

Reliability Qualification establishes that a score is trustworthy enough to report; it does not mean the evaluated method is good enough to ship.

### Public Decision
The schema-constrained aggregate derived from private evaluation evidence while excluding frames, case-level text, private case/arm/claim/packet/evaluator identifiers, paths, timestamps, and raw evaluator output.

## Relationships

The Frontier Reference Oracle produces Canonical References. Concealed Mappers connect candidate claims to those references. Reliability Qualification controls which results may enter the Public Decision.

## Capture privacy

### Capture Admission
The authorization decision that permits a captured screen moment to enter local history only while the active login session is definitely unlocked and the foreground process is ordinary user content.

Capture Admission is evaluated again after asynchronous frame work and immediately before persistence, so a lock transition can revoke work that began while the session was still eligible.

### Protected System Shell
A macOS process that renders login or screen-saver surfaces rather than user activity and is therefore never eligible for capture, even when another session signal is stale.

## Call evidence

### Call Envelope

A durable interval that binds one uninterrupted local call recording to its microphone and system-audio evidence, bookmarks, source health, and transcript state.

### Bookmark Checkpoint

A timestamp saved during an active Call Envelope that requests a provisional Whisper transcript for the new interval plus 45 seconds of preceding context without changing capture state.

### Preferred Final Transcript

The authoritative transcript produced by a full-call Whisper pass after recording ends. Bookmark Checkpoint text is a replaceable draft; bookmark timestamps remain durable.

### Source Span

A continuous, sample-addressed epoch of microphone or system-audio evidence. A device restart or sample-rate change closes one Source Span and opens another instead of pretending the stream was continuous.

### Source Gap

A durable statement that a source interval is absent, unavailable, redacted, or dropped. A Source Gap is evidence about missing evidence: UI, export, REST, and MCP surface it instead of guessing speech.

### Evidence Reference

An opaque typed identifier such as `call:42`, `bookmark:7`, or `call-audio-chunk:19`. It resolves only through authenticated local services and never serializes an absolute filesystem path.

### Per-Call Speaker Cluster

An anonymous, stable grouping of speech intervals inside one Call Envelope. It may receive a name from current-call evidence or a manual correction, but it never becomes a cross-call voiceprint.

### Speaker Assignment

A revisioned annotation that maps a Per-Call Speaker Cluster or a selected time range to a human-readable name within one Call Envelope.

### Call Trim

Confirmed physical removal of a selected head, tail, or interior time range from a completed Call Envelope. It preserves evidence outside the range and invalidates every derived view until retained audio is rebuilt.

### Call Automation Event

A minimal signed lifecycle hint created only after its Call Envelope state is durable. It carries a stable event ID and typed Evidence Reference, never transcript text, audio, screenshots, local paths, or API credentials. A receiver uses the reference to read authoritative evidence through authenticated MCP or REST.

### Delivery Outbox

The crash-safe local queue that stores a Call Automation Event in the same database transaction as its source call transition. Delivery is at-least-once, so retries keep the same event ID and receivers deduplicate durably.

## Call evidence relationships

A Call Envelope owns its Bookmark Checkpoints, Source Spans, Source Gaps, Evidence References, Per-Call Speaker Clusters, Speaker Assignments, and any Call Automation Events created while the local hook is enabled. Bookmark Checkpoints produce provisional text; the completed Call Envelope produces one Preferred Final Transcript. Source labels describe microphone/system provenance, while Speaker Assignments describe current-call human attribution without changing that provenance. The Delivery Outbox reports durable transitions without becoming another source of evidence.
