# Claim-mapping rubric

This rubric is for a frontier mapper operating a blinded packet. Do not infer the method, case identity,
source application, timing, or split. Judge only the locked reference and the candidate evidence present in
the packet. Primary and hidden-duplicate packets must be handled by different mapper identities without
sharing decisions.

## One decision per claim

The packet contains only claims that still require semantic judgment. The preparation stage resolves three
classes deterministically and keeps them out of the mapper packet:

- `appName=...` is structured runtime evidence for `required.surface`;
- `windowTitle=...` is structured runtime evidence for `required.content`;
- `label:...` uses normalized exact containment in a required fact, otherwise it is `unsupported: minor`.

Do not reconstruct or second-guess those decisions. They are receipt-bound in the private owner mapping and
count as exact-agreement decisions in the scorer.

Every candidate claim receives exactly one decision:

- `matchedRequired: <fact-id>` — the claim semantically entails that locked required fact. The wording may
  differ, but the claim must assert the same observable fact. A merely related topic is not a match.
- `matchedForbidden: <fact-id>` — the claim directly asserts that locked forbidden inference. Use the exact
  forbidden fact ID. Missing detail, weak wording, or low confidence alone is not a forbidden match.
- `unsupported: major` — use this exact severity for every unsupported summary or remaining free-form atomic
  fact. Severity is fixed by claim source; the mapper decides only whether the claim is unsupported.
- `unsupported: minor` — reserved for deterministic label claims and therefore never emitted by the mapper.
- `ambiguous: true` — the locked reference and supplied evidence genuinely do not permit a reliable decision.
  Do not use ambiguity as a substitute for choosing between a supported and unsupported claim.

Do not give one claim credit for multiple required facts. If a sentence contains multiple independently
judgeable assertions, the preparation stage should already have split them; judge the emitted claim as-is.

## Visible text

`visibleText` is exact-text evidence, not a hallucination claim. Never create a claim judgment for it. For
each canonical `criticalText` string, set the corresponding `criticalTextMatched` boolean to true only when
the entire canonical string appears as a contiguous substring in one supplied visible-text entry after
Unicode normalization and whitespace collapsing. Paraphrases and semantic similarity do not count.

## Abstention

Set `abstentionCorrect` to:

- true when the reference permits abstention or marks the case unjudgeable and the candidate abstains;
- true when the case is judgeable, abstention is not permitted, and the candidate does not abstain;
- false in the two opposite combinations.

Judge abstention independently of whether individual non-empty claims are supported.

## Hidden duplicates and adjudication

The hidden mapper repeats only the concealed stratified sample and must not see primary decisions. Agreement
is exact at the claim-decision level and at the critical-text/abstention decision level. A third, fresh
identity receives only disagreements. The third mapper applies this same rubric and never sees method or
case identities.

The locked 60-case quality split conceals 15 duplicate arms per method (25%). This keeps each method's
one-summary-per-case reliability cell at or above 15 decisions instead of drawing a conclusion from nine.
