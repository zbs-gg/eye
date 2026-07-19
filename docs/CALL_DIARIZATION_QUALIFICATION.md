# Local speaker diarization qualification

ZBS Eye can add anonymous, per-call speaker lanes after the Preferred Final Transcript is ready. The
backend is optional, is not installed by default, runs offline in a same-signed helper process, and never
persists voiceprints or acoustic embeddings. Missing assets leave the call usable with its original
`me` / `system` source labels.

## Pinned artifacts

| Component | Immutable identity | License |
|---|---|---|
| FluidAudio | `0.15.5`, commit `19600a485baa4998812e4654b70d2bab8f2c9949` | Apache-2.0 |
| Speaker diarization Core ML models | `FluidInference/speaker-diarization-coreml` revision `1ed7a662fdc7109e36d822db793ee6eebdaf8594` | CC-BY-4.0 |

The managed model set contains 21 checksum-pinned files across four compiled Core ML model directories
plus `plda-parameters.json`, totalling **21,599,417 bytes**. Every path, byte count, and SHA-256 is pinned
in `SpeakerDiarizationModelManifest`; unexpected files, symlinks, missing files, or checksum mismatches fail
closed. The model is downloaded only after an explicit install action and lives below the relocatable data
root at `ai/speech/v1/diarization/speaker-diarization`.

## Physical Apple Silicon qualification

Run date: 2026-07-18. Hardware: Apple M4 Max, 64 GB. Runtime: macOS 26.2, arm64. Input was generated
locally from two public macOS text-to-speech voices and repeated into deterministic 16 kHz mono PCM.
No personal corpus, real call, raw audio, or transcript is committed.

| Fixture | Threshold | Wall time | Real-time factor | Peak RSS | Detected / expected speakers |
|---|---:|---:|---:|---:|---:|
| 15 minutes | 0.6 | 16.32 s | 0.0181 | 442 MiB | 2 / 2 |
| 15 minutes | 0.7 | 12.80 s | 0.0142 | 466 MiB | 2 / 2 |
| 60 minutes | 0.6 | 53.65 s | 0.0149 | 562 MiB | 2 / 2 |
| 60 minutes | 0.7 | 53.25 s | 0.0148 | 621 MiB | 2 / 2 |

The first cold load compiled the models in about 0.91 seconds; subsequent loads compiled in roughly
0.05 seconds. The benchmark also caught a real integration bug: FluidAudio expects the repository name
below the supplied model root. The shipping helper now verifies the exact repository directory and passes
its parent to FluidAudio, which logs that the local model was found without downloading.

## What this proves, and what it does not

This qualifies the pinned runtime, offline directory layout, model integrity path, bounded helper schema,
hour-long processing time, peak process memory, and a basic two-speaker count proxy. It does **not** prove
production accuracy for overlapping speech, shared-room microphones, accents, noisy calls, or arbitrary
speaker counts. Those cases remain correctable in Call Detail: unknown voices stay `Speaker N`, a whole
cluster can be renamed for that call, and a mistaken interval can be reassigned without creating a
cross-call identity.

The idle detector does not load these assets. The helper result contains only timed anonymous cluster IDs;
embeddings and voice features die with the helper process.
