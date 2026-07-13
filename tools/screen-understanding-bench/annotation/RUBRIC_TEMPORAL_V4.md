# Temporal screen annotation rubric v4

This rubric evaluates visible state transition, not screenshot transcription. The frontier vision-language
annotator sees only the locked before/after images. It must not see candidate methods, candidate outputs,
scores, metadata/AX/OCR context, split membership, prior labels, or owner case identifiers.

## Capability boundary

- Exact visible-text extraction remains a single-frame capability and is scored only in that lane.
- Temporal labels therefore use `criticalText: []` by contract. This is an explicit denominator boundary,
  not permission to omit text from the visible after-state when it is necessary to describe the state.
- Temporal evaluation asks two questions: what is visibly true after the transition, and what one primary
  visible change occurred.

## Fixed after-state slots

Every label contains exactly three required facts:

- `required.surface`: the dominant visible app, window, page, dialog, or system surface after the change.
- `required.content`: the primary visible content or object after the change, without guessing intent.
- `required.state`: the most salient directly visible state, selection, progress, error, or layout after the
  change.

Every label contains the same two rubric-level forbidden inferences:

- `forbidden.intent`: `The user's purpose or intended next action is not established by the visible frames.`
- `forbidden.outcome`: `Off-screen completion, persistence, sending, saving, payment, or publication is not
  established beyond the visible after-state.`

These sentences are fixed, not rewritten per case. They prevent free-form evaluator variance from entering
the temporal reliability denominator.

## Primary change

- Inspect each frame independently before comparing them.
- Use `meaningfulChange: []` only when there is no directly visible meaningful change (`NO_CHANGE`).
- Otherwise use exactly one `change.primary` fact describing the most consequential directly visible change.
- Describe observation, not cause: `A settings dialog is visible in the after frame` is valid; `The user
  opened settings to disable audio` is not.
- Do not list secondary animations, cursor movement, clocks, notifications, or tiny layout shifts when a more
  meaningful transition is visible.

## Ambiguity and abstention

- `judgeable`: the after-state and primary change are both visually supported.
- `ambiguous`: a coarse transition is visible but one required slot has multiple plausible readings.
- `unjudgeable`: blur, occlusion, blank content, or insufficient visual evidence prevents a reliable label.
- Set `abstentionAllowed: true` for `ambiguous` and `unjudgeable`; otherwise false.

## Reliability gate

- The hidden duplicate set contains 15 temporal pairs.
- Independently executed passes are audited on three required after-state facts, the primary-change decision,
  and ambiguity/abstention: five opportunities per pair.
- Joint correctness must remain at or above the pre-registered `0.90` floor. The threshold is never lowered.
- A final fresh audit must report zero material false facts before the temporal lane can be sealed.
