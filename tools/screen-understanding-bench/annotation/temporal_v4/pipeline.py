#!/usr/bin/python3
"""Private temporal-v4 annotation pipeline."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import shutil
import stat
from pathlib import Path
from typing import Any

from common.contracts import exact_keys
from common.evaluator_receipt import (
    validate_independent_sessions,
    validate_receipt,
)
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
from common.provenance import file_evidence


PROTOCOL = "screen-understanding-temporal-annotation-v4"
RUBRIC = "screen-understanding-temporal-v4"
WORK_SCHEMA = "screen-understanding-temporal-work-v4"
LABEL_OUTPUT_SCHEMA = "screen-understanding-temporal-labels-v4"
AUDIT_OUTPUT_SCHEMA = "screen-understanding-temporal-audit-judgments-v4"
TIEBREAK_OUTPUT_SCHEMA = "screen-understanding-temporal-tiebreak-judgments-v4"
FINAL_OUTPUT_SCHEMA = "screen-understanding-temporal-final-audit-judgments-v4"
AUDIT_PACKET_SCHEMA = "screen-understanding-temporal-audit-packet-v4"
TIEBREAK_PACKET_SCHEMA = "screen-understanding-temporal-tiebreak-work-v4"
FINAL_PACKET_SCHEMA = "screen-understanding-temporal-final-audit-packet-v4"
CASE_ID = re.compile(r"^[0-9a-f]{24}$")
SAFE_ID = re.compile(r"^[A-Za-z0-9._-]{1,96}$")
AMBIGUITIES = frozenset({"judgeable", "ambiguous", "unjudgeable"})
REQUIRED_IDS = ("required.surface", "required.content", "required.state")
AUDIT_SLOTS = (
    "surface", "content", "state", "primaryChange", "ambiguityAbstention",
)
RAW_JOINT_FLOOR = 0.90
FIXED_FORBIDDEN_FACTS = [
    {
        "id": "forbidden.intent",
        "text": "The user's purpose or intended next action is not established by the visible frames.",
    },
    {
        "id": "forbidden.outcome",
        "text": "Off-screen completion, persistence, sending, saving, payment, or publication is not established beyond the visible after-state.",
    },
]


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _load_json(path: Path, subject: str) -> tuple[dict[str, Any], str]:
    source = validate_private_input_file(path)
    try:
        text = source.read_text(encoding="utf-8")
        value = json.loads(text)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{subject} is not valid JSON") from error
    if not isinstance(value, dict):
        raise ValueError(f"{subject} must be an object")
    return value, text


def _assert_owner_only_file(path: Path, subject: str) -> None:
    mode = stat.S_IMODE(path.stat().st_mode)
    if mode & 0o077:
        raise ValueError(f"{subject} must be owner-only")


def _reject_leaks(value: object, subject: str, owner_tokens: set[str] | None = None) -> None:
    serialized = json.dumps(value, sort_keys=True, ensure_ascii=False).lower()
    forbidden = (
        "candidateoutput\"", "candidateoutputs\"", "methodid", "/users/",
        "/volumes/", "file://",
    )
    if any(fragment in serialized for fragment in forbidden):
        raise ValueError(f"{subject} contains candidate data or a local path")
    if owner_tokens and any(token.lower() in serialized for token in owner_tokens):
        raise ValueError(f"{subject} exposes an owner identifier")


def _resolve_corpus_image(corpus: Path, identifier: str) -> Path:
    if not CASE_ID.fullmatch(identifier):
        raise ValueError("corpus case identifier is invalid")
    source = corpus / "cases" / identifier / "image.heic"
    if source.is_symlink() or not source.is_file():
        raise ValueError("temporal source must be a regular sealed image")
    resolved = source.resolve(strict=True)
    if corpus not in resolved.parents:
        raise ValueError("temporal source escapes the corpus root")
    return resolved


def _copy_pair_images(
    corpus: Path,
    staging: Path,
    opaque_id: str,
    pair: dict[str, Any],
) -> tuple[str, str]:
    before_relative = f"images/{opaque_id}-before.heic"
    after_relative = f"images/{opaque_id}-after.heic"
    copy_private(
        _resolve_corpus_image(corpus, pair["beforeCaseID"]),
        staging / before_relative,
    )
    copy_private(
        _resolve_corpus_image(corpus, pair["afterCaseID"]),
        staging / after_relative,
    )
    return before_relative, after_relative


def _work_item(
    corpus: Path,
    staging: Path,
    opaque_id: str,
    pair: dict[str, Any],
) -> dict[str, Any]:
    before, after = _copy_pair_images(corpus, staging, opaque_id, pair)
    return {
        "opaqueID": opaque_id,
        "targetType": "temporal-pair",
        "beforeImage": before,
        "afterImage": after,
    }


def prepare(corpus_root: Path, output_root: Path, seed: str) -> dict:
    output = validate_private_output(output_root)
    corpus = validate_private_input(corpus_root)
    if not isinstance(seed, str) or not seed:
        raise ValueError("temporal-v4 seed is required")
    if corpus == output or corpus in output.parents or output in corpus.parents:
        raise ValueError("corpus and temporal work roots must be disjoint")
    manifest_path = validate_private_input_file(corpus / "manifest.json")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    pairs = manifest.get("temporalPairs") if isinstance(manifest, dict) else None
    if not isinstance(pairs, list) or len(pairs) != 100:
        raise ValueError("sealed corpus must contain exactly 100 temporal pairs")
    by_id: dict[str, dict[str, Any]] = {}
    owner_tokens: set[str] = set()
    for pair in pairs:
        if not isinstance(pair, dict):
            raise ValueError("temporal pair is invalid")
        identifier = pair.get("id")
        before = pair.get("beforeCaseID")
        after = pair.get("afterCaseID")
        if not all(isinstance(value, str) and CASE_ID.fullmatch(value) for value in (
            identifier, before, after,
        )) or identifier in by_id or before == after:
            raise ValueError("temporal pair identifiers are invalid")
        by_id[identifier] = pair
        owner_tokens.update((identifier, before, after))

    pass1_pairs = sorted(
        pairs,
        key=lambda pair: _digest(f"{seed}:pass1-order:{pair['id']}"),
    )
    pass2_pairs = sorted(
        pairs,
        key=lambda pair: _digest(f"{seed}:concealed-pass2:{pair['id']}"),
    )[:15]
    pass2_pairs.sort(key=lambda pair: _digest(f"{seed}:pass2-order:{pair['id']}"))

    output, staging = prepare_private_output(output)
    try:
        make_private_directory(staging / "images")
        make_private_directory(staging / "packets")
        pass_items: dict[int, list[dict[str, Any]]] = {1: [], 2: []}
        mapping: dict[str, dict[str, dict[str, str]]] = {
            "pass1": {}, "pass2": {},
        }
        for pass_number, selected in ((1, pass1_pairs), (2, pass2_pairs)):
            mapping_key = f"pass{pass_number}"
            for pair in selected:
                opaque_id = "pair-" + _digest(
                    f"{seed}:pass{pass_number}:alias:{pair['id']}"
                )[:24]
                item = _work_item(corpus, staging, opaque_id, pair)
                pass_items[pass_number].append(item)
                mapping[mapping_key][opaque_id] = {
                    "pair": pair["id"],
                    "before": pair["beforeCaseID"],
                    "after": pair["afterCaseID"],
                }
            packet = {
                "schema": WORK_SCHEMA,
                "protocol": PROTOCOL,
                "rubricVersion": RUBRIC,
                "packetID": "packet-" + _digest(
                    f"{seed}:pass{pass_number}:packet"
                )[:24],
                "pass": pass_number,
                "candidateOutputsAvailable": False,
                "items": pass_items[pass_number],
            }
            _reject_leaks(packet, f"pass {pass_number} packet", owner_tokens)
            atomic_private_json(staging / "packets" / f"pass{pass_number}.json", packet)

        owner_mapping = {
            "schema": "screen-understanding-temporal-owner-mapping-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "seedSHA256": _digest(seed),
            "candidateOutputsAvailable": False,
            "passes": mapping,
        }
        result = {
            "schema": "screen-understanding-temporal-work-manifest-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "corpusManifestSHA256": file_evidence(manifest_path)["sha256"],
            "pass1Count": 100,
            "pass2Count": 15,
            "opportunitiesPerPair": 5,
            "candidateOutputsAvailable": False,
        }
        atomic_private_json(staging / "owner-mapping.json", owner_mapping)
        atomic_private_json(staging / "work-manifest.json", result)
        publish_private_output(staging, output)
        return result
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def _validate_work_packet(packet: dict[str, Any]) -> dict[str, dict[str, Any]]:
    exact_keys(packet, {
        "schema", "protocol", "rubricVersion", "packetID", "pass",
        "candidateOutputsAvailable", "items",
    }, "temporal work packet")
    if packet["schema"] != WORK_SCHEMA or packet["protocol"] != PROTOCOL \
            or packet["rubricVersion"] != RUBRIC \
            or packet["candidateOutputsAvailable"] is not False:
        raise ValueError("temporal work packet metadata is invalid")
    pass_number = packet["pass"]
    expected_count = 100 if pass_number == 1 else 15 if pass_number == 2 else None
    if expected_count is None or not isinstance(packet["packetID"], str) \
            or not SAFE_ID.fullmatch(packet["packetID"]):
        raise ValueError("temporal work packet identity or pass is invalid")
    items = packet["items"]
    if not isinstance(items, list) or len(items) != expected_count:
        raise ValueError("temporal work packet count is invalid")
    by_id: dict[str, dict[str, Any]] = {}
    for item in items:
        exact_keys(item, {
            "opaqueID", "targetType", "beforeImage", "afterImage",
        }, "temporal work item")
        identifier = item["opaqueID"]
        if not isinstance(identifier, str) or not SAFE_ID.fullmatch(identifier) \
                or identifier in by_id or item["targetType"] != "temporal-pair":
            raise ValueError("temporal work item identity is invalid")
        for key, suffix in (("beforeImage", "before"), ("afterImage", "after")):
            relative = Path(item[key]) if isinstance(item[key], str) else None
            if relative is None or relative.is_absolute() or len(relative.parts) != 2 \
                    or relative.parts[0] != "images" or ".." in relative.parts \
                    or not relative.name.startswith(f"{identifier}-{suffix}"):
                raise ValueError("temporal work image alias is invalid")
        by_id[identifier] = item
    return by_id


def _validate_text_fact(fact: object, expected_id: str, subject: str) -> None:
    exact_keys(fact, {"id", "text"}, subject)
    if fact["id"] != expected_id:
        raise ValueError(f"{subject} slots are invalid")
    if not isinstance(fact["text"], str) or not 1 <= len(fact["text"]) <= 240:
        raise ValueError(f"{subject} text is invalid")


def _validate_label(label: object, expected: set[str], pass_number: int) -> dict[str, Any]:
    exact_keys(label, {
        "opaqueID", "requiredFacts", "criticalText", "forbiddenInferences",
        "meaningfulChange", "ambiguity", "abstentionAllowed", "pass", "locked",
    }, "temporal label")
    identifier = label["opaqueID"]
    if identifier not in expected:
        raise ValueError("temporal label identifiers do not match the work packet")
    if label["pass"] != pass_number or label["locked"] is not False:
        raise ValueError("temporal label pass or lock state is invalid")
    required = label["requiredFacts"]
    if not isinstance(required, list) or len(required) != 3:
        raise ValueError("required slots count is invalid")
    for fact, expected_id in zip(required, REQUIRED_IDS):
        _validate_text_fact(fact, expected_id, "required")
    if label["criticalText"] != []:
        raise ValueError("critical text must be empty")
    if label["forbiddenInferences"] != FIXED_FORBIDDEN_FACTS:
        raise ValueError("fixed forbidden text or order is invalid")
    change = label["meaningfulChange"]
    if not isinstance(change, list) or len(change) > 1:
        raise ValueError("primary change must be empty or contain exactly one fact")
    if change:
        _validate_text_fact(change[0], "change.primary", "primary change")
    ambiguity = label["ambiguity"]
    abstention = label["abstentionAllowed"]
    if ambiguity not in AMBIGUITIES or not isinstance(abstention, bool) \
            or abstention is not (ambiguity != "judgeable"):
        raise ValueError("abstention does not match ambiguity")
    return label


def validate_labels(
    packet_path: Path,
    output_path: Path,
    receipt_path: Path,
    expected_role: str,
) -> dict:
    packet, _ = _load_json(packet_path, "temporal work packet")
    output, _ = _load_json(output_path, "temporal label output")
    _assert_owner_only_file(validate_private_input_file(output_path), "temporal label output")
    receipt = validate_receipt(
        receipt_path,
        packet_path,
        output_path,
        expected_role,
    )
    expected = _validate_work_packet(packet)
    exact_keys(output, {
        "schema", "protocol", "rubricVersion", "packetID", "pass", "annotator",
        "candidateOutputsAvailable", "labels",
    }, "temporal label output")
    expected_role_for_pass = f"annotation-pass{packet['pass']}"
    if expected_role != expected_role_for_pass:
        raise ValueError("annotation receipt role does not match the packet pass")
    if output["schema"] != LABEL_OUTPUT_SCHEMA or output["protocol"] != PROTOCOL \
            or output["rubricVersion"] != RUBRIC \
            or output["packetID"] != packet["packetID"] \
            or output["pass"] != packet["pass"] \
            or output["candidateOutputsAvailable"] is not False:
        raise ValueError("temporal label output metadata is invalid")
    if not isinstance(output["annotator"], str) or not SAFE_ID.fullmatch(output["annotator"]):
        raise ValueError("temporal annotator identity is invalid")
    labels = output["labels"]
    if not isinstance(labels, list) or len(labels) != len(expected):
        raise ValueError("temporal label count does not match the work packet")
    by_id: dict[str, dict[str, Any]] = {}
    for label in labels:
        validated = _validate_label(label, set(expected), packet["pass"])
        identifier = validated["opaqueID"]
        if identifier in by_id:
            raise ValueError("temporal label identifier is duplicated")
        by_id[identifier] = validated
    if set(by_id) != set(expected):
        raise ValueError("temporal labels do not cover the work packet")
    _reject_leaks(output, "temporal label output")
    return {
        "count": len(by_id),
        "pass": packet["pass"],
        "opportunityCount": len(by_id) * 5,
        "annotator": output["annotator"],
        "receipt": receipt,
        "labels": by_id,
    }


def prepare_audit(
    work_root: Path,
    pass1_output: Path,
    pass1_receipt: Path,
    pass2_output: Path,
    pass2_receipt: Path,
    output_root: Path,
    seed: str,
) -> dict:
    output = validate_private_output(output_root)
    work = validate_private_input(work_root)
    if not isinstance(seed, str) or not seed:
        raise ValueError("temporal audit seed is required")
    if work == output or work in output.parents or output in work.parents:
        raise ValueError("work and audit roots must be disjoint")
    pass1 = validate_labels(
        work / "packets" / "pass1.json",
        pass1_output,
        pass1_receipt,
        "annotation-pass1",
    )
    pass2 = validate_labels(
        work / "packets" / "pass2.json",
        pass2_output,
        pass2_receipt,
        "annotation-pass2",
    )
    validate_independent_sessions(
        [pass1["receipt"], pass2["receipt"]],
        {"annotation-pass1", "annotation-pass2"},
    )
    owner_mapping, _ = _load_json(work / "owner-mapping.json", "temporal owner mapping")
    exact_keys(owner_mapping, {
        "schema", "protocol", "rubricVersion", "seedSHA256",
        "candidateOutputsAvailable", "passes",
    }, "temporal owner mapping")
    if owner_mapping["schema"] != "screen-understanding-temporal-owner-mapping-v4" \
            or owner_mapping["protocol"] != PROTOCOL \
            or owner_mapping["rubricVersion"] != RUBRIC \
            or owner_mapping["candidateOutputsAvailable"] is not False \
            or set(owner_mapping["passes"]) != {"pass1", "pass2"}:
        raise ValueError("temporal owner mapping metadata is invalid")
    pass_owners: dict[int, dict[str, dict[str, str]]] = {}
    reverse: dict[int, dict[str, str]] = {}
    for pass_number in (1, 2):
        values = owner_mapping["passes"][f"pass{pass_number}"]
        expected_count = 100 if pass_number == 1 else 15
        if not isinstance(values, dict) or len(values) != expected_count:
            raise ValueError("temporal owner mapping count is invalid")
        pass_owners[pass_number] = values
        reverse[pass_number] = {}
        for opaque_id, owner in values.items():
            exact_keys(owner, {"pair", "before", "after"}, "temporal owner item")
            if opaque_id not in (pass1 if pass_number == 1 else pass2)["labels"] \
                    or any(not isinstance(owner[key], str) or not CASE_ID.fullmatch(owner[key])
                           for key in ("pair", "before", "after")) \
                    or owner["pair"] in reverse[pass_number]:
                raise ValueError("temporal owner mapping item is invalid")
            reverse[pass_number][owner["pair"]] = opaque_id
    duplicate_pairs = set(reverse[2])
    if len(duplicate_pairs) != 15 or not duplicate_pairs.issubset(reverse[1]):
        raise ValueError("concealed pass2 set is not a 15-pair subset of pass1")

    source_packets = {
        1: json.loads((work / "packets" / "pass1.json").read_text(encoding="utf-8")),
        2: json.loads((work / "packets" / "pass2.json").read_text(encoding="utf-8")),
    }
    source_items = {
        number: {item["opaqueID"]: item for item in packet["items"]}
        for number, packet in source_packets.items()
    }
    labels_by_pass = {1: pass1["labels"], 2: pass2["labels"]}
    owner_tokens = set(duplicate_pairs)
    for number in (1, 2):
        for pair in duplicate_pairs:
            owner = pass_owners[number][reverse[number][pair]]
            owner_tokens.update((owner["before"], owner["after"]))

    output, staging = prepare_private_output(output)
    try:
        make_private_directory(staging / "packets")
        make_private_directory(staging / "sources")
        for pass_number, (source_output, source_receipt) in enumerate((
            (pass1_output, pass1_receipt),
            (pass2_output, pass2_receipt),
        ), start=1):
            copy_private(
                work / "packets" / f"pass{pass_number}.json",
                staging / "sources" / f"pass{pass_number}-packet.json",
            )
            copy_private(
                validate_private_input_file(source_output),
                staging / "sources" / f"pass{pass_number}-output.json",
            )
            copy_private(
                validate_private_input_file(source_receipt),
                staging / "sources" / f"pass{pass_number}-receipt.json",
            )
        copy_private(
            work / "owner-mapping.json",
            staging / "sources" / "work-owner-mapping.json",
        )

        auditor_mappings: dict[str, dict[str, dict[str, Any]]] = {}
        for auditor_number in (1, 2):
            slot = f"auditor-{auditor_number:02d}"
            packet_root = staging / "packets" / slot
            make_private_directory(packet_root)
            make_private_directory(packet_root / "images")
            items = []
            slot_mapping: dict[str, dict[str, Any]] = {}
            for pair in sorted(duplicate_pairs):
                for pass_number in (1, 2):
                    source_opaque = reverse[pass_number][pair]
                    source_item = source_items[pass_number][source_opaque]
                    label = labels_by_pass[pass_number][source_opaque]
                    opaque_id = "audit-" + _digest(
                        f"{seed}:auditor:{auditor_number}:{pair}:{pass_number}"
                    )[:24]
                    images = []
                    for position, key in (("before", "beforeImage"), ("after", "afterImage")):
                        source = (work / source_item[key]).resolve(strict=True)
                        if work not in source.parents or source.is_symlink() \
                                or not source.is_file():
                            raise ValueError("temporal audit source image is invalid")
                        relative = f"images/{opaque_id}-{position}{source.suffix.lower()}"
                        copy_private(source, packet_root / relative)
                        images.append(relative)
                    reference = _reference_from_label(label)
                    items.append({
                        "opaqueID": opaque_id,
                        "targetType": "temporal-pair",
                        "reference": reference,
                        "images": images,
                    })
                    slot_mapping[opaque_id] = {
                        "pair": pair,
                        "pass": pass_number,
                    }
            items.sort(key=lambda item: _digest(
                f"{seed}:audit-order:{auditor_number}:{item['opaqueID']}"
            ))
            packet = {
                "schema": AUDIT_PACKET_SCHEMA,
                "protocol": PROTOCOL,
                "rubricVersion": RUBRIC,
                "packetID": "audit-packet-" + _digest(
                    f"{seed}:audit-packet:{auditor_number}"
                )[:24],
                "candidateOutputsAvailable": False,
                "items": items,
            }
            _reject_leaks(packet, f"auditor {auditor_number} packet", owner_tokens)
            atomic_private_json(packet_root / "packet.json", packet)
            auditor_mappings[slot] = slot_mapping

        mapping_payload = {
            "schema": "screen-understanding-temporal-audit-owner-mapping-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "seedSHA256": _digest(seed),
            "candidateOutputsAvailable": False,
            "auditors": auditor_mappings,
        }
        manifest = {
            "schema": "screen-understanding-temporal-audit-manifest-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "pairCount": 15,
            "referenceCount": 30,
            "opportunitiesPerPair": 5,
            "opportunityCount": 75,
            "auditorCount": 2,
            "candidateOutputsAvailable": False,
        }
        atomic_private_json(staging / "owner-mapping.json", mapping_payload)
        atomic_private_json(staging / "audit-manifest.json", manifest)
        publish_private_output(staging, output)
        return manifest
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def _reference_from_label(label: dict[str, Any]) -> dict[str, Any]:
    reference = {
        key: label[key]
        for key in (
            "requiredFacts", "criticalText", "forbiddenInferences",
            "meaningfulChange", "ambiguity", "abstentionAllowed",
        )
    }
    _validate_reference(reference)
    return reference


def _validate_reference(reference: object) -> dict[str, Any]:
    exact_keys(reference, {
        "requiredFacts", "criticalText", "forbiddenInferences",
        "meaningfulChange", "ambiguity", "abstentionAllowed",
    }, "temporal reference")
    synthetic = {
        "opaqueID": "synthetic",
        **reference,
        "pass": 1,
        "locked": False,
    }
    _validate_label(synthetic, {"synthetic"}, 1)
    return reference


def _validate_audit_packet(packet: dict[str, Any]) -> dict[str, dict[str, Any]]:
    exact_keys(packet, {
        "schema", "protocol", "rubricVersion", "packetID",
        "candidateOutputsAvailable", "items",
    }, "temporal audit packet")
    if packet["schema"] != AUDIT_PACKET_SCHEMA or packet["protocol"] != PROTOCOL \
            or packet["rubricVersion"] != RUBRIC \
            or packet["candidateOutputsAvailable"] is not False \
            or not isinstance(packet["packetID"], str) \
            or not SAFE_ID.fullmatch(packet["packetID"]):
        raise ValueError("temporal audit packet metadata is invalid")
    items = packet["items"]
    if not isinstance(items, list) or len(items) != 30:
        raise ValueError("temporal audit packet must contain exactly 30 references")
    by_id = {}
    for item in items:
        exact_keys(item, {
            "opaqueID", "targetType", "reference", "images",
        }, "temporal audit item")
        identifier = item["opaqueID"]
        if not isinstance(identifier, str) or not SAFE_ID.fullmatch(identifier) \
                or identifier in by_id or item["targetType"] != "temporal-pair":
            raise ValueError("temporal audit item identity is invalid")
        _validate_reference(item["reference"])
        images = item["images"]
        if not isinstance(images, list) or len(images) != 2:
            raise ValueError("temporal audit item images are invalid")
        for image in images:
            relative = Path(image) if isinstance(image, str) else None
            if relative is None or relative.is_absolute() or len(relative.parts) != 2 \
                    or relative.parts[0] != "images" or ".." in relative.parts \
                    or not relative.name.startswith(identifier):
                raise ValueError("temporal audit image alias is invalid")
        by_id[identifier] = item
    return by_id


def validate_audit(
    packet_path: Path,
    output_path: Path,
    receipt_path: Path,
    expected_role: str,
) -> dict:
    packet, _ = _load_json(packet_path, "temporal audit packet")
    output, _ = _load_json(output_path, "temporal audit output")
    _assert_owner_only_file(validate_private_input_file(output_path), "temporal audit output")
    receipt = validate_receipt(
        receipt_path,
        packet_path,
        output_path,
        expected_role,
    )
    expected = _validate_audit_packet(packet)
    exact_keys(output, {
        "schema", "protocol", "rubricVersion", "packetID", "auditor",
        "candidateOutputsAvailable", "items",
    }, "temporal audit output")
    if expected_role not in {"correctness-auditor-1", "correctness-auditor-2"}:
        raise ValueError("temporal audit receipt role is invalid")
    if output["schema"] != AUDIT_OUTPUT_SCHEMA or output["protocol"] != PROTOCOL \
            or output["rubricVersion"] != RUBRIC \
            or output["packetID"] != packet["packetID"] \
            or output["candidateOutputsAvailable"] is not False:
        raise ValueError("temporal audit output metadata is invalid")
    if not isinstance(output["auditor"], str) or not SAFE_ID.fullmatch(output["auditor"]):
        raise ValueError("temporal audit identity is invalid")
    items = output["items"]
    if not isinstance(items, list) or len(items) != 30:
        raise ValueError("temporal audit output count is invalid")
    by_id = {}
    for item in items:
        exact_keys(item, {"opaqueID", "slots"}, "temporal audit judgment")
        identifier = item["opaqueID"]
        if identifier not in expected or identifier in by_id:
            raise ValueError("temporal audit judgment identity is invalid")
        slots = item["slots"]
        exact_keys(slots, set(AUDIT_SLOTS), "temporal audit slots")
        for slot_name, decision in slots.items():
            exact_keys(decision, {"correct", "materialFalse"}, f"{slot_name} decision")
            if not isinstance(decision["correct"], bool) \
                    or not isinstance(decision["materialFalse"], bool) \
                    or decision["materialFalse"] and decision["correct"]:
                raise ValueError("temporal audit decisions must be consistent booleans")
        by_id[identifier] = item
    if set(by_id) != set(expected):
        raise ValueError("temporal audit output does not cover the packet")
    _reject_leaks(output, "temporal audit output")
    return {
        "count": 30,
        "opportunityCount": 75,
        "auditor": output["auditor"],
        "receipt": receipt,
        "judgments": by_id,
        "packetItems": expected,
    }


def aggregate(
    audit_root: Path,
    auditor_one: Path,
    receipt_one: Path,
    auditor_two: Path,
    receipt_two: Path,
    output_root: Path,
    tiebreak_output: Path | None = None,
    tiebreak_receipt: Path | None = None,
) -> dict:
    output = validate_private_output(output_root)
    audit = validate_private_input(audit_root)
    if audit == output or audit in output.parents or output in audit.parents:
        raise ValueError("audit and aggregate roots must be disjoint")
    manifest, _ = _load_json(audit / "audit-manifest.json", "temporal audit manifest")
    exact_keys(manifest, {
        "schema", "protocol", "rubricVersion", "pairCount", "referenceCount",
        "opportunitiesPerPair", "opportunityCount", "auditorCount",
        "candidateOutputsAvailable",
    }, "temporal audit manifest")
    if manifest != {
        "schema": "screen-understanding-temporal-audit-manifest-v4",
        "protocol": PROTOCOL,
        "rubricVersion": RUBRIC,
        "pairCount": 15,
        "referenceCount": 30,
        "opportunitiesPerPair": 5,
        "opportunityCount": 75,
        "auditorCount": 2,
        "candidateOutputsAvailable": False,
    }:
        raise ValueError("temporal audit manifest is not locked")
    mapping, _ = _load_json(audit / "owner-mapping.json", "temporal audit owner mapping")
    exact_keys(mapping, {
        "schema", "protocol", "rubricVersion", "seedSHA256",
        "candidateOutputsAvailable", "auditors",
    }, "temporal audit owner mapping")
    if mapping["schema"] != "screen-understanding-temporal-audit-owner-mapping-v4" \
            or mapping["protocol"] != PROTOCOL or mapping["rubricVersion"] != RUBRIC \
            or mapping["candidateOutputsAvailable"] is not False \
            or not isinstance(mapping["seedSHA256"], str) \
            or not re.fullmatch(r"[0-9a-f]{64}", mapping["seedSHA256"]) \
            or set(mapping["auditors"]) != {"auditor-01", "auditor-02"}:
        raise ValueError("temporal audit owner mapping metadata is invalid")

    pass_results = []
    for pass_number in (1, 2):
        source_root = audit / "sources"
        pass_results.append(validate_labels(
            source_root / f"pass{pass_number}-packet.json",
            source_root / f"pass{pass_number}-output.json",
            source_root / f"pass{pass_number}-receipt.json",
            f"annotation-pass{pass_number}",
        ))
    auditor_results = [
        validate_audit(
            audit / "packets" / "auditor-01" / "packet.json",
            auditor_one,
            receipt_one,
            "correctness-auditor-1",
        ),
        validate_audit(
            audit / "packets" / "auditor-02" / "packet.json",
            auditor_two,
            receipt_two,
            "correctness-auditor-2",
        ),
    ]
    if auditor_results[0]["auditor"] == auditor_results[1]["auditor"]:
        raise ValueError("correctness auditor identities must be distinct")
    base_receipts = [
        pass_results[0]["receipt"], pass_results[1]["receipt"],
        auditor_results[0]["receipt"], auditor_results[1]["receipt"],
    ]
    base_roles = {
        "annotation-pass1", "annotation-pass2", "correctness-auditor-1",
        "correctness-auditor-2",
    }
    validate_independent_sessions(base_receipts, base_roles)
    loaded = _load_auditor_owner_views(mapping, auditor_results)
    differences = _audit_disagreements(loaded)
    if not differences and (tiebreak_output is not None or tiebreak_receipt is not None):
        raise ValueError("tiebreak artifacts were supplied without disagreements")
    if (tiebreak_output is None) != (tiebreak_receipt is None):
        raise ValueError("tiebreak output and receipt must be supplied together")

    output, staging = prepare_private_output(output)
    try:
        tiebreak_packet_path = None
        tiebreak_mapping: dict[str, tuple[str, int]] = {}
        tiebreak_values: dict[tuple[str, int], dict[tuple[str, str], bool]] = {}
        tiebreak_receipt_value = None
        if differences:
            tiebreak_packet_path, tiebreak_mapping = _build_tiebreak(
                audit,
                staging,
                mapping["seedSHA256"],
                differences,
                loaded,
            )
            if tiebreak_output is None:
                pending = {
                    "schema": "screen-understanding-temporal-correctness-result-v4",
                    "protocol": PROTOCOL,
                    "rubricVersion": RUBRIC,
                    "state": "tiebreak-required",
                    "disputedReferenceCount": len(differences),
                    "disputedBooleanCount": sum(
                        len(fields) for fields in differences.values()
                    ),
                    "candidateOutputsAvailable": False,
                }
                atomic_private_json(staging / "result.json", pending)
                publish_private_output(staging, output)
                return pending
            tiebreak_values, tiebreak_receipt_value = _validate_tiebreak(
                tiebreak_packet_path,
                tiebreak_output,
                tiebreak_receipt,
                tiebreak_mapping,
            )
            validate_independent_sessions(
                [*base_receipts, tiebreak_receipt_value],
                {*base_roles, "correctness-tiebreak"},
            )

        resolved = _resolve_audit_fields(
            loaded,
            differences,
            tiebreak_values,
        )
        result, selections, selected_references = _score_and_select(
            resolved,
            loaded,
        )
        make_private_directory(staging / "sources")
        _copy_aggregate_sources(
            audit,
            staging / "sources",
            auditor_one,
            receipt_one,
            auditor_two,
            receipt_two,
            tiebreak_packet_path,
            tiebreak_output,
            tiebreak_receipt,
        )
        receipt_payloads = [*base_receipts]
        if tiebreak_receipt_value is not None:
            receipt_payloads.append(tiebreak_receipt_value)
        session_context_path = staging / "session-context.json"
        selection_path = staging / "selection.json"
        selected_labels_path = staging / "selected-labels.json"
        atomic_private_json(session_context_path, {
            "schema": "screen-understanding-temporal-session-context-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "candidateOutputsAvailable": False,
            "receipts": receipt_payloads,
        })
        atomic_private_json(selection_path, {
            "schema": "screen-understanding-temporal-selection-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "candidateOutputsAvailable": False,
            "items": selections,
        })
        atomic_private_json(selected_labels_path, {
            "schema": "screen-understanding-temporal-selected-labels-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "candidateOutputsAvailable": False,
            "items": [
                {"pair": pair, "reference": selected_references[pair]}
                for pair in sorted(selected_references)
            ],
        })
        result["artifacts"] = {
            "sessionContextSHA256": file_evidence(session_context_path)["sha256"],
            "selectionSHA256": file_evidence(selection_path)["sha256"],
            "selectedLabelsSHA256": file_evidence(selected_labels_path)["sha256"],
        }
        atomic_private_json(staging / "result.json", result)
        publish_private_output(staging, output)
        return result
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def _load_auditor_owner_views(
    mapping: dict[str, Any],
    auditor_results: list[dict[str, Any]],
) -> list[dict[tuple[str, int], dict[str, Any]]]:
    loaded = []
    canonical_keys = None
    for index, result in enumerate(auditor_results, start=1):
        owners = mapping["auditors"][f"auditor-{index:02d}"]
        if not isinstance(owners, dict) or len(owners) != 30:
            raise ValueError("temporal auditor owner mapping count is invalid")
        by_key = {}
        for opaque_id, owner in owners.items():
            exact_keys(owner, {"pair", "pass"}, "temporal auditor owner")
            pair = owner["pair"]
            pass_number = owner["pass"]
            if not isinstance(pair, str) or not CASE_ID.fullmatch(pair) \
                    or pass_number not in {1, 2} \
                    or opaque_id not in result["judgments"] \
                    or opaque_id not in result["packetItems"]:
                raise ValueError("temporal auditor owner mapping item is invalid")
            key = (pair, pass_number)
            if key in by_key:
                raise ValueError("temporal auditor owner mapping item is duplicated")
            by_key[key] = {
                "judgment": result["judgments"][opaque_id],
                "reference": result["packetItems"][opaque_id]["reference"],
                "packetItem": result["packetItems"][opaque_id],
                "opaqueID": opaque_id,
            }
        keys = set(by_key)
        if canonical_keys is None:
            canonical_keys = keys
        elif keys != canonical_keys:
            raise ValueError("temporal auditors do not cover the same references")
        loaded.append(by_key)
    pairs = {pair for pair, _ in canonical_keys or set()}
    if len(pairs) != 15 or any(
        (pair, pass_number) not in (canonical_keys or set())
        for pair in pairs for pass_number in (1, 2)
    ):
        raise ValueError("temporal audit does not cover the locked 15 duplicate pairs")
    for key in canonical_keys or set():
        if loaded[0][key]["reference"] != loaded[1][key]["reference"]:
            raise ValueError("temporal auditors received different references")
    return loaded


def _decision_fields(judgment: dict[str, Any]) -> dict[tuple[str, str], bool]:
    return {
        (slot, field): decision[field]
        for slot, decision in judgment["slots"].items()
        for field in ("correct", "materialFalse")
    }


def _audit_disagreements(
    loaded: list[dict[tuple[str, int], dict[str, Any]]],
) -> dict[tuple[str, int], list[tuple[str, str]]]:
    differences = {}
    for key in loaded[0]:
        first = _decision_fields(loaded[0][key]["judgment"])
        second = _decision_fields(loaded[1][key]["judgment"])
        if set(first) != set(second):
            raise ValueError("temporal auditor judgment shapes differ")
        fields = [field for field in first if first[field] != second[field]]
        if fields:
            differences[key] = sorted(fields)
    return differences


def _build_tiebreak(
    audit: Path,
    staging: Path,
    seed_hash: str,
    differences: dict[tuple[str, int], list[tuple[str, str]]],
    loaded: list[dict[tuple[str, int], dict[str, Any]]],
) -> tuple[Path, dict[str, tuple[str, int]]]:
    root = staging / "tiebreak"
    make_private_directory(root)
    make_private_directory(root / "images")
    items = []
    owners = {}
    owner_tokens = {pair for pair, _ in differences}
    source_root = audit / "packets" / "auditor-01"
    for key in sorted(differences):
        pair, pass_number = key
        source = loaded[0][key]
        opaque_id = "tie-" + _digest(
            f"{seed_hash}:tiebreak:{pair}:{pass_number}"
        )[:24]
        images = []
        for index, relative in enumerate(source["packetItem"]["images"], start=1):
            source_path = (source_root / relative).resolve(strict=True)
            if source_root not in source_path.parents or source_path.is_symlink() \
                    or not source_path.is_file():
                raise ValueError("temporal tiebreak source image is invalid")
            destination = f"images/{opaque_id}-{index}{source_path.suffix.lower()}"
            copy_private(source_path, root / destination)
            images.append(destination)
        items.append({
            "opaqueID": opaque_id,
            "targetType": "temporal-pair",
            "reference": source["reference"],
            "images": images,
            "disputed": [
                {"slot": slot, "field": field}
                for slot, field in differences[key]
            ],
        })
        owners[opaque_id] = key
    items.sort(key=lambda item: _digest(f"{seed_hash}:tie-order:{item['opaqueID']}"))
    packet = {
        "schema": TIEBREAK_PACKET_SCHEMA,
        "protocol": PROTOCOL,
        "rubricVersion": RUBRIC,
        "packetID": "tiebreak-" + _digest(
            f"{seed_hash}:tiebreak-packet:{len(differences)}"
        )[:24],
        "candidateOutputsAvailable": False,
        "items": items,
    }
    _reject_leaks(packet, "temporal tiebreak packet", owner_tokens)
    atomic_private_json(root / "packet.json", packet)
    atomic_private_json(staging / "tiebreak-owner-mapping.json", {
        "schema": "screen-understanding-temporal-tiebreak-owner-mapping-v4",
        "protocol": PROTOCOL,
        "rubricVersion": RUBRIC,
        "candidateOutputsAvailable": False,
        "items": {
            opaque_id: {"pair": key[0], "pass": key[1]}
            for opaque_id, key in owners.items()
        },
    })
    return root / "packet.json", owners


def _validate_tiebreak(
    packet_path: Path,
    output_path: Path,
    receipt_path: Path,
    owner_mapping: dict[str, tuple[str, int]],
) -> tuple[dict[tuple[str, int], dict[tuple[str, str], bool]], dict[str, Any]]:
    packet, _ = _load_json(packet_path, "temporal tiebreak packet")
    output, _ = _load_json(output_path, "temporal tiebreak output")
    receipt = validate_receipt(
        receipt_path,
        packet_path,
        output_path,
        "correctness-tiebreak",
    )
    exact_keys(packet, {
        "schema", "protocol", "rubricVersion", "packetID",
        "candidateOutputsAvailable", "items",
    }, "temporal tiebreak packet")
    if packet["schema"] != TIEBREAK_PACKET_SCHEMA or packet["protocol"] != PROTOCOL \
            or packet["rubricVersion"] != RUBRIC \
            or packet["candidateOutputsAvailable"] is not False:
        raise ValueError("temporal tiebreak packet metadata is invalid")
    expected = {}
    for item in packet["items"]:
        exact_keys(item, {
            "opaqueID", "targetType", "reference", "images", "disputed",
        }, "temporal tiebreak item")
        identifier = item["opaqueID"]
        if identifier not in owner_mapping or identifier in expected:
            raise ValueError("temporal tiebreak identity is invalid")
        disputes = set()
        for dispute in item["disputed"]:
            exact_keys(dispute, {"slot", "field"}, "temporal tiebreak dispute")
            key = (dispute["slot"], dispute["field"])
            if dispute["slot"] not in AUDIT_SLOTS \
                    or dispute["field"] not in {"correct", "materialFalse"} \
                    or key in disputes:
                raise ValueError("temporal tiebreak dispute is invalid")
            disputes.add(key)
        if not disputes:
            raise ValueError("temporal tiebreak disputes are missing")
        expected[identifier] = disputes
    exact_keys(output, {
        "schema", "protocol", "rubricVersion", "packetID", "auditor",
        "candidateOutputsAvailable", "items",
    }, "temporal tiebreak output")
    if output["schema"] != TIEBREAK_OUTPUT_SCHEMA or output["protocol"] != PROTOCOL \
            or output["rubricVersion"] != RUBRIC \
            or output["packetID"] != packet["packetID"] \
            or output["candidateOutputsAvailable"] is not False \
            or not isinstance(output["auditor"], str) \
            or not SAFE_ID.fullmatch(output["auditor"]):
        raise ValueError("temporal tiebreak output metadata is invalid")
    values = {}
    for item in output["items"]:
        exact_keys(item, {"opaqueID", "decisions"}, "temporal tiebreak judgment")
        identifier = item["opaqueID"]
        if identifier not in expected or identifier in values:
            raise ValueError("temporal tiebreak judgment identity is invalid")
        decisions = {}
        for decision in item["decisions"]:
            exact_keys(decision, {"slot", "field", "value"}, "temporal tiebreak decision")
            key = (decision["slot"], decision["field"])
            if key not in expected[identifier] or key in decisions \
                    or not isinstance(decision["value"], bool):
                raise ValueError("temporal tiebreak decision is invalid")
            decisions[key] = decision["value"]
        if set(decisions) != expected[identifier]:
            raise ValueError("temporal tiebreak decisions do not match disagreements")
        values[identifier] = decisions
    if set(values) != set(expected):
        raise ValueError("temporal tiebreak output does not cover the packet")
    by_owner = {
        owner_mapping[opaque_id]: decisions
        for opaque_id, decisions in values.items()
    }
    _reject_leaks(output, "temporal tiebreak output")
    return by_owner, receipt


def _resolve_audit_fields(
    loaded: list[dict[tuple[str, int], dict[str, Any]]],
    differences: dict[tuple[str, int], list[tuple[str, str]]],
    tiebreak_values: dict[tuple[str, int], dict[tuple[str, str], bool]],
) -> dict[tuple[str, int], dict[tuple[str, str], bool]]:
    resolved = {}
    for key in loaded[0]:
        first = _decision_fields(loaded[0][key]["judgment"])
        second = _decision_fields(loaded[1][key]["judgment"])
        values = {}
        for field in first:
            if first[field] == second[field]:
                values[field] = first[field]
            else:
                if key not in tiebreak_values or field not in tiebreak_values[key]:
                    raise ValueError("tiebreak does not resolve every disagreement")
                values[field] = tiebreak_values[key][field]
        resolved[key] = values
    return resolved


def _slot_is_clean(fields: dict[tuple[str, str], bool], slot: str) -> bool:
    return fields[(slot, "correct")] and not fields[(slot, "materialFalse")]


def _merge_reference(
    first: dict[str, Any],
    second: dict[str, Any],
    slot_sources: dict[str, str],
) -> dict[str, Any]:
    merged = copy.deepcopy(first)
    required_index = {"surface": 0, "content": 1, "state": 2}
    for slot, index in required_index.items():
        source = first if slot_sources[slot] == "pass1" else second
        merged["requiredFacts"][index] = copy.deepcopy(source["requiredFacts"][index])
    source = first if slot_sources["primaryChange"] == "pass1" else second
    merged["meaningfulChange"] = copy.deepcopy(source["meaningfulChange"])
    source = first if slot_sources["ambiguityAbstention"] == "pass1" else second
    merged["ambiguity"] = source["ambiguity"]
    merged["abstentionAllowed"] = source["abstentionAllowed"]
    _validate_reference(merged)
    return merged


def _score_and_select(
    resolved: dict[tuple[str, int], dict[tuple[str, str], bool]],
    loaded: list[dict[tuple[str, int], dict[str, Any]]],
) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, dict[str, Any]]]:
    pairs = sorted({pair for pair, _ in resolved})
    if len(pairs) != 15:
        raise ValueError("temporal scoring pair count is invalid")
    pass_correct = {1: 0, 2: 0}
    joint_correct = 0
    material_false = {1: 0, 2: 0}
    selections = []
    selected = {}
    for pair in pairs:
        clean = {1: {}, 2: {}}
        for pass_number in (1, 2):
            fields = resolved[(pair, pass_number)]
            for slot in AUDIT_SLOTS:
                clean[pass_number][slot] = _slot_is_clean(fields, slot)
                pass_correct[pass_number] += int(clean[pass_number][slot])
                material_false[pass_number] += int(fields[(slot, "materialFalse")])
        joint_correct += sum(
            clean[1][slot] and clean[2][slot] for slot in AUDIT_SLOTS
        )
        if all(clean[1].values()):
            decision = "pass1"
        elif all(clean[2].values()):
            decision = "pass2"
        else:
            decision = "merge"
        slot_sources = {
            slot: "pass1" if clean[1][slot] else "pass2" if clean[2][slot] else "pass1"
            for slot in AUDIT_SLOTS
        }
        first = loaded[0][(pair, 1)]["reference"]
        second = loaded[0][(pair, 2)]["reference"]
        selected[pair] = copy.deepcopy(
            first if decision == "pass1" else second if decision == "pass2"
            else _merge_reference(first, second, slot_sources)
        )
        selections.append({
            "pair": pair,
            "selectedReference": decision,
            "slotSources": slot_sources,
        })
    opportunity_count = len(pairs) * len(AUDIT_SLOTS)
    if opportunity_count != 75:
        raise ValueError("temporal opportunity denominator must be exactly 75")
    required_correct_count = 68
    qualified = joint_correct >= required_correct_count
    result = {
        "schema": "screen-understanding-temporal-correctness-result-v4",
        "protocol": PROTOCOL,
        "rubricVersion": RUBRIC,
        "state": "complete",
        "opportunityCount": opportunity_count,
        "pass1CorrectCount": pass_correct[1],
        "pass2CorrectCount": pass_correct[2],
        "jointCorrectCount": joint_correct,
        "pass1Rate": pass_correct[1] / opportunity_count,
        "pass2Rate": pass_correct[2] / opportunity_count,
        "jointRate": joint_correct / opportunity_count,
        "materialFalseCount": {
            "pass1": material_false[1],
            "pass2": material_false[2],
        },
        "rawJointGate": {
            "minimum": RAW_JOINT_FLOOR,
            "requiredCorrectCount": required_correct_count,
            "qualified": qualified,
        },
        "selection": {
            "pass1": sum(item["selectedReference"] == "pass1" for item in selections),
            "pass2": sum(item["selectedReference"] == "pass2" for item in selections),
            "merge": sum(item["selectedReference"] == "merge" for item in selections),
        },
        "finalAudit": {
            "state": "pending",
            "materialFalseCount": None,
            "qualified": False,
        },
        "candidateOutputsAvailable": False,
        "qualified": False,
    }
    return result, selections, selected


def _copy_aggregate_sources(
    audit: Path,
    destination: Path,
    auditor_one: Path,
    receipt_one: Path,
    auditor_two: Path,
    receipt_two: Path,
    tiebreak_packet: Path | None,
    tiebreak_output: Path | None,
    tiebreak_receipt: Path | None,
) -> None:
    copy_private(
        audit / "sources" / "work-owner-mapping.json",
        destination / "work-owner-mapping.json",
    )
    for pass_number in (1, 2):
        for kind in ("packet", "output", "receipt"):
            source = audit / "sources" / f"pass{pass_number}-{kind}.json"
            copy_private(source, destination / f"pass{pass_number}-{kind}.json")
    for number, (output, receipt) in enumerate((
        (auditor_one, receipt_one), (auditor_two, receipt_two),
    ), start=1):
        copy_private(
            audit / "packets" / f"auditor-{number:02d}" / "packet.json",
            destination / f"auditor{number}-packet.json",
        )
        copy_private(
            validate_private_input_file(output),
            destination / f"auditor{number}-output.json",
        )
        copy_private(
            validate_private_input_file(receipt),
            destination / f"auditor{number}-receipt.json",
        )
    if tiebreak_packet is not None:
        copy_private(tiebreak_packet, destination / "tiebreak-packet.json")
        copy_private(
            validate_private_input_file(tiebreak_output),
            destination / "tiebreak-output.json",
        )
        copy_private(
            validate_private_input_file(tiebreak_receipt),
            destination / "tiebreak-receipt.json",
        )


def prepare_final(
    work_root: Path,
    aggregate_root: Path,
    output_root: Path,
    seed: str,
) -> dict:
    output = validate_private_output(output_root)
    work = validate_private_input(work_root)
    aggregate_root = validate_private_input(aggregate_root)
    if not isinstance(seed, str) or not seed:
        raise ValueError("temporal final audit seed is required")
    for left, right in ((output, work), (output, aggregate_root)):
        if left == right or left in right.parents or right in left.parents:
            raise ValueError("temporal final audit roots must be disjoint")
    result, _ = _load_json(
        aggregate_root / "result.json", "temporal aggregate result"
    )
    expected_result_keys = {
        "schema", "protocol", "rubricVersion", "state", "opportunityCount",
        "pass1CorrectCount", "pass2CorrectCount", "jointCorrectCount",
        "pass1Rate", "pass2Rate", "jointRate", "materialFalseCount",
        "rawJointGate", "selection", "finalAudit", "candidateOutputsAvailable",
        "qualified", "artifacts",
    }
    exact_keys(result, expected_result_keys, "temporal aggregate result")
    if result["schema"] != "screen-understanding-temporal-correctness-result-v4" \
            or result["protocol"] != PROTOCOL or result["rubricVersion"] != RUBRIC \
            or result["state"] != "complete" \
            or result["candidateOutputsAvailable"] is not False \
            or result["opportunityCount"] != 75:
        raise ValueError("temporal aggregate result is not complete")
    gate = result["rawJointGate"]
    exact_keys(gate, {"minimum", "requiredCorrectCount", "qualified"}, "raw joint gate")
    if gate != {
        "minimum": RAW_JOINT_FLOOR,
        "requiredCorrectCount": 68,
        "qualified": result["jointCorrectCount"] >= 68,
    } or gate["qualified"] is not True:
        raise ValueError("temporal raw joint gate does not clear the fixed 0.90 floor")
    artifacts = result["artifacts"]
    exact_keys(artifacts, {
        "sessionContextSHA256", "selectionSHA256", "selectedLabelsSHA256",
    }, "temporal aggregate artifacts")
    artifact_paths = {
        "sessionContextSHA256": aggregate_root / "session-context.json",
        "selectionSHA256": aggregate_root / "selection.json",
        "selectedLabelsSHA256": aggregate_root / "selected-labels.json",
    }
    if any(
        not isinstance(artifacts[key], str)
        or artifacts[key] != file_evidence(path)["sha256"]
        for key, path in artifact_paths.items()
    ):
        raise ValueError("temporal aggregate artifact binding is invalid")
    prior_receipts = _validate_copied_receipts(
        aggregate_root / "sources",
        aggregate_root / "session-context.json",
    )

    selected_payload, _ = _load_json(
        aggregate_root / "selected-labels.json", "temporal selected labels"
    )
    exact_keys(selected_payload, {
        "schema", "protocol", "rubricVersion", "candidateOutputsAvailable", "items",
    }, "temporal selected labels")
    if selected_payload["schema"] != "screen-understanding-temporal-selected-labels-v4" \
            or selected_payload["protocol"] != PROTOCOL \
            or selected_payload["rubricVersion"] != RUBRIC \
            or selected_payload["candidateOutputsAvailable"] is not False:
        raise ValueError("temporal selected label metadata is invalid")
    selected = {}
    for item in selected_payload["items"]:
        exact_keys(item, {"pair", "reference"}, "temporal selected label")
        pair = item["pair"]
        if not isinstance(pair, str) or not CASE_ID.fullmatch(pair) or pair in selected:
            raise ValueError("temporal selected label pair is invalid")
        selected[pair] = _validate_reference(item["reference"])
    if len(selected) != 15:
        raise ValueError("temporal selected labels must cover exactly 15 pairs")
    selection_payload, _ = _load_json(
        aggregate_root / "selection.json", "temporal selection"
    )
    exact_keys(selection_payload, {
        "schema", "protocol", "rubricVersion", "candidateOutputsAvailable", "items",
    }, "temporal selection")
    if selection_payload["schema"] != "screen-understanding-temporal-selection-v4" \
            or selection_payload["protocol"] != PROTOCOL \
            or selection_payload["rubricVersion"] != RUBRIC \
            or selection_payload["candidateOutputsAvailable"] is not False:
        raise ValueError("temporal selection metadata is invalid")
    selection_pairs = set()
    for item in selection_payload["items"]:
        exact_keys(item, {"pair", "selectedReference", "slotSources"}, "selection item")
        if item["pair"] in selection_pairs or item["pair"] not in selected \
                or item["selectedReference"] not in {"pass1", "pass2", "merge"}:
            raise ValueError("temporal selection item is invalid")
        exact_keys(item["slotSources"], set(AUDIT_SLOTS), "selection slot sources")
        if any(value not in {"pass1", "pass2"} for value in item["slotSources"].values()):
            raise ValueError("temporal selection slot source is invalid")
        selection_pairs.add(item["pair"])
    if selection_pairs != set(selected):
        raise ValueError("temporal selection and selected labels do not cross-link")

    work_mapping, _ = _load_json(work / "owner-mapping.json", "temporal owner mapping")
    pass1_owners = work_mapping.get("passes", {}).get("pass1") \
        if isinstance(work_mapping, dict) else None
    if not isinstance(pass1_owners, dict) or len(pass1_owners) != 100:
        raise ValueError("temporal pass1 owner mapping is invalid")
    reverse = {}
    for opaque_id, owner in pass1_owners.items():
        if not isinstance(owner, dict) or set(owner) != {"pair", "before", "after"} \
                or owner["pair"] in reverse:
            raise ValueError("temporal pass1 owner item is invalid")
        reverse[owner["pair"]] = (opaque_id, owner)
    work_packet, _ = _load_json(work / "packets" / "pass1.json", "pass1 packet")
    work_items = _validate_work_packet(work_packet)
    if not set(selected).issubset(reverse):
        raise ValueError("temporal selected pairs are absent from pass1 work")

    output, staging = prepare_private_output(output)
    try:
        make_private_directory(staging / "packet")
        make_private_directory(staging / "packet" / "images")
        make_private_directory(staging / "sources")
        items = []
        owner_items = {}
        owner_tokens = set(selected)
        packet_root = staging / "packet"
        for pair in sorted(selected):
            source_opaque, owner = reverse[pair]
            owner_tokens.update((owner["before"], owner["after"]))
            source_item = work_items[source_opaque]
            opaque_id = "final-" + _digest(f"{seed}:final:{pair}")[:24]
            images = []
            for index, key in enumerate(("beforeImage", "afterImage"), start=1):
                source = (work / source_item[key]).resolve(strict=True)
                if work not in source.parents or source.is_symlink() or not source.is_file():
                    raise ValueError("temporal final source image is invalid")
                relative = f"images/{opaque_id}-{index}{source.suffix.lower()}"
                copy_private(source, packet_root / relative)
                images.append(relative)
            items.append({
                "opaqueID": opaque_id,
                "targetType": "temporal-pair",
                "reference": selected[pair],
                "images": images,
            })
            owner_items[opaque_id] = {"pair": pair}
        items.sort(key=lambda item: _digest(f"{seed}:final-order:{item['opaqueID']}"))
        packet = {
            "schema": FINAL_PACKET_SCHEMA,
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "packetID": "final-packet-" + _digest(f"{seed}:final-packet")[:24],
            "candidateOutputsAvailable": False,
            "items": items,
        }
        _reject_leaks(packet, "temporal final audit packet", owner_tokens)
        atomic_private_json(packet_root / "packet.json", packet)
        atomic_private_json(staging / "owner-mapping.json", {
            "schema": "screen-understanding-temporal-final-owner-mapping-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "candidateOutputsAvailable": False,
            "items": owner_items,
        })
        for source in sorted((aggregate_root / "sources").glob("*.json")):
            copy_private(source, staging / "sources" / source.name)
        for name in ("result", "session-context", "selection", "selected-labels"):
            copy_private(
                aggregate_root / f"{name}.json",
                staging / "sources" / f"aggregate-{name}.json",
            )
        manifest = {
            "schema": "screen-understanding-temporal-final-audit-manifest-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "pairCount": 15,
            "opportunitiesPerPair": 5,
            "opportunityCount": 75,
            "priorSessionCount": len(prior_receipts),
            "candidateOutputsAvailable": False,
        }
        atomic_private_json(staging / "final-audit-manifest.json", manifest)
        publish_private_output(staging, output)
        return manifest
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def _validate_copied_receipts(
    sources: Path,
    session_context_path: Path,
) -> list[dict[str, Any]]:
    receipts = []
    for pass_number in (1, 2):
        receipts.append(validate_receipt(
            sources / f"pass{pass_number}-receipt.json",
            sources / f"pass{pass_number}-packet.json",
            sources / f"pass{pass_number}-output.json",
            f"annotation-pass{pass_number}",
        ))
    for number in (1, 2):
        receipts.append(validate_receipt(
            sources / f"auditor{number}-receipt.json",
            sources / f"auditor{number}-packet.json",
            sources / f"auditor{number}-output.json",
            f"correctness-auditor-{number}",
        ))
    required_roles = {
        "annotation-pass1", "annotation-pass2", "correctness-auditor-1",
        "correctness-auditor-2",
    }
    tiebreak_files = [
        sources / f"tiebreak-{kind}.json"
        for kind in ("packet", "output", "receipt")
    ]
    if any(path.exists() or path.is_symlink() for path in tiebreak_files):
        if not all(path.is_file() and not path.is_symlink() for path in tiebreak_files):
            raise ValueError("temporal tiebreak source artifacts are incomplete")
        receipts.append(validate_receipt(
            tiebreak_files[2],
            tiebreak_files[0],
            tiebreak_files[1],
            "correctness-tiebreak",
        ))
        required_roles.add("correctness-tiebreak")
    validate_independent_sessions(receipts, required_roles)
    context, _ = _load_json(session_context_path, "temporal session context")
    exact_keys(context, {
        "schema", "protocol", "rubricVersion", "candidateOutputsAvailable", "receipts",
    }, "temporal session context")
    if context["schema"] != "screen-understanding-temporal-session-context-v4" \
            or context["protocol"] != PROTOCOL or context["rubricVersion"] != RUBRIC \
            or context["candidateOutputsAvailable"] is not False \
            or context["receipts"] != receipts:
        raise ValueError("temporal session context does not bind prior receipts")
    return receipts


def _validate_final_packet(packet: dict[str, Any]) -> dict[str, dict[str, Any]]:
    exact_keys(packet, {
        "schema", "protocol", "rubricVersion", "packetID",
        "candidateOutputsAvailable", "items",
    }, "temporal final audit packet")
    if packet["schema"] != FINAL_PACKET_SCHEMA or packet["protocol"] != PROTOCOL \
            or packet["rubricVersion"] != RUBRIC \
            or packet["candidateOutputsAvailable"] is not False \
            or not isinstance(packet["packetID"], str) \
            or not SAFE_ID.fullmatch(packet["packetID"]):
        raise ValueError("temporal final audit packet metadata is invalid")
    if not isinstance(packet["items"], list) or len(packet["items"]) != 15:
        raise ValueError("temporal final audit must contain exactly 15 pairs")
    by_id = {}
    for item in packet["items"]:
        exact_keys(item, {
            "opaqueID", "targetType", "reference", "images",
        }, "temporal final audit item")
        identifier = item["opaqueID"]
        if not isinstance(identifier, str) or not SAFE_ID.fullmatch(identifier) \
                or identifier in by_id or item["targetType"] != "temporal-pair":
            raise ValueError("temporal final audit item identity is invalid")
        _validate_reference(item["reference"])
        if not isinstance(item["images"], list) or len(item["images"]) != 2:
            raise ValueError("temporal final audit item images are invalid")
        by_id[identifier] = item
    return by_id


def finalize(
    final_audit_root: Path,
    final_output: Path,
    final_receipt: Path,
    output_root: Path,
) -> dict:
    output = validate_private_output(output_root)
    final_root = validate_private_input(final_audit_root)
    if final_root == output or final_root in output.parents or output in final_root.parents:
        raise ValueError("final audit and temporal output roots must be disjoint")
    manifest, _ = _load_json(
        final_root / "final-audit-manifest.json", "temporal final audit manifest"
    )
    exact_keys(manifest, {
        "schema", "protocol", "rubricVersion", "pairCount",
        "opportunitiesPerPair", "opportunityCount", "priorSessionCount",
        "candidateOutputsAvailable",
    }, "temporal final audit manifest")
    if manifest["schema"] != "screen-understanding-temporal-final-audit-manifest-v4" \
            or manifest["protocol"] != PROTOCOL or manifest["rubricVersion"] != RUBRIC \
            or manifest["pairCount"] != 15 or manifest["opportunitiesPerPair"] != 5 \
            or manifest["opportunityCount"] != 75 \
            or manifest["candidateOutputsAvailable"] is not False:
        raise ValueError("temporal final audit manifest is invalid")
    packet_path = final_root / "packet" / "packet.json"
    packet, _ = _load_json(packet_path, "temporal final audit packet")
    packet_items = _validate_final_packet(packet)
    output_payload, _ = _load_json(final_output, "temporal final audit output")
    _assert_owner_only_file(
        validate_private_input_file(final_output), "temporal final audit output"
    )
    receipt = validate_receipt(
        final_receipt,
        packet_path,
        final_output,
        "final-reference-auditor",
    )
    prior_receipts = _validate_copied_receipts(
        final_root / "sources",
        final_root / "sources" / "aggregate-session-context.json",
    )
    pass1 = validate_labels(
        final_root / "sources" / "pass1-packet.json",
        final_root / "sources" / "pass1-output.json",
        final_root / "sources" / "pass1-receipt.json",
        "annotation-pass1",
    )
    pass2 = validate_labels(
        final_root / "sources" / "pass2-packet.json",
        final_root / "sources" / "pass2-output.json",
        final_root / "sources" / "pass2-receipt.json",
        "annotation-pass2",
    )
    work_mapping, _ = _load_json(
        final_root / "sources" / "work-owner-mapping.json",
        "temporal work owner mapping",
    )
    exact_keys(work_mapping, {
        "schema", "protocol", "rubricVersion", "seedSHA256",
        "candidateOutputsAvailable", "passes",
    }, "temporal work owner mapping")
    passes = work_mapping.get("passes")
    pass1_owners = passes.get("pass1") if isinstance(passes, dict) else None
    if work_mapping["schema"] != "screen-understanding-temporal-owner-mapping-v4" \
            or work_mapping["protocol"] != PROTOCOL \
            or work_mapping["rubricVersion"] != RUBRIC \
            or work_mapping["candidateOutputsAvailable"] is not False \
            or not isinstance(pass1_owners, dict) \
            or len(pass1_owners) != 100 \
            or set(pass1_owners) != set(pass1["labels"]):
        raise ValueError("temporal pass1 owner mapping is invalid")
    all_pairs = set()
    for opaque_id, owner in pass1_owners.items():
        exact_keys(owner, {"pair", "before", "after"}, "temporal pass1 owner")
        if any(
            not isinstance(owner[key], str) or not CASE_ID.fullmatch(owner[key])
            for key in ("pair", "before", "after")
        ) or owner["pair"] in all_pairs:
            raise ValueError("temporal pass1 owner identity is invalid")
        all_pairs.add(owner["pair"])
    required_roles = {value["role"] for value in prior_receipts}
    independence = validate_independent_sessions(
        [*prior_receipts, receipt],
        {*required_roles, "final-reference-auditor"},
    )
    if manifest["priorSessionCount"] != len(prior_receipts):
        raise ValueError("temporal final audit prior session count changed")
    exact_keys(output_payload, {
        "schema", "protocol", "rubricVersion", "packetID", "auditor",
        "candidateOutputsAvailable", "items",
    }, "temporal final audit output")
    if output_payload["schema"] != FINAL_OUTPUT_SCHEMA \
            or output_payload["protocol"] != PROTOCOL \
            or output_payload["rubricVersion"] != RUBRIC \
            or output_payload["packetID"] != packet["packetID"] \
            or output_payload["candidateOutputsAvailable"] is not False \
            or not isinstance(output_payload["auditor"], str) \
            or not SAFE_ID.fullmatch(output_payload["auditor"]):
        raise ValueError("temporal final audit output metadata is invalid")
    prior_auditors = {
        json.loads(
            (final_root / "sources" / f"auditor{number}-output.json").read_text()
        )["auditor"]
        for number in (1, 2)
    }
    if output_payload["auditor"] in prior_auditors:
        raise ValueError("temporal final auditor identity must be fresh")
    judgments = {}
    if not isinstance(output_payload["items"], list) \
            or len(output_payload["items"]) != 15:
        raise ValueError("temporal final audit output must cover exactly 15 pairs")
    material_false_count = 0
    incorrect_count = 0
    for item in output_payload["items"]:
        exact_keys(item, {"opaqueID", "slots"}, "temporal final audit judgment")
        identifier = item["opaqueID"]
        if identifier not in packet_items or identifier in judgments:
            raise ValueError("temporal final audit judgment identity is invalid")
        exact_keys(item["slots"], set(AUDIT_SLOTS), "temporal final audit slots")
        for slot, decision in item["slots"].items():
            exact_keys(decision, {"correct", "materialFalse"}, f"final {slot} decision")
            if not isinstance(decision["correct"], bool) \
                    or not isinstance(decision["materialFalse"], bool) \
                    or decision["materialFalse"] and decision["correct"]:
                raise ValueError("temporal final audit decisions are invalid")
            material_false_count += int(decision["materialFalse"])
            incorrect_count += int(not decision["correct"])
        judgments[identifier] = item
    if set(judgments) != set(packet_items):
        raise ValueError("temporal final audit does not cover the packet")
    if material_false_count != 0:
        raise ValueError("temporal final audit requires zero material false facts")
    if incorrect_count != 0:
        raise ValueError("temporal final audit requires all 75 opportunities to be correct")
    _reject_leaks(output_payload, "temporal final audit output")
    owner_mapping, _ = _load_json(
        final_root / "owner-mapping.json", "temporal final owner mapping"
    )
    exact_keys(owner_mapping, {
        "schema", "protocol", "rubricVersion", "candidateOutputsAvailable", "items",
    }, "temporal final owner mapping")
    if owner_mapping["schema"] != "screen-understanding-temporal-final-owner-mapping-v4" \
            or owner_mapping["protocol"] != PROTOCOL \
            or owner_mapping["rubricVersion"] != RUBRIC \
            or owner_mapping["candidateOutputsAvailable"] is not False \
            or set(owner_mapping["items"]) != set(packet_items):
        raise ValueError("temporal final owner mapping is invalid")
    selected_references = {}
    for opaque_id, packet_item in packet_items.items():
        owner = owner_mapping["items"][opaque_id]
        exact_keys(owner, {"pair"}, "temporal final owner item")
        pair = owner["pair"]
        if not isinstance(pair, str) or not CASE_ID.fullmatch(pair):
            raise ValueError("temporal final owner pair is invalid")
        selected_references[pair] = copy.deepcopy(packet_item["reference"])
    if not set(selected_references).issubset(all_pairs):
        raise ValueError("temporal final references are outside the pass1 corpus")
    selection_payload, _ = _load_json(
        final_root / "sources" / "aggregate-selection.json",
        "temporal aggregate selection",
    )
    exact_keys(selection_payload, {
        "schema", "protocol", "rubricVersion", "candidateOutputsAvailable", "items",
    }, "temporal aggregate selection")
    if selection_payload["schema"] != "screen-understanding-temporal-selection-v4" \
            or selection_payload["protocol"] != PROTOCOL \
            or selection_payload["rubricVersion"] != RUBRIC \
            or selection_payload["candidateOutputsAvailable"] is not False:
        raise ValueError("temporal aggregate selection metadata is invalid")
    selected_modes = {}
    for item in selection_payload["items"]:
        exact_keys(item, {"pair", "selectedReference", "slotSources"}, "selection item")
        pair = item["pair"]
        decision = item["selectedReference"]
        if pair in selected_modes or pair not in selected_references \
                or decision not in {"pass1", "pass2", "merge"}:
            raise ValueError("temporal aggregate selection item is invalid")
        selected_modes[pair] = decision
    if set(selected_modes) != set(selected_references):
        raise ValueError("temporal aggregate selection does not cover final references")
    labels = []
    for opaque_id, owner in pass1_owners.items():
        pair = owner["pair"]
        reference = selected_references.get(pair)
        if reference is None:
            reference = _reference_from_label(pass1["labels"][opaque_id])
            mode = "pass1-base"
            annotator = pass1["annotator"]
        else:
            decision = selected_modes[pair]
            mode = f"selected-{decision}"
            annotator = (
                pass1["annotator"] if decision == "pass1"
                else pass2["annotator"] if decision == "pass2"
                else "frontier-temporal-merge-v4"
            )
        labels.append({
            "pair": pair,
            "targetType": "temporal-pair",
            **copy.deepcopy(reference),
            "locked": True,
            "annotation": {
                "producer": "frontier-vlm",
                "mode": mode,
                "annotator": annotator,
                "rubricVersion": RUBRIC,
                "blindedToCandidateOutputs": True,
                "candidateOutputsAvailable": False,
            },
        })
    labels.sort(key=lambda item: item["pair"])
    aggregate_result, _ = _load_json(
        final_root / "sources" / "aggregate-result.json",
        "temporal aggregate result",
    )
    result = {
        "schema": "screen-understanding-temporal-final-result-v4",
        "protocol": PROTOCOL,
        "rubricVersion": RUBRIC,
        "pairCount": 100,
        "auditPairCount": 15,
        "opportunityCount": 75,
        "materialFalseCount": 0,
        "incorrectCount": 0,
        "candidateOutputsAvailable": False,
        "qualified": True,
    }
    output, staging = prepare_private_output(output)
    try:
        atomic_private_json(staging / "labels.json", {
            "schema": "screen-understanding-temporal-final-labels-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "candidateOutputsAvailable": False,
            "labels": labels,
        })
        atomic_private_json(staging / "reliability.json", {
            "schema": "screen-understanding-temporal-reliability-v4",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "rawJoint": {
                "minimum": aggregate_result["rawJointGate"]["minimum"],
                "correctCount": aggregate_result["jointCorrectCount"],
                "opportunityCount": 75,
                "rate": aggregate_result["jointRate"],
                "qualified": aggregate_result["rawJointGate"]["qualified"],
            },
            "finalAudit": {
                "auditor": output_payload["auditor"],
                "pairCount": 15,
                "opportunityCount": 75,
                "materialFalseCount": 0,
                "incorrectCount": 0,
                "qualified": True,
            },
            "independence": independence,
            "candidateOutputsAvailable": False,
            "qualified": True,
        })
        atomic_private_json(staging / "result.json", result)
        publish_private_output(staging, output)
        return result
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
