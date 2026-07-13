#!/usr/bin/python3
"""Fail-closed preflight for the private screen-understanding quality runner."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any


BENCHMARK_DIRECTORY = Path(__file__).parents[1]
if str(BENCHMARK_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(BENCHMARK_DIRECTORY))

from common.private_io import (  # noqa: E402
    load_private_json,
    validate_private_input_file,
)
from common.private_root import (  # noqa: E402
    PrivateRootError,
    validate_private_root,
)
from common.provenance import (  # noqa: E402
    COMMIT_SCHEMA,
    HASH_ALGORITHM,
    ProvenanceError,
    build_canonical_commit,
)


REPOSITORY_ROOT = Path(__file__).parents[3]
BUILT_IN_METHODS = frozenset({
    "metadata-ax-ocr",
    "apple-vision",
    "deterministic-hybrid",
})
CANONICAL_RUBRIC = "screen-understanding-canonical-v2"
CANONICAL_PROTOCOL = "screen-understanding-correctness-audit-v3"
CASE_ID = re.compile(r"^[0-9a-f]{24}$")
SAFE_ID = re.compile(r"^[A-Za-z0-9._-]{1,96}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
CANONICAL_LABEL_ENVELOPE_FIELDS = {
    "schema", "protocol", "rubricVersion",
    "candidateOutputsAvailableDuringAnnotation", "labels",
}
CANONICAL_LABEL_FIELDS = {
    "case", "targetType", "requiredFacts", "criticalText",
    "forbiddenInferences", "meaningfulChange", "ambiguity",
    "abstentionAllowed", "locked", "annotation",
}
CANONICAL_ANNOTATION_FIELDS = {
    "producer", "mode", "annotator", "rubricVersion",
    "blindedToCandidateOutputs", "candidateOutputsAvailable",
}
CANONICAL_ANNOTATION_MODES = {
    "pass1-base", "selected-pass1", "selected-pass2", "selected-merge",
    "frontier-correction",
}
FACT_SEVERITIES = {"minor", "major", "critical"}
EXPECTED_SPLITS = frozenset({
    "tuneSingleFrames",
    "validationSingleFrames",
    "testSingleFrames",
    "tuneTemporalPairs",
    "validationTemporalPairs",
    "testTemporalPairs",
})
FORBIDDEN_VALUE_FRAGMENTS = ("/Users/", "/Volumes/", "file://")
FORBIDDEN_KEYS = frozenset({"candidateoutput", "candidateoutputs", "methodid"})
COMMIT_FIELDS = {
    "schema", "protocol", "rubricVersion", "hashAlgorithm",
    "candidateOutputsAvailableDuringAnnotation", "canonical", "producer",
    "evidence", "counts",
}
TREE_EVIDENCE_FIELDS = {"sha256", "fileCount", "directoryCount"}
FILE_EVIDENCE_FIELDS = {"sha256", "byteCount"}


class PreflightError(ValueError):
    """The private quality runner must not continue."""


class UnsupportedMethodError(PreflightError):
    """A selected adapter has not qualified for private-corpus access."""


def parse_method_ids(raw: str) -> tuple[str, ...]:
    if not isinstance(raw, str):
        raise PreflightError("methods must be a comma-separated string")
    methods = tuple(part.strip() for part in raw.split(","))
    if not methods or any(not method for method in methods):
        raise PreflightError("methods must contain non-empty identifiers")
    if len(set(methods)) != len(methods):
        raise PreflightError("selected method is duplicated")
    return methods


def select_methods(manifest: dict[str, Any], raw: str) -> tuple[dict[str, Any], ...]:
    adapters = manifest.get("adapters")
    if not isinstance(adapters, list):
        raise PreflightError("adapter manifest is invalid")
    by_id: dict[str, dict[str, Any]] = {}
    for entry in adapters:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            raise PreflightError("adapter manifest is invalid")
        identifier = entry["id"]
        if identifier in by_id:
            raise PreflightError("adapter manifest contains duplicate identifiers")
        by_id[identifier] = entry

    selected = []
    for identifier in parse_method_ids(raw):
        entry = by_id.get(identifier)
        if entry is None:
            raise PreflightError("selected method is absent from the adapter manifest")
        status = entry.get("status")
        if status == "security-unsupported":
            raise UnsupportedMethodError(
                f"selected method {identifier} is security-unsupported"
            )
        if status != "built-in":
            raise PreflightError("selected method is not executable by this runner")
        if identifier not in BUILT_IN_METHODS:
            raise PreflightError("built-in method is outside the locked allowlist")
        selected.append(entry)
    return tuple(selected)


def _assert_owner_only(path: Path, subject: str) -> None:
    try:
        mode = stat.S_IMODE(path.stat().st_mode)
    except OSError as error:
        raise PreflightError(f"{subject} is unavailable") from error
    if mode & 0o077:
        raise PreflightError(f"{subject} must use owner-only permissions")


def _load_json(
    path: Path, subject: str, *, require_owner_only: bool = True
) -> tuple[dict[str, Any], str]:
    if path.is_symlink() or not path.is_file():
        raise PreflightError(f"{subject} is unavailable")
    if require_owner_only:
        try:
            return load_private_json(path, subject)
        except ValueError as error:
            raise PreflightError(str(error)) from error
    try:
        raw = path.read_text(encoding="utf-8")
        value = json.loads(raw)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PreflightError(f"{subject} is not valid JSON") from error
    if not isinstance(value, dict):
        raise PreflightError(f"{subject} root must be an object")
    return value, raw


def _identifier_set(values: Any, subject: str) -> set[str]:
    if not isinstance(values, list) or any(
        not isinstance(value, str) or not CASE_ID.fullmatch(value)
        for value in values
    ):
        raise PreflightError(f"{subject} identifiers are invalid")
    if len(set(values)) != len(values):
        raise PreflightError(f"{subject} identifiers are duplicated")
    return set(values)


def _require_exact_fields(value: Any, expected: set[str], subject: str) -> None:
    if not isinstance(value, dict) or set(value) != expected:
        raise PreflightError(f"{subject} fields do not match the canonical-v3 contract")


def _validate_manifest(manifest: dict[str, Any]) -> tuple[set[str], set[str]]:
    if manifest.get("protocolID") != "screen-understanding-v1":
        raise PreflightError("corpus protocol is invalid")
    for key in ("snapshotSHA256", "splitSHA256"):
        value = manifest.get(key)
        if not isinstance(value, str) or not SHA256.fullmatch(value):
            raise PreflightError("corpus integrity hash is invalid")

    single_ids = _identifier_set(manifest.get("singleFrameCaseIDs"), "single-frame")
    pairs = manifest.get("temporalPairs")
    if not isinstance(pairs, list):
        raise PreflightError("temporal-pair manifest is invalid")
    pair_ids: list[str] = []
    referenced_case_ids: set[str] = set(single_ids)
    for pair in pairs:
        if not isinstance(pair, dict):
            raise PreflightError("temporal-pair manifest is invalid")
        identifier = pair.get("id")
        before = pair.get("beforeCaseID")
        after = pair.get("afterCaseID")
        if any(
            not isinstance(value, str) or not CASE_ID.fullmatch(value)
            for value in (identifier, before, after)
        ):
            raise PreflightError("temporal-pair identifier is invalid")
        pair_ids.append(identifier)
        referenced_case_ids.update((before, after))
    temporal_ids = _identifier_set(pair_ids, "temporal-pair")
    if single_ids & temporal_ids:
        raise PreflightError("single-frame and temporal identifiers overlap")
    if len(single_ids) != 200 or len(temporal_ids) != 100:
        raise PreflightError("corpus must contain 200 single frames and 100 temporal pairs")

    cases = manifest.get("cases")
    if not isinstance(cases, list) or any(not isinstance(case, dict) for case in cases):
        raise PreflightError("corpus case inventory is invalid")
    case_ids = _identifier_set([case.get("id") for case in cases], "corpus case")
    if not referenced_case_ids.issubset(case_ids):
        raise PreflightError("corpus case inventory does not cover the manifest")

    splits = manifest.get("splits")
    if not isinstance(splits, dict) or set(splits) != EXPECTED_SPLITS:
        raise PreflightError("corpus split inventory is invalid")
    split_sets = {
        name: _identifier_set(values, f"{name} split")
        for name, values in splits.items()
    }
    single_split_names = (
        "tuneSingleFrames", "validationSingleFrames", "testSingleFrames"
    )
    temporal_split_names = (
        "tuneTemporalPairs", "validationTemporalPairs", "testTemporalPairs"
    )
    if not _is_partition([split_sets[name] for name in single_split_names], single_ids):
        raise PreflightError("single-frame splits do not partition the manifest")
    if not _is_partition([split_sets[name] for name in temporal_split_names], temporal_ids):
        raise PreflightError("temporal-pair splits do not partition the manifest")
    return single_ids, temporal_ids


def _is_partition(parts: list[set[str]], whole: set[str]) -> bool:
    union: set[str] = set()
    for part in parts:
        if union & part:
            return False
        union.update(part)
    return union == whole


def _reject_private_payload(value: Any) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if lowered in FORBIDDEN_KEYS or lowered.endswith("path") or lowered.endswith("paths"):
                raise PreflightError("canonical seal contains a forbidden path or candidate field")
            _reject_private_payload(child)
    elif isinstance(value, list):
        for child in value:
            _reject_private_payload(child)
    elif isinstance(value, str) and any(
        fragment in value for fragment in FORBIDDEN_VALUE_FRAGMENTS
    ):
        raise PreflightError("canonical seal contains a private local path")


def _finite_number(value: Any, subject: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PreflightError(f"{subject} is invalid")
    number = float(value)
    if not 0.0 <= number <= 1.0:
        raise PreflightError(f"{subject} is invalid")
    return number


def _validate_fact(
    fact: Any,
    expected_id: str,
    *,
    severity_required: bool,
    subject: str,
) -> None:
    if not isinstance(fact, dict) \
            or not {"id", "text"}.issubset(fact) \
            or not set(fact).issubset({"id", "text", "severity"}):
        raise PreflightError(f"{subject} fields are invalid")
    if fact["id"] != expected_id:
        raise PreflightError(f"{subject} slot is invalid")
    text = fact["text"]
    if not isinstance(text, str) or not 1 <= len(text) <= 240:
        raise PreflightError(f"{subject} text is invalid")
    if severity_required and "severity" not in fact:
        raise PreflightError(f"{subject} severity is missing")
    if "severity" in fact:
        severity = fact["severity"]
        if not isinstance(severity, str) or severity not in FACT_SEVERITIES:
            raise PreflightError(f"{subject} severity is invalid")


def _validate_reference(label: dict[str, Any], expected_target: str) -> None:
    target = label["targetType"]
    if target != expected_target:
        raise PreflightError("canonical label target type does not match the corpus manifest")

    required = label["requiredFacts"]
    required_ids = [
        fact.get("id") if isinstance(fact, dict) else None
        for fact in required
    ] if isinstance(required, list) else None
    expected_required_ids = [
        "required.surface", "required.content", "required.state",
    ]
    if required_ids != expected_required_ids:
        raise PreflightError("canonical required fact slots are invalid")
    for fact, identifier in zip(required, expected_required_ids):
        _validate_fact(
            fact,
            identifier,
            severity_required=False,
            subject="canonical required fact",
        )

    forbidden = label["forbiddenInferences"]
    forbidden_ids = [
        fact.get("id") if isinstance(fact, dict) else None
        for fact in forbidden
    ] if isinstance(forbidden, list) else None
    expected_forbidden_ids = ["forbidden.intent", "forbidden.outcome"]
    if forbidden_ids != expected_forbidden_ids:
        raise PreflightError("canonical forbidden fact slots are invalid")
    for fact, identifier in zip(forbidden, expected_forbidden_ids):
        _validate_fact(
            fact,
            identifier,
            severity_required=True,
            subject="canonical forbidden fact",
        )

    critical_text = label["criticalText"]
    if not isinstance(critical_text, list) or len(critical_text) > 2 \
            or any(
                not isinstance(text, str) or not 1 <= len(text) <= 240
                for text in critical_text
            ):
        raise PreflightError("canonical critical text is invalid")

    change = label["meaningfulChange"]
    if target == "single-frame":
        if change is not None:
            raise PreflightError("single-frame canonical label contains temporal change")
    elif not isinstance(change, list) or len(change) > 3:
        raise PreflightError("temporal canonical change list is invalid")
    else:
        seen_change_ids: set[str] = set()
        for fact in change:
            if not isinstance(fact, dict) \
                    or not {"id", "text"}.issubset(fact) \
                    or not set(fact).issubset({"id", "text", "severity"}):
                raise PreflightError("canonical change fact fields are invalid")
            identifier = fact["id"]
            if not isinstance(identifier, str) \
                    or not identifier.startswith("change.") \
                    or identifier in seen_change_ids:
                raise PreflightError("canonical change fact identifiers are invalid")
            seen_change_ids.add(identifier)
            text = fact["text"]
            if not isinstance(text, str) or not 1 <= len(text) <= 240:
                raise PreflightError("canonical change fact text is invalid")
            if "severity" in fact:
                severity = fact["severity"]
                if not isinstance(severity, str) or severity not in FACT_SEVERITIES:
                    raise PreflightError("canonical change fact severity is invalid")

    if not isinstance(label["ambiguity"], str) \
            or label["ambiguity"] not in {"judgeable", "ambiguous", "unjudgeable"} \
            or not isinstance(label["abstentionAllowed"], bool):
        raise PreflightError("canonical ambiguity decision is invalid")


def _validate_annotation(annotation: Any, target: str) -> None:
    _require_exact_fields(
        annotation,
        CANONICAL_ANNOTATION_FIELDS,
        "canonical annotation",
    )
    expected_rubric = (
        CANONICAL_RUBRIC if target == "single-frame"
        else "screen-understanding-temporal-v4"
    )
    if annotation["producer"] != "frontier-vlm" \
            or not isinstance(annotation["mode"], str) \
            or annotation["mode"] not in CANONICAL_ANNOTATION_MODES \
            or not isinstance(annotation["annotator"], str) \
            or not SAFE_ID.fullmatch(annotation["annotator"]) \
            or annotation["rubricVersion"] != expected_rubric \
            or annotation["blindedToCandidateOutputs"] is not True \
            or annotation["candidateOutputsAvailable"] is not False:
        raise PreflightError("canonical annotation provenance is invalid")


def _validate_labels(
    labels_document: dict[str, Any],
    expected_targets: dict[str, str],
) -> None:
    if labels_document.get("schema") != "screen-understanding-canonical-labels-v3":
        raise PreflightError("canonical label schema is invalid")
    _require_exact_fields(
        labels_document,
        CANONICAL_LABEL_ENVELOPE_FIELDS,
        "canonical label envelope",
    )
    if labels_document.get("protocol") != CANONICAL_PROTOCOL:
        raise PreflightError("canonical label protocol is invalid")
    if labels_document.get("rubricVersion") != CANONICAL_RUBRIC:
        raise PreflightError("canonical labels do not use the v2 rubric")
    if labels_document.get("candidateOutputsAvailableDuringAnnotation") is not False:
        raise PreflightError("candidate outputs were available during annotation")
    labels = labels_document.get("labels")
    if not isinstance(labels, list) or len(labels) != 300:
        raise PreflightError("canonical labels must contain exactly 300 cases")
    actual_ids: list[str] = []
    for label in labels:
        _require_exact_fields(label, CANONICAL_LABEL_FIELDS, "canonical label")
        identifier = label["case"]
        if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier):
            raise PreflightError("canonical label identifier is invalid")
        actual_ids.append(identifier)
        if label["locked"] is not True:
            raise PreflightError("every canonical label must be locked")
        expected_target = expected_targets.get(identifier)
        if expected_target is None:
            raise PreflightError("canonical label identifiers do not match the manifest")
        _validate_reference(label, expected_target)
        _validate_annotation(label["annotation"], expected_target)
    if len(set(actual_ids)) != len(actual_ids) \
            or set(actual_ids) != set(expected_targets):
        raise PreflightError("canonical label identifiers do not match the manifest")


def _validate_reliability(reliability: dict[str, Any]) -> None:
    if reliability.get("schema") != "screen-understanding-canonical-reliability-v3":
        raise PreflightError("canonical reliability schema is invalid")
    if reliability.get("protocol") != CANONICAL_PROTOCOL \
            or reliability.get("rubricVersion") != CANONICAL_RUBRIC:
        raise PreflightError("canonical reliability protocol is invalid")
    if reliability.get("qualified") is not True:
        raise PreflightError("canonical reliability is not qualified")
    raw_joint = reliability.get("rawJoint")
    if not isinstance(raw_joint, dict) or set(raw_joint) != {
        "minimum", "overall", "singleFrame", "temporalPair",
    }:
        raise PreflightError("canonical raw joint reliability is invalid")
    minimum = _finite_number(raw_joint.get("minimum"), "raw joint minimum")
    if minimum < 0.90:
        raise PreflightError("canonical reliability threshold is below the protocol")
    for key in ("overall", "singleFrame", "temporalPair"):
        value = _finite_number(raw_joint.get(key), f"raw joint {key}")
        if value < minimum:
            raise PreflightError("canonical reliability does not clear its thresholds")
    duplicate_count = reliability.get("duplicateCount")
    if isinstance(duplicate_count, bool) or not isinstance(duplicate_count, int) \
            or duplicate_count < 45:
        raise PreflightError("canonical reliability duplicate sample is too small")
    final_audit = reliability.get("finalReferenceAudit")
    expected_final_keys = {
        "auditor", "caseCount", "slotCount", "materialFalseCount",
        "ambiguityErrorCount", "criticalErrorCount",
        "requiredCriticalErrorCount", "qualified",
    }
    if not isinstance(final_audit, dict) or set(final_audit) != expected_final_keys:
        raise PreflightError("canonical final reference audit is invalid")
    if not isinstance(final_audit.get("auditor"), str) or not final_audit["auditor"] \
            or final_audit.get("caseCount") != 45 \
            or final_audit.get("slotCount") != 255 \
            or final_audit.get("materialFalseCount") != 0 \
            or final_audit.get("ambiguityErrorCount") != 0 \
            or final_audit.get("criticalErrorCount") != 0 \
            or final_audit.get("requiredCriticalErrorCount") != 0 \
            or final_audit.get("qualified") is not True:
        raise PreflightError("canonical final reference audit is not qualified")


def _validate_commit_evidence(
    evidence: Any,
    expected_fields: set[str],
    subject: str,
) -> None:
    _require_exact_fields(evidence, expected_fields, subject)
    digest = evidence.get("sha256")
    if not isinstance(digest, str) or not SHA256.fullmatch(digest):
        raise PreflightError(f"{subject} digest is invalid")
    for key in expected_fields - {"sha256"}:
        value = evidence.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise PreflightError(f"{subject} count is invalid")


def _validate_commit(commit: dict[str, Any]) -> None:
    _require_exact_fields(commit, COMMIT_FIELDS, "canonical commit")
    if commit.get("schema") != COMMIT_SCHEMA \
            or commit.get("protocol") != CANONICAL_PROTOCOL \
            or commit.get("rubricVersion") != CANONICAL_RUBRIC \
            or commit.get("hashAlgorithm") != HASH_ALGORITHM \
            or commit.get("candidateOutputsAvailableDuringAnnotation") is not False:
        raise PreflightError("canonical commit metadata is invalid")
    canonical = commit.get("canonical")
    _require_exact_fields(
        canonical,
        {"labelsSHA256", "reliabilitySHA256"},
        "canonical commit outputs",
    )
    if any(
        not isinstance(value, str) or not SHA256.fullmatch(value)
        for value in canonical.values()
    ):
        raise PreflightError("canonical commit output digest is invalid")
    producer = commit.get("producer")
    _require_exact_fields(producer, {"finalizerSHA256"}, "canonical commit producer")
    if not isinstance(producer["finalizerSHA256"], str) \
            or not SHA256.fullmatch(producer["finalizerSHA256"]):
        raise PreflightError("canonical commit finalizer digest is invalid")
    evidence = commit.get("evidence")
    _require_exact_fields(evidence, {
        "sourceAnnotationRoot", "correctnessAuditRoot", "aggregateRoot",
        "finalAudit", "finalJudgments",
    }, "canonical commit evidence")
    for key in (
        "sourceAnnotationRoot", "correctnessAuditRoot", "aggregateRoot",
        "finalAudit",
    ):
        _validate_commit_evidence(
            evidence[key], TREE_EVIDENCE_FIELDS, f"canonical commit {key}"
        )
    _validate_commit_evidence(
        evidence["finalJudgments"],
        FILE_EVIDENCE_FIELDS,
        "canonical commit final judgments",
    )
    counts = commit.get("counts")
    _require_exact_fields(counts, {
        "labelCount", "duplicateCount", "finalAuditCaseCount",
        "finalAuditSlotCount",
    }, "canonical commit counts")
    if counts != {
        "labelCount": 300,
        "duplicateCount": 45,
        "finalAuditCaseCount": 45,
        "finalAuditSlotCount": 255,
    }:
        raise PreflightError("canonical commit counts are invalid")


def validate_seal(
    corpus_root: Path,
    annotation_root: Path,
    *,
    source_annotation_root: Path | None = None,
    correctness_audit_root: Path | None = None,
    aggregate_root: Path | None = None,
    final_audit_root: Path | None = None,
    final_judgments: Path | None = None,
) -> dict[str, Any]:
    if any(value is None for value in (
        source_annotation_root,
        correctness_audit_root,
        aggregate_root,
        final_audit_root,
        final_judgments,
    )):
        raise PreflightError(
            "explicit provenance evidence roots and final judgments are required"
        )
    try:
        corpus_root = validate_private_root(
            corpus_root,
            REPOSITORY_ROOT,
            must_exist=True,
            require_exclusions=True,
        )
        annotation_root = validate_private_root(
            annotation_root,
            REPOSITORY_ROOT,
            must_exist=True,
            require_exclusions=True,
        )
        source_annotation_root = validate_private_root(
            source_annotation_root,
            REPOSITORY_ROOT,
            must_exist=True,
            require_exclusions=True,
        )
        correctness_audit_root = validate_private_root(
            correctness_audit_root,
            REPOSITORY_ROOT,
            must_exist=True,
            require_exclusions=True,
        )
        aggregate_root = validate_private_root(
            aggregate_root,
            REPOSITORY_ROOT,
            must_exist=True,
            require_exclusions=True,
        )
        final_audit_root = validate_private_root(
            final_audit_root,
            REPOSITORY_ROOT,
            must_exist=True,
            require_exclusions=True,
        )
        final_judgments = validate_private_input_file(final_judgments)
    except PrivateRootError as error:
        raise PreflightError(str(error)) from error
    _assert_owner_only(final_judgments, "final judgments")
    if annotation_root != final_audit_root:
        raise PreflightError(
            "canonical root and final-audit evidence root must be identical"
        )

    canonical_root = annotation_root / "canonical"
    if canonical_root.is_symlink() or not canonical_root.is_dir():
        raise PreflightError("canonical root is unavailable")
    _assert_owner_only(canonical_root, "canonical root")

    manifest, manifest_raw = _load_json(
        corpus_root / "manifest.json", "corpus manifest"
    )
    labels, labels_raw = _load_json(
        canonical_root / "labels.json", "canonical labels"
    )
    reliability, reliability_raw = _load_json(
        canonical_root / "reliability.json", "canonical reliability"
    )
    commit, commit_raw = _load_json(
        canonical_root / "commit.json", "canonical commit"
    )
    single_ids, temporal_ids = _validate_manifest(manifest)
    _reject_private_payload(labels)
    _reject_private_payload(reliability)
    _reject_private_payload(commit)
    expected_targets = {
        **{identifier: "single-frame" for identifier in single_ids},
        **{identifier: "temporal-pair" for identifier in temporal_ids},
    }
    _validate_labels(labels, expected_targets)
    _validate_reliability(reliability)
    _validate_commit(commit)
    try:
        expected_commit = build_canonical_commit(
            labels_path=canonical_root / "labels.json",
            reliability_path=canonical_root / "reliability.json",
            finalizer_path=(
                Path(__file__).parents[1] / "annotation" /
                "combine_canonical_v4.py"
            ),
            source_annotation_root=source_annotation_root,
            correctness_audit_root=correctness_audit_root,
            aggregate_root=aggregate_root,
            final_audit_root=final_audit_root,
            final_judgments_path=final_judgments,
            protocol=CANONICAL_PROTOCOL,
            rubric_version=CANONICAL_RUBRIC,
            label_count=300,
            duplicate_count=45,
            final_audit_case_count=45,
            final_audit_slot_count=255,
        )
    except ProvenanceError as error:
        raise PreflightError("canonical provenance evidence is invalid") from error
    if commit != expected_commit:
        raise PreflightError("canonical commit does not match provenance evidence")
    return {
        "labelCount": len(single_ids) + len(temporal_ids),
        "singleFrameCount": len(single_ids),
        "temporalPairCount": len(temporal_ids),
        "rubricVersion": CANONICAL_RUBRIC,
        "datasetManifestSHA256": hashlib.sha256(
            manifest_raw.encode("utf-8")
        ).hexdigest(),
        "canonicalLabelsSHA256": hashlib.sha256(
            labels_raw.encode("utf-8")
        ).hexdigest(),
        "canonicalReliabilitySHA256": hashlib.sha256(
            reliability_raw.encode("utf-8")
        ).hexdigest(),
        "canonicalCommitSHA256": hashlib.sha256(
            commit_raw.encode("utf-8")
        ).hexdigest(),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-root", required=True, type=Path)
    parser.add_argument("--annotation-root", required=True, type=Path)
    parser.add_argument("--source-annotation-root", required=True, type=Path)
    parser.add_argument("--correctness-audit-root", required=True, type=Path)
    parser.add_argument("--aggregate-root", required=True, type=Path)
    parser.add_argument("--final-audit-root", required=True, type=Path)
    parser.add_argument("--final-judgments", required=True, type=Path)
    parser.add_argument("--methods", required=True)
    parser.add_argument(
        "--adapter-manifest",
        type=Path,
        default=Path(__file__).parents[1] / "adapters" / "manifest.json",
    )
    args = parser.parse_args()
    try:
        manifest, _ = _load_json(
            args.adapter_manifest,
            "adapter manifest",
            require_owner_only=False,
        )
        selected = select_methods(manifest, args.methods)
        summary = validate_seal(
            args.dataset_root,
            args.annotation_root,
            source_annotation_root=args.source_annotation_root,
            correctness_audit_root=args.correctness_audit_root,
            aggregate_root=args.aggregate_root,
            final_audit_root=args.final_audit_root,
            final_judgments=args.final_judgments,
        )
    except UnsupportedMethodError as error:
        print(f"security-unsupported: {error}", file=sys.stderr)
        return 3
    except PreflightError as error:
        print(f"preflight failed: {error}", file=sys.stderr)
        return 2
    output = dict(summary)
    output["selectedMethods"] = [entry["id"] for entry in selected]
    print(json.dumps(output, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
