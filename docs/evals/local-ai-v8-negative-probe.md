# Local AI V8 negative physical preflight

This is the compact, immutable record of the first and only physical
`local-ai-v8` bounded preflight. It is not a release qualification result. The
raw report remains under `build/` and is intentionally not checked in.

- Generated: `2026-07-11T00:41:27Z`
- Artifact: `zbs-eye-local-qwen3.5-4b-4bit-v1`
- Model revision: `0e7ffd5c629ef7719d4cbc04069232580bfa9d9c`
- Raw report filename: `local-ai-v8-probe-2026-07-11T00-41-27Z.json`
- Raw report SHA-256: `f481844c5054ff7695c32df2d564e6f78478c15f131f15a7444a2df5ad6466f9`
- Attempts: `24` (`8` fixed cases x `3` locked seeds; no retries)
- Stable cases passed: `7 / 8`
- Parser acceptance: `22 / 24` (`91.6667%`)
- Release qualification: `false`

Ask, Insights, both Summary cases, and Russian Label passed every attempt. The
English Label case passed its perturbation-1 attempt through the required native
tool event. Its production and perturbation-2 attempts instead emitted bare
argument JSON as normal model text. The strict parser correctly rejected both;
V8 performed no repair or JSON fallback.

Revision 9 keeps the same cases, thresholds, strict parser, and no-repair rule,
with freshly derived V9 seeds. It forces the exact Qwen native-tool XML prefix at
decoder level for every built-in structured generation and selects a
purpose-specific tool schema. Summary and Label expose only `status`,
`item1_text`, and `item1_sources`; Ask and Insights retain only the fields and
statuses their renderers use. V8 is never rerun or relabelled.
