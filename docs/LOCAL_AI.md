# ZBS Eye Local AI

ZBS Eye's built-in generative provider runs inside the macOS app with MLX. Model files are downloaded only after an explicit user action, stored under the resolved ZBS Eye data root, verified before first load, and never embedded in the application bundle. Runtime loading is local-directory-only; it does not ask Hugging Face or MLX to resolve or download a model.

## Pinned runtime and artifact

| Qualified physical configuration | Product artifact | Immutable revision | Download | Total-token ceiling |
|---|---|---|---:|---:|
| `Mac16,5`, Apple M4 Max, 64 GiB | `mlx-community/Qwen3.5-4B-4bit` | `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c` | 3,061,129,077 bytes | 8,192 |

The package graph is pinned to `mlx-swift-lm 3.31.4`, `mlx-swift 0.31.4`, and `swift-transformers 1.3.3`. `BuiltInModelManifest` is the authority for every required filename, immutable URL, exact byte count, SHA-256 digest, aggregate manifest fingerprint, generation profile, and hardware envelope. A manifest change is release work and requires a new artifact version and a full qualification run.

The complete Swift package graph is checked in at
`ZBSEye.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, even though the rest of the
generated project is ignored. Build, test, release, and notarization commands require those exact resolved
versions. The tokenizer bridge is implemented in-tree; release builds do not bypass package-plugin or Swift
macro validation and do not execute the upstream convenience macro.

The product catalog contains only Qwen3.5 4B. The previously measured Qwen3 1.7B, Qwen3.5 2B, and Qwen3 4B artifacts remain in the qualification inventory for reproducibility, but are neither downloadable nor advertised by the product.

The support resolver is intentionally narrower than the model's theoretical capabilities: it enables the built-in model only for the exact physical configuration tested so far (`Mac16,5`, Apple M4 Max, 64 GiB, macOS 15+, arm64). Other Apple Silicon configurations and Intel Macs see an honest not-yet-qualified/unsupported state while external providers remain available. No M1 or 16 GiB support is inferred from the faster development Mac. Expanding this matrix requires the oldest/slowest newly declared physical device to pass the versioned quality, latency, memory, cancellation, and recorder-isolation gates.

## License provenance

The selected upstream Qwen model family is Apache-2.0. The MLX Swift runtime packages are MIT, while `swift-transformers` is Apache-2.0. The application downloads the MLX-community conversion from its immutable revision; it does not redistribute the generative model bytes inside the app.

- Product conversion: `mlx-community/Qwen3.5-4B-4bit` at `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c`; upstream `Qwen/Qwen3.5-4B` at `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a`, Apache-2.0.
- Runtime: `ml-explore/mlx-swift-lm 3.31.4` and `ml-explore/mlx-swift 0.31.4`, MIT; `huggingface/swift-transformers 1.3.3`, Apache-2.0.
- Bundled retrieval model: `intfloat/multilingual-e5-small` at `614241f622f53c4eeff9890bdc4f31cfecc418b3`, MIT.

The immutable upstream license and provenance URLs are embedded alongside each downloadable artifact inventory in `BuiltInModelManifest.swift`. The app bundle also contains `LOCAL_AI_NOTICES.txt` with exact release revisions and license links. Release verification must stop if any revision, byte count, digest, or license differs.

## Verification and local smoke

Ordinary tests use tiny injected byte fixtures and never download model weights. A real runtime smoke requires an already downloaded model directory:

```bash
scripts/verify-local-ai.sh --runtime-smoke --model-dir /absolute/path/to/verified/model
```

The smoke runs as a Release test build with the network guards active. It first verifies the full offline inventory, then exercises the shipping `AskService → LocalInferenceService → MLXLocalRuntimeDriver` path through native-tool parsing and local provenance. A second production Ask request is cancelled while the real MLX worker is active; the test waits for drain and proves that the service unloads its final model reference. A model cache that is not already in the production `installed/<uuid>/payload` layout is exposed through temporary same-volume APFS clones, never links or copies from a repository identifier.

The V9 release-quality and performance gates share one fail-closed environment validator. A qualifying report requires the exact `Mac16,5` / 64 GiB / arm64 envelope, a Release test bundle, active `HF_HUB_OFFLINE=1` and `TRANSFORMERS_OFFLINE=1` guards, disabled downloads, the three exact package pins, and the exact product manifest/protocol identity. Reports include the machine/OS/kernel/CPU facts, app build, source revision and tree state, Xcode/Swift/SDK versions, `Package.resolved` SHA-256 and package versions, and model revision/fingerprint. Any missing or mismatched field aborts before generation. Benchmark outputs and machine/build/runtime evidence belong under the gitignored `build/local-ai-results/` directory.

The release-candidate quality contract is `docs/evals/local-ai-v9.json`. It locks 64 unique synthetic cases (32 English and 32 Russian), evenly split across Ask, Daily Insights, Day Summary, and Activity Label, including eight refusal cases. Every case runs with three freshly derived deterministic V9 seeds for 192 no-retry attempts. The gate captures the exact channel-separated production `LLMRequest`: ZBS Eye Local receives only its unconditional native-tool contract, while external providers receive only visible-output instructions. The same structured-generation helper is used by production and qualification: it forces the exact Qwen XML native-function prefix at decoder level and selects `LocalAIAnswerToolContract.schema(for:)` from the output purpose. Ask and Insights expose only their used fields and statuses; Summary and Label expose only `status`, `item1_text`, and `item1_sources`. The strict parser still accepts exactly one native tool event with zero normal text and performs no repair. Summary v4, Label v4, the 160-token Label cap, cases, scorer, and thresholds are unchanged from V8. The physical report is generated under the gitignored `build/local-ai-results/` directory and is never selected from retries. The passing single-run quality and performance evidence is bound by hashes in the [V9 qualification record](evals/local-ai-v9-qualification.md). The failed V8 and V7 preflights are retained as [V8](evals/local-ai-v8-negative-probe.md) and [V7](evals/local-ai-v7-negative-probe.md) non-release negative records; the failed immutable V6 baseline remains in its [negative-run record](evals/local-ai-v6-negative-run.md), and V5 remains an earlier successful qualification artifact.

Before spending the full gate time, an optional bounded preflight runs one fixed English and one fixed Russian V9 case for each of the four consumers, with all three freshly derived deterministic V9 seeds (8 cases, 24 attempts):

```bash
scripts/verify-local-ai.sh --quality-probe --model-dir /absolute/path/to/verified/model
```

The probe uses the same production-request, purpose-specific schema, decoder-prefix generation helper, parser, renderer, and scorer path as the release gate. It requires every selected case to pass all three seeds and 100% parser acceptance, writes `local-ai-v9-probe-*.json`, and records `releaseQualification: false`. It is diagnostic evidence only: it neither changes the immutable V9 fixtures/protocol/seeds nor substitutes for the 64-case release report.

## U9 recorder coexistence and concurrency gates

The required model-backed safe-writer coexistence invocation is separate from ordinary fixtures:

```bash
scripts/verify-local-ai.sh --recorder-coexistence-gate --model-dir /absolute/path/to/verified/model
```

It runs a Release build on the exact qualified machine with offline guards and a clean source revision. The gate uses the production `MLXLocalRuntimeDriver → LocalInferenceService → LLMRouter → AIComputeCoordinator` chain while a fixed recorder workload writes real screen and audio records through `IngestService` and GRDB under a throwaway root. It captures an AI-off baseline, then measures 50 sequential generations, capture trigger/completion/coalescing/failure counts, capture and ingest p95, audio queue high-water/drop count, DB errors, embed-queue growth, active gaps, and process physical footprint. The checked thresholds are the KTD2 zero-error/zero-drop contract, no active gap beyond two 3-second ticks, at most 10% capture/ingest p95 regression, exact DB reconciliation, and at most 5.5 GiB incremental footprint.

The JSON report deliberately records `releaseQualification: false`: the unhosted test bundle uses safe synthetic screen/audio records and does not open ScreenCaptureKit, AX/OCR, microphone, system-audio, VAD, or speech-recognition hardware. It does not replace the staging-app hardware recorder run. U9 still requires the staging app to keep real screen and explicitly enabled audio recording active through load, full-context prefill, 50 generations, cancellation, memory pressure, and unload, then reconcile its DB/media counts against the same-machine baseline. A safe-writer green report must never be presented as that physical hardware green.

The bounded concurrency gate has normal and Thread Sanitizer invocations:

```bash
scripts/verify-local-ai.sh --concurrency-stress
scripts/verify-local-ai.sh --concurrency-stress-tsan
```

Both run deterministic activation/revocation, cancellation/drain, shutdown, and relocation/compute-drain interleavings. The same dedicated invocation also runs the provisioner's activation-outbox, in-flight candidate-load relocation, suspended-verification relocation, and shutdown recovery tests. `--concurrency-stress-tsan` enables Xcode Thread Sanitizer only for these pure actor/provisioner tests. MLX/Metal performance and physical model gates are not representative under TSan and remain unsanitized; if the active Xcode/MLX toolchain refuses a TSan run, archive that failure and run `--concurrency-stress` as the required bounded compensating actor suite rather than claiming sanitizer coverage.

## Privacy and resource boundaries

- Built-in prompts, history excerpts, generated tokens, and model files remain on the Mac.
- Model download is the only network operation associated with this provider and happens before inference through the dedicated provisioner.
- Recording, audio, ingestion, retention, and database writes do not wait on inference.
- Built-in generations are serialized; background work yields to interactive Ask.
- Backfill embeddings never overlap MLX generation. Until a tier proves coexistence safe, foreground semantic retrieval releases e5 before MLX starts.
- Disk preflight preserves the 2 GiB capture reserve plus 512 MiB safety and never prunes history to make room for a model.

## Provisioning and storage lifecycle

The built-in provider has separate, truthful states for the installed inventory, the current download or
verification job, the user's activation intent, and the loaded runtime. A partial download is never a ready
model. Downloads stream into a staging directory, resume only against the same strong validator, verify every
manifest file, write the verified marker last, and atomically promote the candidate. Reinstall and replacement
keep the last-known-good version available until the candidate has passed the same checks.

Model files live below `StorageLocation.generativeAIModelRoot()` in the currently resolved ZBS Eye data root.
Moving ZBS Eye storage drains downloads and inference, copies and verifies installed and partial model assets,
then flips the root. If the configured external volume disappears, the app refuses to create a second model
inventory in the default location. It reports the unavailable root instead.

Model weights and provisioning metadata are deliberately excluded from iCloud backups. They are reproducible
downloads, while the backup's job is to protect irreplaceable history. The live SQLite database is backed up
online; it is never copied together with active WAL files. Removing the built-in model removes only its verified
and partial assets, not recordings, search data, provider preferences, or generated history.

## Provider choice and consent

`ZBS Eye Local` is one provider, not a model marketplace. The screen also supports Codex, OpenRouter,
Anthropic, Moonshot AI/Kimi, Z.AI/GLM, Xiaomi/MiMo, OpenAI, Claude Code, Ollama, LM Studio, and an advanced
localhost connection. Each provider owns its authentication, catalog, selected model, and optional
recommendation. Catalog discovery cannot activate a model; activation changes one global `Provider · Model`
pair through an explicit, revision-checked intent.

Local providers do not need egress consent. Cloud, broker, and signed-in CLI providers show the actual
recipient and requested consumer scopes before activation. Cancelling leaves the previous pair intact.
Previously granted manual-use consent does not silently authorize new background features such as generated
activity labels. Revocation and provider/model changes invalidate queued work, and stale results are discarded.

The REST and MCP surfaces do not expose model setup, credentials, consent, or generation. Those remain GUI-only
product boundaries. Existing authenticated search/timeline/diagnostic contracts stay unchanged.

## Troubleshooting

**The Download & enable button is unavailable.** The hardware support check is intentionally exact. This
release qualifies only `Mac16,5` with 64 GiB on macOS 15 or newer. Use Ollama, LM Studio, Codex, or another
provider on an unqualified Mac; do not override the check and infer support from architecture alone.

**The download pauses for disk space.** Free enough space for the remaining bytes plus verification scratch,
the 2 GiB capture reserve, and the 512 MiB safety margin. ZBS Eye never deletes history to make room for a
model. Resume from AI Models after space is available.

**A download restarts instead of resuming.** The remote object changed, its validator was weak or missing, or
the partial range did not match the manifest. Restarting from zero is the safe behavior. Repeated checksum or
length failures are release-blocking: preserve diagnostics and do not bypass verification.

**The model is installed but Ask is unavailable.** Check that the global active pair is `ZBS Eye Local ·
Qwen3.5 4B`, the configured storage volume is mounted, and AI Models reports the runtime as ready. A provider
selected after the download intentionally wins; discovery and completed provisioning do not override a later
choice or an explicit off state.

**Generation was cancelled or timed out.** Interactive Ask may preempt background generation. Memory pressure,
relocation, provider revocation, or a changed selection can also cancel work. The recorder continues. A runtime
that does not acknowledge cancellation is marked unhealthy and must unload before another local request.

**Offline verification.** After the model is installed, disconnect the network and run Ask or Daily Insights.
Any network attempt during built-in inference is a release blocker. The model loader accepts only the verified
local directory; it never resolves a repository identifier at runtime.

## Release checklist

- Keep MLX packages, model revision, per-file hashes, aggregate fingerprint, sizes, generation settings,
  hardware envelope, licenses, and evaluation protocol immutable together.
- Run the complete English/Russian quality set and physical performance/resource/recording-isolation gates.
- Exercise interrupted download, restart, replacement failure, remove/reinstall, relocation, and offline use.
- Confirm the app archive contains e5 plus required notices, but no generative weights, partial downloads,
  credentials, logs, or evaluation history.
- Confirm authenticated REST/MCP compatibility and that no AI endpoint or MCP tool was added.
- Stage and dogfood the signed app before replacing `/Applications/ZBS Eye.app`; install the final verified
  artifact exactly once and then run the installed-app smoke.
