# Canonical screen annotation rubric v2

The annotator is a frontier vision-language model that sees only the locked image or image pair. It must
not see candidate method names, outputs, scores, metadata/AX/OCR context, split membership, or prior labels.
The annotation is a private reference artifact, not a product inference and not a public dataset.

## Fixed fact slots

Every annotation uses exactly three required facts. The IDs and meanings are fixed:

- `required.surface`: the dominant visible app, window, page, dialog, or system surface.
- `required.content`: the primary visible content or object, without guessing intent.
- `required.state`: the most salient directly visible state, selection, progress, error, or layout.

Every annotation also uses exactly two forbidden inferences:

- `forbidden.intent`: an unsupported claim about the user's purpose, identity, emotion, or next action.
- `forbidden.outcome`: an unsupported claim that an operation succeeded, failed, was sent, saved, paid,
  published, or otherwise changed off-screen state.

Use at most two `criticalText` strings: only the most decision-relevant legible text.

## Single frame

- Fill the three fixed required-fact slots with concrete visible UI, content, and state.
- Record up to 2 `criticalText` strings only when visibly legible and decision-relevant. Preserve script,
  spelling, and numbers; do not reconstruct clipped or tiny text.
- Fill the two fixed forbidden-inference slots; do not add extra speculative variants.
- Set `meaningfulChange` to `null`.
- Use `ambiguous` or `unjudgeable` and permit abstention when the frame is blurred, occluded, blank, or too
  small to support reliable facts.

## Temporal pair

- Inspect both frames independently before comparing them.
- The three fixed required slots describe the visible after-state.
- `meaningfulChange` contains at most three directly visible changes. Use an empty array for `NO_CHANGE`.
- Do not turn correlation into intent or causality: “a dialog is visible in the after frame” is valid;
  “the user opened the dialog to change settings” is forbidden unless directly established.
- `criticalText` contains at most two newly visible or materially changed legible strings.

## Fact identifiers and severity

- Required and forbidden IDs use the fixed slots above. Change IDs are `change.01` through `change.03`.
- `minor`: cosmetic or low-impact unsupported detail.
- `major`: wrong activity, app state, object, or meaningful action.
- `critical`: invented sensitive content, identity, intent, credential/payment state, or safety-relevant claim.
- Independent-pass agreement is adjudicated semantically from fact text; matching local IDs are not assumed.

## Required metadata

Every label records `producer: frontier-vlm`, the annotator identity, rubric version
`screen-understanding-canonical-v2`, pass 1 or 2,
`blindedToCandidateOutputs: true`, and `candidateOutputsAvailable: false`. Candidate outputs remain unavailable
until canonical labels are sealed.
