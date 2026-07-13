#!/usr/bin/python3
"""Select v3 references and prepare one blinded final-reference audit."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
if str(BENCHMARK_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCHMARK_ROOT))

from annotation import validate_correctness_audit as correctness_validator
from common.contracts import exact_keys
from common.private_io import (
    atomic_private_json,
    copy_private,
    make_private_directory,
    prepare_private_output,
    publish_private_output,
    validate_private_input,
    validate_private_input_file,
    validate_private_output,
)


PROTOCOL = "screen-understanding-correctness-audit-v3"
RUBRIC = "screen-understanding-canonical-v2"
RAW_JOINT_FLOOR = 0.90
CASE_ID = re.compile(r"^[0-9a-f]{24}$")
SAFE_ID = re.compile(r"^[A-Za-z0-9._-]{1,96}$")
REFERENCE_KEYS = {
    "targetType", "requiredFacts", "criticalText", "forbiddenInferences",
    "meaningfulChange", "ambiguity", "abstentionAllowed",
}
FORBIDDEN_PACKET_FRAGMENTS = (
    '"case"', '"pass"', '"preference"', '"candidateoutput"',
    '"methodid"', '"path"', "/users/", "/volumes/", "file://",
)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def validate_fact(fact: object, expected_id: str, severity_required: bool) -> None:
    if not isinstance(fact, dict) or not {"id", "text"}.issubset(fact) \
            or not set(fact).issubset({"id", "text", "severity"}):
        raise ValueError("reference fact keys are invalid")
    if fact["id"] != expected_id:
        raise ValueError("reference fact slot is invalid")
    if not isinstance(fact["text"], str) or not 1 <= len(fact["text"]) <= 240:
        raise ValueError("reference fact text is invalid")
    if severity_required and "severity" not in fact:
        raise ValueError("reference forbidden severity is missing")
    if "severity" in fact and fact["severity"] not in {"minor", "major", "critical"}:
        raise ValueError("reference severity is invalid")


def validate_reference(reference: object, target_type: str) -> dict:
    exact_keys(reference, REFERENCE_KEYS, "reference")
    correctness_validator.validate_reference(reference, target_type)
    for fact, expected in zip(reference["requiredFacts"], [
        "required.surface", "required.content", "required.state",
    ]):
        validate_fact(fact, expected, False)
    for fact, expected in zip(reference["forbiddenInferences"], [
        "forbidden.intent", "forbidden.outcome",
    ]):
        validate_fact(fact, expected, True)
    for text in reference["criticalText"]:
        if not isinstance(text, str) or not 1 <= len(text) <= 240:
            raise ValueError("reference critical text is invalid")
    if target_type == "temporal-pair":
        seen = set()
        for fact in reference["meaningfulChange"]:
            if not isinstance(fact, dict) or not {"id", "text"}.issubset(fact) \
                    or not set(fact).issubset({"id", "text", "severity"}):
                raise ValueError("reference change fact is invalid")
            identifier = fact["id"]
            if not isinstance(identifier, str) or not identifier.startswith("change.") \
                    or identifier in seen:
                raise ValueError("reference change slot is invalid")
            seen.add(identifier)
            if not isinstance(fact["text"], str) or not 1 <= len(fact["text"]) <= 240:
                raise ValueError("reference change text is invalid")
            if "severity" in fact and fact["severity"] not in {"minor", "major", "critical"}:
                raise ValueError("reference change severity is invalid")
    return reference


def reference_from_label(label: dict) -> dict:
    reference = {key: label.get(key) for key in REFERENCE_KEYS}
    return validate_reference(reference, label.get("targetType"))


def load_labels(root: Path, pass_number: int) -> dict[str, dict]:
    paths = sorted((root / "labels" / f"pass{pass_number}").glob("*.json"))
    if not paths:
        raise ValueError(f"pass {pass_number} labels are missing")
    labels = {}
    for path in paths:
        batch = json.loads(path.read_text(encoding="utf-8"))
        if batch.get("schema") != "screen-understanding-label-batch-v1" \
                or batch.get("pass") != pass_number \
                or batch.get("rubricVersion") != RUBRIC:
            raise ValueError("label batch metadata is invalid")
        if not isinstance(batch.get("annotator"), str) or not batch["annotator"]:
            raise ValueError("label batch annotator is invalid")
        for label in batch.get("labels", []):
            if not isinstance(label, dict):
                raise ValueError("label is invalid")
            identifier = label.get("case")
            if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier) \
                    or identifier in labels:
                raise ValueError("label case identifier is invalid or duplicated")
            if label.get("pass") != pass_number or label.get("locked") is not False:
                raise ValueError("source label pass or lock state is invalid")
            annotation = label.get("annotation")
            if annotation != {
                "producer": "frontier-vlm",
                "annotator": batch["annotator"],
                "rubricVersion": RUBRIC,
                "blindedToCandidateOutputs": True,
                "candidateOutputsAvailable": False,
            }:
                raise ValueError("source label provenance is invalid")
            reference_from_label(label)
            labels[identifier] = label
    return labels


def load_duplicate_work(root: Path) -> dict[str, dict]:
    paths = sorted((root / "batches").glob("pass2-*.json"))
    if not paths:
        raise ValueError("pass 2 duplicate work is missing")
    items = {}
    for path in paths:
        batch = json.loads(path.read_text(encoding="utf-8"))
        if batch.get("pass") != 2 or batch.get("rubricVersion") != RUBRIC \
                or batch.get("candidateOutputsAvailable") is not False:
            raise ValueError("duplicate work metadata is invalid")
        for item in batch.get("items", []):
            identifier = item.get("id") if isinstance(item, dict) else None
            if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier) \
                    or identifier in items:
                raise ValueError("duplicate work identifier is invalid or duplicated")
            target = item.get("targetType")
            if target == "single-frame":
                if not isinstance(item.get("image"), str):
                    raise ValueError("single-frame render is missing")
            elif target == "temporal-pair":
                if not all(isinstance(item.get(key), str) for key in [
                    "beforeImage", "afterImage",
                ]):
                    raise ValueError("temporal renders are missing")
            else:
                raise ValueError("duplicate work target type is invalid")
            items[identifier] = item
    singles = sum(item["targetType"] == "single-frame" for item in items.values())
    if (len(items), singles, len(items) - singles) != (45, 30, 15):
        raise ValueError("final audit requires the locked 45/30/15 set")
    return items


def finite_rate(value: object, subject: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{subject} is invalid")
    rate = float(value)
    if not 0 <= rate <= 1:
        raise ValueError(f"{subject} is invalid")
    return rate


def load_aggregate(root: Path) -> tuple[dict, dict[str, dict]]:
    result = json.loads((root / "result.json").read_text(encoding="utf-8"))
    if result.get("schema") != "screen-understanding-correctness-audit-result-v3" \
            or result.get("protocol") != PROTOCOL or result.get("rubricVersion") != RUBRIC \
            or result.get("state") != "complete":
        raise ValueError("correctness aggregate is not complete")
    gate = result.get("rawJointGate")
    if not isinstance(gate, dict) or gate.get("qualified") is not True \
            or any(gate.get(key) is not True for key in [
                "overall", "singleFrame", "temporalPair",
            ]) or finite_rate(gate.get("minimum"), "raw joint minimum") < RAW_JOINT_FLOOR:
        raise ValueError("raw joint gate is not qualified")
    joint = result.get("joint")
    if not isinstance(joint, dict) or any(
        finite_rate(joint.get(key), f"raw joint {key}") < RAW_JOINT_FLOOR
        for key in ["overall", "singleFrame", "temporalPair"]
    ):
        raise ValueError("raw joint rates do not clear the floor")
    if result.get("pairedOpportunityCount") != 285:
        raise ValueError("raw joint opportunity count is invalid")

    selection = json.loads((root / "selection.json").read_text(encoding="utf-8"))
    exact_keys(selection, {
        "schema", "protocol", "rubricVersion", "items",
    }, "selection")
    if selection["schema"] != "screen-understanding-correctness-selection-v3" \
            or selection["protocol"] != PROTOCOL or selection["rubricVersion"] != RUBRIC:
        raise ValueError("selection metadata is invalid")
    by_id = {}
    for item in selection["items"]:
        exact_keys(item, {
            "case", "targetType", "selectedReference", "selectedFinalAudit",
        }, "selection item")
        identifier = item["case"]
        if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier) \
                or identifier in by_id:
            raise ValueError("selection identifier is invalid or duplicated")
        if item["targetType"] not in {"single-frame", "temporal-pair"} \
                or item["selectedReference"] not in {
                    "pass1", "pass2", "merge-required",
                } or item["selectedFinalAudit"] != "pending":
            raise ValueError("selection decision is invalid")
        by_id[identifier] = item
    if len(by_id) != 45:
        raise ValueError("selection must cover exactly 45 duplicate cases")
    return result, by_id


def load_correctness_audit(root: Path) -> dict[str, str]:
    manifest = json.loads((root / "audit-manifest.json").read_text(encoding="utf-8"))
    exact_keys(manifest, {
        "schema", "protocol", "rubricVersion", "caseCount", "singleFrameCount",
        "temporalPairCount", "referenceCount", "pairedOpportunityCount",
        "auditorCount", "candidateOutputsAvailable",
    }, "correctness audit manifest")
    if manifest["schema"] != "screen-understanding-correctness-audit-manifest-v3" \
            or manifest["protocol"] != PROTOCOL or manifest["rubricVersion"] != RUBRIC \
            or manifest["candidateOutputsAvailable"] is not False \
            or manifest["auditorCount"] != 2:
        raise ValueError("correctness audit manifest provenance is invalid")
    if (
        manifest["caseCount"], manifest["singleFrameCount"],
        manifest["temporalPairCount"], manifest["referenceCount"],
        manifest["pairedOpportunityCount"],
    ) != (45, 30, 15, 90, 285):
        raise ValueError("correctness audit manifest counts are invalid")

    mapping = json.loads((root / "owner-mapping.json").read_text(encoding="utf-8"))
    exact_keys(mapping, {
        "schema", "protocol", "rubricVersion", "seedSHA256", "auditors",
    }, "correctness audit mapping")
    if mapping["schema"] != "screen-understanding-correctness-audit-mapping-v3" \
            or mapping["protocol"] != PROTOCOL or mapping["rubricVersion"] != RUBRIC \
            or not isinstance(mapping["seedSHA256"], str) \
            or not re.fullmatch(r"[0-9a-f]{64}", mapping["seedSHA256"]) \
            or set(mapping["auditors"]) != {"auditor-01", "auditor-02"}:
        raise ValueError("correctness audit mapping metadata is invalid")
    canonical = None
    for slot in ["auditor-01", "auditor-02"]:
        by_case: dict[str, dict[int, str]] = {}
        owners = mapping["auditors"][slot]
        if not isinstance(owners, dict) or len(owners) != 90:
            raise ValueError("correctness audit owner mapping count is invalid")
        for owner in owners.values():
            exact_keys(owner, {
                "case", "sourceReference", "pass", "targetType",
            }, "correctness audit owner")
            identifier = owner["case"]
            pass_number = owner["pass"]
            target = owner["targetType"]
            if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier) \
                    or pass_number not in {1, 2} \
                    or owner["sourceReference"] != f"pass{pass_number}" \
                    or target not in {"single-frame", "temporal-pair"}:
                raise ValueError("correctness audit owner is invalid")
            passes = by_case.setdefault(identifier, {})
            if pass_number in passes:
                raise ValueError("correctness audit owner reference is duplicated")
            passes[pass_number] = target
        if len(by_case) != 45 or any(
            set(passes) != {1, 2} or len(set(passes.values())) != 1
            for passes in by_case.values()
        ):
            raise ValueError("correctness audit owner set is incomplete")
        targets = {identifier: passes[1] for identifier, passes in by_case.items()}
        if canonical is None:
            canonical = targets
        elif targets != canonical:
            raise ValueError("correctness auditors do not share the same owner set")
    singles = sum(target == "single-frame" for target in (canonical or {}).values())
    if (len(canonical or {}), singles) != (45, 30):
        raise ValueError("correctness audit owner strata are invalid")
    return canonical or {}


def validate_forbidden_auditors(values: list[str] | tuple[str, ...]) -> list[str]:
    auditors = list(values)
    if len(auditors) < 2 or len(set(auditors)) != len(auditors) \
            or any(not isinstance(value, str) or not SAFE_ID.fullmatch(value) for value in auditors):
        raise ValueError("explicit forbidden auditors must record distinct prior identities")
    return sorted(auditors)


def load_corrections(path: Path | None, required_ids: set[str]) -> tuple[dict[str, dict], str | None]:
    if not required_ids:
        if path is not None:
            raise ValueError("corrections are allowed only for merge-required cases")
        return {}, None
    if path is None:
        raise ValueError("a correction is required for every merge-required case")
    path = validate_private_input_file(path)
    text = path.read_text(encoding="utf-8")
    lowered = text.lower()
    if any(fragment in lowered for fragment in [
        '"candidateoutput"', '"methodid"', "/users/", "/volumes/", "file://",
    ]):
        raise ValueError("corrections contain a forbidden candidate field or path")
    payload = json.loads(text)
    exact_keys(payload, {
        "schema", "protocol", "rubricVersion", "producer", "mode", "annotator",
        "blindedToCandidateOutputs", "candidateOutputsAvailable", "items",
    }, "corrections")
    if any([
        payload["schema"] != "screen-understanding-corrections-v3",
        payload["protocol"] != PROTOCOL,
        payload["rubricVersion"] != RUBRIC,
        payload["producer"] != "frontier-vlm",
        payload["mode"] != "correction",
        payload["blindedToCandidateOutputs"] is not True,
        payload["candidateOutputsAvailable"] is not False,
    ]):
        raise ValueError("correction provenance is invalid")
    annotator = payload["annotator"]
    if not isinstance(annotator, str) or not SAFE_ID.fullmatch(annotator):
        raise ValueError("correction annotator is invalid")
    corrections = {}
    for item in payload["items"]:
        exact_keys(item, {"case", *REFERENCE_KEYS}, "correction item")
        identifier = item["case"]
        if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier) \
                or identifier in corrections:
            raise ValueError("correction identifier is invalid or duplicated")
        reference = {key: item[key] for key in REFERENCE_KEYS}
        corrections[identifier] = validate_reference(reference, item["targetType"])
    if set(corrections) != required_ids:
        raise ValueError("corrections must match exactly the merge-required cases")
    return corrections, annotator


def resolve_render(root: Path, relative: str) -> Path:
    if not isinstance(relative, str):
        raise ValueError("render path is invalid")
    candidate = (root / relative).resolve(strict=True)
    if root != candidate and root not in candidate.parents:
        raise ValueError("render path escapes the annotation root")
    if not candidate.is_file() or candidate.is_symlink():
        raise ValueError("render is not a regular private file")
    return candidate


def source_images(root: Path, item: dict) -> list[Path]:
    if item["targetType"] == "single-frame":
        return [resolve_render(root, item["image"])]
    return [
        resolve_render(root, item["beforeImage"]),
        resolve_render(root, item["afterImage"]),
    ]


def make_draft_label(identifier: str, reference: dict, annotator: str, mode: str) -> dict:
    return {
        "case": identifier,
        **reference,
        "locked": False,
        "annotation": {
            "producer": "frontier-vlm",
            "mode": mode,
            "annotator": annotator,
            "rubricVersion": RUBRIC,
            "blindedToCandidateOutputs": True,
            "candidateOutputsAvailable": False,
        },
    }


def prepare(
    annotation_root: Path,
    correctness_audit_root: Path,
    aggregate_root: Path,
    output_root: Path,
    seed: str,
    corrections_path: Path | None = None,
    forbidden_auditors: list[str] | tuple[str, ...] = (),
) -> dict:
    output = validate_private_output(output_root)
    annotation = validate_private_input(annotation_root)
    correctness_audit = validate_private_input(correctness_audit_root)
    aggregate = validate_private_input(aggregate_root)
    if not seed:
        raise ValueError("final-reference audit seed is required")
    for source in [annotation, correctness_audit, aggregate]:
        if source == output or source in output.parents or output in source.parents:
            raise ValueError("source and final-audit roots must be disjoint")
    prior_auditors = validate_forbidden_auditors(forbidden_auditors)
    result, selections = load_aggregate(aggregate)
    correctness_targets = load_correctness_audit(correctness_audit)
    pass1 = load_labels(annotation, 1)
    pass2 = load_labels(annotation, 2)
    duplicate_work = load_duplicate_work(annotation)
    if len(pass1) != 300 or set(pass2) != set(duplicate_work) \
            or set(selections) != set(duplicate_work):
        raise ValueError("labels, selection, and duplicate work have inconsistent IDs")
    if correctness_targets != {
        identifier: item["targetType"] for identifier, item in selections.items()
    }:
        raise ValueError("aggregate selection differs from its correctness audit owner set")
    for identifier, item in selections.items():
        if item["targetType"] != duplicate_work[identifier]["targetType"] \
                or pass1[identifier]["targetType"] != item["targetType"] \
                or pass2[identifier]["targetType"] != item["targetType"]:
            raise ValueError("selection target type is inconsistent")

    merge_ids = {
        identifier for identifier, item in selections.items()
        if item["selectedReference"] == "merge-required"
    }
    corrections, correction_annotator = load_corrections(corrections_path, merge_ids)
    draft_labels = {}
    for identifier, source in pass1.items():
        draft_labels[identifier] = make_draft_label(
            identifier,
            reference_from_label(source),
            source["annotation"]["annotator"],
            "pass1-base",
        )
    for identifier, selection in selections.items():
        selected = selection["selectedReference"]
        if selected == "merge-required":
            reference = corrections[identifier]
            annotator = correction_annotator
            mode = "frontier-correction"
        else:
            source = pass1[identifier] if selected == "pass1" else pass2[identifier]
            reference = reference_from_label(source)
            annotator = source["annotation"]["annotator"]
            mode = f"selected-{selected}"
        draft_labels[identifier] = make_draft_label(
            identifier, reference, annotator, mode,
        )
    if len(draft_labels) != 300 or any(label["locked"] for label in draft_labels.values()):
        raise ValueError("draft final labels do not match the locked 300-case protocol")

    output, staging = prepare_private_output(output)
    try:
        make_private_directory(staging / "packet")
        make_private_directory(staging / "packet" / "images")
        packet_items = []
        owner_items = {}
        source_basenames = set()
        for identifier, work_item in duplicate_work.items():
            opaque_id = "final-" + digest(f"{seed}:final:{identifier}")[:24]
            sources = source_images(annotation, work_item)
            source_basenames.update(path.name.lower() for path in sources)
            suffixes = ["frame"] if len(sources) == 1 else ["before", "after"]
            images = []
            for source, suffix in zip(sources, suffixes):
                relative = f"images/{opaque_id}-{suffix}{source.suffix.lower()}"
                copy_private(source, staging / "packet" / relative)
                images.append(relative)
            reference = {
                key: draft_labels[identifier][key] for key in REFERENCE_KEYS
            }
            packet_items.append({
                "opaqueID": opaque_id,
                "targetType": work_item["targetType"],
                "reference": reference,
                "images": images,
            })
            owner_items[opaque_id] = {
                "case": identifier,
                "targetType": work_item["targetType"],
            }
        packet_items.sort(key=lambda item: digest(f"{seed}:order:{item['opaqueID']}"))
        packet = {
            "schema": "screen-understanding-correctness-audit-packet-v3",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "packetID": "final-packet-" + digest(f"{seed}:packet")[:24],
            "items": packet_items,
        }
        packet_text = json.dumps(packet, sort_keys=True, ensure_ascii=False).lower()
        leaked_tokens = set(selections) | source_basenames
        if any(fragment in packet_text for fragment in FORBIDDEN_PACKET_FRAGMENTS) \
                or any(token.lower() in packet_text for token in leaked_tokens):
            raise ValueError("final audit packet exposes owner, selection, candidate, or path data")

        draft_payload = {
            "schema": "screen-understanding-draft-final-labels-v3",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "candidateOutputsAvailableDuringAnnotation": False,
            "locked": False,
            "labels": [draft_labels[key] for key in sorted(draft_labels)],
        }
        owner_mapping = {
            "schema": "screen-understanding-final-reference-mapping-v3",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "forbiddenAuditors": prior_auditors,
            "items": owner_items,
        }
        manifest = {
            "schema": "screen-understanding-final-reference-audit-manifest-v3",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "caseCount": 45,
            "singleFrameCount": 30,
            "temporalPairCount": 15,
            "slotCount": 285,
            "draftLabelCount": 300,
            "auditorCount": 1,
            "candidateOutputsAvailable": False,
            "rawJoint": result["joint"],
        }
        atomic_private_json(staging / "packet" / "packet.json", packet)
        atomic_private_json(staging / "owner-mapping.json", owner_mapping)
        atomic_private_json(staging / "draft-final-labels.json", draft_payload)
        atomic_private_json(staging / "audit-manifest.json", manifest)
        publish_private_output(staging, output)
        return manifest
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--annotation-root", required=True, type=Path)
    parser.add_argument("--correctness-audit-root", required=True, type=Path)
    parser.add_argument("--aggregate-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--seed", default="screen-understanding-final-reference-v3")
    parser.add_argument("--corrections", type=Path)
    parser.add_argument("--forbidden-auditor", action="append", default=[])
    args = parser.parse_args()
    result = prepare(
        args.annotation_root,
        args.correctness_audit_root,
        args.aggregate_root,
        args.output_root,
        args.seed,
        args.corrections,
        args.forbidden_auditor,
    )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
