#!/usr/bin/python3
"""Seal blinded frontier annotations after the locked reliability gate passes."""

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
if str(BENCHMARK_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCHMARK_ROOT))

from common.contracts import exact_keys
from common.private_io import (
    atomic_private_json,
    prepare_private_output,
    publish_private_output,
    validate_private_input,
    validate_private_output,
)


CASE_ID = re.compile(r"^[0-9a-f]{24}$")
RUBRIC = "screen-understanding-canonical-v2"
MINIMUM_FACT_AGREEMENT = 0.90
MINIMUM_DECISION_AGREEMENT = 0.80
FORBIDDEN_FRAGMENTS = (
    '"candidateOutput"',
    '"methodID"',
    "/Users/",
    "/Volumes/",
    "file://",
)
REFERENCE_KEYS = {
    "targetType", "requiredFacts", "criticalText", "forbiddenInferences",
    "meaningfulChange", "ambiguity", "abstentionAllowed",
}


def validate_reference(reference: object, target_type: str) -> dict:
    exact_keys(reference, REFERENCE_KEYS, "reference")
    if reference["targetType"] != target_type:
        raise ValueError("reference target type mismatch")
    if [fact.get("id") for fact in reference["requiredFacts"]] != [
        "required.surface", "required.content", "required.state",
    ]:
        raise ValueError("reference required fact slots are invalid")
    if [fact.get("id") for fact in reference["forbiddenInferences"]] != [
        "forbidden.intent", "forbidden.outcome",
    ]:
        raise ValueError("reference forbidden fact slots are invalid")
    if len(reference["criticalText"]) > 2:
        raise ValueError("reference critical text exceeds its cap")
    change = reference["meaningfulChange"]
    if target_type == "single-frame" and change is not None:
        raise ValueError("single-frame reference contains a temporal change")
    if target_type == "temporal-pair" and (not isinstance(change, list) or len(change) > 3):
        raise ValueError("temporal reference change is invalid")
    return reference


def load_pass1(root: Path) -> dict[str, dict]:
    labels: dict[str, dict] = {}
    paths = sorted((root / "labels" / "pass1").glob("batch-*.json"))
    if not paths:
        raise ValueError("pass 1 labels are missing")
    for path in paths:
        batch = json.loads(path.read_text(encoding="utf-8"))
        if batch.get("rubricVersion") != RUBRIC or batch.get("pass") != 1:
            raise ValueError("pass 1 rubric or pass is invalid")
        for label in batch.get("labels", []):
            identifier = label.get("case")
            if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier):
                raise ValueError("pass 1 case identifier is invalid")
            if identifier in labels:
                raise ValueError("pass 1 case identifier is duplicated")
            if label.get("locked") is not False:
                raise ValueError("pass 1 label was locked before adjudication")
            labels[identifier] = label
    return labels


def load_adjudication(root: Path) -> tuple[dict, dict]:
    work = json.loads((root / "adjudication" / "work.json").read_text(encoding="utf-8"))
    decisions_path = root / "adjudication" / "decisions.json"
    decisions_text = decisions_path.read_text(encoding="utf-8")
    if any(fragment in decisions_text for fragment in FORBIDDEN_FRAGMENTS):
        raise ValueError("adjudication decisions contain a forbidden field or local path")
    decisions = json.loads(decisions_text)
    exact_keys(decisions, {
        "schema", "annotator", "rubricVersion", "candidateOutputsAvailable",
        "items", "overrides",
    }, "adjudication decisions")
    if decisions["schema"] != "screen-understanding-adjudication-decisions-v2" \
            or decisions["rubricVersion"] != RUBRIC \
            or decisions["candidateOutputsAvailable"] is not False:
        raise ValueError("adjudication provenance is invalid")
    if work.get("rubricVersion") != RUBRIC \
            or work.get("candidateOutputsAvailable") is not False:
        raise ValueError("adjudication work provenance is invalid")
    return work, decisions


def validate_decisions(work: dict, decisions: dict) -> tuple[dict, float, float]:
    work_items = {item["id"]: item for item in work.get("items", [])}
    if len(work_items) != len(work.get("items", [])) or not work_items:
        raise ValueError("adjudication work identifiers are invalid")
    by_id = {}
    merge_ids = set()
    for decision in decisions["items"]:
        exact_keys(decision, {
            "id", "factAgreement", "decisionAgreement", "preference",
        }, "adjudication decision")
        identifier = decision["id"]
        if identifier in by_id or identifier not in work_items:
            raise ValueError("adjudication decision identifiers are invalid")
        agreement = decision["factAgreement"]
        if isinstance(agreement, bool) or not isinstance(agreement, (int, float)) \
                or not 0 <= agreement <= 1:
            raise ValueError("fact agreement is invalid")
        if not isinstance(decision["decisionAgreement"], bool):
            raise ValueError("decision agreement is invalid")
        if decision["preference"] not in {"A", "B", "merge"}:
            raise ValueError("adjudication preference is invalid")
        if decision["preference"] == "merge":
            merge_ids.add(identifier)
        by_id[identifier] = decision
    if set(by_id) != set(work_items):
        raise ValueError("adjudication decisions do not cover the work set")
    if set(decisions["overrides"]) != merge_ids:
        raise ValueError("adjudication overrides do not match merge decisions")
    count = len(by_id)
    fact_agreement = sum(item["factAgreement"] for item in by_id.values()) / count
    decision_agreement = sum(item["decisionAgreement"] for item in by_id.values()) / count
    return by_id, fact_agreement, decision_agreement


def final_label(identifier: str, reference: dict, annotator: str) -> dict:
    target_type = reference["targetType"]
    validate_reference(reference, target_type)
    return {
        "case": identifier,
        **reference,
        "pass": 1,
        "locked": True,
        "annotation": {
            "producer": "frontier-vlm",
            "annotator": annotator,
            "rubricVersion": RUBRIC,
            "blindedToCandidateOutputs": True,
            "candidateOutputsAvailable": False,
        },
    }


def finalize(root: Path) -> dict:
    root = validate_private_input(root)
    canonical = validate_private_output(root / "canonical")
    labels = load_pass1(root)
    work, decisions = load_adjudication(root)
    by_id, fact_agreement, decision_agreement = validate_decisions(work, decisions)
    if fact_agreement < MINIMUM_FACT_AGREEMENT \
            or decision_agreement < MINIMUM_DECISION_AGREEMENT:
        raise ValueError("canonical annotation did not clear the reliability floor")

    work_items = {item["id"]: item for item in work["items"]}
    for identifier, decision in by_id.items():
        if identifier not in labels:
            raise ValueError("adjudication case is missing from pass 1")
        item = work_items[identifier]
        preference = decision["preference"]
        if preference == "A":
            reference = item["referenceA"]
        elif preference == "B":
            reference = item["referenceB"]
        else:
            reference = decisions["overrides"][identifier]
        labels[identifier] = final_label(identifier, reference, decisions["annotator"])

    for identifier, label in list(labels.items()):
        if identifier not in by_id:
            reference = {key: label[key] for key in REFERENCE_KEYS}
            labels[identifier] = final_label(
                identifier,
                reference,
                label["annotation"]["annotator"],
            )

    payload = {
        "schema": "screen-understanding-canonical-labels-v2",
        "rubricVersion": RUBRIC,
        "candidateOutputsAvailableDuringAnnotation": False,
        "labels": [labels[key] for key in sorted(labels)],
    }
    reliability = {
        "schema": "screen-understanding-canonical-reliability-v2",
        "duplicateCount": len(by_id),
        "factAgreement": fact_agreement,
        "decisionAgreement": decision_agreement,
        "minimumFactAgreement": MINIMUM_FACT_AGREEMENT,
        "minimumDecisionAgreement": MINIMUM_DECISION_AGREEMENT,
        "qualified": True,
    }
    serialized = json.dumps(payload, ensure_ascii=False) + json.dumps(reliability)
    if any(fragment in serialized for fragment in FORBIDDEN_FRAGMENTS):
        raise ValueError("canonical output contains a forbidden field or local path")

    canonical, staging = prepare_private_output(canonical)
    try:
        atomic_private_json(staging / "labels.json", payload)
        atomic_private_json(staging / "reliability.json", reliability)
        publish_private_output(staging, canonical)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return {
        "labelCount": len(labels),
        "duplicateCount": len(by_id),
        "factAgreement": fact_agreement,
        "decisionAgreement": decision_agreement,
        "qualified": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--annotation-root", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(finalize(args.annotation_root), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
