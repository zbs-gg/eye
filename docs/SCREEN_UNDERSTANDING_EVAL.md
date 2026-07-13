# Screen understanding evaluation

Status: **partial-qualified after the first private built-in run**. The public artifacts contain aggregate evidence
only: no personal frames, case identifiers, captions, labels, timestamps, local paths, or raw adapter output.

## Current evidence (2026-07-13)

- A frontier vision model created the canonical references; independent evaluator sessions audited them.
  The final reference set contains 200 single images and 100 temporal pairs, with a zero-error final audit
  over 45 cases and 255 slots. This frontier model is evaluation infrastructure and is absent from ZBS Eye.
- Metadata + AX/OCR, Apple Vision, and their deterministic hybrid completed the locked 60-image private
  test split offline.
- Apple Vision label mapping cleared the pre-registered reliability floor. Its published quality result is
  weak for scene description: 0% required-fact recall, 0% critical-text recall, and 42.08% overall.
- Metadata + AX/OCR and the deterministic hybrid remain score-withheld because summary and/or atomic-fact
  mapping did not clear the 90% per-capability agreement floor.
- All six downloaded model/parser adapters remain `security-unsupported`: the qualification Mac did not
  prove the required descendant filesystem sandbox, so they received zero private inputs.

Machine-readable current status:
`docs/evals/screen-understanding-status-2026-07-13.json`.

Aggregate result and reliability details:
[`docs/evals/screen-understanding-v1-results.json`](evals/screen-understanding-v1-results.json) and
[`docs/evals/screen-understanding-v1-results.md`](evals/screen-understanding-v1-results.md).

## Interpretation

`mapping-inconclusive` means the candidate ran, but the independent scorer did not clear the pre-registered
reliability floor. It is not a quality verdict. `security-unsupported` is also not an accuracy verdict: the
adapter was deliberately blocked before private-corpus access. `qualified` means the scoring contract was
reliable enough to publish; it does not imply the method is good.

## Next valid gate

1. Keep Apple Vision only as a lightweight label signal; do not use it as the scene-description layer.
2. Redesign metadata and hybrid scene claims before another pre-registered mapping repeat.
3. Qualify a strict descendant filesystem/network sandbox before any downloaded model sees private data.
4. Run the micro-model matrix once the sandbox is proven, then publish aggregate-only comparisons.
5. Run footprint and recorder/screenshot coexistence only for quality-qualified finalists.
