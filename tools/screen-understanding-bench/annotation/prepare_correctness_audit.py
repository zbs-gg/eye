#!/usr/bin/python3
"""Prepare two independently blinded correctness-audit packets."""

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

from common.contracts import exact_keys
from common.private_io import (
    atomic_private_json,
    copy_private,
    make_private_directory,
    prepare_private_output,
    publish_private_output,
    validate_private_input,
    validate_private_output,
)


PROTOCOL = "screen-understanding-correctness-audit-v3"
RUBRIC = "screen-understanding-canonical-v2"
CASE_ID = re.compile(r"^[0-9a-f]{24}$")
REFERENCE_KEYS = {
    "targetType", "requiredFacts", "criticalText", "forbiddenInferences",
    "meaningfulChange", "ambiguity", "abstentionAllowed",
}


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def reference_from_label(label: dict, target_type: str) -> dict:
    if label.get("targetType") != target_type:
        raise ValueError("label target type mismatch")
    if label.get("locked") is not False:
        raise ValueError("correctness audit requires unsealed draft labels")
    reference = {key: label.get(key) for key in REFERENCE_KEYS}
    exact_keys(reference, REFERENCE_KEYS, "reference")
    required = reference["requiredFacts"]
    forbidden = reference["forbiddenInferences"]
    if not isinstance(required, list) or any(not isinstance(fact, dict) for fact in required) \
            or [fact.get("id") for fact in required] != [
        "required.surface", "required.content", "required.state",
    ]:
        raise ValueError("v2 required fact slots are invalid")
    if not isinstance(forbidden, list) or any(not isinstance(fact, dict) for fact in forbidden) \
            or [fact.get("id") for fact in forbidden] != [
        "forbidden.intent", "forbidden.outcome",
    ]:
        raise ValueError("v2 forbidden fact slots are invalid")
    if not isinstance(reference["criticalText"], list) \
            or len(reference["criticalText"]) > 2:
        raise ValueError("v2 critical text is invalid")
    change = reference["meaningfulChange"]
    if target_type == "single-frame" and change is not None:
        raise ValueError("single-frame reference contains temporal change")
    if target_type == "temporal-pair" \
            and (not isinstance(change, list) or len(change) > 3):
        raise ValueError("temporal reference change is invalid")
    return reference


def load_labels(root: Path, pass_number: int) -> dict[str, dict]:
    labels: dict[str, dict] = {}
    paths = sorted((root / "labels" / f"pass{pass_number}").glob("*.json"))
    if not paths:
        raise ValueError(f"pass {pass_number} labels are missing")
    for path in paths:
        batch = json.loads(path.read_text(encoding="utf-8"))
        if batch.get("rubricVersion") != RUBRIC:
            raise ValueError("annotation rubric mismatch")
        if batch.get("pass") != pass_number:
            raise ValueError("annotation pass mismatch")
        for label in batch.get("labels", []):
            identifier = label.get("case") if isinstance(label, dict) else None
            if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier):
                raise ValueError("label case identifier is invalid")
            if identifier in labels:
                raise ValueError("label case identifier is duplicated")
            if label.get("pass") != pass_number:
                raise ValueError("label pass mismatch")
            annotation = label.get("annotation", {})
            if annotation.get("producer") != "frontier-vlm" \
                    or annotation.get("rubricVersion") != RUBRIC \
                    or annotation.get("blindedToCandidateOutputs") is not True \
                    or annotation.get("candidateOutputsAvailable") is not False:
                raise ValueError("label annotation provenance is invalid")
            labels[identifier] = label
    return labels


def load_duplicate_work(root: Path) -> dict[str, dict]:
    items: dict[str, dict] = {}
    paths = sorted((root / "batches").glob("pass2-*.json"))
    if not paths:
        raise ValueError("pass 2 duplicate work is missing")
    for path in paths:
        batch = json.loads(path.read_text(encoding="utf-8"))
        if batch.get("rubricVersion") != RUBRIC or batch.get("pass") != 2 \
                or batch.get("candidateOutputsAvailable") is not False:
            raise ValueError("duplicate work rubric or provenance is invalid")
        for item in batch.get("items", []):
            identifier = item.get("id") if isinstance(item, dict) else None
            if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier):
                raise ValueError("duplicate work identifier is invalid")
            if identifier in items:
                raise ValueError("duplicate work identifier is duplicated")
            target_type = item.get("targetType")
            if target_type not in {"single-frame", "temporal-pair"}:
                raise ValueError("duplicate work target type is invalid")
            if target_type == "single-frame":
                if not isinstance(item.get("image"), str):
                    raise ValueError("single-frame image is missing")
            elif not all(isinstance(item.get(key), str) for key in [
                "beforeImage", "afterImage",
            ]):
                raise ValueError("temporal-pair images are missing")
            items[identifier] = item
    return items


def resolve_render(root: Path, relative: str) -> Path:
    candidate = (root / relative).resolve(strict=True)
    if root != candidate and root not in candidate.parents:
        raise ValueError("render path escapes the annotation root")
    if not candidate.is_file() or candidate.is_symlink():
        raise ValueError("render must be a regular private file")
    return candidate


def source_images(root: Path, item: dict) -> list[Path]:
    if item["targetType"] == "single-frame":
        return [resolve_render(root, item["image"])]
    return [
        resolve_render(root, item["beforeImage"]),
        resolve_render(root, item["afterImage"]),
    ]


def prepare_audit(annotation_root: Path, output_root: Path, seed: str) -> dict:
    output = validate_private_output(output_root)
    annotation = validate_private_input(annotation_root)
    if annotation == output or annotation in output.parents or output in annotation.parents:
        raise ValueError("annotation and audit roots must be disjoint")
    if not seed:
        raise ValueError("audit seed is required")

    duplicate_work = load_duplicate_work(annotation)
    pass_labels = {1: load_labels(annotation, 1), 2: load_labels(annotation, 2)}
    duplicate_ids = set(duplicate_work)
    for pass_number in (1, 2):
        if not duplicate_ids.issubset(pass_labels[pass_number]):
            raise ValueError(f"pass {pass_number} labels do not cover duplicate work")

    single_count = sum(
        item["targetType"] == "single-frame" for item in duplicate_work.values()
    )
    temporal_count = len(duplicate_work) - single_count
    if (single_count, temporal_count) != (30, 15):
        raise ValueError("correctness audit requires the locked 30/15 duplicate set")
    paired_opportunities = single_count * 6 + temporal_count * 7
    output, staging = prepare_private_output(output)
    try:
        make_private_directory(staging / "packets")
        mapping: dict[str, dict] = {}
        source_basenames: set[str] = set()
        for auditor_number in (1, 2):
            auditor_slot = f"auditor-{auditor_number:02d}"
            packet_root = staging / "packets" / auditor_slot
            make_private_directory(packet_root)
            make_private_directory(packet_root / "images")
            packet_items = []
            auditor_mapping = {}
            for identifier, work_item in duplicate_work.items():
                sources = source_images(annotation, work_item)
                source_basenames.update(path.name for path in sources)
                for pass_number in (1, 2):
                    opaque_id = "item-" + digest(
                        f"{seed}:alias:{auditor_number}:{identifier}:{pass_number}"
                    )[:24]
                    suffixes = ["frame"] if len(sources) == 1 else ["before", "after"]
                    images = []
                    for source, suffix in zip(sources, suffixes):
                        relative = f"images/{opaque_id}-{suffix}{source.suffix.lower()}"
                        copy_private(source, packet_root / relative)
                        images.append(relative)
                    label = pass_labels[pass_number][identifier]
                    packet_items.append({
                        "opaqueID": opaque_id,
                        "targetType": work_item["targetType"],
                        "reference": reference_from_label(label, work_item["targetType"]),
                        "images": images,
                    })
                    auditor_mapping[opaque_id] = {
                        "case": identifier,
                        "sourceReference": f"pass{pass_number}",
                        "pass": pass_number,
                        "targetType": work_item["targetType"],
                    }
            packet_items.sort(key=lambda item: digest(
                f"{seed}:order:{auditor_number}:{item['opaqueID']}"
            ))
            packet = {
                "schema": "screen-understanding-correctness-audit-packet-v3",
                "protocol": PROTOCOL,
                "rubricVersion": RUBRIC,
                "packetID": "packet-" + digest(
                    f"{seed}:packet:{auditor_number}"
                )[:24],
                "items": packet_items,
            }
            serialized = json.dumps(packet, sort_keys=True, ensure_ascii=False)
            leaked_tokens = set(duplicate_ids) | source_basenames
            if any(token in serialized for token in leaked_tokens):
                raise ValueError("blinded packet exposes a case identifier or source basename")
            atomic_private_json(packet_root / "packet.json", packet)
            mapping[auditor_slot] = auditor_mapping

        owner_mapping = {
            "schema": "screen-understanding-correctness-audit-mapping-v3",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "seedSHA256": digest(seed),
            "auditors": mapping,
        }
        manifest = {
            "schema": "screen-understanding-correctness-audit-manifest-v3",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "caseCount": len(duplicate_work),
            "singleFrameCount": single_count,
            "temporalPairCount": temporal_count,
            "referenceCount": len(duplicate_work) * 2,
            "pairedOpportunityCount": paired_opportunities,
            "auditorCount": 2,
            "candidateOutputsAvailable": False,
        }
        atomic_private_json(staging / "owner-mapping.json", owner_mapping)
        atomic_private_json(staging / "audit-manifest.json", manifest)
        publish_private_output(staging, output)
        return manifest
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--annotation-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--seed", default="screen-understanding-correctness-v3")
    args = parser.parse_args()
    print(json.dumps(prepare_audit(args.annotation_root, args.output_root, args.seed), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
