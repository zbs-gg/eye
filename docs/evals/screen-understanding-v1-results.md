# Screen understanding evaluation: first qualified results

Status: **inconclusive**. This report contains aggregate metrics only. The private frames, temporal pairs,
references, raw model outputs, judgments, local paths, timestamps, and case identifiers are not published.

## What is already trustworthy

- The private reference set contains 200 single images and 100 temporal pairs.
- Independent frontier-model annotation and audit reached 91.11% raw joint reliability for single images
  and 98.67% for temporal pairs. A fresh final audit covered 45 cases and 255 reference slots with zero
  remaining errors. The frontier model is evaluation infrastructure only and is absent from ZBS Eye.
- All three zero-download methods completed the locked 60-image test split offline: stored metadata plus
  AX/OCR, Apple Vision classification, and their deterministic hybrid.

## Result

| Method | Outcome | Evidence |
|---|---|---|
| Metadata + AX/OCR | Mapping inconclusive | 51.11% claim agreement across 15 concealed arms; summary 80.00%, atomic facts 36.67%. |
| Apple Vision | Mapping inconclusive | 87.84% label agreement across 15 concealed arms. |
| Deterministic hybrid | Mapping inconclusive | 84.48% claim agreement; summary 93.33%, atomic facts 53.33%, labels 95.77%. |
| Downloaded micro-models and OmniParser | Security unsupported | The strict local sandbox boundary was not proven on the qualification Mac, so no third-party adapter received private inputs. |

No candidate quality score is published. The earlier 9-arm pilot appeared stable enough to score Apple
Vision, but the pre-registered minimum cell size is 15. After increasing the concealed sample to 15 arms per
method, independent mappers disagreed sharply about whether structured claims such as `appName=...` and
`windowTitle=...` satisfy a natural-language required fact, and about the severity of unmatched broad labels.
Repeating judges until one run passes would invalidate the evaluation.

The next gate is a scorer correction: structured metadata matching and unsupported-claim severity need
deterministic, testable rules before independent concealed mapping is repeated. Downloaded models remain
blocked until a strict offline process and filesystem boundary passes its canary; offline environment
variables alone are not enough.

Machine-readable aggregates and allowed hashes are in
[`screen-understanding-v1-results.json`](screen-understanding-v1-results.json).
