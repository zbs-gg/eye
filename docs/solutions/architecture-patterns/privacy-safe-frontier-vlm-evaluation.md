---
title: Privacy-safe frontier VLM evaluation for tiny screen models
date: 2026-07-13
category: architecture-patterns
module: screen-understanding-bench
problem_type: architecture_pattern
component: testing_framework
severity: high
applies_when:
  - "Private visual examples need high-capability semantic annotation without making a frontier model a product dependency."
  - "Only aggregate benchmark evidence may be published."
tags: [frontier-vlm, private-corpus, blinded-evaluation, authenticated-evidence, declassification, screen-understanding]
---

# Privacy-safe frontier VLM evaluation for tiny screen models

## Context

A tiny local screen-understanding method may be suitable for a product while being too weak to create its own trustworthy evaluation labels. Asking one person to describe hundreds of screenshots and temporal pairs is also slow, inconsistent, and difficult to repeat.

The useful boundary is therefore not “never use a large model anywhere.” It is: **a frontier VLM may manufacture and audit private reference truth, but it is never a candidate, runtime dependency, or product inference path**. ZBS Eye records this separation in its product contract: the frontier oracle runs before candidate output exists and is absent from the app, candidate runners, runtime measurements, and public artifacts (`docs/plans/2026-07-13-001-feat-screen-understanding-eval-plan.md:28-34`).

This creates two different trust problems:

1. Can independent evaluators produce a reliable canonical reference without seeing candidate output?
2. Can fresh evaluators map candidate claims to that sealed reference reproducibly enough for deterministic scoring?

## Guidance

### 1. Freeze the contract before any annotation or inference

Lock the corpus split, observable fact slots, forbidden inferences, ambiguity and abstention rules, reliability floors, and public schema first. Use a bounded structured reference rather than a free-form caption. The current rubric, for example, separates directly visible surface, content, and state from unsupported intent or off-screen outcomes (`tools/screen-understanding-bench/annotation/RUBRIC.md:7-21`).

Canonical-reference workers must see only the locked visual evidence and rubric. They must not see candidate names, outputs, scores, production metadata, split membership, or prior labels (`tools/screen-understanding-bench/annotation/RUBRIC.md:3-5`). Candidate output remains unavailable until the reference is sealed (`tools/screen-understanding-bench/annotation/RUBRIC.md:50-55`).

### 2. Replace manual labeling with independent frontier passes

Run two independent frontier-VLM annotation passes. Compare their overlapping work semantically; matching local IDs alone is not agreement. Send only disagreements to a third fresh evaluator, then run a final audit. Correction and re-audit are valid; silently overriding a failed reliability gate is not (`docs/plans/2026-07-13-001-feat-screen-understanding-eval-plan.md:38-43`).

This is the practical answer to “how can one person manually label a screen corpus?” The person defines and approves the rubric. Independent frontier sessions do the repetitive visual work. Deterministic gates decide whether the resulting oracle is usable.

Current limitation: the temporal lane and claim-mapping lane bind their independent work to stronger evidence, but the single-frame lane still imports legacy labels without annotation-pass receipts (`tools/screen-understanding-bench/annotation/single_frame_lane_v4.py:192-237`). Until that lane adopts the same authenticated challenge/receipt boundary, its annotation-level independence is supported by distinct declared sessions and downstream audit rather than cryptographic provenance.

### 3. Seal references before interpreting candidates

After the canonical reference is sealed, run candidates without rewriting it. Normalize candidate output into atomic, capability-specific claims. Give fresh, identity-blind mapper sessions only the reference and evidence needed to judge those claims.

Use a primary mapper plus a hidden mapper on a concealed duplicate sample. They must not share decisions. A third mapper sees only disagreements (`tools/screen-understanding-bench/mapping/MAPPING_RUBRIC.md:47-52`). Structured-looking fields do not receive automatic credit: the actual value must entail a locked fact (`tools/screen-understanding-bench/mapping/MAPPING_RUBRIC.md:8-28`).

If any supported capability misses its pre-registered agreement floor, withhold that method's quality score. Do not rerun judges until a favorable result appears.

### 4. Bind mapper independence to evidence, not names

Different display names or caller-written session IDs do not prove independent claim mapping. Pre-issue a random one-time challenge bound to the packet digest and evaluator role (`tools/screen-understanding-bench/common/evaluator_receipt.py:248-277`). After evaluation, issue a signed receipt that binds the exact packet bytes, exact output bytes, role, session identity, and challenge (`tools/screen-understanding-bench/common/evaluator_receipt.py:307-334`). Claim-mapping roles fail closed instead of accepting legacy unsigned receipts (`tools/screen-understanding-bench/common/evaluator_receipt.py:330-334`).

Aggregation must verify those digests and the consumed session claim, then require distinct sessions and challenges for every role (`tools/screen-understanding-bench/common/evaluator_receipt.py:437-465`, `tools/screen-understanding-bench/common/evaluator_receipt.py:520-558`). Score only the verified bytes; never validate one file and later score a mutable reread.

### 5. Declassify into a new public object

Never publish a hand-redacted private report. Construct a new object from an allowlist of aggregate fields. Reject case text, private case/arm/claim/packet/evaluator identifiers, paths, timestamps, raw outputs, captions, labels, secret-like strings, and undersized strata. ZBS Eye's publication validator requires exact keys and recursively rejects private-shaped fields and values (`tools/screen-understanding-bench/common/public_results.py:89-138`, `tools/screen-understanding-bench/common/public_results.py:163-222`).

Render public prose from that validated object so the Markdown and JSON cannot drift independently.

### Compact workflow

1. Lock protocol, rubric, splits, reliability floors, privacy policy, and public schema.
2. Create opaque private annotation packets.
3. Run independent frontier passes A and B.
4. Adjudicate disagreements with a fresh session; audit; seal or fail.
5. Run lightweight candidates against the sealed corpus.
6. Create content-addressed, model-identity-blind claim packets.
7. Pre-issue one-time challenges; run independent primary and hidden mappers.
8. Adjudicate mapping disagreements with a third authenticated session.
9. Deterministically score only receipt-bound bytes; withhold unreliable cells.
10. Generate and validate an aggregate-only public decision.

## Why This Matters

The pattern separates four questions that are easy to blur:

- Is the private reference reliable?
- Is semantic claim mapping reproducible?
- Is the tiny candidate accurate enough?
- Is the candidate small, fast, private, and operationally safe enough to ship?

That separation prevents the failures found during this evaluation:

- Human-only labeling made the benchmark operationally unrealistic. (session history)
- A single frontier response could be confidently wrong or internally inconsistent. (session history)
- Candidate-aware annotation would turn the reference into a reaction to the candidate.
- Caller-authored receipts and different names did not prove independent sessions. (session history)
- Automatic credit for metadata-shaped claims inflated scores without checking the values.
- Re-running evaluators until agreement rose would hide uncertainty.
- Hand-redaction and permissive public schemas left leak channels for private text and paths. (session history)

A method may become reliable enough to score yet still be too weak to use. Conversely, an apparently strong aggregate must remain unpublished when the mapping contract is unreliable. “Qualified” describes the evidence contract, not product quality (`docs/SCREEN_UNDERSTANDING_EVAL.md:27-32`).

## When to Apply

Use this pattern when:

- the shipping method must remain tiny, local, cheap, or offline;
- private examples cannot become a public dataset;
- semantic visual judgments are too rich for exact-match labels;
- human annotation at the needed scale is unrealistic;
- candidate output can be decomposed into atomic claims;
- reproducibility matters more than producing a leaderboard number.

Do not use this pattern as permission to send live product screenshots to a frontier model. The frontier VLM belongs to isolated evaluation infrastructure only. Downloaded runtimes also remain blocked from private input until their full descendant process tree has a proven filesystem and network boundary.

## Examples

### Keep the oracle independent

```text
Bad:
  candidate = tiny_model.describe(screen)
  score = frontier_vlm.judge(screen, candidate)

Good:
  canonical = seal(independent_frontier_annotations(screen))
  candidate = tiny_model.describe(screen)
  mapped = independent_blind_mappers(canonical, candidate)
  score = deterministic_score(mapped)
```

### Authenticate evaluator evidence

```text
challenge = preissue(packet_digest, evaluator_role, random_nonce)
output = independent_session.evaluate(packet)
receipt = sign(packet_digest, output_digest, role, session_id, challenge_id)
verify(receipt, consumed_challenge, distinct_session)
```

### Publish by construction

```text
private evidence -> aggregate transform -> exact schema -> leak rejection -> public JSON -> public Markdown
```

The public document contains only the validated aggregate decision; the private corpus, references, raw outputs, judgments, and case-level derivatives remain outside the repository.

## Related

- [Screen understanding evaluation guide](../../SCREEN_UNDERSTANDING_EVAL.md)
- [Implementation plan](../../plans/2026-07-13-001-feat-screen-understanding-eval-plan.md)
- [First aggregate-only public result](../../evals/screen-understanding-v1-results.md)
- [GitHub issue #16](https://github.com/zbs-gg/eye/issues/16)
