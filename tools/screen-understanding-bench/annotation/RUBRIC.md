# Canonical screen annotation rubric v1

The annotator is a frontier vision-language model that sees only the locked image or image pair. It must
not see candidate method names, outputs, scores, metadata/AX/OCR context, split membership, or prior labels.
The annotation is a private reference artifact, not a product inference and not a public dataset.

## Single frame

- Record 3–8 `requiredFacts`: concrete visible UI, objects, layout, and current state.
- Record up to 5 `criticalText` strings only when visibly legible and decision-relevant. Preserve script,
  spelling, and numbers; do not reconstruct clipped or tiny text.
- Record 2–4 `forbiddenInferences`: tempting claims the image does not establish, especially user intent,
  identity, emotion, off-screen state, hidden content, causality, or whether an action succeeded.
- Set `meaningfulChange` to `null`.
- Use `ambiguous` or `unjudgeable` and permit abstention when the frame is blurred, occluded, blank, or too
  small to support reliable facts.

## Temporal pair

- Inspect both frames independently before comparing them.
- `requiredFacts` describes the visible after-state needed to understand the scene.
- `meaningfulChange` is an array of only directly visible changes. Use an empty array for `NO_CHANGE`.
- Do not turn correlation into intent or causality: “a dialog is visible in the after frame” is valid;
  “the user opened the dialog to change settings” is forbidden unless directly established.
- `criticalText` contains only newly visible or materially changed legible text.

## Fact identifiers and severity

- IDs are local to one annotation: `required.01`, `forbidden.01`, `change.01`, and so on.
- `minor`: cosmetic or low-impact unsupported detail.
- `major`: wrong activity, app state, object, or meaningful action.
- `critical`: invented sensitive content, identity, intent, credential/payment state, or safety-relevant claim.
- Independent-pass agreement is adjudicated semantically from fact text; matching local IDs are not assumed.

## Required metadata

Every label records `producer: frontier-vlm`, the annotator identity, rubric version, pass 1 or 2,
`blindedToCandidateOutputs: true`, and `candidateOutputsAvailable: false`. Candidate outputs remain unavailable
until canonical labels are sealed.
