# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Screen understanding evaluation

### Canonical Reference
A private, sealed description of directly observable screen facts and forbidden inferences against which candidate outputs are evaluated.

### Frontier Reference Oracle
The evaluation-only process in which frontier vision-language model sessions create, adjudicate, and audit Canonical References; it is never a shipping inference provider or product dependency.

### Concealed Mapper
A fresh evaluator that receives identity-blind candidate claims and a Canonical Reference, then records claim-level semantic matches without knowing the candidate method or other mappers' decisions.

### Reliability Qualification
The pre-registered agreement gate that permits a method's quality score to be published only when reference creation and claim mapping are sufficiently reproducible for every supported capability.

Reliability Qualification establishes that a score is trustworthy enough to report; it does not mean the evaluated method is good enough to ship.

### Public Decision
The schema-constrained aggregate derived from private evaluation evidence while excluding frames, case-level text, private case/arm/claim/packet/evaluator identifiers, paths, timestamps, and raw evaluator output.

## Relationships

The Frontier Reference Oracle produces Canonical References. Concealed Mappers connect candidate claims to those references. Reliability Qualification controls which results may enter the Public Decision.
