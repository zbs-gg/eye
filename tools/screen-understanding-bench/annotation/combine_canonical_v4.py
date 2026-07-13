#!/usr/bin/python3
"""Combine independently audited single-image and temporal references."""

from __future__ import annotations

import argparse
import copy
import json
import shutil
import sys
from pathlib import Path
from typing import Any

BENCHMARK_DIRECTORY = Path(__file__).resolve().parents[1]
if str(BENCHMARK_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(BENCHMARK_DIRECTORY))

from common.contracts import exact_keys
from common.evaluator_receipt import validate_receipt
from common.private_io import (
    atomic_private_json,
    load_private_json,
    make_private_directory,
    prepare_private_output,
    prepare_private_temporary,
    publish_private_output,
    snapshot_private_file,
    snapshot_private_tree,
    validate_private_input,
    validate_private_input_file,
    validate_private_output,
)
from common.provenance import (
    HASH_ALGORITHM,
    build_canonical_commit,
    file_evidence,
    final_audit_evidence,
    tree_evidence,
)


PROTOCOL = "screen-understanding-correctness-audit-v3"
RUBRIC = "screen-understanding-canonical-v2"
SINGLE_PROTOCOL = "screen-understanding-single-frame-lane-v4"
TEMPORAL_PROTOCOL = "screen-understanding-temporal-annotation-v4"
TEMPORAL_RUBRIC = "screen-understanding-temporal-v4"
FINALIZER = Path(__file__)


def _load(path: Path, subject: str) -> dict[str, Any]:
    try:
        value, _ = load_private_json(path, subject)
    except ValueError as error:
        raise ValueError(f"{subject} is not valid JSON") from error
    return value


def _corpus_ids(corpus: Path) -> tuple[set[str], set[str]]:
    manifest = _load(corpus / "manifest.json", "corpus manifest")
    singles = manifest.get("singleFrameCaseIDs")
    pairs = manifest.get("temporalPairs")
    if not isinstance(singles, list) or len(singles) != 200 \
            or len(set(singles)) != 200 or not all(isinstance(value, str) for value in singles):
        raise ValueError("corpus does not contain the locked 200 single images")
    if not isinstance(pairs, list) or len(pairs) != 100:
        raise ValueError("corpus does not contain the locked 100 temporal pairs")
    pair_ids = [item.get("id") if isinstance(item, dict) else None for item in pairs]
    if len(set(pair_ids)) != 100 or not all(isinstance(value, str) for value in pair_ids):
        raise ValueError("corpus temporal pair identifiers are invalid")
    return set(singles), set(pair_ids)


def _label_ids(
    payload: dict[str, Any],
    *,
    identity_key: str,
    target: str,
    expected: set[str],
    subject: str,
) -> list[dict[str, Any]]:
    labels = payload.get("labels")
    if not isinstance(labels, list) or len(labels) != len(expected):
        raise ValueError(f"{subject} count is invalid")
    identifiers = []
    for label in labels:
        if not isinstance(label, dict):
            raise ValueError(f"{subject} label is invalid")
        identifier = label.get(identity_key)
        annotation = label.get("annotation")
        if not isinstance(identifier, str) or label.get("targetType") != target \
                or label.get("locked") is not True \
                or not isinstance(annotation, dict) \
                or annotation.get("producer") != "frontier-vlm" \
                or annotation.get("blindedToCandidateOutputs") is not True \
                or annotation.get("candidateOutputsAvailable") is not False:
            raise ValueError(f"{subject} label provenance is invalid")
        identifiers.append(identifier)
    if len(set(identifiers)) != len(identifiers) or set(identifiers) != expected:
        raise ValueError(f"{subject} identifiers do not match the corpus")
    return labels


def _single_source(single: Path, expected: set[str]) -> tuple[list[dict], dict]:
    canonical = single / "canonical"
    labels = _load(canonical / "labels.json", "single-image labels")
    reliability = _load(canonical / "reliability.json", "single-image reliability")
    commit = _load(canonical / "commit.json", "single-image commit")
    if labels.get("schema") != "screen-understanding-single-frame-labels-v4" \
            or labels.get("protocol") != SINGLE_PROTOCOL \
            or labels.get("rubricVersion") != RUBRIC \
            or labels.get("candidateOutputsAvailableDuringAnnotation") is not False:
        raise ValueError("single-image labels metadata is invalid")
    values = _label_ids(
        labels,
        identity_key="case",
        target="single-frame",
        expected=expected,
        subject="single-image labels",
    )
    audit = reliability.get("finalReferenceAudit")
    rate = reliability.get("rawJointSingleFrame")
    if reliability.get("schema") != "screen-understanding-single-frame-reliability-v4" \
            or reliability.get("protocol") != SINGLE_PROTOCOL \
            or reliability.get("rubricVersion") != RUBRIC \
            or reliability.get("qualified") is not True \
            or reliability.get("duplicateCount") != 30 \
            or not isinstance(rate, (int, float)) or isinstance(rate, bool) \
            or rate < 0.90 or not isinstance(audit, dict) \
            or audit.get("caseCount") != 30 or audit.get("slotCount") != 180 \
            or audit.get("materialFalseCount") != 0 \
            or audit.get("ambiguityErrorCount") != 0 \
            or audit.get("slotErrorCount") != 0 or audit.get("qualified") is not True:
        raise ValueError("single-image reliability is not qualified")
    exact_keys(commit, {
        "schema", "protocol", "rubricVersion", "hashAlgorithm",
        "candidateOutputsAvailableDuringAnnotation", "canonical", "producer",
        "evidence", "counts",
    }, "single-image commit")
    canonical_commit = commit["canonical"]
    exact_keys(
        canonical_commit, {"labelsSHA256", "reliabilitySHA256"},
        "single-image canonical commit",
    )
    exact_keys(commit["producer"], {"finalizerSHA256"}, "single-image producer")
    if commit["schema"] != "screen-understanding-single-frame-commit-v4" \
            or commit["protocol"] != SINGLE_PROTOCOL \
            or commit["rubricVersion"] != RUBRIC \
            or commit["hashAlgorithm"] != HASH_ALGORITHM \
            or commit["candidateOutputsAvailableDuringAnnotation"] is not False \
            or canonical_commit["labelsSHA256"] \
                != file_evidence(canonical / "labels.json")["sha256"] \
            or canonical_commit["reliabilitySHA256"] \
                != file_evidence(canonical / "reliability.json")["sha256"] \
            or commit["producer"]["finalizerSHA256"] \
                != file_evidence(Path(__file__).with_name("single_frame_lane_v4.py"))["sha256"] \
            or commit["evidence"].get("finalAudit") \
                != final_audit_evidence(single) \
            or commit["counts"] != {
                "labelCount": 200,
                "duplicateCount": 30,
                "finalAuditCaseCount": 30,
                "finalAuditSlotCount": 180,
            }:
        raise ValueError("single-image commit does not bind its canonical files")
    return values, reliability


def _temporal_source(
    temporal: Path,
    temporal_audit: Path,
    expected: set[str],
) -> tuple[list[dict], dict]:
    labels = _load(temporal / "labels.json", "temporal labels")
    reliability = _load(temporal / "reliability.json", "temporal reliability")
    result = _load(temporal / "result.json", "temporal final result")
    commit = _load(temporal / "commit.json", "temporal commit")
    if labels.get("schema") != "screen-understanding-temporal-final-labels-v4" \
            or labels.get("protocol") != TEMPORAL_PROTOCOL \
            or labels.get("rubricVersion") != TEMPORAL_RUBRIC \
            or labels.get("candidateOutputsAvailable") is not False:
        raise ValueError("temporal labels metadata is invalid")
    values = _label_ids(
        labels,
        identity_key="pair",
        target="temporal-pair",
        expected=expected,
        subject="temporal labels",
    )
    raw = reliability.get("rawJoint")
    audit = reliability.get("finalAudit")
    if reliability.get("schema") != "screen-understanding-temporal-reliability-v4" \
            or reliability.get("protocol") != TEMPORAL_PROTOCOL \
            or reliability.get("rubricVersion") != TEMPORAL_RUBRIC \
            or reliability.get("candidateOutputsAvailable") is not False \
            or reliability.get("qualified") is not True \
            or not isinstance(raw, dict) or raw.get("minimum") != 0.90 \
            or raw.get("opportunityCount") != 75 \
            or not isinstance(raw.get("correctCount"), int) \
            or raw["correctCount"] < 68 or raw.get("qualified") is not True \
            or not isinstance(raw.get("rate"), (int, float)) \
            or abs(raw["rate"] - raw["correctCount"] / 75) > 1e-12 \
            or not isinstance(audit, dict) or audit.get("pairCount") != 15 \
            or audit.get("opportunityCount") != 75 \
            or audit.get("materialFalseCount") != 0 or audit.get("incorrectCount") != 0 \
            or audit.get("qualified") is not True \
            or result.get("qualified") is not True or result.get("pairCount") != 100:
        raise ValueError("temporal reliability is not qualified")
    exact_keys(commit, {
        "schema", "protocol", "rubricVersion", "hashAlgorithm",
        "candidateOutputsAvailable", "canonical", "producer", "evidence",
        "counts",
    }, "temporal commit")
    exact_keys(commit["canonical"], {
        "labelsSHA256", "reliabilitySHA256", "resultSHA256",
    }, "temporal canonical commit")
    exact_keys(commit["producer"], {"finalizerSHA256"}, "temporal producer")
    exact_keys(commit["evidence"], {
        "finalAuditRoot", "finalOutput", "finalReceipt",
    }, "temporal evidence")
    evidence = temporal / "evidence"
    output_path = evidence / "final-output.json"
    receipt_path = evidence / "final-receipt.json"
    if commit["schema"] != "screen-understanding-temporal-commit-v4" \
            or commit["protocol"] != TEMPORAL_PROTOCOL \
            or commit["rubricVersion"] != TEMPORAL_RUBRIC \
            or commit["hashAlgorithm"] != HASH_ALGORITHM \
            or commit["candidateOutputsAvailable"] is not False \
            or commit["canonical"] != {
                "labelsSHA256": file_evidence(temporal / "labels.json")["sha256"],
                "reliabilitySHA256": file_evidence(
                    temporal / "reliability.json"
                )["sha256"],
                "resultSHA256": file_evidence(temporal / "result.json")["sha256"],
            } \
            or commit["producer"]["finalizerSHA256"] \
                != file_evidence(Path(__file__).parent / "temporal_v4" / "pipeline.py")["sha256"] \
            or commit["evidence"] != {
                "finalAuditRoot": tree_evidence(temporal_audit),
                "finalOutput": file_evidence(output_path),
                "finalReceipt": file_evidence(receipt_path),
            } \
            or commit["counts"] != {
                "labelCount": 100,
                "duplicateCount": 15,
                "finalAuditCaseCount": 15,
                "finalAuditSlotCount": 75,
            }:
        raise ValueError("temporal commit does not bind its evidence")
    validate_receipt(
        receipt_path,
        temporal_audit / "packet" / "packet.json",
        output_path,
        "final-reference-auditor",
        allow_legacy=True,
    )
    return values, reliability


def _canonical_temporal(label: dict[str, Any]) -> dict[str, Any]:
    value = copy.deepcopy(label)
    value["case"] = value.pop("pair")
    severities = {
        "forbidden.intent": "critical",
        "forbidden.outcome": "major",
    }
    for fact in value["forbiddenInferences"]:
        fact["severity"] = severities[fact["id"]]
    return value


def combine(
    corpus_root: Path,
    single_root: Path,
    temporal_root: Path,
    temporal_audit_root: Path,
    output_root: Path,
) -> dict[str, Any]:
    """Publish one canonical root from stable, bounded snapshots of every input."""

    output = validate_private_output(output_root)
    corpus = validate_private_input(corpus_root)
    single = validate_private_input(single_root)
    temporal = validate_private_input(temporal_root)
    temporal_audit = validate_private_input(temporal_audit_root)
    roots = (corpus, single, temporal, temporal_audit)
    if any(output == root or output in root.parents or root in output.parents for root in roots):
        raise ValueError("combined canonical root must be disjoint from every private input")
    snapshot_root = prepare_private_temporary(
        output.parent,
        "combined-canonical-inputs",
    )
    try:
        corpus_snapshot = snapshot_root / "corpus"
        make_private_directory(corpus_snapshot)
        snapshot_private_file(
            corpus / "manifest.json",
            corpus_snapshot / "manifest.json",
            "combined corpus manifest",
        )
        single_snapshot = snapshot_private_tree(
            single,
            snapshot_root / "single",
            "single-image canonical source",
        )
        temporal_snapshot = snapshot_private_tree(
            temporal,
            snapshot_root / "temporal",
            "temporal canonical source",
        )
        temporal_audit_snapshot = snapshot_private_tree(
            temporal_audit,
            snapshot_root / "temporal-audit",
            "temporal final audit source",
        )
        return _combine_snapshots(
            corpus_snapshot,
            single_snapshot,
            temporal_snapshot,
            temporal_audit_snapshot,
            output,
        )
    finally:
        shutil.rmtree(snapshot_root, ignore_errors=True)


def _combine_snapshots(
    corpus_root: Path,
    single_root: Path,
    temporal_root: Path,
    temporal_audit_root: Path,
    output_root: Path,
) -> dict[str, Any]:
    """Validate and publish using immutable private snapshots only."""

    output = validate_private_output(output_root)
    corpus = validate_private_input(corpus_root)
    single = validate_private_input(single_root)
    temporal = validate_private_input(temporal_root)
    temporal_audit = validate_private_input(temporal_audit_root)
    single_ids, pair_ids = _corpus_ids(corpus)
    single_labels, single_reliability = _single_source(single, single_ids)
    temporal_labels, temporal_reliability = _temporal_source(
        temporal, temporal_audit, pair_ids
    )
    single_correct = round(single_reliability["rawJointSingleFrame"] * 180)
    temporal_correct = temporal_reliability["rawJoint"]["correctCount"]
    overall_rate = (single_correct + temporal_correct) / 255
    if overall_rate < 0.90:
        raise ValueError("combined raw-joint reliability does not clear 0.90")

    output, staging = prepare_private_output(output)
    try:
        make_private_directory(staging / "canonical")
        make_private_directory(staging / "aggregate-evidence")
        atomic_private_json(staging / "aggregate-evidence" / ".metadata_never_index", {})
        labels_path = staging / "canonical" / "labels.json"
        reliability_path = staging / "canonical" / "reliability.json"
        final_judgments_path = staging / "final-judgments.json"
        combined_labels = [
            *copy.deepcopy(single_labels),
            *[_canonical_temporal(label) for label in temporal_labels],
        ]
        combined_labels.sort(key=lambda label: label["case"])
        labels_document = {
            "schema": "screen-understanding-canonical-labels-v3",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "candidateOutputsAvailableDuringAnnotation": False,
            "labels": combined_labels,
        }
        temporal_auditor = temporal_reliability["finalAudit"]["auditor"]
        reliability_document = {
            "schema": "screen-understanding-canonical-reliability-v3",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "duplicateCount": 45,
            "rawJoint": {
                "minimum": 0.90,
                "overall": overall_rate,
                "singleFrame": single_reliability["rawJointSingleFrame"],
                "temporalPair": temporal_reliability["rawJoint"]["rate"],
            },
            "finalReferenceAudit": {
                "auditor": f"single-panel+{temporal_auditor}",
                "caseCount": 45,
                "slotCount": 255,
                "materialFalseCount": 0,
                "ambiguityErrorCount": 0,
                "criticalErrorCount": 0,
                "requiredCriticalErrorCount": 0,
                "qualified": True,
            },
            "qualified": True,
        }
        atomic_private_json(labels_path, labels_document)
        atomic_private_json(reliability_path, reliability_document)
        atomic_private_json(staging / "aggregate-evidence" / "manifest.json", {
            "schema": "screen-understanding-combined-source-evidence-v4",
            "protocol": PROTOCOL,
            "candidateOutputsAvailable": False,
            "single": {
                "labels": file_evidence(single / "canonical" / "labels.json"),
                "reliability": file_evidence(single / "canonical" / "reliability.json"),
                "commit": file_evidence(single / "canonical" / "commit.json"),
            },
            "temporal": {
                "labels": file_evidence(temporal / "labels.json"),
                "reliability": file_evidence(temporal / "reliability.json"),
                "result": file_evidence(temporal / "result.json"),
                "commit": file_evidence(temporal / "commit.json"),
            },
        })
        atomic_private_json(final_judgments_path, {
            "schema": "screen-understanding-combined-final-judgments-v4",
            "protocol": PROTOCOL,
            "single": single_reliability["finalReferenceAudit"],
            "temporal": temporal_reliability["finalAudit"],
            "candidateOutputsAvailable": False,
            "qualified": True,
        })
        atomic_private_json(staging / "seal-manifest.json", {
            "schema": "screen-understanding-combined-seal-v4",
            "protocol": PROTOCOL,
            "labelCount": 300,
            "singleFrameCount": 200,
            "temporalPairCount": 100,
            "duplicateCount": 45,
            "finalAuditSlotCount": 255,
            "candidateOutputsAvailable": False,
            "qualified": True,
        })
        commit = build_canonical_commit(
            labels_path=labels_path,
            reliability_path=reliability_path,
            finalizer_path=FINALIZER,
            source_annotation_root=single,
            correctness_audit_root=temporal_audit,
            aggregate_root=staging / "aggregate-evidence",
            final_audit_root=staging,
            final_judgments_path=final_judgments_path,
            protocol=PROTOCOL,
            rubric_version=RUBRIC,
            label_count=300,
            duplicate_count=45,
            final_audit_case_count=45,
            final_audit_slot_count=255,
        )
        # Commit is deliberately written last: it binds every published evidence file.
        atomic_private_json(staging / "canonical" / "commit.json", commit)
        publish_private_output(staging, output)
        return {
            "schema": "screen-understanding-combined-result-v4",
            "labelCount": 300,
            "singleFrameCount": 200,
            "temporalPairCount": 100,
            "finalAuditSlotCount": 255,
            "rawJointOverall": overall_rate,
            "qualified": True,
        }
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Seal independent single-image and temporal references for the runner."
    )
    parser.add_argument("--corpus-root", required=True, type=Path)
    parser.add_argument("--single-root", required=True, type=Path)
    parser.add_argument("--temporal-root", required=True, type=Path)
    parser.add_argument("--temporal-audit-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(combine(
        args.corpus_root,
        args.single_root,
        args.temporal_root,
        args.temporal_audit_root,
        args.output_root,
    ), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
