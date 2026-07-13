#!/usr/bin/python3
"""Fail-closed validation for private frontier annotation batch outputs."""

import argparse
import json
import re
import sys
from pathlib import Path

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
if str(BENCHMARK_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCHMARK_ROOT))

from common.contracts import exact_keys
from common.private_io import validate_private_input_file


CASE_ID = re.compile(r"^[0-9a-f]{24}$")
FACT_ID = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
SEVERITIES = {"minor", "major", "critical"}
AMBIGUITIES = {"judgeable", "ambiguous", "unjudgeable"}


def validate_facts(
    facts: object,
    minimum: int,
    maximum: int,
    subject: str,
    severity_required: bool = False,
) -> None:
    if not isinstance(facts, list) or not minimum <= len(facts) <= maximum:
        raise ValueError(f"{subject} count is outside the rubric")
    identifiers = set()
    for fact in facts:
        if not isinstance(fact, dict):
            raise ValueError(f"{subject} fact is not an object")
        allowed_keys = {"id", "text", "severity"}
        if not set(fact).issubset(allowed_keys) or not {"id", "text"}.issubset(fact):
            raise ValueError(f"{subject} keys do not match the locked schema")
        if severity_required and "severity" not in fact:
            raise ValueError(f"{subject} severity is required")
        identifier = fact["id"]
        text = fact["text"]
        if not isinstance(identifier, str) or not FACT_ID.fullmatch(identifier):
            raise ValueError(f"{subject} fact identifier is invalid")
        if identifier in identifiers:
            raise ValueError(f"{subject} fact identifier is duplicated")
        identifiers.add(identifier)
        if not isinstance(text, str) or not 1 <= len(text) <= 240:
            raise ValueError(f"{subject} fact text is invalid")
        if "severity" in fact and fact["severity"] not in SEVERITIES:
            raise ValueError(f"{subject} fact severity is invalid")


def validate(work_path: Path, labels_path: Path) -> dict:
    work_path = validate_private_input_file(work_path)
    labels_path = validate_private_input_file(labels_path)
    work = json.loads(work_path.read_text(encoding="utf-8"))
    output_text = labels_path.read_text(encoding="utf-8")
    if any(fragment in output_text for fragment in [
        '"candidateOutput"',
        '"methodID"',
        "/Users/",
        "/Volumes/",
        "file://",
    ]):
        raise ValueError("label output contains a forbidden field or local path")
    output = json.loads(output_text)
    exact_keys(output, {"schema", "pass", "annotator", "rubricVersion", "labels"}, "batch")
    if output["schema"] != "screen-understanding-label-batch-v1":
        raise ValueError("unexpected label batch schema")
    if output["pass"] != work["pass"] or output["pass"] not in [1, 2]:
        raise ValueError("annotation pass mismatch")
    rubric_version = work["rubricVersion"]
    if output["rubricVersion"] != rubric_version or rubric_version not in {
        "screen-understanding-canonical-v1",
        "screen-understanding-canonical-v2",
    }:
        raise ValueError("annotation rubric mismatch")
    if not isinstance(output["annotator"], str) or not output["annotator"]:
        raise ValueError("annotator identity is missing")

    expected = {item["id"]: item for item in work["items"]}
    labels = output["labels"]
    if not isinstance(labels, list) or len(labels) != len(expected):
        raise ValueError("label count does not match the work batch")
    actual_ids = [label.get("case") for label in labels if isinstance(label, dict)]
    if len(actual_ids) != len(labels) or set(actual_ids) != set(expected) \
            or len(set(actual_ids)) != len(actual_ids):
        raise ValueError("label identifiers do not match the work batch")

    singles = 0
    temporal = 0
    for label in labels:
        exact_keys(label, {
            "case", "targetType", "requiredFacts", "criticalText",
            "forbiddenInferences", "meaningfulChange", "ambiguity",
            "abstentionAllowed", "pass", "locked", "annotation",
        }, "label")
        identifier = label["case"]
        if not CASE_ID.fullmatch(identifier):
            raise ValueError("case identifier is invalid")
        item = expected[identifier]
        if label["targetType"] != item["targetType"]:
            raise ValueError("target type mismatch")
        if label["pass"] != output["pass"] or label["locked"] is not False:
            raise ValueError("draft pass or lock state is invalid")
        if label["ambiguity"] not in AMBIGUITIES \
                or not isinstance(label["abstentionAllowed"], bool):
            raise ValueError("ambiguity or abstention state is invalid")
        validate_facts(label["requiredFacts"], 3, 8, "required")
        validate_facts(
            label["forbiddenInferences"],
            2,
            4,
            "forbidden",
            severity_required=True,
        )
        critical_text = label["criticalText"]
        if not isinstance(critical_text, list) or len(critical_text) > 5 \
                or any(not isinstance(text, str) or not 1 <= len(text) <= 240
                       for text in critical_text):
            raise ValueError("critical text is invalid")
        if rubric_version == "screen-understanding-canonical-v2":
            if [fact["id"] for fact in label["requiredFacts"]] != [
                "required.surface", "required.content", "required.state",
            ]:
                raise ValueError("v2 required fact slots are invalid")
            if [fact["id"] for fact in label["forbiddenInferences"]] != [
                "forbidden.intent", "forbidden.outcome",
            ]:
                raise ValueError("v2 forbidden fact slots are invalid")
            if len(critical_text) > 2:
                raise ValueError("v2 critical text exceeds its cap")

        if label["targetType"] == "single-frame":
            singles += 1
            if label["meaningfulChange"] is not None:
                raise ValueError("single-frame change must be null")
        else:
            temporal += 1
            validate_facts(
                label["meaningfulChange"],
                0,
                3 if rubric_version == "screen-understanding-canonical-v2" else 8,
                "change",
            )

        annotation = label["annotation"]
        exact_keys(annotation, {
            "producer", "annotator", "rubricVersion",
            "blindedToCandidateOutputs", "candidateOutputsAvailable",
        }, "annotation")
        if annotation != {
            "producer": "frontier-vlm",
            "annotator": output["annotator"],
            "rubricVersion": rubric_version,
            "blindedToCandidateOutputs": True,
            "candidateOutputsAvailable": False,
        }:
            raise ValueError("annotation provenance is invalid")

    return {"count": len(labels), "singleFrames": singles, "temporalPairs": temporal}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-batch", required=True, type=Path)
    parser.add_argument("--labels", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(validate(args.work_batch, args.labels), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
