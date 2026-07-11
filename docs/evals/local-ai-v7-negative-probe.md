# Local AI V7 negative physical preflight

This is the compact, immutable record of the first and only physical
`local-ai-v7` bounded preflight. It is not a release qualification result. The
raw report remains under `build/` and is intentionally not checked in.

- Generated: `2026-07-11T00:22:21Z`
- Artifact: `zbs-eye-local-qwen3.5-4b-4bit-v1`
- Model revision: `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c`
- Raw report filename: `local-ai-v7-probe-2026-07-11T00-22-21Z.json`
- Raw report SHA-256: `8ff6f3f2ea960c8e43491c5978690efc6fbc2141433ab7cc09db362c4c00e930`
- Attempts: `24` (`8` fixed cases x `3` locked seeds; no retries)
- Stable cases passed: `5 / 8`
- Parser acceptance: `18 / 24` (`75%`)
- Release qualification: `false`

Ask and Insights passed all six attempts. Russian Summary passed all three.
English Summary failed one seed after turning the non-citable coverage metadata
`Sessions: 2` into the work claim `Completed 2 sessions on Friday`. V7 correctly
kept coverage metadata outside the numeric allowlist. Both English and Russian
Label attempts started the required native `emit_zbs_eye_answer` call, but all
six were cut off before the call closed because the production Label request
allowed only 60 output tokens.

Revision 8 keeps the strict native-call parser, the same cases, and the same
three-variant seed policy with freshly derived V8 seeds. It raises the Label
output budget enough to finish the existing tool schema,
requires specific labels, and marks date/count metadata as non-output context.
V7 is never rerun or relabelled.
