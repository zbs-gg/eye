# Changelog

All notable changes to ZBS Eye. The format follows Added / Changed / Fixed sections.

## [Unreleased] — 2026-06-25

### Fixed
- **Live-recording crash (self-AX reentrancy).** While actively recording, ZBS Eye stayed frontmost →
  `CaptureCoordinator` inspected its own process → `AXReader` read our own SwiftUI tree → `kAXValue` on our
  `Slider` synchronously called its `@MainActor Binding.get` (`TimelineView.swift:294`) right on the
  `AXReader` serial queue → `dispatch_assert_queue(main)` → `EXC_BREAKPOINT`. It crashed inside
  `AXCore.perform`, before returning from `await` — so no executor hop helped. The diagnosis came from a Pro
  review. Fix: `guard pid != ownPID` in `runCycle` + a guard in `AXReader.extract/titleOnly`; AX reading by
  role (text → value/title/selected, chrome → title/desc, otherwise nothing — we don't poke `kAXValue` on
  non-text); `Bundle.main` is excluded from ScreenCaptureKit (the timeline doesn't record itself);
  `MainActor.preconditionIsolated()` after the AX branch. A dead-end attempt with a custom `SerialExecutor` was reverted.

### Added
- **LLM model picker from LM Studio/Ollama.** In "Connections" the "Model" field is now a `Picker` from the
  models actually loaded (`GET /v1/models`), not free text input. Auto-load on open, auto-select the first
  available, fallback input + ↻ if the server is silent.
- **Developer ID notarization pipeline** (`scripts/build-notarized.sh` + `docs/NOTARIZE.md`): build with
  Hardened Runtime → Developer ID signature + a secure timestamp → `notarytool submit --wait` → `stapler
  staple` → a Gatekeeper check. The output is a notarized `dist/ZBSEye-notarized-*.zip` (double-click to
  launch, no "Open Anyway"; the signature is stable — rebuilds don't reset TCC permissions).

### Changed
- **Distribution decision: Developer ID + notarization, NOT the Mac App Store.** The App Store requires App
  Sandbox, under which cross-app Accessibility is impossible (the core of text extraction), and an "eternal
  memory, records everything" profile is rejected on privacy — so, like Rewind/screenpipe, distribution is
  outside the App Store. AGENTS.md/README updated.
