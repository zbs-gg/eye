# Screen understanding evaluation

Status: protocol and harness implementation in progress. The public status artifact contains no personal
corpus material, case identifiers, captions, labels, timestamps, file paths, or raw adapter errors.

## Current evidence (2026-07-13)

- The protocol, private-corpus policy, normalized schemas, and deterministic human-grounded scorer are
  locked and pass standalone contract checks.
- The native Apple Vision baseline completed a synthetic smoke test and emitted only labels/confidence.
- The process adapter passes handshake, case, shutdown, unsupported, malformed-output, crash, and timeout
  checks on synthetic messages.
- The qualification host could not prove the strict inherited filesystem sandbox: the sandbox exits before
  its malicious canary starts. All six third-party model/parser adapters are therefore recorded as
  `security-unsupported` and have received zero private-corpus access.
- No quality ranking is published. Blind human labels are not sealed, so any ranking would be invalid.

Machine-readable public status:
`docs/evals/screen-understanding-status-2026-07-13.json`.

## Interpretation

`security-unsupported` does not mean a model is inaccurate. It means this Mac did not prove the required
privacy boundary, so the model was deliberately not run against personal history. `smoke-passed` also does
not mean quality-qualified. Product consideration requires the locked private test split, independent
human labels, the R20 quality gate, the exact Apple Silicon runtime, and the R19 resource gate.

## Next valid gate

1. Restore or replace the descendant-process filesystem sandbox and re-run all malicious canaries.
2. Prepare the opaque private corpus without changing the live ZBS Eye database or media.
3. Complete both blind label passes and pass the reliability floor.
4. Run official-checkpoint quality once, with zero retries, followed by exact-runtime quality.
5. Run footprint and recorder/screenshot coexistence only for quality-qualified finalists.
6. Publish only the allowlisted aggregate matrix; keep every case-level artifact private.
