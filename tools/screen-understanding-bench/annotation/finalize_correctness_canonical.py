#!/usr/bin/python3
"""Atomically seal v3 canonical labels after the final correctness audit."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import uuid
from pathlib import Path


PROTOCOL = "screen-understanding-correctness-audit-v3"
RUBRIC = "screen-understanding-canonical-v2"
RAW_JOINT_FLOOR = 0.90
CASE_ID = re.compile(r"^[0-9a-f]{24}$")
SAFE_ID = re.compile(r"^[A-Za-z0-9._-]{1,96}$")
REFERENCE_KEYS = {
    "targetType", "requiredFacts", "criticalText", "forbiddenInferences",
    "meaningfulChange", "ambiguity", "abstentionAllowed",
}
ALLOWED_MODES = {
    "pass1-base", "selected-pass1", "selected-pass2", "frontier-correction",
}
FORBIDDEN_FRAGMENTS = (
    '"candidateOutput"', '"methodID"', '"opaqueID"', '"images"',
    "/Users/", "/Volumes/", "file://",
)


def load_module(filename: str, module_name: str):
    path = Path(__file__).with_name(filename)
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prepare_module():
    return load_module("prepare_final_reference_audit.py", "prepare_final_reference_v3")


def final_validator():
    return load_module("validate_final_reference_audit.py", "validate_final_reference_v3")


def exact_keys(value: object, expected: set[str], subject: str) -> None:
    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError(f"{subject} keys do not match the locked schema")


def atomic_private_json(path: Path, value: object) -> None:
    temporary = path.with_name(f".{path.name}.tmp-{uuid.uuid4().hex}")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        path.chmod(0o600)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def load_manifest(root: Path) -> dict:
    manifest = json.loads((root / "audit-manifest.json").read_text(encoding="utf-8"))
    exact_keys(manifest, {
        "schema", "protocol", "rubricVersion", "caseCount", "singleFrameCount",
        "temporalPairCount", "slotCount", "draftLabelCount", "auditorCount",
        "candidateOutputsAvailable", "rawJoint",
    }, "final audit manifest")
    if manifest["schema"] != "screen-understanding-final-reference-audit-manifest-v3" \
            or manifest["protocol"] != PROTOCOL or manifest["rubricVersion"] != RUBRIC \
            or manifest["candidateOutputsAvailable"] is not False \
            or manifest["auditorCount"] != 1:
        raise ValueError("final audit manifest provenance is invalid")
    if (
        manifest["caseCount"], manifest["singleFrameCount"],
        manifest["temporalPairCount"], manifest["slotCount"],
        manifest["draftLabelCount"],
    ) != (45, 30, 15, 285, 300):
        raise ValueError("final audit manifest counts are invalid")
    return manifest


def load_mapping(root: Path) -> dict:
    mapping = json.loads((root / "owner-mapping.json").read_text(encoding="utf-8"))
    exact_keys(mapping, {
        "schema", "protocol", "rubricVersion", "forbiddenAuditors", "items",
    }, "owner mapping")
    if mapping["schema"] != "screen-understanding-final-reference-mapping-v3" \
            or mapping["protocol"] != PROTOCOL or mapping["rubricVersion"] != RUBRIC:
        raise ValueError("owner mapping metadata is invalid")
    auditors = mapping["forbiddenAuditors"]
    if not isinstance(auditors, list) or len(auditors) < 2 \
            or len(set(auditors)) != len(auditors) \
            or any(not isinstance(value, str) or not SAFE_ID.fullmatch(value) for value in auditors):
        raise ValueError("owner mapping prior auditor identities are invalid")
    items = mapping["items"]
    if not isinstance(items, dict) or len(items) != 45:
        raise ValueError("owner mapping must contain exactly 45 cases")
    seen_cases = set()
    for opaque_id, owner in items.items():
        if not isinstance(opaque_id, str) or not SAFE_ID.fullmatch(opaque_id):
            raise ValueError("owner mapping opaque identifier is invalid")
        exact_keys(owner, {"case", "targetType"}, "owner mapping item")
        identifier = owner["case"]
        if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier) \
                or identifier in seen_cases:
            raise ValueError("owner mapping case identifier is invalid or duplicated")
        if owner["targetType"] not in {"single-frame", "temporal-pair"}:
            raise ValueError("owner mapping target type is invalid")
        seen_cases.add(identifier)
    return mapping


def load_drafts(root: Path, prepare) -> dict[str, dict]:
    draft_path = root / "draft-final-labels.json"
    text = draft_path.read_text(encoding="utf-8")
    if any(fragment in text for fragment in FORBIDDEN_FRAGMENTS):
        raise ValueError("draft final labels contain a candidate, path, or packet leak")
    payload = json.loads(text)
    exact_keys(payload, {
        "schema", "protocol", "rubricVersion",
        "candidateOutputsAvailableDuringAnnotation", "locked", "labels",
    }, "draft final labels")
    if payload["schema"] != "screen-understanding-draft-final-labels-v3" \
            or payload["protocol"] != PROTOCOL or payload["rubricVersion"] != RUBRIC \
            or payload["candidateOutputsAvailableDuringAnnotation"] is not False \
            or payload["locked"] is not False:
        raise ValueError("draft final label metadata is invalid")
    labels = {}
    if not isinstance(payload["labels"], list) or len(payload["labels"]) != 300:
        raise ValueError("draft final labels must contain exactly 300 cases")
    for label in payload["labels"]:
        exact_keys(label, {"case", *REFERENCE_KEYS, "locked", "annotation"}, "draft label")
        identifier = label["case"]
        if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier) \
                or identifier in labels or label["locked"] is not False:
            raise ValueError("draft label identity or lock state is invalid")
        prepare.validate_reference(
            {key: label[key] for key in REFERENCE_KEYS}, label["targetType"]
        )
        annotation = label["annotation"]
        exact_keys(annotation, {
            "producer", "mode", "annotator", "rubricVersion",
            "blindedToCandidateOutputs", "candidateOutputsAvailable",
        }, "draft annotation")
        if annotation["producer"] != "frontier-vlm" \
                or annotation["mode"] not in ALLOWED_MODES \
                or not isinstance(annotation["annotator"], str) \
                or not SAFE_ID.fullmatch(annotation["annotator"]) \
                or annotation["rubricVersion"] != RUBRIC \
                or annotation["blindedToCandidateOutputs"] is not True \
                or annotation["candidateOutputsAvailable"] is not False:
            raise ValueError("draft annotation provenance or mode is invalid")
        labels[identifier] = label
    return labels


def validate_cross_links(
    annotation: Path,
    correctness_audit: Path,
    aggregate: Path,
    audit: Path,
    mapping: dict,
    drafts: dict[str, dict],
    prepare,
) -> None:
    source_pass1 = prepare.load_labels(annotation, 1)
    source_pass2 = prepare.load_labels(annotation, 2)
    duplicate_work = prepare.load_duplicate_work(annotation)
    _, selections = prepare.load_aggregate(aggregate)
    correctness_targets = prepare.load_correctness_audit(correctness_audit)
    if set(source_pass1) != set(drafts) or set(source_pass2) != set(duplicate_work) \
            or set(duplicate_work) != set(selections):
        raise ValueError("draft labels do not preserve the original owner sets")
    if correctness_targets != {
        identifier: item["targetType"] for identifier, item in selections.items()
    }:
        raise ValueError("aggregate selection differs from its correctness audit owner set")

    packet = final_validator().base_validator().load_packet(
        audit / "packet" / "packet.json"
    )
    packet_items = {item["opaqueID"]: item for item in packet["items"]}
    owners = mapping["items"]
    if set(packet_items) != set(owners):
        raise ValueError("packet and owner mapping opaque sets differ")
    if len(packet_items) != 45:
        raise ValueError("final packet must contain exactly 45 cases")
    for opaque_id, item in packet_items.items():
        owner = owners[opaque_id]
        identifier = owner["case"]
        if identifier not in duplicate_work or owner["targetType"] != item["targetType"]:
            raise ValueError("owner mapping does not match duplicate work")
        draft = drafts[identifier]
        reference = {key: draft[key] for key in REFERENCE_KEYS}
        if item["reference"] != reference:
            raise ValueError("audited reference differs from the owner draft")
        for relative in item["images"]:
            image = (audit / "packet" / relative).resolve(strict=True)
            packet_root = (audit / "packet").resolve(strict=True)
            if packet_root not in image.parents or not image.is_file() or image.is_symlink():
                raise ValueError("final packet image is invalid")

    for identifier, selection in selections.items():
        expected_mode = {
            "pass1": "selected-pass1",
            "pass2": "selected-pass2",
            "merge-required": "frontier-correction",
        }[selection["selectedReference"]]
        if drafts[identifier]["annotation"]["mode"] != expected_mode:
            raise ValueError("draft provenance mode disagrees with the selection")
        if selection["selectedReference"] in {"pass1", "pass2"}:
            source = source_pass1[identifier] if selection["selectedReference"] == "pass1" \
                else source_pass2[identifier]
            expected_reference = {key: source[key] for key in REFERENCE_KEYS}
            actual_reference = {key: drafts[identifier][key] for key in REFERENCE_KEYS}
            if actual_reference != expected_reference \
                    or drafts[identifier]["annotation"]["annotator"] \
                    != source["annotation"]["annotator"]:
                raise ValueError("selected draft is not the exact locked source reference")
    for identifier in set(drafts) - set(selections):
        if drafts[identifier]["annotation"]["mode"] != "pass1-base":
            raise ValueError("non-duplicate draft must retain pass1-base mode")
        expected_reference = {key: source_pass1[identifier][key] for key in REFERENCE_KEYS}
        actual_reference = {key: drafts[identifier][key] for key in REFERENCE_KEYS}
        if actual_reference != expected_reference \
                or drafts[identifier]["annotation"]["annotator"] \
                != source_pass1[identifier]["annotation"]["annotator"]:
            raise ValueError("pass1-base draft is not the exact locked source reference")


def acquire_lock(path: Path) -> int:
    try:
        return os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError as error:
        raise ValueError("canonical seal is already in progress") from error


def finalize(
    annotation_root: Path,
    correctness_audit_root: Path,
    aggregate_root: Path,
    final_audit_root: Path,
    judgments_path: Path,
) -> dict:
    annotation = annotation_root.resolve(strict=True)
    correctness_audit = correctness_audit_root.resolve(strict=True)
    aggregate = aggregate_root.resolve(strict=True)
    audit = final_audit_root.resolve(strict=True)
    canonical = audit / "canonical"
    if canonical.exists():
        raise ValueError("canonical output already exists")

    prepare = prepare_module()
    result, _ = prepare.load_aggregate(aggregate)
    manifest = load_manifest(audit)
    mapping = load_mapping(audit)
    drafts = load_drafts(audit, prepare)
    validate_cross_links(
        annotation, correctness_audit, aggregate, audit, mapping, drafts, prepare
    )
    if manifest["rawJoint"] != result["joint"]:
        raise ValueError("final audit manifest raw joint rates were changed")
    final_result = final_validator().validate(
        audit / "packet" / "packet.json",
        judgments_path,
        mapping["forbiddenAuditors"],
    )
    if final_result["criticalErrorCount"] != 0 or final_result["qualified"] is not True:
        raise ValueError("final reference audit contains critical errors; canonical seal refused")

    labels = []
    for identifier in sorted(drafts):
        label = {**drafts[identifier], "locked": True}
        labels.append(label)
    labels_payload = {
        "schema": "screen-understanding-canonical-labels-v3",
        "protocol": PROTOCOL,
        "rubricVersion": RUBRIC,
        "candidateOutputsAvailableDuringAnnotation": False,
        "labels": labels,
    }
    reliability = {
        "schema": "screen-understanding-canonical-reliability-v3",
        "protocol": PROTOCOL,
        "rubricVersion": RUBRIC,
        "duplicateCount": 45,
        "rawJoint": {
            "minimum": RAW_JOINT_FLOOR,
            "overall": result["joint"]["overall"],
            "singleFrame": result["joint"]["singleFrame"],
            "temporalPair": result["joint"]["temporalPair"],
        },
        "finalReferenceAudit": {
            "auditor": final_result["auditor"],
            "caseCount": 45,
            "slotCount": 285,
            "materialFalseCount": 0,
            "ambiguityErrorCount": 0,
            "criticalErrorCount": 0,
            "requiredCriticalErrorCount": 0,
            "qualified": True,
        },
        "qualified": True,
    }
    serialized = json.dumps(labels_payload, ensure_ascii=False) \
        + json.dumps(reliability, ensure_ascii=False)
    if any(fragment in serialized for fragment in FORBIDDEN_FRAGMENTS):
        raise ValueError("canonical output contains a candidate, path, or packet leak")
    if len(labels) != 300 or not all(label["locked"] for label in labels):
        raise ValueError("canonical output does not contain 300 locked owner labels")

    lock_path = audit / ".canonical-seal.lock"
    lock = acquire_lock(lock_path)
    staging = audit / f".canonical.staging-{uuid.uuid4().hex}"
    try:
        if canonical.exists():
            raise ValueError("canonical output already exists")
        staging.mkdir(mode=0o700)
        staging.chmod(0o700)
        atomic_private_json(staging / "labels.json", labels_payload)
        atomic_private_json(staging / "reliability.json", reliability)
        staging.rename(canonical)
        canonical.chmod(0o700)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    finally:
        os.close(lock)
        lock_path.unlink(missing_ok=True)
    return {
        "labelCount": 300,
        "duplicateCount": 45,
        "slotCount": 285,
        "criticalErrorCount": 0,
        "rawJoint": result["joint"],
        "qualified": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--annotation-root", required=True, type=Path)
    parser.add_argument("--correctness-audit-root", required=True, type=Path)
    parser.add_argument("--aggregate-root", required=True, type=Path)
    parser.add_argument("--final-audit-root", required=True, type=Path)
    parser.add_argument("--judgments", required=True, type=Path)
    args = parser.parse_args()
    result = finalize(
        args.annotation_root,
        args.correctness_audit_root,
        args.aggregate_root,
        args.final_audit_root,
        args.judgments,
    )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
