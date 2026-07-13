#!/usr/bin/python3
"""Fail-closed preflight for the private screen-understanding quality runner."""

import argparse
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any


BUILT_IN_METHODS = frozenset({
    "metadata-ax-ocr",
    "apple-vision",
    "deterministic-hybrid",
})
CANONICAL_RUBRIC = "screen-understanding-canonical-v2"
CASE_ID = re.compile(r"^[0-9a-f]{24}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
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
        _assert_owner_only(path, subject)
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


def _validate_labels(
    labels_document: dict[str, Any], expected_ids: set[str]
) -> None:
    if labels_document.get("schema") != "screen-understanding-canonical-labels-v2":
        raise PreflightError("canonical label schema is invalid")
    if labels_document.get("rubricVersion") != CANONICAL_RUBRIC:
        raise PreflightError("canonical labels do not use the v2 rubric")
    if labels_document.get("candidateOutputsAvailableDuringAnnotation") is not False:
        raise PreflightError("candidate outputs were available during annotation")
    labels = labels_document.get("labels")
    if not isinstance(labels, list) or len(labels) != 300:
        raise PreflightError("canonical labels must contain exactly 300 cases")
    actual_ids: list[str] = []
    for label in labels:
        if not isinstance(label, dict):
            raise PreflightError("canonical label is invalid")
        identifier = label.get("case")
        if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier):
            raise PreflightError("canonical label identifier is invalid")
        actual_ids.append(identifier)
        if label.get("locked") is not True:
            raise PreflightError("every canonical label must be locked")
        annotation = label.get("annotation")
        if not isinstance(annotation, dict) \
                or annotation.get("rubricVersion") != CANONICAL_RUBRIC \
                or annotation.get("blindedToCandidateOutputs") is not True \
                or annotation.get("candidateOutputsAvailable") is not False:
            raise PreflightError("canonical annotation provenance is invalid")
    if len(set(actual_ids)) != len(actual_ids) or set(actual_ids) != expected_ids:
        raise PreflightError("canonical label identifiers do not match the manifest")


def _validate_reliability(reliability: dict[str, Any]) -> None:
    if reliability.get("schema") != "screen-understanding-canonical-reliability-v2":
        raise PreflightError("canonical reliability schema is invalid")
    if reliability.get("qualified") is not True:
        raise PreflightError("canonical reliability is not qualified")
    minimum_fact = _finite_number(
        reliability.get("minimumFactAgreement"), "minimum fact agreement"
    )
    minimum_decision = _finite_number(
        reliability.get("minimumDecisionAgreement"), "minimum decision agreement"
    )
    fact = _finite_number(reliability.get("factAgreement"), "fact agreement")
    decision = _finite_number(
        reliability.get("decisionAgreement"), "decision agreement"
    )
    if minimum_fact < 0.90 or minimum_decision < 0.80:
        raise PreflightError("canonical reliability thresholds are below the protocol")
    if fact < minimum_fact or decision < minimum_decision:
        raise PreflightError("canonical reliability does not clear its thresholds")
    duplicate_count = reliability.get("duplicateCount")
    if isinstance(duplicate_count, bool) or not isinstance(duplicate_count, int) \
            or duplicate_count < 45:
        raise PreflightError("canonical reliability duplicate sample is too small")
    if "rubricVersion" in reliability \
            and reliability["rubricVersion"] != CANONICAL_RUBRIC:
        raise PreflightError("canonical reliability does not use the v2 rubric")


def validate_seal(corpus_root: Path, annotation_root: Path) -> dict[str, Any]:
    corpus_root = corpus_root.resolve()
    annotation_root = annotation_root.resolve()
    canonical_root = annotation_root / "canonical"
    for path, subject in (
        (corpus_root, "corpus root"),
        (annotation_root, "annotation root"),
        (canonical_root, "canonical root"),
    ):
        if path.is_symlink() or not path.is_dir():
            raise PreflightError(f"{subject} is unavailable")
        _assert_owner_only(path, subject)

    manifest, _ = _load_json(corpus_root / "manifest.json", "corpus manifest")
    labels, _ = _load_json(canonical_root / "labels.json", "canonical labels")
    reliability, _ = _load_json(
        canonical_root / "reliability.json", "canonical reliability"
    )
    single_ids, temporal_ids = _validate_manifest(manifest)
    _reject_private_payload(labels)
    _reject_private_payload(reliability)
    _validate_labels(labels, single_ids | temporal_ids)
    _validate_reliability(reliability)
    return {
        "labelCount": len(single_ids) + len(temporal_ids),
        "singleFrameCount": len(single_ids),
        "temporalPairCount": len(temporal_ids),
        "rubricVersion": CANONICAL_RUBRIC,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-root", required=True, type=Path)
    parser.add_argument("--annotation-root", required=True, type=Path)
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
        summary = validate_seal(args.dataset_root, args.annotation_root)
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
