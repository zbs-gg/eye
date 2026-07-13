#!/usr/bin/python3
"""Prepare blinded claim mapping packets and deterministically score judgments."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import math
import os
import re
import shutil
import stat
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any, Optional


RUNNER_DIRECTORY = Path(__file__).parents[1] / "runner"
sys.path.insert(0, str(RUNNER_DIRECTORY))

from preflight import (  # noqa: E402
    _reject_private_payload,
    _validate_labels,
    _validate_reliability,
)


PROTOCOL = "screen-understanding-correctness-audit-v3"
RUBRIC = "screen-understanding-canonical-v2"
PACKET_SCHEMA = "screen-understanding-claim-mapping-packet-v1"
MAPPING_SCHEMA = "screen-understanding-claim-owner-mapping-v1"
JUDGMENT_SCHEMA = "screen-understanding-claim-judgments-v1"
ADJUDICATION_PACKET_SCHEMA = "screen-understanding-claim-adjudication-packet-v1"
ADJUDICATION_SCHEMA = "screen-understanding-claim-adjudication-v1"
PUBLIC_SCHEMA = "screen-understanding-public-claim-scores-v1"
RUN_SCHEMA = "screen-understanding-built-in-run-v1"
RECORD_SCHEMA = "screen-understanding-built-in-output-v1"
EXPECTED_CASES = 60
DUPLICATE_FRACTION = 0.15
CLAIM_AGREEMENT_FLOOR = 0.90
DECISION_AGREEMENT_FLOOR = 0.80
METHOD_FILES = {
    "metadata-ax-ocr": "metadata-ax-ocr.jsonl",
    "apple-vision": "apple-vision.jsonl",
    "deterministic-hybrid": "deterministic-hybrid.jsonl",
}
REQUIRED_FACT_IDS = (
    "required.surface", "required.content", "required.state",
)
FORBIDDEN_FACT_IDS = ("forbidden.intent", "forbidden.outcome")
SEVERITY_WEIGHTS = {"minor": 0.25, "major": 0.60, "critical": 1.0}
SAFE_ID = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
CASE_ID = re.compile(r"^[0-9a-f]{24}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
FORBIDDEN_FRAGMENTS = ("/Users/", "/Volumes/", "file://")
PACKET_FORBIDDEN_KEYS = {
    "methodid", "caseid", "candidateoutput", "candidateoutputs",
    "timing", "timings", "split", "splits",
}


class MappingError(ValueError):
    """The private mapping pipeline must fail closed."""


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _token(seed: str, namespace: str, value: str, length: int = 24) -> str:
    return hashlib.sha256(
        f"{seed}:{namespace}:{value}".encode("utf-8")
    ).hexdigest()[:length]


def _assert_owner_only(path: Path, subject: str, *, directory: bool) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise MappingError(f"{subject} is unavailable") from error
    if path.is_symlink() or (
        directory and not stat.S_ISDIR(metadata.st_mode)
    ) or (not directory and not stat.S_ISREG(metadata.st_mode)):
        raise MappingError(f"{subject} is unavailable")
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise MappingError(f"{subject} must use owner-only permissions")


def _read_private_bytes(path: Path, subject: str) -> bytes:
    _assert_owner_only(path, subject, directory=False)
    try:
        return path.read_bytes()
    except OSError as error:
        raise MappingError(f"{subject} is unavailable") from error


def _load_private_json(path: Path, subject: str) -> tuple[dict[str, Any], bytes]:
    data = _read_private_bytes(path, subject)
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MappingError(f"{subject} is not valid JSON") from error
    if not isinstance(value, dict):
        raise MappingError(f"{subject} root must be an object")
    return value, data


def _json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        .encode("utf-8") + b"\n"
    )


def _atomic_private_json(path: Path, value: Any) -> bytes:
    data = _json_bytes(value)
    temporary = path.with_name(f".{path.name}.tmp-{uuid.uuid4().hex}")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        path.chmod(0o600)
        return data
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def _make_private_directory(path: Path) -> None:
    path.mkdir(mode=0o700)
    path.chmod(0o700)


def _exact_keys(value: Any, expected: set[str], subject: str) -> None:
    if not isinstance(value, dict) or set(value) != expected:
        raise MappingError(f"{subject} keys do not match the locked schema")


def _reject_leaks(
    value: Any,
    *,
    forbidden_values: tuple[str, ...] = (),
    subject: str = "blinded artifact",
) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if lowered in PACKET_FORBIDDEN_KEYS \
                    or lowered.endswith("path") or lowered.endswith("paths"):
                raise MappingError(f"{subject} contains a forbidden field")
            _reject_leaks(
                child, forbidden_values=forbidden_values, subject=subject
            )
    elif isinstance(value, list):
        for child in value:
            _reject_leaks(
                child, forbidden_values=forbidden_values, subject=subject
            )
    elif isinstance(value, str):
        if any(fragment in value for fragment in FORBIDDEN_FRAGMENTS) \
                or any(identifier in value for identifier in forbidden_values):
            raise MappingError(f"{subject} contains a private identifier or path")


def _reject_public_leaks(value: Any) -> None:
    """Allow methodID only inside the locked aggregate method object."""
    forbidden = {
        "caseid", "claimid", "text", "raw", "rawoutput", "errors",
        "owner", "ownermapping", "packetid", "armid", "candidateoutput",
        "candidateoutputs", "timing", "timings", "split", "splits",
    }
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if lowered in forbidden or lowered.endswith("path") or lowered.endswith("paths"):
                raise MappingError("public aggregate contains a forbidden field")
            _reject_public_leaks(child)
    elif isinstance(value, list):
        for child in value:
            _reject_public_leaks(child)
    elif isinstance(value, str) and any(
        fragment in value for fragment in FORBIDDEN_FRAGMENTS
    ):
        raise MappingError("public aggregate contains a private path")


def _validate_reference(label: dict[str, Any]) -> dict[str, Any]:
    if label.get("targetType") != "single-frame":
        raise MappingError("quality run case is not a canonical single frame")
    required = label.get("requiredFacts")
    forbidden = label.get("forbiddenInferences")
    critical = label.get("criticalText")
    if not isinstance(required, list) or [
        item.get("id") if isinstance(item, dict) else None for item in required
    ] != list(REQUIRED_FACT_IDS):
        raise MappingError("canonical required facts are invalid")
    if not isinstance(forbidden, list) or [
        item.get("id") if isinstance(item, dict) else None for item in forbidden
    ] != list(FORBIDDEN_FACT_IDS):
        raise MappingError("canonical forbidden facts are invalid")
    for fact in required:
        _exact_keys(fact, {"id", "text"}, "canonical required fact")
        if not isinstance(fact["text"], str) or not fact["text"].strip():
            raise MappingError("canonical required fact text is invalid")
    for fact in forbidden:
        _exact_keys(fact, {"id", "text", "severity"}, "canonical forbidden fact")
        if not isinstance(fact["text"], str) or not fact["text"].strip() \
                or fact["severity"] not in SEVERITY_WEIGHTS:
            raise MappingError("canonical forbidden fact is invalid")
    if not isinstance(critical, list) or len(critical) > 2 \
            or any(not isinstance(text, str) or not text.strip() for text in critical):
        raise MappingError("canonical critical text is invalid")
    ambiguity = label.get("ambiguity")
    if not isinstance(ambiguity, str) or not ambiguity:
        raise MappingError("canonical ambiguity is invalid")
    if not isinstance(label.get("abstentionAllowed"), bool):
        raise MappingError("canonical abstention decision is invalid")
    return {
        "requiredFacts": required,
        "forbiddenInferences": forbidden,
        "criticalText": critical,
        "ambiguity": ambiguity,
        "abstentionAllowed": label["abstentionAllowed"],
    }


def _load_canonical(canonical_root: Path) -> tuple[dict[str, dict], bytes, bytes]:
    canonical_root = Path(canonical_root)
    _assert_owner_only(canonical_root, "canonical root", directory=True)
    labels_document, labels_bytes = _load_private_json(
        canonical_root / "labels.json", "canonical labels"
    )
    reliability, reliability_bytes = _load_private_json(
        canonical_root / "reliability.json", "canonical reliability"
    )
    try:
        _reject_private_payload(labels_document)
        _reject_private_payload(reliability)
        raw_labels = labels_document.get("labels")
        if not isinstance(raw_labels, list):
            raise MappingError("canonical labels are invalid")
        identifiers = {
            label.get("case") for label in raw_labels if isinstance(label, dict)
        }
        _validate_labels(labels_document, identifiers)
        _validate_reliability(reliability)
    except MappingError:
        raise
    except ValueError as error:
        raise MappingError(str(error)) from error
    labels: dict[str, dict] = {}
    for label in raw_labels:
        identifier = label.get("case")
        if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier) \
                or identifier in labels:
            raise MappingError("canonical label identifier is invalid or duplicated")
        labels[identifier] = label
    return labels, labels_bytes, reliability_bytes


def _extract_claims(result: dict[str, Any]) -> tuple[list[dict[str, str]], list[str], bool]:
    summary = result.get("summary")
    atomic = result.get("atomicFacts", [])
    labels = result.get("labels", [])
    visible = result.get("visibleText", [])
    abstention = result.get("abstention")
    if summary is not None and not isinstance(summary, str):
        raise MappingError("candidate summary is invalid")
    for value, subject in ((atomic, "atomic facts"), (labels, "labels"), (visible, "visible text")):
        if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
            raise MappingError(f"candidate {subject} are invalid")
    if not isinstance(abstention, bool):
        raise MappingError("candidate abstention is invalid")
    claims: list[dict[str, str]] = []
    if isinstance(summary, str) and summary.strip():
        claims.append({"source": "summary", "text": summary})
    claims.extend(
        {"source": "atomicFact", "text": text}
        for text in atomic if text.strip()
    )
    claims.extend(
        {"source": "label", "text": f"label:{text}"}
        for text in labels if text.strip()
    )
    return claims, list(visible), abstention


def _load_run(
    result_root: Path,
    labels_bytes: bytes,
    reliability_bytes: bytes,
) -> tuple[list[str], list[str], dict[tuple[str, str], dict[str, Any]]]:
    result_root = Path(result_root)
    _assert_owner_only(result_root, "result root", directory=True)
    inventory, _ = _load_private_json(
        result_root / "run-inventory.json", "run inventory"
    )
    if inventory.get("schema") != RUN_SCHEMA \
            or inventory.get("protocolID") != "screen-understanding-v1" \
            or inventory.get("split") != "testSingleFrames" \
            or inventory.get("caseCount") != EXPECTED_CASES \
            or inventory.get("mappingPending") is not True \
            or inventory.get("complete") is not True \
            or inventory.get("commitFile") != "run-inventory.json" \
            or inventory.get("partialOutputsValidWithoutInventory") is not False:
        raise MappingError("run inventory is incomplete or invalid")
    if not hmac.compare_digest(
        str(inventory.get("canonicalLabelsSHA256")), _sha256(labels_bytes)
    ) or not hmac.compare_digest(
        str(inventory.get("canonicalReliabilitySHA256")),
        _sha256(reliability_bytes),
    ):
        raise MappingError("run inventory does not bind the canonical seal")
    methods = inventory.get("selectedMethods")
    output_hashes = inventory.get("outputSHA256")
    if not isinstance(methods, list) or not methods \
            or len(set(methods)) != len(methods) \
            or any(method not in METHOD_FILES for method in methods) \
            or not isinstance(output_hashes, dict) \
            or set(output_hashes) != set(methods):
        raise MappingError("run method inventory is invalid")
    records: dict[tuple[str, str], dict[str, Any]] = {}
    common_ids: Optional[set[str]] = None
    ordered_ids: list[str] = []
    for method in methods:
        data = _read_private_bytes(
            result_root / METHOD_FILES[method], f"{method} output"
        )
        expected_hash = output_hashes[method]
        if not isinstance(expected_hash, str) or not SHA256.fullmatch(expected_hash) \
                or not hmac.compare_digest(_sha256(data), expected_hash):
            raise MappingError("method output hash verification failed")
        try:
            values = [
                json.loads(line) for line in data.decode("utf-8").splitlines()
                if line
            ]
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MappingError("method output is invalid JSONL") from error
        if len(values) != EXPECTED_CASES:
            raise MappingError("method output must contain exactly 60 cases")
        method_ids: list[str] = []
        for record in values:
            if not isinstance(record, dict) or record.get("schema") != RECORD_SCHEMA \
                    or record.get("mappingPending") is not True:
                raise MappingError("method output record is invalid")
            identifier = record.get("caseID")
            result = record.get("result")
            if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier) \
                    or not isinstance(result, dict) or result.get("methodID") != method:
                raise MappingError("method output identity is invalid")
            if identifier in method_ids:
                raise MappingError("method output case identifier is duplicated")
            _extract_claims(result)
            method_ids.append(identifier)
            records[(method, identifier)] = result
        actual = set(method_ids)
        if common_ids is None:
            common_ids = actual
            ordered_ids = sorted(actual)
        elif actual != common_ids:
            raise MappingError("methods do not cover identical case identifiers")
    return list(methods), ordered_ids, records


def _build_item(
    seed: str,
    stage: str,
    method: str,
    case_id: str,
    result: dict[str, Any],
    reference: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    alias = "method-" + _token(seed, f"{stage}-method", method, 12)
    arm_id = "arm-" + _token(seed, f"{stage}-arm", f"{method}:{case_id}")
    raw_claims, visible, abstention = _extract_claims(result)
    claims = []
    claim_ids = []
    for index, claim in enumerate(raw_claims):
        claim_id = "claim-" + _token(
            seed, f"{stage}-claim", f"{method}:{case_id}:{index}"
        )
        claims.append({"claimID": claim_id, **claim})
        claim_ids.append(claim_id)
    item = {
        "armID": arm_id,
        "anonymousMethod": alias,
        "requiredFacts": reference["requiredFacts"],
        "forbiddenInferences": reference["forbiddenInferences"],
        "criticalText": reference["criticalText"],
        "claims": claims,
        "visibleText": visible,
        "abstention": abstention,
        "ambiguity": reference["ambiguity"],
        "abstentionAllowed": reference["abstentionAllowed"],
    }
    owner = {
        "methodID": method,
        "caseID": case_id,
        "claimIDs": claim_ids,
    }
    return item, owner


def prepare_mapping(
    canonical_root: Path,
    result_root: Path,
    mapping_root: Path,
    seed: str,
) -> dict[str, Any]:
    """Seal primary and concealed duplicate packets after canonical validation."""
    if not isinstance(seed, str) or not seed:
        raise MappingError("mapping seed must be non-empty")
    # This ordering is deliberate: candidate result files are not opened until
    # the v3 canonical seal and reliability gate have both passed.
    labels, labels_bytes, reliability_bytes = _load_canonical(Path(canonical_root))
    methods, case_ids, results = _load_run(
        Path(result_root), labels_bytes, reliability_bytes
    )
    if any(identifier not in labels for identifier in case_ids):
        raise MappingError("candidate case is absent from canonical labels")
    references = {
        identifier: _validate_reference(labels[identifier])
        for identifier in case_ids
    }

    target = Path(mapping_root)
    if target.exists():
        raise MappingError("mapping root already exists")
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{target.name}.tmp-", dir=target.parent))
    staging.chmod(0o700)
    try:
        primary_items = []
        primary_owners: dict[str, dict[str, Any]] = {}
        primary_by_key: dict[tuple[str, str], tuple[dict, dict]] = {}
        for method in methods:
            for case_id in case_ids:
                item, owner = _build_item(
                    seed, "primary", method, case_id,
                    results[(method, case_id)], references[case_id],
                )
                primary_items.append(item)
                primary_owners[item["armID"]] = owner
                primary_by_key[(method, case_id)] = (item, owner)
        primary_items.sort(
            key=lambda item: _token(seed, "primary-order", item["armID"], 64)
        )

        duplicate_count = math.ceil(EXPECTED_CASES * DUPLICATE_FRACTION)
        hidden_items = []
        hidden_owners: dict[str, dict[str, Any]] = {}
        for method in methods:
            selected = sorted(
                case_ids,
                key=lambda identifier: _token(
                    seed, "hidden-selection", f"{method}:{identifier}", 64
                ),
            )[:duplicate_count]
            for case_id in selected:
                hidden_item, hidden_owner = _build_item(
                    seed, "hidden", method, case_id,
                    results[(method, case_id)], references[case_id],
                )
                primary_item, primary_owner = primary_by_key[(method, case_id)]
                hidden_owner.update({
                    "primaryArmID": primary_item["armID"],
                    "claimPairs": [
                        {
                            "hiddenClaimID": hidden_claim,
                            "primaryClaimID": primary_claim,
                        }
                        for hidden_claim, primary_claim in zip(
                            hidden_owner.pop("claimIDs"), primary_owner["claimIDs"]
                        )
                    ],
                })
                hidden_items.append(hidden_item)
                hidden_owners[hidden_item["armID"]] = hidden_owner
        hidden_items.sort(
            key=lambda item: _token(seed, "hidden-order", item["armID"], 64)
        )

        primary_packet = {
            "schema": PACKET_SCHEMA,
            "protocol": PROTOCOL,
            "packetID": "packet-primary-" + _token(seed, "packet", "primary", 16),
            "stage": "primary",
            "sealVerifiedBeforePreparation": True,
            "items": primary_items,
        }
        hidden_packet = {
            "schema": PACKET_SCHEMA,
            "protocol": PROTOCOL,
            "packetID": "packet-hidden-" + _token(seed, "packet", "hidden", 16),
            "stage": "hidden-duplicate",
            "sealVerifiedBeforePreparation": True,
            "items": hidden_items,
        }
        forbidden = tuple(methods) + tuple(case_ids)
        _reject_leaks(primary_packet, forbidden_values=forbidden)
        _reject_leaks(hidden_packet, forbidden_values=forbidden)
        primary_bytes = _atomic_private_json(staging / "primary-packet.json", primary_packet)
        hidden_bytes = _atomic_private_json(staging / "hidden-packet.json", hidden_packet)
        owner_mapping = {
            "schema": MAPPING_SCHEMA,
            "protocol": PROTOCOL,
            "seedSHA256": _sha256(seed.encode("utf-8")),
            "selectedMethods": methods,
            "caseCountPerMethod": EXPECTED_CASES,
            "duplicateCountPerMethod": duplicate_count,
            "primaryPacketSHA256": _sha256(primary_bytes),
            "hiddenPacketSHA256": _sha256(hidden_bytes),
            "primary": primary_owners,
            "hidden": hidden_owners,
        }
        _atomic_private_json(staging / "owner-mapping.json", owner_mapping)
        os.replace(staging, target)
        target.chmod(0o700)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return {
        "mappingRoot": str(target),
        "primaryPacket": str(target / "primary-packet.json"),
        "hiddenPacket": str(target / "hidden-packet.json"),
        "primaryArmCount": len(primary_items),
        "hiddenArmCount": len(hidden_items),
    }


def _load_packet(path: Path) -> tuple[dict[str, Any], bytes]:
    packet, data = _load_private_json(path, "mapping packet")
    _exact_keys(packet, {
        "schema", "protocol", "packetID", "stage",
        "sealVerifiedBeforePreparation", "items",
    }, "mapping packet")
    if packet["schema"] != PACKET_SCHEMA or packet["protocol"] != PROTOCOL \
            or packet["stage"] not in {"primary", "hidden-duplicate"} \
            or packet["sealVerifiedBeforePreparation"] is not True \
            or not isinstance(packet["packetID"], str) \
            or not SAFE_ID.fullmatch(packet["packetID"]):
        raise MappingError("mapping packet provenance is invalid")
    if not isinstance(packet["items"], list):
        raise MappingError("mapping packet items are invalid")
    _reject_leaks(packet)
    seen_arms = set()
    for item in packet["items"]:
        _exact_keys(item, {
            "armID", "anonymousMethod", "requiredFacts",
            "forbiddenInferences", "criticalText", "claims", "visibleText",
            "abstention", "ambiguity", "abstentionAllowed",
        }, "mapping packet item")
        if not isinstance(item["armID"], str) or not SAFE_ID.fullmatch(item["armID"]) \
                or item["armID"] in seen_arms \
                or not isinstance(item["anonymousMethod"], str) \
                or not SAFE_ID.fullmatch(item["anonymousMethod"]):
            raise MappingError("mapping packet arm identity is invalid")
        seen_arms.add(item["armID"])
        required_ids = [fact.get("id") for fact in item["requiredFacts"]]
        forbidden_ids = [fact.get("id") for fact in item["forbiddenInferences"]]
        if required_ids != list(REQUIRED_FACT_IDS) \
                or forbidden_ids != list(FORBIDDEN_FACT_IDS):
            raise MappingError("mapping packet reference is invalid")
        if not isinstance(item["criticalText"], list) \
                or any(not isinstance(value, str) for value in item["criticalText"]):
            raise MappingError("mapping packet critical text is invalid")
        if not isinstance(item["visibleText"], list) \
                or any(not isinstance(value, str) for value in item["visibleText"]):
            raise MappingError("mapping packet visible text is invalid")
        if not isinstance(item["abstention"], bool) \
                or not isinstance(item["abstentionAllowed"], bool) \
                or not isinstance(item["ambiguity"], str):
            raise MappingError("mapping packet decision context is invalid")
        if not isinstance(item["claims"], list):
            raise MappingError("mapping packet claims are invalid")
        seen_claims = set()
        for claim in item["claims"]:
            _exact_keys(claim, {"claimID", "source", "text"}, "candidate claim")
            if not isinstance(claim["claimID"], str) \
                    or not SAFE_ID.fullmatch(claim["claimID"]) \
                    or claim["claimID"] in seen_claims \
                    or claim["source"] not in {"summary", "atomicFact", "label"} \
                    or not isinstance(claim["text"], str) or not claim["text"]:
                raise MappingError("candidate claim is invalid")
            seen_claims.add(claim["claimID"])
    return packet, data


def _validate_decision(
    judgment: Any,
    required_ids: set[str],
    forbidden_ids: set[str],
) -> None:
    if not isinstance(judgment, dict) or len(judgment) != 1:
        raise MappingError("each claim judgment must contain exactly one decision")
    key, value = next(iter(judgment.items()))
    if key == "matchedRequired" and value in required_ids:
        return
    if key == "matchedForbidden" and value in forbidden_ids:
        return
    if key == "unsupported" and value in SEVERITY_WEIGHTS:
        return
    if key == "ambiguous" and value is True:
        return
    raise MappingError("claim judgment decision is invalid")


def validate_mapper_output(
    packet_path: Path,
    output_path: Path,
    forbidden_identity: Optional[str] = None,
) -> dict[str, Any]:
    packet, _ = _load_packet(Path(packet_path))
    output, _ = _load_private_json(Path(output_path), "mapper judgments")
    _exact_keys(output, {
        "schema", "protocol", "packetID", "mapperIdentity", "items",
    }, "mapper judgments")
    identity = output["mapperIdentity"]
    if output["schema"] != JUDGMENT_SCHEMA or output["protocol"] != PROTOCOL \
            or output["packetID"] != packet["packetID"] \
            or not isinstance(identity, str) or not SAFE_ID.fullmatch(identity):
        raise MappingError("mapper judgment provenance is invalid")
    if forbidden_identity is not None and identity == forbidden_identity:
        raise MappingError("mapper identities must be distinct")
    _reject_leaks(output, subject="mapper judgments")
    packet_items = {item["armID"]: item for item in packet["items"]}
    if not isinstance(output["items"], list):
        raise MappingError("mapper judgment items are invalid")
    judgments = {}
    for item in output["items"]:
        _exact_keys(item, {
            "armID", "claimJudgments", "criticalTextMatched", "abstentionCorrect",
        }, "mapper judgment item")
        arm_id = item["armID"]
        if not isinstance(arm_id, str) or arm_id not in packet_items \
                or arm_id in judgments:
            raise MappingError("mapper judgment arm identity is invalid")
        packet_item = packet_items[arm_id]
        required_ids = {fact["id"] for fact in packet_item["requiredFacts"]}
        forbidden_ids = {fact["id"] for fact in packet_item["forbiddenInferences"]}
        expected_claims = {claim["claimID"] for claim in packet_item["claims"]}
        if not isinstance(item["claimJudgments"], list):
            raise MappingError("claim judgments are invalid")
        actual_claims = set()
        for claim in item["claimJudgments"]:
            _exact_keys(claim, {"claimID", "judgment"}, "claim judgment")
            claim_id = claim["claimID"]
            if claim_id not in expected_claims or claim_id in actual_claims:
                raise MappingError("claim judgment identity is invalid")
            actual_claims.add(claim_id)
            _validate_decision(claim["judgment"], required_ids, forbidden_ids)
        if actual_claims != expected_claims:
            raise MappingError("claim judgments do not cover the packet")
        critical = item["criticalTextMatched"]
        if not isinstance(critical, list) or len(critical) != len(packet_item["criticalText"]) \
                or any(not isinstance(value, bool) for value in critical):
            raise MappingError("critical text judgments are invalid")
        if not isinstance(item["abstentionCorrect"], bool):
            raise MappingError("abstention judgment is invalid")
        judgments[arm_id] = item
    if set(judgments) != set(packet_items):
        raise MappingError("mapper judgments do not cover the packet")
    return output


def _load_mapping(mapping_root: Path) -> tuple[dict, dict, dict]:
    mapping_root = Path(mapping_root)
    _assert_owner_only(mapping_root, "mapping root", directory=True)
    mapping, _ = _load_private_json(
        mapping_root / "owner-mapping.json", "owner mapping"
    )
    primary, primary_bytes = _load_packet(mapping_root / "primary-packet.json")
    hidden, hidden_bytes = _load_packet(mapping_root / "hidden-packet.json")
    if mapping.get("schema") != MAPPING_SCHEMA or mapping.get("protocol") != PROTOCOL \
            or primary.get("stage") != "primary" \
            or hidden.get("stage") != "hidden-duplicate" \
            or not hmac.compare_digest(
                str(mapping.get("primaryPacketSHA256")), _sha256(primary_bytes)
            ) or not hmac.compare_digest(
                str(mapping.get("hiddenPacketSHA256")), _sha256(hidden_bytes)
            ):
        raise MappingError("owner mapping or packet integrity is invalid")
    methods = mapping.get("selectedMethods")
    if not isinstance(methods, list) or not methods \
            or len(set(methods)) != len(methods) \
            or any(method not in METHOD_FILES for method in methods) \
            or mapping.get("caseCountPerMethod") != EXPECTED_CASES \
            or mapping.get("duplicateCountPerMethod") != math.ceil(
                EXPECTED_CASES * DUPLICATE_FRACTION
            ):
        raise MappingError("owner mapping inventory is invalid")
    primary_owners = mapping.get("primary")
    hidden_owners = mapping.get("hidden")
    if not isinstance(primary_owners, dict) or not isinstance(hidden_owners, dict) \
            or set(primary_owners) != {item["armID"] for item in primary["items"]} \
            or set(hidden_owners) != {item["armID"] for item in hidden["items"]}:
        raise MappingError("owner mapping coverage is invalid")
    primary_items = {item["armID"]: item for item in primary["items"]}
    hidden_items = {item["armID"]: item for item in hidden["items"]}
    cases_by_method = {method: set() for method in methods}
    for arm_id, owner in primary_owners.items():
        _exact_keys(
            owner, {"methodID", "caseID", "claimIDs"},
            "primary owner mapping item",
        )
        method = owner["methodID"]
        case_id = owner["caseID"]
        claim_ids = owner["claimIDs"]
        expected_claims = [
            claim["claimID"] for claim in primary_items[arm_id]["claims"]
        ]
        if method not in cases_by_method \
                or not isinstance(case_id, str) or not CASE_ID.fullmatch(case_id) \
                or case_id in cases_by_method[method] \
                or claim_ids != expected_claims:
            raise MappingError("primary owner mapping inventory is invalid")
        cases_by_method[method].add(case_id)
    if any(len(values) != EXPECTED_CASES for values in cases_by_method.values()) \
            or any(values != next(iter(cases_by_method.values())) for values in cases_by_method.values()):
        raise MappingError("primary owner mapping methods do not share the locked cases")

    hidden_counts = {method: 0 for method in methods}
    for hidden_arm, owner in hidden_owners.items():
        _exact_keys(owner, {
            "methodID", "caseID", "primaryArmID", "claimPairs",
        }, "hidden owner mapping item")
        primary_arm = owner["primaryArmID"]
        if primary_arm not in primary_owners:
            raise MappingError("hidden owner mapping cross-link is invalid")
        primary_owner = primary_owners[primary_arm]
        if owner["methodID"] != primary_owner["methodID"] \
                or owner["caseID"] != primary_owner["caseID"]:
            raise MappingError("hidden owner mapping cross-link is invalid")
        method = owner["methodID"]
        hidden_counts[method] += 1
        pairs = owner["claimPairs"]
        if not isinstance(pairs, list):
            raise MappingError("hidden owner mapping cross-link is invalid")
        hidden_claims = []
        primary_claims = []
        for pair in pairs:
            _exact_keys(
                pair, {"hiddenClaimID", "primaryClaimID"},
                "hidden claim cross-link",
            )
            hidden_claims.append(pair["hiddenClaimID"])
            primary_claims.append(pair["primaryClaimID"])
        expected_hidden = [
            claim["claimID"] for claim in hidden_items[hidden_arm]["claims"]
        ]
        expected_primary = [
            claim["claimID"] for claim in primary_items[primary_arm]["claims"]
        ]
        if hidden_claims != expected_hidden or primary_claims != expected_primary:
            raise MappingError("hidden owner mapping claim cross-link is invalid")
        hidden_item = hidden_items[hidden_arm]
        primary_item = primary_items[primary_arm]
        for key in (
            "requiredFacts", "forbiddenInferences", "criticalText", "visibleText",
            "abstention", "ambiguity", "abstentionAllowed",
        ):
            if hidden_item[key] != primary_item[key]:
                raise MappingError("hidden owner mapping packet cross-link is invalid")
        if [
            {"source": claim["source"], "text": claim["text"]}
            for claim in hidden_item["claims"]
        ] != [
            {"source": claim["source"], "text": claim["text"]}
            for claim in primary_item["claims"]
        ]:
            raise MappingError("hidden owner mapping claim cross-link is invalid")
    expected_duplicates = mapping["duplicateCountPerMethod"]
    if any(count != expected_duplicates for count in hidden_counts.values()):
        raise MappingError("hidden owner mapping stratification is invalid")
    forbidden = tuple(methods) + tuple(
        owner.get("caseID") for owner in primary_owners.values()
        if isinstance(owner, dict) and isinstance(owner.get("caseID"), str)
    )
    _reject_leaks(primary, forbidden_values=forbidden)
    _reject_leaks(hidden, forbidden_values=forbidden)
    return mapping, primary, hidden


def _write_aggregate_result(
    root: Path,
    status: str,
    reliability: dict[str, Any],
    adjudication_packet: Optional[Path] = None,
    public_aggregate: Optional[Path] = None,
) -> Path:
    adjudication = None
    if adjudication_packet is not None:
        data = _read_private_bytes(adjudication_packet, "adjudication packet")
        adjudication = {
            "file": adjudication_packet.name,
            "sha256": _sha256(data),
        }
    public = None
    if public_aggregate is not None:
        data = _read_private_bytes(public_aggregate, "public aggregate")
        public = {
            "file": public_aggregate.name,
            "sha256": _sha256(data),
        }
    payload = {
        "schema": "screen-understanding-claim-aggregate-result-v1",
        "protocol": PROTOCOL,
        "status": status,
        "reliability": reliability,
        "adjudication": adjudication,
        "publicAggregate": public,
    }
    path = root / "aggregate-result.json"
    _atomic_private_json(path, payload)
    return path


def _judgment_map(output: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["armID"]: item for item in output["items"]}


def _claim_map(item: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        claim["claimID"]: claim["judgment"]
        for claim in item["claimJudgments"]
    }


def _duplicate_agreement(
    mapping: dict,
    primary_output: dict,
    hidden_output: dict,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    primary = _judgment_map(primary_output)
    hidden = _judgment_map(hidden_output)
    claim_equal = 0
    claim_total = 0
    decision_equal = 0
    decision_total = 0
    differences = []
    for hidden_arm, owner in mapping["hidden"].items():
        primary_arm = owner["primaryArmID"]
        left = primary[primary_arm]
        right = hidden[hidden_arm]
        left_claims = _claim_map(left)
        right_claims = _claim_map(right)
        claim_differences = []
        for pair in owner["claimPairs"]:
            primary_claim = pair["primaryClaimID"]
            hidden_claim = pair["hiddenClaimID"]
            claim_total += 1
            if left_claims[primary_claim] == right_claims[hidden_claim]:
                claim_equal += 1
            else:
                claim_differences.append({
                    "primaryClaimID": primary_claim,
                    "hiddenClaimID": hidden_claim,
                })
        critical_differences = []
        for index, (left_value, right_value) in enumerate(zip(
            left["criticalTextMatched"], right["criticalTextMatched"]
        )):
            decision_total += 1
            if left_value == right_value:
                decision_equal += 1
            else:
                critical_differences.append(index)
        decision_total += 1
        abstention_difference = (
            left["abstentionCorrect"] != right["abstentionCorrect"]
        )
        if not abstention_difference:
            decision_equal += 1
        if claim_differences or critical_differences or abstention_difference:
            differences.append({
                "primaryArmID": primary_arm,
                "hiddenArmID": hidden_arm,
                "claimDifferences": claim_differences,
                "criticalDifferences": critical_differences,
                "abstentionDifference": abstention_difference,
            })
    claim_agreement = claim_equal / claim_total if claim_total else 1.0
    decision_agreement = decision_equal / decision_total if decision_total else 1.0
    reliability = {
        "duplicateArmCount": len(mapping["hidden"]),
        "claimJudgmentAgreement": claim_agreement,
        "decisionAgreement": decision_agreement,
        "qualified": (
            claim_agreement >= CLAIM_AGREEMENT_FLOOR
            and decision_agreement >= DECISION_AGREEMENT_FLOOR
        ),
    }
    return reliability, differences


def _build_adjudication(
    aggregate_root: Path,
    mapping: dict,
    primary_packet: dict,
    differences: list[dict[str, Any]],
) -> tuple[Path, Path, dict[str, Any]]:
    primary_items = {item["armID"]: item for item in primary_packet["items"]}
    seed_hash = mapping["seedSHA256"]
    work = []
    owners = {}
    for difference in sorted(differences, key=lambda value: value["primaryArmID"]):
        arm_id = difference["primaryArmID"]
        source = primary_items[arm_id]
        source_claims = {claim["claimID"]: claim for claim in source["claims"]}
        adjudication_id = "tie-" + _token(
            seed_hash, "adjudication-arm", arm_id
        )
        claims = []
        claim_map = []
        for index, pair in enumerate(difference["claimDifferences"]):
            primary_claim = pair["primaryClaimID"]
            adjudication_claim = "tie-claim-" + _token(
                seed_hash, "adjudication-claim", f"{arm_id}:{index}"
            )
            claims.append({
                "claimID": adjudication_claim,
                "source": source_claims[primary_claim]["source"],
                "text": source_claims[primary_claim]["text"],
            })
            claim_map.append({
                "adjudicationClaimID": adjudication_claim,
                "primaryClaimID": primary_claim,
            })
        critical = [
            {"index": index, "text": source["criticalText"][index]}
            for index in difference["criticalDifferences"]
        ]
        work.append({
            "adjudicationID": adjudication_id,
            "requiredFacts": source["requiredFacts"],
            "forbiddenInferences": source["forbiddenInferences"],
            "claimJudgments": claims,
            "criticalTextDisagreements": critical,
            "abstentionDisagreement": difference["abstentionDifference"],
            "abstention": source["abstention"],
            "ambiguity": source["ambiguity"],
            "abstentionAllowed": source["abstentionAllowed"],
        })
        owners[adjudication_id] = {
            "primaryArmID": arm_id,
            "claimMap": claim_map,
            "criticalIndices": difference["criticalDifferences"],
            "abstentionDisagreement": difference["abstentionDifference"],
        }
    packet = {
        "schema": ADJUDICATION_PACKET_SCHEMA,
        "protocol": PROTOCOL,
        "packetID": "packet-tie-" + _token(
            seed_hash, "adjudication-packet", _sha256(_json_bytes(differences)), 16
        ),
        "items": work,
    }
    forbidden = tuple(mapping["selectedMethods"]) + tuple(
        owner["caseID"] for owner in mapping["primary"].values()
    )
    _reject_leaks(packet, forbidden_values=forbidden)
    packet_path = aggregate_root / "adjudication-packet.json"
    packet_bytes = _atomic_private_json(packet_path, packet)
    owner = {
        "schema": "screen-understanding-claim-adjudication-owner-v1",
        "protocol": PROTOCOL,
        "packetSHA256": _sha256(packet_bytes),
        "items": owners,
    }
    owner_path = aggregate_root / "adjudication-owner.json"
    _atomic_private_json(owner_path, owner)
    return packet_path, owner_path, packet


def _apply_adjudication(
    packet_path: Path,
    owner_path: Path,
    output_path: Path,
    primary_output: dict[str, Any],
    prior_identities: set[str],
) -> None:
    packet, packet_bytes = _load_private_json(packet_path, "adjudication packet")
    owner, _ = _load_private_json(owner_path, "adjudication owner mapping")
    output, _ = _load_private_json(output_path, "adjudication output")
    if owner.get("schema") != "screen-understanding-claim-adjudication-owner-v1" \
            or owner.get("protocol") != PROTOCOL \
            or not hmac.compare_digest(
                str(owner.get("packetSHA256")), _sha256(packet_bytes)
            ):
        raise MappingError("adjudication owner mapping is invalid")
    _exact_keys(output, {
        "schema", "protocol", "packetID", "adjudicatorIdentity", "items",
    }, "adjudication output")
    identity = output["adjudicatorIdentity"]
    if output["schema"] != ADJUDICATION_SCHEMA or output["protocol"] != PROTOCOL \
            or output["packetID"] != packet.get("packetID") \
            or not isinstance(identity, str) or not SAFE_ID.fullmatch(identity) \
            or identity in prior_identities:
        raise MappingError("adjudicator identity must be fresh")
    _reject_leaks(output, subject="adjudication output")
    packet_items = {item["adjudicationID"]: item for item in packet.get("items", [])}
    owner_items = owner.get("items")
    if not isinstance(owner_items, dict) or set(owner_items) != set(packet_items) \
            or not isinstance(output["items"], list):
        raise MappingError("adjudication coverage is invalid")
    primary_items = _judgment_map(primary_output)
    seen = set()
    for result in output["items"]:
        _exact_keys(result, {
            "adjudicationID", "claimJudgments", "criticalTextMatched",
            "abstentionCorrect",
        }, "adjudication item")
        identifier = result["adjudicationID"]
        if identifier not in packet_items or identifier in seen:
            raise MappingError("adjudication identity is invalid")
        seen.add(identifier)
        item = packet_items[identifier]
        mapping = owner_items[identifier]
        required_ids = {fact["id"] for fact in item["requiredFacts"]}
        forbidden_ids = {fact["id"] for fact in item["forbiddenInferences"]}
        claim_owner = {
            pair["adjudicationClaimID"]: pair["primaryClaimID"]
            for pair in mapping["claimMap"]
        }
        actual_claims = set()
        primary_arm = primary_items[mapping["primaryArmID"]]
        primary_claims = {
            claim["claimID"]: claim for claim in primary_arm["claimJudgments"]
        }
        for claim in result["claimJudgments"]:
            _exact_keys(claim, {"claimID", "judgment"}, "adjudicated claim")
            claim_id = claim["claimID"]
            if claim_id not in claim_owner or claim_id in actual_claims:
                raise MappingError("adjudicated claim identity is invalid")
            actual_claims.add(claim_id)
            _validate_decision(claim["judgment"], required_ids, forbidden_ids)
            primary_claims[claim_owner[claim_id]]["judgment"] = claim["judgment"]
        if actual_claims != set(claim_owner):
            raise MappingError("adjudication does not cover disputed claims")
        critical = result["criticalTextMatched"]
        if not isinstance(critical, list) \
                or len(critical) != len(mapping["criticalIndices"]) \
                or any(not isinstance(value, bool) for value in critical):
            raise MappingError("adjudicated critical text decisions are invalid")
        for index, value in zip(mapping["criticalIndices"], critical):
            primary_arm["criticalTextMatched"][index] = value
        if mapping["abstentionDisagreement"]:
            if not isinstance(result["abstentionCorrect"], bool):
                raise MappingError("adjudicated abstention decision is invalid")
            primary_arm["abstentionCorrect"] = result["abstentionCorrect"]
        elif result["abstentionCorrect"] is not None:
            raise MappingError("adjudication includes an undisputed abstention")
    if seen != set(packet_items):
        raise MappingError("adjudication does not cover every disagreement")


def _score(
    mapping: dict,
    primary_packet: dict,
    primary_output: dict,
    reliability: dict[str, Any],
) -> dict[str, Any]:
    packet_items = {item["armID"]: item for item in primary_packet["items"]}
    judgments = _judgment_map(primary_output)
    methods = []
    for method_id in mapping["selectedMethods"]:
        arms = [
            arm_id for arm_id, owner in mapping["primary"].items()
            if owner["methodID"] == method_id
        ]
        if len(arms) != EXPECTED_CASES:
            raise MappingError("method score does not meet the locked case minimum")
        required_hits = 0
        required_total = 0
        critical_hits = 0
        critical_total = 0
        hallucination_weight = 0.0
        claim_count = 0
        abstention_hits = 0
        for arm_id in arms:
            packet = packet_items[arm_id]
            judgment = judgments[arm_id]
            required = {fact["id"] for fact in packet["requiredFacts"]}
            matched = set()
            forbidden_severity = {
                fact["id"]: fact["severity"]
                for fact in packet["forbiddenInferences"]
            }
            for claim in judgment["claimJudgments"]:
                decision = claim["judgment"]
                claim_count += 1
                if "matchedRequired" in decision:
                    matched.add(decision["matchedRequired"])
                elif "matchedForbidden" in decision:
                    hallucination_weight += SEVERITY_WEIGHTS[
                        forbidden_severity[decision["matchedForbidden"]]
                    ]
                elif "unsupported" in decision:
                    hallucination_weight += SEVERITY_WEIGHTS[decision["unsupported"]]
            required_hits += len(matched & required)
            required_total += len(required)
            critical_hits += sum(judgment["criticalTextMatched"])
            critical_total += len(judgment["criticalTextMatched"])
            abstention_hits += int(judgment["abstentionCorrect"])
        required_recall = required_hits / required_total
        critical_recall = critical_hits / critical_total if critical_total else 1.0
        hallucination = min(1.0, hallucination_weight / max(1, claim_count))
        abstention_accuracy = abstention_hits / len(arms)
        overall = (
            required_recall + critical_recall + (1.0 - hallucination)
            + abstention_accuracy
        ) / 4.0
        methods.append({
            "methodID": method_id,
            "caseCount": len(arms),
            "claimCount": claim_count,
            "requiredFactRecall": required_recall,
            "criticalTextRecall": critical_recall,
            "severityWeightedHallucination": hallucination,
            "abstentionAccuracy": abstention_accuracy,
            "overall": overall,
        })
    public = {
        "schema": PUBLIC_SCHEMA,
        "protocol": PROTOCOL,
        "status": "qualified",
        "reliability": reliability,
        "methods": methods,
    }
    validate_public_output(public)
    return public


def validate_public_output(value: Any) -> None:
    _exact_keys(value, {
        "schema", "protocol", "status", "reliability", "methods",
    }, "public aggregate")
    if value["schema"] != PUBLIC_SCHEMA or value["protocol"] != PROTOCOL \
            or value["status"] != "qualified":
        raise MappingError("public aggregate provenance is invalid")
    reliability = value["reliability"]
    _exact_keys(reliability, {
        "duplicateArmCount", "claimJudgmentAgreement",
        "decisionAgreement", "qualified",
    }, "public aggregate reliability")
    if not isinstance(reliability["duplicateArmCount"], int) \
            or reliability["duplicateArmCount"] < 1 \
            or reliability["qualified"] is not True:
        raise MappingError("public aggregate reliability is invalid")
    for key in ("claimJudgmentAgreement", "decisionAgreement"):
        score = reliability[key]
        if isinstance(score, bool) or not isinstance(score, (int, float)) \
                or not 0.0 <= float(score) <= 1.0:
            raise MappingError("public aggregate reliability is invalid")
    methods = value["methods"]
    if not isinstance(methods, list) or not methods:
        raise MappingError("public aggregate methods are invalid")
    seen = set()
    for method in methods:
        _exact_keys(method, {
            "methodID", "caseCount", "claimCount", "requiredFactRecall",
            "criticalTextRecall", "severityWeightedHallucination",
            "abstentionAccuracy", "overall",
        }, "public aggregate method")
        method_id = method["methodID"]
        if method_id not in METHOD_FILES or method_id in seen \
                or not isinstance(method["caseCount"], int) \
                or method["caseCount"] < EXPECTED_CASES \
                or not isinstance(method["claimCount"], int) \
                or method["claimCount"] < 0:
            raise MappingError("public aggregate method inventory is invalid")
        seen.add(method_id)
        for key in (
            "requiredFactRecall", "criticalTextRecall",
            "severityWeightedHallucination", "abstentionAccuracy", "overall",
        ):
            score = method[key]
            if isinstance(score, bool) or not isinstance(score, (int, float)) \
                    or not math.isfinite(float(score)) \
                    or not 0.0 <= float(score) <= 1.0:
                raise MappingError("public aggregate metric is invalid")
    _reject_public_leaks(value)


def aggregate_mappings(
    mapping_root: Path,
    primary_output_path: Path,
    hidden_output_path: Path,
    aggregate_root: Path,
    adjudication_output_path: Optional[Path] = None,
) -> dict[str, Any]:
    mapping, primary_packet, hidden_packet = _load_mapping(Path(mapping_root))
    primary_output = validate_mapper_output(
        Path(mapping_root) / "primary-packet.json", Path(primary_output_path)
    )
    hidden_output = validate_mapper_output(
        Path(mapping_root) / "hidden-packet.json", Path(hidden_output_path),
        primary_output["mapperIdentity"],
    )
    forbidden_values = tuple(mapping["selectedMethods"]) + tuple(
        owner["caseID"] for owner in mapping["primary"].values()
    )
    _reject_leaks(primary_output, forbidden_values=forbidden_values, subject="mapper judgments")
    _reject_leaks(hidden_output, forbidden_values=forbidden_values, subject="mapper judgments")
    reliability, differences = _duplicate_agreement(
        mapping, primary_output, hidden_output
    )
    target = Path(aggregate_root)
    if target.exists():
        raise MappingError("aggregate root already exists")
    _make_private_directory(target)
    result: dict[str, Any] = {
        "status": "qualified",
        "reliability": reliability,
    }
    packet_path = None
    owner_path = None
    if differences:
        packet_path, owner_path, _ = _build_adjudication(
            target, mapping, primary_packet, differences
        )
        result["adjudicationPacket"] = str(packet_path)
    if not reliability["qualified"]:
        result["status"] = "inconclusive"
        result["aggregateResult"] = str(_write_aggregate_result(
            target, result["status"], reliability, packet_path
        ))
        return result
    if differences and adjudication_output_path is None:
        result["status"] = "adjudication-required"
        result["aggregateResult"] = str(_write_aggregate_result(
            target, result["status"], reliability, packet_path
        ))
        return result
    if differences:
        assert packet_path is not None and owner_path is not None
        _apply_adjudication(
            packet_path, owner_path, Path(adjudication_output_path),
            primary_output,
            {
                primary_output["mapperIdentity"],
                hidden_output["mapperIdentity"],
            },
        )
    public = _score(mapping, primary_packet, primary_output, reliability)
    public_path = target / "public-aggregate.json"
    _atomic_private_json(public_path, public)
    result["publicAggregate"] = str(public_path)
    result["aggregateResult"] = str(_write_aggregate_result(
        target, result["status"], reliability, packet_path, public_path
    ))
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--canonical-root", required=True, type=Path)
    prepare.add_argument("--result-root", required=True, type=Path)
    prepare.add_argument("--mapping-root", required=True, type=Path)
    prepare.add_argument("--seed", required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--packet", required=True, type=Path)
    validate.add_argument("--output", required=True, type=Path)
    validate.add_argument("--forbidden-identity")
    aggregate = subparsers.add_parser("aggregate")
    aggregate.add_argument("--mapping-root", required=True, type=Path)
    aggregate.add_argument("--primary-output", required=True, type=Path)
    aggregate.add_argument("--hidden-output", required=True, type=Path)
    aggregate.add_argument("--aggregate-root", required=True, type=Path)
    aggregate.add_argument("--adjudication-output", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            output = prepare_mapping(
                args.canonical_root, args.result_root, args.mapping_root, args.seed
            )
        elif args.command == "validate":
            validated = validate_mapper_output(
                args.packet, args.output, args.forbidden_identity
            )
            output = {
                "mapperIdentity": validated["mapperIdentity"],
                "itemCount": len(validated["items"]),
            }
        else:
            output = aggregate_mappings(
                args.mapping_root, args.primary_output, args.hidden_output,
                args.aggregate_root, args.adjudication_output,
            )
    except MappingError as error:
        print(f"claim mapping failed: {error}", file=sys.stderr)
        return 2
    print(json.dumps(output, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
