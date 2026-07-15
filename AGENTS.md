# AGENTS.md — guide for agents and reviewers

This file is for AI agents and people opening the repository for the first time, to understand/verify/
extend the code. It reads in 5 minutes and saves hours. Build details are in [`BUILD.md`](BUILD.md).

> **The product brand is "ZBS Eye".** The internal codename in the code is `ZBSEye`: the Xcode target/scheme
> `ZBSEye`, types `ZBSEyeDatabase`/`ZBSEyeHTTPServer`/…, the binary `ZBS Eye.app`, the signature "ZBS Eye Dev".
> That's normal (brand ≠ code name) — do NOT rename identifiers. Externally (bundle id `gg.zbs.eye`, display
> name, data paths `~/…/ZBS Eye`, text) it's "ZBS Eye" everywhere.
> Compact in-app sentences may use the established `Eye` shorthand after the product context is clear.

## What it is

**ZBS Eye** (codename `ZBSEye`) is a native macOS "eternal memory" recorder: it continuously records what
happens on the computer (screen + accessibility text/OCR + audio with transcription), indexes it, and serves
it over a local REST + MCP surface. Capture and storage are **100% local, with no account required.** Optional
generative providers may receive explicitly approved text excerpts after the user connects and consents; raw
screenshots, audio, and file paths stay local. A light, native alternative to the
proprietary equivalents (which moved to subscription + cloud).

- Swift 6 (strict concurrency = `complete`), SwiftUI, target macOS 15+.
- Storage: GRDB (`DatabasePool` + WAL) + FTS5 (external-content) + sqlite-vec (statically linked).
- Search: hybrid FTS + semantics (multilingual-e5-small, 384-dim) via RRF.
- ~9,300 lines of Swift. No App Sandbox (Hardened Runtime) — otherwise SCK + cross-app AX + a local server
  are impossible. Self-signed "ZBS Eye Dev" signature (without a paid Apple Developer account).

## Build and run

```bash
xcodegen generate                                 # project.yml → ZBSEye.xcodeproj (sources globbed from ZBSEyeApp/)
xcodebuild -project ZBSEye.xcodeproj -scheme ZBSEye -configuration Debug build
bash scripts/make-signing-cert.sh                 # ONCE: self-signed cert → stable TCC (see gotchas)
bash scripts/build-release.sh                     # Release + sign + bundle the e5 model + zip
```

CLI modes (single binary): `--mcp-read-only` (new least-privilege MCP setup), legacy `--mcp` / explicit
`--mcp-full` (full MCP), `--import-history`, `--relocate <path>`,
`--backup-now`, `--backup-verify <file>`.

## Architecture map (`ZBSEyeApp/`)

| Folder | What |
|---|---|
| `App/` | `ZBSEyeMain` (@main, CLI/GUI dispatch), `ZBSEyeApp` (Scene + AppDelegate), `AppEnvironment` (owns the service graph, `bootstrap()`) |
| `Capture/` | `CaptureCoordinator` (capture loop, idle/active/burst modes), `FramePipeline` (capture+HEIC+phash, ONE actor), `AXReader` (accessibility extraction, dedicated thread, per-PID health) |
| `Audio/` | `AudioCoordinator`, mic/system engines, `VADSegmenter`, `TranscriptionService` (SFSpeech on-device) |
| `Data/` | `ZBSEyeDatabase` (pool + migrations), `StorageManager` (media), **`StorageLocation`** (the single path resolver — see invariants), `StorageRelocation` (move), `BackupManager` (iCloud), `RetentionManager`, `IngestService` (the only writer) |
| `Search/` | `SearchService` (FTS+vector RRF), `EmbeddingService` (e5), `TimelineService`, `VectorBackfill` |
| `Server/` | `ZBSEyeHTTPServer` (FlyingFox REST, 127.0.0.1, Bearer), `KeychainStore`, DTO |
| `MCP/` | `ZBSEyeMCPServer` (stdio, proxies into the GUI instance) |
| `Automations/` | `HistoryImporter` (history import), `DailySummaryService`, `ExportService` |
| `State/` | `@MainActor @Observable` stores (Recording/Permissions/Storage/Backup/…) |
| `Views/` | SwiftUI (Timeline, Settings, onboarding) |

## Invariants (break them and you break things)

1. **A single source of the data path — `StorageLocation`.** The DB, media, the port file, server.log,
   automations — EVERYTHING is resolved through `StorageLocation.dataRoot()/databaseURL()/mediaDirectory()/portURL()`.
   Do NOT hardcode `Application Support/ZBS Eye`. This is needed so relocate (move to an external SSD) and
   helper processes (`--mcp`, `--backup-now`) see one place. Exceptions: the iCloud backup and user export —
   intentionally separate paths.
2. **One writer — `IngestService`.** Non-Sendable (`CVPixelBuffer`/`CMSampleBuffer`/`AXUIElement`/`VNRequest`)
   live and die inside a single actor; only Sendable leaves it.
3. **FTS5 external-content:** compute `snippet()`/`bm25()` in a subquery PURELY over the FTS table. Add a
   condition over a joined table (`c.ts BETWEEN …`) to the same SELECT and SQLite loses the FTS context
   ("unable to use function snippet"). Pattern: `WITH hits AS (… FROM text_fts WHERE MATCH … LIMIT N)`.
4. **Capture/storage remain local; egress is narrow and consent-gated.** REST is localhost-only with auth on
   everything except `/health`; the bearer token stays in the data-protection Keychain. Only an explicitly
   connected generative provider may receive the named consumer's approved text excerpts. Never send raw media,
   file paths, credentials, or history for an unapproved/background consumer.
5. **Keep Media is the only automatic retention contract.** Fresh empty profiles start at 5 GB; upgrades never
   shorten retention without an explicit selection and authoritative reconciliation. `Forever` closes automatic
   deletion. Critically low disk pauses capture for every policy and never overrides the selected retention promise.

## Gotchas (already stepped on — don't again)

- **e5 = mean-pooling, not CLS.** `swift-embeddings .encode()` returns CLS — for retrieval that's 3×+ worse
  cross-lingually. We take the mean.
- **Keychain — data-protection, NOT legacy.** `KeychainStore` uses `kSecUseDataProtectionKeychain`. The
  legacy file keychain HANGS the main thread on an ACL prompt when reading a token created by a different
  signature (after reinstalling a re-signed app) → bootstrap hangs forever.
- **Stable TCC = a stable signature.** Self-signed "ZBS Eye Dev" + installing into `/Applications` (not
  DerivedData). The `designated requirement` pins the leaf cert → permissions survive rebuilds. Traps:
  `bash set -u` eats the first byte of a multibyte character next to `"$VAR"` (fix — `${VAR}`); p12 import
  needs the system `/usr/bin/openssl` (LibreSSL), not Homebrew OpenSSL 3.x; trust in the user domain without
  sudo; SPM dependencies with an explicit identity require `CODE_SIGN_STYLE=Manual`.
- **A live SQLite MUST NOT go into iCloud Drive** (WAL desync + file eviction = corruption). Only a compressed
  snapshot goes to iCloud via `pool.backup(to:)` (online backup, consistent under WAL).
- **Moving/backing up the live database — `pool.backup(to:)`, NOT a file copy** (a file cp mid-checkpoint =
  a broken DB). media — copy-not-move (the old location is intact until verify+flip).
- **Capture is paused during relocate** (`pauseForMaintenance` + draining in-flight), otherwise a boundary
  frame/audio segment is orphaned (outside the backup snapshot / outside the media copy).
- **The AX tree is often empty on Electron apps** — hence adaptive AX-first + OCR-fallback per-app, not
  "we beat Electron". OCR is an equal path, not a rare fallback.

## How to review (where the risk lives)

1. **Data loss** (the main thing): any path where 50k+ frames could be lost/orphaned/split. Look at
   `StorageRelocation` (copy-not-move? verify BEFORE flip?), `BackupManager` (is the online backup consistent?),
   `StorageLocation` (volume unavailable → do NOT start on legacy "from scratch", anti-split-brain), retention.
2. **Swift 6 concurrency:** actor isolation, Sendable at boundaries, `@unchecked Sendable` only in explicit
   bridges, blocking C calls (AX) on a dedicated thread, not in the cooperative pool.
3. **Security:** auth on everything except `/health`, path traversal in serving frames/files (numeric id →
   lookup, the media-directory boundary), no egress.
4. **Honest state:** the UI doesn't lie (the recording icon, permission statuses, "busy").

Check both the build and the unhosted `ZBSEyeUnitTests` target. Pure production policies are shared into
that target explicitly so verification does not launch an ad-hoc `gg.zbs.eye` app or churn the installed
app's TCC grants. Distribution and OS-integration changes still require installed-app REST/MCP/SQLite dogfood.

## Status (what works)

Working and verified live: screen capture (HEIC + AX/OCR), audio + transcription, hybrid search
(cross-lingual), timeline, REST + MCP, import of previous history, retention, **relocatable storage**,
**iCloud backup** (compressed, keep-N, on exit), size tracking, the daily-summary automation, export.

Deferred: source_id for multi-monitor dedup (~0.15% of frames, documented in `HistoryImporter`).

**Distribution — Developer ID + notarization (NOT the App Store).** The App Store requires App Sandbox,
under which cross-app AX (the core) is impossible + a "records everything" profile gets rejected — so, like
Rewind/screenpipe, the target is a notarized Developer ID outside the App Store. The pipeline is ready:
`scripts/build-notarized.sh` (Hardened Runtime + Developer ID + timestamp + notarytool + staple), cert/cred
setup — `docs/NOTARIZE.md`. Release qualification binds an exact version/build/source ZIP to its manifest,
reverse-verifies the draft download, and exercises the installed artifact across unlocked capture and a real
lock → unlock transition before publication. `scripts/build-release.sh` remains only the self-signed local
fallback ("Open Anyway"; its cdhash/TCC churn is exactly what notarization removes).
