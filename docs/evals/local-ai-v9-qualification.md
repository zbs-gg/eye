# Local AI V9 release qualification

This is the immutable release-qualification record for
`zbs-eye-local-qwen3.5-4b-4bit-v1` at revision
`0e7ffd5c629ef7719d4cbc04069232580bfa9d9c`. The raw reports remain under the
gitignored `build/local-ai-results/` directory; their SHA-256 digests below bind
this checked-in record to the single no-retry physical runs.

## Quality

- Protocol: `local-ai-v9`
- Bounded preflight:
  `local-ai-v9-probe-2026-07-11T01-06-39Z.json`
- Preflight SHA-256:
  `54e1f621da3be21a36995f2f7dd3056065d367176e34b26fb96751fcc6be8630`
- Preflight result: 8/8 stable cases and 24/24 parser acceptance
- Release report: `local-ai-v9-2026-07-11T01-22-07Z.json`
- Release-report SHA-256:
  `00bcfd6b0adace064e9e8f8d6cfb93074e2981963c75552a443898f3041f4406`
- Attempts: 192, with no retries
- Stable cases: 62/64 (96.875%)
- English / Russian stable pass rate: 96.875% / 96.875%
- Ask / Insights / Summary / Label: 100% / 100% / 100% / 87.5%
- Strict native-tool parser acceptance: 100%
- Unsupported-evidence refusal rate: 100%

Five attempts across two Label cases missed the locked semantic concept rubric:
all three variants of `v6-en-label-08`, and the production plus second
perturbation variants of `v6-ru-label-02`. No output was repaired or selected
from retries. The locked release thresholds still pass.

## Performance

- Protocol: `local-ai-performance-v1`
- Report: `local-ai-performance-v1-2026-07-11T01-32-28Z.json`
- Report SHA-256:
  `f654adea36d58949cb5468570ffe7e6d845317279874b781d22857602aef6d48`
- Run: offline, Release, serial, no retries, 1,158.694 seconds
- Device: Mac16,5, 64 GiB, arm64, macOS 26.2
- 2K-context TTFT p95: 2.496 s cold / 2.658 s warm
- Full-context TTFT p95: 8.309 s cold / 7.996 s warm
- Minimum observed decode speed: 43.404 tokens/s
- Maximum incremental MLX peak: 3,409,149,642 bytes
- Cancellation drain: 0.0143 s (2K) / 0.0121 s (full)
- Retained growth after 50 full-context generations: 0 bytes
- Unload: at least 99.99989% released in at most 0.0157 s

Cold means a fresh verified MLX model container after releasing the previous
container and clearing the MLX cache. It does not purge the macOS disk page
cache. Recorder coexistence and the production service graph are verified by
the separate release build and installed-app dogfood gates.
