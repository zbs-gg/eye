#!/usr/bin/python3
"""Seal the qualified v2 single-frame lane without inheriting v3 temporal failure."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
from pathlib import Path
from typing import Any

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
if str(BENCHMARK_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCHMARK_ROOT))

from annotation import aggregate_correctness_audit as legacy_aggregate  # noqa: E402
from annotation import prepare_final_reference_audit as legacy_reference  # noqa: E402
from annotation import validate_correctness_audit as legacy_validator  # noqa: E402
from common.contracts import exact_keys  # noqa: E402
from common.evaluator_receipt import (  # noqa: E402
    validate_independent_sessions,
    validate_receipt,
)
from common.private_io import (  # noqa: E402
    atomic_private_json,
    copy_private,
    load_private_json,
    make_private_directory,
    prepare_private_output,
    publish_private_output,
    validate_private_input,
    validate_private_input_file,
    validate_private_output,
)
from common.provenance import (  # noqa: E402
    HASH_ALGORITHM,
    file_evidence,
    final_audit_evidence,
    tree_evidence,
)


PROTOCOL = "screen-understanding-single-frame-lane-v4"
LEGACY_PROTOCOL = "screen-understanding-correctness-audit-v3"
RUBRIC = "screen-understanding-canonical-v2"
RAW_JOINT_FLOOR = 0.90
CASE_ID = re.compile(r"^[0-9a-f]{24}$")
SAFE_ID = re.compile(r"^[A-Za-z0-9._:/-]{1,160}$")
REFERENCE_KEYS = {
    "targetType", "requiredFacts", "criticalText", "forbiddenInferences",
    "meaningfulChange", "ambiguity", "abstentionAllowed",
}
SINGLE_SLOT_ORDER = [
    "surface", "content", "state", "intent", "outcome", "criticalText",
]
MODEL_FORBIDDEN_KEYS = {
    "case", "pass", "selectedReference", "selectedFinalAudit", "methodID",
    "candidateOutput", "candidateOutputs", "owner", "ownerMapping", "path",
}
FORBIDDEN_TEXT = ("/users/", "/volumes/", "file://")


class V3EvidencePaths:
    """Explicit paths needed to independently revalidate the legacy aggregate."""

    def __init__(
        self,
        annotation_root: Path,
        correctness_audit_root: Path,
        aggregate_root: Path,
        auditor_one_output: Path,
        auditor_one_receipt: Path,
        auditor_two_output: Path,
        auditor_two_receipt: Path,
        tiebreak_output: Path | None = None,
        tiebreak_receipt: Path | None = None,
    ) -> None:
        self.annotation_root = Path(annotation_root)
        self.correctness_audit_root = Path(correctness_audit_root)
        self.aggregate_root = Path(aggregate_root)
        self.auditor_one_output = Path(auditor_one_output)
        self.auditor_one_receipt = Path(auditor_one_receipt)
        self.auditor_two_output = Path(auditor_two_output)
        self.auditor_two_receipt = Path(auditor_two_receipt)
        self.tiebreak_output = Path(tiebreak_output) if tiebreak_output else None
        self.tiebreak_receipt = Path(tiebreak_receipt) if tiebreak_receipt else None


def _read_json(path: Path, subject: str) -> dict:
    value, _ = load_private_json(path, subject)
    return value


def _digest_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _json_digest(value: object) -> str:
    serialized = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    return _digest_text(serialized)


def _finite_rate(value: object, subject: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{subject} is invalid")
    result = float(value)
    if not 0 <= result <= 1:
        raise ValueError(f"{subject} is invalid")
    return result


def _assert_disjoint(output: Path, sources: list[Path]) -> None:
    for source in sources:
        if source == output or source in output.parents or output in source.parents:
            raise ValueError("private source and output roots must be disjoint")


def _validate_all_files(paths: list[Path]) -> None:
    for path in paths:
        validate_private_input_file(path)


def _walk_keys(value: object) -> list[str]:
    keys: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            keys.append(str(key))
            keys.extend(_walk_keys(child))
    elif isinstance(value, list):
        for child in value:
            keys.extend(_walk_keys(child))
    return keys


def _reject_model_leaks(value: object, forbidden_tokens: set[str]) -> None:
    if any(key in MODEL_FORBIDDEN_KEYS for key in _walk_keys(value)):
        raise ValueError("model-visible artifact contains a forbidden owner or candidate field")
    serialized = json.dumps(value, ensure_ascii=False, sort_keys=True).lower()
    if any(fragment in serialized for fragment in FORBIDDEN_TEXT):
        raise ValueError("model-visible artifact contains a forbidden local path")
    if any(token.lower() in serialized for token in forbidden_tokens):
        raise ValueError("model-visible artifact exposes a private owner identifier")


def _load_work(root: Path, pass_number: int) -> dict[str, dict]:
    paths = sorted((root / "batches").glob(f"pass{pass_number}-*.json"))
    if not paths:
        raise ValueError(f"source pass {pass_number} work is missing")
    _validate_all_files(paths)
    items: dict[str, dict] = {}
    for path in paths:
        batch = _read_json(path, "source work batch")
        exact_keys(batch, {
            "schema", "pass", "annotatorSlot", "rubricVersion",
            "candidateOutputsAvailable", "items",
        }, "source work batch")
        if batch["schema"] != "screen-understanding-annotation-batch-v1" \
                or batch["pass"] != pass_number \
                or batch["rubricVersion"] != RUBRIC \
                or batch["candidateOutputsAvailable"] is not False \
                or not isinstance(batch["items"], list):
            raise ValueError("source work provenance is invalid")
        for item in batch["items"]:
            if not isinstance(item, dict):
                raise ValueError("source work item is invalid")
            identifier = item.get("id")
            target = item.get("targetType")
            if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier) \
                    or identifier in items or target not in {"single-frame", "temporal-pair"}:
                raise ValueError("source work identity is invalid or duplicated")
            if target == "single-frame":
                exact_keys(item, {"id", "targetType", "image"}, "single-frame work")
                if not isinstance(item["image"], str):
                    raise ValueError("single-frame render is invalid")
            else:
                if not {"id", "targetType", "beforeImage", "afterImage"}.issubset(item) \
                        or not set(item).issubset({
                            "id", "targetType", "beforeImage", "afterImage", "deltaMs",
                        }) or not isinstance(item["beforeImage"], str) \
                        or not isinstance(item["afterImage"], str):
                    raise ValueError("temporal work is invalid")
            items[identifier] = item
    return items


def _load_source_labels(root: Path) -> tuple[dict, dict, dict]:
    pass1_paths = sorted((root / "labels" / "pass1").glob("*.json"))
    pass2_paths = sorted((root / "labels" / "pass2").glob("*.json"))
    _validate_all_files(pass1_paths + pass2_paths)
    for pass_number, paths in [(1, pass1_paths), (2, pass2_paths)]:
        for path in paths:
            batch = _read_json(path, "source label batch")
            exact_keys(batch, {
                "schema", "pass", "annotator", "rubricVersion", "labels",
            }, "source label batch")
            if batch["schema"] != "screen-understanding-label-batch-v1" \
                    or batch["pass"] != pass_number \
                    or batch["rubricVersion"] != RUBRIC \
                    or not isinstance(batch["labels"], list):
                raise ValueError("source label batch provenance is invalid")
            for label in batch["labels"]:
                exact_keys(label, {
                    "case", *REFERENCE_KEYS, "pass", "locked", "annotation",
                }, "source v2 label")
    pass1 = legacy_reference.load_labels(root, 1)
    pass2 = legacy_reference.load_labels(root, 2)
    work1 = _load_work(root, 1)
    work2 = _load_work(root, 2)
    single_work1 = {
        identifier for identifier, item in work1.items()
        if item["targetType"] == "single-frame"
    }
    single_work2 = {
        identifier for identifier, item in work2.items()
        if item["targetType"] == "single-frame"
    }
    single_labels1 = {
        identifier for identifier, label in pass1.items()
        if label["targetType"] == "single-frame"
    }
    single_labels2 = {
        identifier for identifier, label in pass2.items()
        if label["targetType"] == "single-frame"
    }
    if len(single_work1) != 200 or single_labels1 != single_work1:
        raise ValueError("source v2 pass1 must contain all 200 single-frame labels")
    if len(single_work2) != 30 or single_labels2 != single_work2:
        raise ValueError("source v2 duplicate pass must contain exactly 30 single frames")
    if set(pass1) != set(work1) or set(pass2) != set(work2):
        raise ValueError("source labels and blinded work do not cover the same cases")
    return pass1, pass2, work2


def _load_tiebreak(
    sources: V3EvidencePaths,
    differences: dict,
    loaded: list[dict],
) -> tuple[dict, dict, dict | None]:
    packet_path = sources.aggregate_root / "tiebreak" / "packet.json"
    mapping_path = sources.aggregate_root / "tiebreak-owner-mapping.json"
    if not differences:
        if any(value is not None for value in [
            sources.tiebreak_output, sources.tiebreak_receipt,
        ]) or packet_path.exists() or mapping_path.exists():
            raise ValueError("tiebreak evidence was supplied without disagreements")
        return {}, {}, None
    if sources.tiebreak_output is None or sources.tiebreak_receipt is None:
        raise ValueError("complete aggregate disagreements require tiebreak evidence")
    packet = _read_json(packet_path, "tiebreak packet")
    mapping = _read_json(mapping_path, "tiebreak owner mapping")
    exact_keys(mapping, {
        "schema", "protocol", "rubricVersion", "items",
    }, "tiebreak owner mapping")
    if mapping["schema"] != "screen-understanding-correctness-tiebreak-mapping-v3" \
            or mapping["protocol"] != LEGACY_PROTOCOL \
            or mapping["rubricVersion"] != RUBRIC \
            or not isinstance(mapping["items"], dict):
        raise ValueError("tiebreak owner mapping provenance is invalid")
    expected_keys = set(differences)
    actual_keys = set()
    packet_items = {
        item.get("opaqueID"): item for item in packet.get("items", [])
        if isinstance(item, dict)
    }
    if set(packet_items) != set(mapping["items"]):
        raise ValueError("tiebreak packet and owner mapping differ")
    for opaque_id, owner in mapping["items"].items():
        exact_keys(owner, {
            "case", "sourceReference", "pass", "targetType",
        }, "tiebreak owner")
        key = (owner["case"], owner["pass"])
        if owner["sourceReference"] != f"pass{owner['pass']}" or key in actual_keys:
            raise ValueError("tiebreak owner mapping is invalid")
        source = loaded[0]["byKey"].get(key)
        item = packet_items[opaque_id]
        expected_disputes = [
            {"slot": slot, "field": field} for slot, field in differences[key]
        ]
        if source is None or item.get("targetType") != source["targetType"] \
                or item.get("reference") != source["packetItem"]["reference"] \
                or item.get("disputed") != expected_disputes:
            raise ValueError("tiebreak packet differs from its audited reference")
        actual_keys.add(key)
    if actual_keys != expected_keys:
        raise ValueError("tiebreak owner mapping does not match disagreements")
    tiebreak_values = legacy_validator.validate_tiebreak(
        packet_path, sources.tiebreak_output
    )
    receipt = validate_receipt(
        sources.tiebreak_receipt,
        packet_path,
        sources.tiebreak_output,
        "correctness-tiebreak",
        allow_legacy=True,
    )
    output = _read_json(sources.tiebreak_output, "tiebreak judgments")
    if output["auditor"] in {loaded[0]["auditor"], loaded[1]["auditor"]}:
        raise ValueError("tiebreak auditor identity must be independent")
    return tiebreak_values, mapping["items"], receipt


def _receipt_entry(path: Path, payload: dict) -> dict:
    return {
        "role": payload["role"],
        "sessionID": payload["sessionID"],
        "receiptSHA256": file_evidence(validate_private_input_file(path))["sha256"],
    }


def _session_provenance(entries: list[tuple[Path, dict]]) -> dict:
    values = [_receipt_entry(path, payload) for path, payload in entries]
    values.sort(key=lambda value: value["role"])
    return {
        "schema": "screen-understanding-session-provenance-v1",
        "issuer": "codex-ce-work-orchestrator-v1",
        "receipts": values,
    }


def _load_v3_evidence(sources: V3EvidencePaths) -> dict[str, Any]:
    annotation = validate_private_input(sources.annotation_root)
    correctness = validate_private_input(sources.correctness_audit_root)
    aggregate = validate_private_input(sources.aggregate_root)
    sources.annotation_root = annotation
    sources.correctness_audit_root = correctness
    sources.aggregate_root = aggregate
    pass1, pass2, duplicate_work = _load_source_labels(annotation)
    _, _, loaded = legacy_aggregate.load_audit(
        correctness,
        (sources.auditor_one_output, sources.auditor_two_output),
    )
    receipt1 = validate_receipt(
        sources.auditor_one_receipt,
        correctness / "packets" / "auditor-01" / "packet.json",
        sources.auditor_one_output,
        "correctness-auditor-1",
        allow_legacy=True,
    )
    receipt2 = validate_receipt(
        sources.auditor_two_receipt,
        correctness / "packets" / "auditor-02" / "packet.json",
        sources.auditor_two_output,
        "correctness-auditor-2",
        allow_legacy=True,
    )
    differences = legacy_aggregate.disagreements(loaded)
    tie_values, tie_mapping, tie_receipt = _load_tiebreak(
        sources, differences, loaded
    )
    resolved = legacy_aggregate.resolved_boolean_fields(
        differences, loaded, tie_values, tie_mapping
    )
    targets = {
        identifier: loaded[0]["byKey"][(identifier, 1)]["targetType"]
        for identifier, _ in resolved
    }
    rates, counts, material, computed_selection = legacy_aggregate.score(resolved, targets)
    result = _read_json(aggregate / "result.json", "aggregate result")
    exact_keys(result, {
        "schema", "protocol", "rubricVersion", "state",
        "pairedOpportunityCount", "pass1", "pass2", "joint",
        "materialFalseCount", "selection", "rawJointGate",
        "finalReferenceAudit", "qualified",
    }, "aggregate result")
    if result["schema"] != "screen-understanding-correctness-audit-result-v3" \
            or result["protocol"] != LEGACY_PROTOCOL \
            or result["rubricVersion"] != RUBRIC or result["state"] != "complete" \
            or result["pairedOpportunityCount"] != 285 \
            or counts["overall"] != 285:
        raise ValueError("v3 aggregate provenance or denominator is invalid")
    for key in ["overall", "singleFrame", "temporalPair"]:
        if _finite_rate(result["joint"].get(key), f"joint {key}") \
                != rates["joint"][key]:
            raise ValueError("v3 aggregate joint rates differ from recomputed evidence")
        if _finite_rate(result["pass1"].get(key), f"pass1 {key}") != rates[1][key] \
                or _finite_rate(result["pass2"].get(key), f"pass2 {key}") != rates[2][key]:
            raise ValueError("v3 aggregate pass rates differ from recomputed evidence")
    if result["materialFalseCount"] != {
        "pass1": material[1], "pass2": material[2],
    }:
        raise ValueError("v3 aggregate material-false counts differ from evidence")
    gate = result["rawJointGate"]
    if not isinstance(gate, dict) or gate.get("singleFrame") is not True \
            or _finite_rate(gate.get("minimum"), "raw joint minimum") < RAW_JOINT_FLOOR \
            or _finite_rate(result["joint"]["singleFrame"], "single-frame joint") \
            < RAW_JOINT_FLOOR:
        raise ValueError("single-frame raw joint gate is not qualified")
    expected_gate = {
        key: rates["joint"][key] is not None
        and rates["joint"][key] >= RAW_JOINT_FLOOR
        for key in ["overall", "singleFrame", "temporalPair"]
    }
    if any(gate.get(key) is not value for key, value in expected_gate.items()) \
            or gate.get("qualified") is not all(expected_gate.values()) \
            or result["qualified"] is not False \
            or result["finalReferenceAudit"] != {
                "state": "pending",
                "criticalErrorCount": None,
                "requiredCriticalErrorCount": 0,
                "qualified": False,
            }:
        raise ValueError("v3 aggregate gate or final-audit state is inconsistent")
    selection_payload = _read_json(aggregate / "selection.json", "selection")
    exact_keys(selection_payload, {
        "schema", "protocol", "rubricVersion", "items",
    }, "selection")
    if selection_payload["schema"] != "screen-understanding-correctness-selection-v3" \
            or selection_payload["protocol"] != LEGACY_PROTOCOL \
            or selection_payload["rubricVersion"] != RUBRIC \
            or not isinstance(selection_payload["items"], list):
        raise ValueError("v3 selection provenance is invalid")
    selections: dict[str, dict] = {}
    for item in selection_payload["items"]:
        exact_keys(item, {
            "case", "targetType", "selectedReference", "selectedFinalAudit",
        }, "selection item")
        identifier = item["case"]
        if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier) \
                or identifier in selections or item["selectedFinalAudit"] != "pending":
            raise ValueError("v3 selection identity is invalid")
        expected = computed_selection.get(identifier)
        if expected is None or item["targetType"] != expected["targetType"] \
                or item["selectedReference"] != expected["selectedReference"]:
            raise ValueError("v3 selection differs from recomputed correctness evidence")
        selections[identifier] = item
    if len(selections) != 45 or set(selections) != set(computed_selection):
        raise ValueError("v3 selection must cover the exact 45 duplicate cases")
    single_selections = {
        identifier: item for identifier, item in selections.items()
        if item["targetType"] == "single-frame"
    }
    if len(single_selections) != 30 \
            or set(single_selections) != {
                identifier for identifier, item in duplicate_work.items()
                if item["targetType"] == "single-frame"
            }:
        raise ValueError("v3 evidence must contain exactly 30 single duplicates")
    expected_counts = {
        "pass1": sum(item["selectedReference"] == "pass1" for item in selections.values()),
        "pass2": sum(item["selectedReference"] == "pass2" for item in selections.values()),
        "mergeRequired": sum(
            item["selectedReference"] == "merge-required" for item in selections.values()
        ),
    }
    if result["selection"] != expected_counts:
        raise ValueError("v3 aggregate selection counts are inconsistent")
    receipt_pairs = [
        (sources.auditor_one_receipt, receipt1),
        (sources.auditor_two_receipt, receipt2),
    ]
    required_roles = {"correctness-auditor-1", "correctness-auditor-2"}
    if tie_receipt is not None:
        receipt_pairs.append((sources.tiebreak_receipt, tie_receipt))
        required_roles.add("correctness-tiebreak")
    validate_independent_sessions(
        [payload for _, payload in receipt_pairs], required_roles
    )
    return {
        "pass1": pass1,
        "pass2": pass2,
        "duplicateWork": duplicate_work,
        "result": result,
        "selections": single_selections,
        "receiptPairs": receipt_pairs,
    }


def _reference(label: dict) -> dict:
    value = {key: label[key] for key in REFERENCE_KEYS}
    legacy_reference.validate_reference(value, "single-frame")
    return value


def _resolve_render(annotation: Path, relative: object) -> Path:
    if not isinstance(relative, str):
        raise ValueError("single-frame render path is invalid")
    original = annotation / relative
    source = validate_private_input_file(original)
    if annotation != source and annotation not in source.parents:
        raise ValueError("single-frame render escapes the annotation root")
    return source


def _make_draft(identifier: str, reference: dict, annotator: str, mode: str) -> dict:
    if not isinstance(annotator, str) or not SAFE_ID.fullmatch(annotator):
        raise ValueError("draft annotator is invalid")
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


def prepare_correction(
    sources: V3EvidencePaths,
    output_root: Path,
    seed: str,
    additional_case_ids: set[str] | None = None,
) -> dict:
    output = validate_private_output(output_root)
    if not seed:
        raise ValueError("correction seed is required")
    evidence = _load_v3_evidence(sources)
    _assert_disjoint(output, [
        sources.annotation_root, sources.correctness_audit_root, sources.aggregate_root,
    ])
    merge_ids = sorted(
        identifier for identifier, item in evidence["selections"].items()
        if item["selectedReference"] == "merge-required"
    )
    if not merge_ids:
        raise ValueError("single-frame correction packet requires at least one merge-required case")
    additional = set(additional_case_ids or set())
    if any(
        not isinstance(identifier, str)
        or not CASE_ID.fullmatch(identifier)
        or identifier not in evidence["selections"]
        for identifier in additional
    ):
        raise ValueError("additional corrections must be audited single-frame duplicates")
    additional.difference_update(merge_ids)
    correction_ids = sorted({*merge_ids, *additional})
    sessions = _session_provenance(evidence["receiptPairs"])
    output, staging = prepare_private_output(output)
    try:
        make_private_directory(staging / "images")
        packet_items = []
        owners = {}
        source_tokens = set(evidence["selections"])
        for identifier in correction_ids:
            opaque_id = "correction-" + _digest_text(
                f"{seed}:single-correction:{identifier}"
            )[:24]
            work = evidence["duplicateWork"][identifier]
            source = _resolve_render(sources.annotation_root, work["image"])
            source_tokens.add(source.name)
            relative = f"images/{opaque_id}{source.suffix.lower()}"
            copy_private(source, staging / relative)
            packet_items.append({
                "opaqueID": opaque_id,
                "targetType": "single-frame",
                "references": [
                    {"alias": "reference-a", "reference": _reference(evidence["pass1"][identifier])},
                    {"alias": "reference-b", "reference": _reference(evidence["pass2"][identifier])},
                ],
                "images": [relative],
            })
            owners[opaque_id] = {"case": identifier}
        packet_items.sort(key=lambda item: _digest_text(f"{seed}:order:{item['opaqueID']}"))
        packet = {
            "schema": "screen-understanding-single-frame-correction-packet-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "packetID": "single-correction-" + _digest_text(f"{seed}:packet")[:24],
            "items": packet_items,
        }
        _reject_model_leaks(packet, source_tokens)
        mapping = {
            "schema": "screen-understanding-single-frame-correction-mapping-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "items": owners,
        }
        manifest = {
            "schema": "screen-understanding-single-frame-correction-manifest-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "mergeRequiredCount": len(merge_ids),
            "additionalCorrectionCount": len(additional),
            "correctionCount": len(correction_ids),
            "candidateOutputsAvailable": False,
            "priorSessionProvenanceSHA256": _json_digest(sessions),
        }
        atomic_private_json(staging / "packet.json", packet)
        atomic_private_json(staging / "owner-mapping.json", mapping)
        atomic_private_json(staging / "session-provenance.json", sessions)
        atomic_private_json(staging / "manifest.json", manifest)
        publish_private_output(staging, output)
        return manifest
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def _load_corrections(
    evidence: dict,
    correction_root: Path,
    correction_output: Path,
    correction_receipt: Path,
) -> tuple[dict[str, dict], dict, dict]:
    root = validate_private_input(correction_root)
    packet_path = root / "packet.json"
    packet = _read_json(packet_path, "correction packet")
    mapping = _read_json(root / "owner-mapping.json", "correction owner mapping")
    manifest = _read_json(root / "manifest.json", "correction manifest")
    prior_sessions = _read_json(root / "session-provenance.json", "prior session provenance")
    exact_keys(packet, {"schema", "protocol", "rubricVersion", "packetID", "items"}, "correction packet")
    exact_keys(mapping, {"schema", "protocol", "rubricVersion", "items"}, "correction mapping")
    exact_keys(manifest, {
        "schema", "protocol", "rubricVersion", "mergeRequiredCount",
        "additionalCorrectionCount", "correctionCount",
        "candidateOutputsAvailable", "priorSessionProvenanceSHA256",
    }, "correction manifest")
    if packet["schema"] != "screen-understanding-single-frame-correction-packet-v4" \
            or mapping["schema"] != "screen-understanding-single-frame-correction-mapping-v4" \
            or manifest["schema"] != "screen-understanding-single-frame-correction-manifest-v4" \
            or any(value["protocol"] != PROTOCOL or value["rubricVersion"] != RUBRIC
                   for value in [packet, mapping, manifest]) \
            or manifest["candidateOutputsAvailable"] is not False \
            or manifest["priorSessionProvenanceSHA256"] != _json_digest(prior_sessions):
        raise ValueError("correction packet provenance is invalid or tampered")
    expected_prior = _session_provenance(evidence["receiptPairs"])
    if prior_sessions != expected_prior:
        raise ValueError("correction packet prior sessions were changed")
    output = _read_json(correction_output, "correction output")
    _reject_model_leaks(output, set(evidence["selections"]))
    exact_keys(output, {
        "schema", "protocol", "rubricVersion", "packetID", "producer", "mode",
        "annotator", "blindedToCandidateOutputs", "candidateOutputsAvailable", "items",
    }, "correction output")
    if output["schema"] != "screen-understanding-single-frame-corrections-v4" \
            or output["protocol"] != PROTOCOL or output["rubricVersion"] != RUBRIC \
            or output["packetID"] != packet["packetID"] \
            or output["producer"] != "frontier-vlm" or output["mode"] != "correction" \
            or output["blindedToCandidateOutputs"] is not True \
            or output["candidateOutputsAvailable"] is not False \
            or not isinstance(output["annotator"], str) \
            or not SAFE_ID.fullmatch(output["annotator"]):
        raise ValueError("correction output provenance is invalid")
    packet_ids = {item["opaqueID"] for item in packet["items"]}
    if not isinstance(mapping["items"], dict) or set(mapping["items"]) != packet_ids:
        raise ValueError("correction packet and owner mapping differ")
    expected_merge = {
        identifier for identifier, item in evidence["selections"].items()
        if item["selectedReference"] == "merge-required"
    }
    expected_corrections = {
        owner.get("case") for owner in mapping["items"].values()
    }
    additional = expected_corrections - expected_merge
    if not expected_merge.issubset(expected_corrections) \
            or not expected_corrections.issubset(evidence["selections"]) \
            or manifest["mergeRequiredCount"] != len(expected_merge) \
            or manifest["additionalCorrectionCount"] != len(additional) \
            or manifest["correctionCount"] != len(expected_corrections):
        raise ValueError("correction mapping differs from derived merge-required singles")
    corrections: dict[str, dict] = {}
    seen_opaque = set()
    if not isinstance(output["items"], list):
        raise ValueError("correction output items are invalid")
    for item in output["items"]:
        exact_keys(item, {"opaqueID", *REFERENCE_KEYS}, "correction item")
        opaque_id = item["opaqueID"]
        if opaque_id not in packet_ids or opaque_id in seen_opaque:
            raise ValueError("correction opaque identity is invalid or duplicated")
        seen_opaque.add(opaque_id)
        identifier = mapping["items"][opaque_id]["case"]
        reference = {key: item[key] for key in REFERENCE_KEYS}
        legacy_reference.validate_reference(reference, "single-frame")
        corrections[identifier] = reference
    if seen_opaque != packet_ids or set(corrections) != expected_corrections:
        raise ValueError("corrections must cover every requested single-frame correction")
    receipt = validate_receipt(
        correction_receipt, packet_path, correction_output, "reference-correction",
        allow_legacy=True,
    )
    return corrections, output, receipt


def prepare_audit(
    sources: V3EvidencePaths,
    correction_root: Path,
    correction_output: Path,
    correction_receipt: Path,
    output_root: Path,
    seed: str,
) -> dict:
    output = validate_private_output(output_root)
    if not seed:
        raise ValueError("final audit seed is required")
    evidence = _load_v3_evidence(sources)
    correction = validate_private_input(correction_root)
    _assert_disjoint(output, [
        sources.annotation_root, sources.correctness_audit_root,
        sources.aggregate_root, correction,
    ])
    corrections, correction_payload, correction_session = _load_corrections(
        evidence, correction, correction_output, correction_receipt
    )
    receipt_pairs = [*evidence["receiptPairs"], (correction_receipt, correction_session)]
    required_roles = {payload["role"] for _, payload in receipt_pairs}
    validate_independent_sessions(
        [payload for _, payload in receipt_pairs], required_roles
    )
    drafts = {
        identifier: _make_draft(
            identifier,
            _reference(label),
            label["annotation"]["annotator"],
            "pass1-base",
        )
        for identifier, label in evidence["pass1"].items()
        if label["targetType"] == "single-frame"
    }
    for identifier, selection in evidence["selections"].items():
        selected = selection["selectedReference"]
        if identifier in corrections:
            reference = corrections[identifier]
            annotator = correction_payload["annotator"]
            mode = "frontier-correction"
        else:
            source = evidence["pass1"][identifier] if selected == "pass1" \
                else evidence["pass2"][identifier]
            reference = _reference(source)
            annotator = source["annotation"]["annotator"]
            mode = f"selected-{selected}"
        drafts[identifier] = _make_draft(identifier, reference, annotator, mode)
    if len(drafts) != 200:
        raise ValueError("single-frame draft set must contain exactly 200 labels")
    merge_required_count = sum(
        item["selectedReference"] == "merge-required"
        for item in evidence["selections"].values()
    )
    sessions = _session_provenance(receipt_pairs)
    output, staging = prepare_private_output(output)
    try:
        make_private_directory(staging / "packet")
        make_private_directory(staging / "packet" / "images")
        packet_items = []
        owners = {}
        source_tokens = set(evidence["selections"])
        for identifier, selection in evidence["selections"].items():
            opaque_id = "single-final-" + _digest_text(
                f"{seed}:single-final:{identifier}"
            )[:24]
            source = _resolve_render(
                sources.annotation_root,
                evidence["duplicateWork"][identifier]["image"],
            )
            source_tokens.add(source.name)
            relative = f"images/{opaque_id}{source.suffix.lower()}"
            copy_private(source, staging / "packet" / relative)
            packet_items.append({
                "opaqueID": opaque_id,
                "targetType": "single-frame",
                "reference": _reference(drafts[identifier]),
                "images": [relative],
            })
            owners[opaque_id] = {"case": identifier}
        packet_items.sort(key=lambda item: _digest_text(f"{seed}:order:{item['opaqueID']}"))
        packet = {
            "schema": "screen-understanding-single-frame-final-packet-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "packetID": "single-final-" + _digest_text(f"{seed}:packet")[:24],
            "items": packet_items,
        }
        _reject_model_leaks(packet, source_tokens)
        draft_payload = {
            "schema": "screen-understanding-single-frame-draft-labels-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "candidateOutputsAvailableDuringAnnotation": False,
            "locked": False,
            "labels": [drafts[key] for key in sorted(drafts)],
        }
        mapping = {
            "schema": "screen-understanding-single-frame-final-mapping-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "items": owners,
        }
        manifest = {
            "schema": "screen-understanding-single-frame-final-manifest-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "caseCount": 30,
            "slotCount": 180,
            "draftLabelCount": 200,
            "mergeRequiredCount": merge_required_count,
            "additionalCorrectionCount": len(corrections) - merge_required_count,
            "correctionCount": len(corrections),
            "candidateOutputsAvailable": False,
            "rawJointSingleFrame": evidence["result"]["joint"]["singleFrame"],
            "ignoredTemporalJoint": evidence["result"]["joint"]["temporalPair"],
            "priorSessionProvenanceSHA256": _json_digest(sessions),
        }
        atomic_private_json(staging / "packet" / "packet.json", packet)
        atomic_private_json(staging / "owner-mapping.json", mapping)
        atomic_private_json(staging / "session-provenance.json", sessions)
        atomic_private_json(staging / "draft-labels.json", draft_payload)
        atomic_private_json(staging / "audit-manifest.json", manifest)
        publish_private_output(staging, output)
        return manifest
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def _validate_final_judgments(
    packet: dict,
    path: Path,
    forbidden_tokens: set[str],
) -> dict:
    output = _read_json(path, "final judgments")
    _reject_model_leaks(output, forbidden_tokens)
    exact_keys(output, {
        "schema", "protocol", "rubricVersion", "packetID", "auditor", "items",
    }, "final judgments")
    if output["schema"] != "screen-understanding-single-frame-final-judgments-v4" \
            or output["protocol"] != PROTOCOL or output["rubricVersion"] != RUBRIC \
            or output["packetID"] != packet["packetID"] \
            or not isinstance(output["auditor"], str) \
            or not SAFE_ID.fullmatch(output["auditor"]) \
            or not isinstance(output["items"], list):
        raise ValueError("final judgment provenance is invalid")
    packet_ids = {item["opaqueID"] for item in packet["items"]}
    seen = set()
    slot_errors = 0
    material_false = 0
    ambiguity_errors = 0
    for item in output["items"]:
        exact_keys(item, {"opaqueID", "slots", "ambiguityDecision"}, "final judgment")
        opaque_id = item["opaqueID"]
        if opaque_id not in packet_ids or opaque_id in seen:
            raise ValueError("final judgment opaque identity is invalid or duplicated")
        seen.add(opaque_id)
        if not isinstance(item["slots"], dict) \
                or set(item["slots"]) != set(SINGLE_SLOT_ORDER):
            raise ValueError("final judgments must cover the exact six single-frame slots")
        for slot in item["slots"].values():
            exact_keys(slot, {"correct", "materialFalse"}, "final slot judgment")
            if not isinstance(slot["correct"], bool) \
                    or not isinstance(slot["materialFalse"], bool):
                raise ValueError("final slot judgment must be boolean")
            material_false += int(slot["materialFalse"])
            slot_errors += int(not slot["correct"] or slot["materialFalse"])
        if not isinstance(item["ambiguityDecision"], bool):
            raise ValueError("final ambiguity judgment must be boolean")
        ambiguity_errors += int(not item["ambiguityDecision"])
    if seen != packet_ids or len(seen) != 30:
        raise ValueError("final judgments must cover exactly 30 single references")
    return {
        "auditor": output["auditor"],
        "slotCount": len(seen) * len(SINGLE_SLOT_ORDER),
        "slotErrorCount": slot_errors,
        "materialFalseCount": material_false,
        "ambiguityErrorCount": ambiguity_errors,
        "criticalErrorCount": slot_errors + ambiguity_errors,
    }


def _load_final_audit(
    root: Path,
    evidence: dict,
    corrections: dict,
    correction_annotator: str,
) -> tuple[dict, dict, dict, dict]:
    manifest = _read_json(root / "audit-manifest.json", "final audit manifest")
    packet = _read_json(root / "packet" / "packet.json", "final audit packet")
    mapping = _read_json(root / "owner-mapping.json", "final audit mapping")
    sessions = _read_json(root / "session-provenance.json", "session provenance")
    drafts_payload = _read_json(root / "draft-labels.json", "draft labels")
    exact_keys(manifest, {
        "schema", "protocol", "rubricVersion", "caseCount", "slotCount",
        "draftLabelCount", "mergeRequiredCount", "additionalCorrectionCount",
        "correctionCount", "candidateOutputsAvailable",
        "rawJointSingleFrame", "ignoredTemporalJoint", "priorSessionProvenanceSHA256",
    }, "final audit manifest")
    exact_keys(packet, {"schema", "protocol", "rubricVersion", "packetID", "items"}, "final packet")
    exact_keys(mapping, {"schema", "protocol", "rubricVersion", "items"}, "final mapping")
    exact_keys(drafts_payload, {
        "schema", "protocol", "rubricVersion",
        "candidateOutputsAvailableDuringAnnotation", "locked", "labels",
    }, "draft labels")
    if manifest["schema"] != "screen-understanding-single-frame-final-manifest-v4" \
            or packet["schema"] != "screen-understanding-single-frame-final-packet-v4" \
            or mapping["schema"] != "screen-understanding-single-frame-final-mapping-v4" \
            or drafts_payload["schema"] != "screen-understanding-single-frame-draft-labels-v4" \
            or any(value["protocol"] != PROTOCOL or value["rubricVersion"] != RUBRIC
                   for value in [manifest, packet, mapping, drafts_payload]) \
            or (manifest["caseCount"], manifest["slotCount"], manifest["draftLabelCount"]) \
            != (30, 180, 200) \
            or manifest["candidateOutputsAvailable"] is not False \
            or drafts_payload["candidateOutputsAvailableDuringAnnotation"] is not False \
            or drafts_payload["locked"] is not False \
            or manifest["priorSessionProvenanceSHA256"] != _json_digest(sessions):
        raise ValueError("final audit provenance is invalid or tampered")
    merge_required_count = sum(
        item["selectedReference"] == "merge-required"
        for item in evidence["selections"].values()
    )
    if manifest["rawJointSingleFrame"] != evidence["result"]["joint"]["singleFrame"] \
            or manifest["ignoredTemporalJoint"] != evidence["result"]["joint"]["temporalPair"] \
            or manifest["mergeRequiredCount"] != merge_required_count \
            or manifest["additionalCorrectionCount"] \
            != len(corrections) - manifest["mergeRequiredCount"] \
            or manifest["correctionCount"] != len(corrections):
        raise ValueError("final audit reliability inputs were changed")
    packet_items = {item.get("opaqueID"): item for item in packet["items"] if isinstance(item, dict)}
    if len(packet_items) != 30 or not isinstance(mapping["items"], dict) \
            or set(packet_items) != set(mapping["items"]):
        raise ValueError("final packet and owner mapping must cover exactly 30 references")
    drafts: dict[str, dict] = {}
    if not isinstance(drafts_payload["labels"], list):
        raise ValueError("draft labels are invalid")
    for label in drafts_payload["labels"]:
        exact_keys(label, {"case", *REFERENCE_KEYS, "locked", "annotation"}, "draft label")
        identifier = label["case"]
        if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier) \
                or identifier in drafts or label["locked"] is not False \
                or label["targetType"] != "single-frame":
            raise ValueError("draft label identity is invalid")
        legacy_reference.validate_reference(_reference(label), "single-frame")
        drafts[identifier] = label
    if len(drafts) != 200:
        raise ValueError("draft labels must contain exactly 200 singles")
    if set(owner.get("case") for owner in mapping["items"].values()) \
            != set(evidence["selections"]):
        raise ValueError("final owner mapping differs from the 30 single duplicates")
    for opaque_id, item in packet_items.items():
        owner = mapping["items"][opaque_id]
        exact_keys(owner, {"case"}, "final owner")
        identifier = owner["case"]
        exact_keys(item, {"opaqueID", "targetType", "reference", "images"}, "final packet item")
        if item["targetType"] != "single-frame" \
                or item["reference"] != _reference(drafts[identifier]) \
                or not isinstance(item["images"], list) or len(item["images"]) != 1:
            raise ValueError("final packet reference differs from its owner draft")
        image = validate_private_input_file(root / "packet" / item["images"][0])
        if root / "packet" not in image.parents:
            raise ValueError("final packet image escapes its private root")
    for identifier, draft in drafts.items():
        selection = evidence["selections"].get(identifier)
        if selection is None:
            source = evidence["pass1"][identifier]
            expected_reference = _reference(source)
            expected_mode = "pass1-base"
            expected_annotator = source["annotation"]["annotator"]
        elif identifier in corrections:
            expected_reference = corrections[identifier]
            expected_mode = "frontier-correction"
            expected_annotator = correction_annotator
        else:
            selected = selection["selectedReference"]
            source = evidence["pass1"][identifier] if selected == "pass1" \
                else evidence["pass2"][identifier]
            expected_reference = _reference(source)
            expected_mode = f"selected-{selected}"
            expected_annotator = source["annotation"]["annotator"]
        annotation = draft["annotation"]
        exact_keys(annotation, {
            "producer", "mode", "annotator", "rubricVersion",
            "blindedToCandidateOutputs", "candidateOutputsAvailable",
        }, "draft annotation")
        if _reference(draft) != expected_reference or annotation != {
            "producer": "frontier-vlm",
            "mode": expected_mode,
            "annotator": expected_annotator,
            "rubricVersion": RUBRIC,
            "blindedToCandidateOutputs": True,
            "candidateOutputsAvailable": False,
        }:
            raise ValueError("draft reference or provenance differs from its selected source")
    return manifest, packet, sessions, drafts


def _verify_receipt_manifest(session_manifest: dict, receipt_pairs: list[tuple[Path, dict]]) -> None:
    expected = _session_provenance(receipt_pairs)
    if session_manifest != expected:
        raise ValueError("stored evaluator session provenance was changed")


def _acquire_lock(path: Path) -> int:
    try:
        return os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except FileExistsError as error:
        raise ValueError("single-frame canonical seal is already in progress") from error


def seal(
    sources: V3EvidencePaths,
    correction_root: Path,
    correction_output: Path,
    correction_receipt: Path,
    final_audit_root: Path,
    judgments_path: Path,
    final_receipt_path: Path,
) -> dict:
    evidence = _load_v3_evidence(sources)
    correction = validate_private_input(correction_root)
    audit = validate_private_input(final_audit_root)
    corrections, correction_payload, correction_session = _load_corrections(
        evidence, correction, correction_output, correction_receipt
    )
    manifest, packet, stored_sessions, drafts = _load_final_audit(
        audit, evidence, corrections, correction_payload["annotator"]
    )
    prior_pairs = [*evidence["receiptPairs"], (correction_receipt, correction_session)]
    _verify_receipt_manifest(stored_sessions, prior_pairs)
    judgments = validate_private_input_file(judgments_path)
    final_receipt = validate_receipt(
        final_receipt_path,
        audit / "packet" / "packet.json",
        judgments,
        "final-reference-auditor",
        allow_legacy=True,
    )
    all_pairs = [*prior_pairs, (final_receipt_path, final_receipt)]
    validate_independent_sessions(
        [payload for _, payload in all_pairs],
        {payload["role"] for _, payload in all_pairs},
    )
    final = _validate_final_judgments(
        packet, judgments, set(evidence["selections"])
    )
    if final["materialFalseCount"] != 0 or final["ambiguityErrorCount"] != 0 \
            or final["criticalErrorCount"] != 0:
        raise ValueError("single-frame canonical seal requires a zero-error final audit")
    canonical = validate_private_output(audit / "canonical")
    labels_payload = {
        "schema": "screen-understanding-single-frame-labels-v4",
        "protocol": PROTOCOL,
        "rubricVersion": RUBRIC,
        "candidateOutputsAvailableDuringAnnotation": False,
        "labels": [{**drafts[key], "locked": True} for key in sorted(drafts)],
    }
    reliability = {
        "schema": "screen-understanding-single-frame-reliability-v4",
        "protocol": PROTOCOL,
        "rubricVersion": RUBRIC,
        "duplicateCount": 30,
        "rawJointMinimum": RAW_JOINT_FLOOR,
        "rawJointSingleFrame": manifest["rawJointSingleFrame"],
        "finalReferenceAudit": {
            "caseCount": 30,
            "slotCount": 180,
            "slotErrorCount": 0,
            "materialFalseCount": 0,
            "ambiguityErrorCount": 0,
            "qualified": True,
        },
        "qualified": True,
    }
    # Use the shared excluded lock name so final_audit_evidence remains stable
    # after the lock is removed.
    lock_path = audit / ".canonical-seal.lock"
    lock = _acquire_lock(lock_path)
    staging = None
    try:
        canonical, staging = prepare_private_output(canonical)
        atomic_private_json(staging / "labels.json", labels_payload)
        atomic_private_json(staging / "reliability.json", reliability)
        commit = {
            "schema": "screen-understanding-single-frame-commit-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "hashAlgorithm": HASH_ALGORITHM,
            "candidateOutputsAvailableDuringAnnotation": False,
            "canonical": {
                "labelsSHA256": file_evidence(staging / "labels.json")["sha256"],
                "reliabilitySHA256": file_evidence(staging / "reliability.json")["sha256"],
            },
            "producer": {"finalizerSHA256": file_evidence(Path(__file__))["sha256"]},
            "evidence": {
                "sourceAnnotationRoot": tree_evidence(sources.annotation_root),
                "correctnessAuditRoot": tree_evidence(sources.correctness_audit_root),
                "aggregateRoot": tree_evidence(sources.aggregate_root),
                "correctionRoot": tree_evidence(correction),
                "correctionOutput": file_evidence(correction_output),
                "finalAudit": final_audit_evidence(audit),
                "finalJudgments": file_evidence(judgments),
                "finalReceipt": file_evidence(final_receipt_path),
            },
            "counts": {
                "labelCount": 200,
                "duplicateCount": 30,
                "finalAuditCaseCount": 30,
                "finalAuditSlotCount": 180,
            },
        }
        atomic_private_json(staging / "commit.json", commit)
        publish_private_output(staging, canonical)
    except BaseException:
        if staging is not None:
            shutil.rmtree(staging, ignore_errors=True)
        raise
    finally:
        os.close(lock)
        lock_path.unlink(missing_ok=True)
    return {
        "labelCount": 200,
        "duplicateCount": 30,
        "slotCount": 180,
        "materialFalseCount": 0,
        "ambiguityErrorCount": 0,
        "rawJointSingleFrame": manifest["rawJointSingleFrame"],
        "qualified": True,
    }


def _add_sources(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--annotation-root", required=True, type=Path)
    parser.add_argument("--correctness-audit-root", required=True, type=Path)
    parser.add_argument("--aggregate-root", required=True, type=Path)
    parser.add_argument("--auditor-one-output", required=True, type=Path)
    parser.add_argument("--auditor-one-receipt", required=True, type=Path)
    parser.add_argument("--auditor-two-output", required=True, type=Path)
    parser.add_argument("--auditor-two-receipt", required=True, type=Path)
    parser.add_argument("--tiebreak-output", type=Path)
    parser.add_argument("--tiebreak-receipt", type=Path)


def _sources(args: argparse.Namespace) -> V3EvidencePaths:
    return V3EvidencePaths(
        args.annotation_root,
        args.correctness_audit_root,
        args.aggregate_root,
        args.auditor_one_output,
        args.auditor_one_receipt,
        args.auditor_two_output,
        args.auditor_two_receipt,
        args.tiebreak_output,
        args.tiebreak_receipt,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    correction = commands.add_parser("prepare-correction")
    _add_sources(correction)
    correction.add_argument("--output-root", required=True, type=Path)
    correction.add_argument("--seed", default="single-frame-correction-v4")
    correction.add_argument("--additional-case", action="append", default=[])
    audit = commands.add_parser("prepare-audit")
    _add_sources(audit)
    audit.add_argument("--correction-root", required=True, type=Path)
    audit.add_argument("--correction-output", required=True, type=Path)
    audit.add_argument("--correction-receipt", required=True, type=Path)
    audit.add_argument("--output-root", required=True, type=Path)
    audit.add_argument("--seed", default="single-frame-final-audit-v4")
    final = commands.add_parser("seal")
    _add_sources(final)
    final.add_argument("--correction-root", required=True, type=Path)
    final.add_argument("--correction-output", required=True, type=Path)
    final.add_argument("--correction-receipt", required=True, type=Path)
    final.add_argument("--final-audit-root", required=True, type=Path)
    final.add_argument("--judgments", required=True, type=Path)
    final.add_argument("--final-receipt", required=True, type=Path)
    args = parser.parse_args()
    source_paths = _sources(args)
    if args.command == "prepare-correction":
        result = prepare_correction(
            source_paths, args.output_root, args.seed, set(args.additional_case)
        )
    elif args.command == "prepare-audit":
        result = prepare_audit(
            source_paths,
            args.correction_root,
            args.correction_output,
            args.correction_receipt,
            args.output_root,
            args.seed,
        )
    else:
        result = seal(
            source_paths,
            args.correction_root,
            args.correction_output,
            args.correction_receipt,
            args.final_audit_root,
            args.judgments,
            args.final_receipt,
        )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
