# Screen understanding evaluation: first public run

Status: **partial-qualified**. This report contains aggregate metrics only. The private frames, temporal pairs,
references, raw model outputs, judgments, local paths, timestamps, and case identifiers are not published.

## What is already trustworthy

- The private reference set contains 200 single images and 100 temporal pairs.
- Independent frontier-model annotation and audit reached 91.11% raw joint reliability for single images
  and 98.67% for temporal pairs. A fresh final audit covered 45 cases and
  255 reference slots with zero remaining errors. The frontier model is evaluation infrastructure only and is absent from ZBS Eye.
- All three zero-download methods completed the locked 60-image test split offline: stored metadata plus
  AX/OCR, Apple Vision classification, and their deterministic hybrid.

## Result

| Method | Outcome | Evidence |
|---|---|---|
| Metadata + AX/OCR | Mapping inconclusive | 86.36% claim agreement across 15 concealed arms; summary 80.00%, atomic facts 89.66%. |
| Apple Vision | Qualified label baseline | 100.00% concealed label agreement; overall 42.08%, required-fact recall 0.00%, critical-text recall 0.00%, severity-weighted hallucination 25.00%. |
| Deterministic hybrid | Mapping inconclusive | 96.55% claim agreement; summary 86.67%, atomic facts 93.33%, labels 100.00%. |
| Downloaded micro-models and OmniParser | Security unsupported | The strict local sandbox boundary was not proven on the qualification Mac, so no third-party adapter received private inputs. |

Only Apple Vision receives a published quality score. Its label decisions were perfectly reproducible on the
concealed sample, but zero required-fact and critical-text recall make it unsuitable as a scene-description
layer by itself. Metadata + AX/OCR and the hybrid remain score-withheld because at least one capability stayed
below the pre-registered 90% mapping-agreement floor. Repeating judges until they pass is forbidden.

## Next gate

retain Apple Vision only as a lightweight label baseline, redesign metadata and hybrid scene claims, and prove a local sandbox before any downloaded micro-model receives private inputs.

Machine-readable aggregates and allowed hashes are in
[`screen-understanding-v1-results.json`](screen-understanding-v1-results.json).
