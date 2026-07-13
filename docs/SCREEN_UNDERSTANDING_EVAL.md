# Screen understanding evaluation

Status: **inconclusive after the first private built-in run**. The public artifacts contain aggregate evidence
only: no personal frames, case identifiers, captions, labels, timestamps, local paths, or raw adapter output.

## Current evidence (2026-07-13)

- A frontier vision model created the canonical references; independent evaluator sessions audited them.
  The final reference set contains 200 single images and 100 temporal pairs, with a zero-error final audit
  over 45 cases and 255 slots. This frontier model is evaluation infrastructure and is absent from ZBS Eye.
- Metadata + AX/OCR, Apple Vision, and their deterministic hybrid completed the locked 60-image private
  test split offline.
- Their quality scores are withheld. The correctly powered 15-arm concealed mapping repeat exposed an
  underdetermined scorer contract for structured metadata and unsupported-claim severity.
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
adapter was deliberately blocked before private-corpus access.

## Next valid gate

1. Make structured metadata matching and unsupported-claim severity deterministic and testable.
2. Bind mapper receipts and packet contents so judgments cannot be replayed or self-certified.
3. Repeat the independent concealed 15-arm mapping once; do not rerun judges until one passes.
4. Publish quality only for methods whose mapping contract clears the floor.
5. Qualify a strict descendant filesystem/network sandbox before any downloaded model sees private data.
6. Run footprint and recorder/screenshot coexistence only for quality-qualified finalists.
