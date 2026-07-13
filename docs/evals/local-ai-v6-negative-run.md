# Local AI V6 negative physical run

This is the compact, immutable record of the first and only physical
`local-ai-v6` release-gate run. It is a failed qualification result, retained
to explain why the corrected contract starts at revision 7. The 181 KB raw
report is intentionally not checked in.

- Generated: `2026-07-10T23:43:45Z`
- Artifact: `zbs-eye-local-qwen3.5-4b-4bit-v1`
- Model revision: `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c`
- Raw report filename: `local-ai-v6-2026-07-10T23-43-45Z.json`
- Raw report SHA-256: `b038747c77bf44ff5a8b56209d310a8b12d85945b046e135554a766cfc8f57df`
- Attempts: `192` (`64` cases × `3` locked seeds; no retries)
- Stable cases passed: `13 / 64` (`20.3125%`)
- Parser acceptance: `48 / 192` (`25%`)
- Unsupported refusal: `50%`
- Stable language rates: English `25%`, Russian `15.625%`
- Stable consumer rates: Ask `6.25%`, Insights `75%`, Summary `0%`, Label `0%`
- Native calls accepted by consumer: Ask `6 / 48`, Insights `40 / 48`,
  Summary `2 / 48`, Label `0 / 48`

The dominant failure was channel selection, not a parser crash: the mixed
production prompts described both the native-tool path and a visible-text
fallback, while the pinned Qwen template also made tool invocation optional.
The model therefore emitted ordinary prose or bare argument JSON in most
attempts. V6 correctly rejected those outputs because its contract permits
exactly one native `emit_zbs_eye_answer` event and no normal text or repair.

Revision 7 preserves the parser boundary and fixtures, but separates the
built-in native-tool production request from external visible-output requests.
