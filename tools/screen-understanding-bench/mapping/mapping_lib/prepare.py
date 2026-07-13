"""Canonical validation and blinded packet preparation."""

from __future__ import annotations

import hmac
import json
import math
import os
import shutil
import sys
import uuid
from pathlib import Path
from typing import Any, Callable, Optional

from .contracts import (
    CASE_ID,
    CLAIM_SOURCE_CAPABILITIES,
    DUPLICATE_FRACTION,
    EXPECTED_CASES,
    FORBIDDEN_FRAGMENTS,
    FORBIDDEN_FACT_IDS,
    MAPPING_SCHEMA,
    METHOD_FILES,
    PACKET_SCHEMA,
    PROTOCOL,
    RECORD_SCHEMA,
    REQUIRED_FACT_IDS,
    RUN_SCHEMA,
    SEVERITY_WEIGHTS,
    SHA256,
    MappingError,
    exact_keys as _exact_keys,
    reject_leaks as _reject_leaks,
    sha256 as _sha256,
    token as _token,
)
from .private_io import (
    assert_owner_only_directory as _assert_owner_only_directory,
    prepare_output_root as _prepare_output_root,
    read_private_bytes as _read_private_bytes,
    validate_existing_output_root as _validate_existing_output_root,
    validate_output_root_path as _validate_output_root_path,
)


BENCHMARK_DIRECTORY = Path(__file__).resolve().parents[2]
RUNNER_DIRECTORY = BENCHMARK_DIRECTORY / "runner"
if str(RUNNER_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(RUNNER_DIRECTORY))

from preflight import (  # noqa: E402
    _reject_private_payload,
    _validate_labels,
    _validate_reliability,
)


PrivateJSONLoader = Callable[[Path, str], tuple[dict[str, Any], bytes]]
PrivateJSONWriter = Callable[[Path, Any], bytes]


def _redact_local_path_lines(
    value: Any,
    *,
    seed: str,
    namespace: str,
) -> Any:
    """Replace path-bearing lines with equality-preserving packet-local tokens."""

    if isinstance(value, dict):
        return {
            key: _redact_local_path_lines(
                child, seed=seed, namespace=namespace
            )
            for key, child in value.items()
        }
    if isinstance(value, list):
        return [
            _redact_local_path_lines(child, seed=seed, namespace=namespace)
            for child in value
        ]
    if not isinstance(value, str):
        return value
    lines = value.split("\n")
    return "\n".join(
        "[LOCAL_PATH_REDACTED:" + _token(
            seed, f"path-redaction:{namespace}", line, 24
        ) + "]"
        if any(fragment in line for fragment in FORBIDDEN_FRAGMENTS)
        else line
        for line in lines
    )


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


def _load_canonical(
    canonical_root: Path,
    load_private_json: PrivateJSONLoader,
) -> tuple[dict[str, dict], bytes, bytes, bytes]:
    canonical_root = Path(canonical_root)
    _assert_owner_only_directory(canonical_root, "canonical root")
    labels_document, labels_bytes = load_private_json(
        canonical_root / "labels.json", "canonical labels"
    )
    reliability, reliability_bytes = load_private_json(
        canonical_root / "reliability.json", "canonical reliability"
    )
    _, commit_bytes = load_private_json(
        canonical_root / "commit.json", "canonical commit"
    )
    try:
        _reject_private_payload(labels_document)
        _reject_private_payload(reliability)
        raw_labels = labels_document.get("labels")
        if not isinstance(raw_labels, list):
            raise MappingError("canonical labels are invalid")
        expected_targets = {
            label.get("case"): label.get("targetType")
            for label in raw_labels if isinstance(label, dict)
        }
        _validate_labels(labels_document, expected_targets)
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
    return labels, labels_bytes, reliability_bytes, commit_bytes


def _extract_claims(
    result: dict[str, Any],
) -> tuple[list[dict[str, str]], list[str], bool]:
    summary = result.get("summary")
    atomic = result.get("atomicFacts", [])
    labels = result.get("labels", [])
    visible = result.get("visibleText", [])
    abstention = result.get("abstention")
    if summary is not None and not isinstance(summary, str):
        raise MappingError("candidate summary is invalid")
    for value, subject in (
        (atomic, "atomic facts"),
        (labels, "labels"),
        (visible, "visible text"),
    ):
        if not isinstance(value, list) \
                or any(not isinstance(item, str) for item in value):
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
    commit_bytes: bytes,
    load_private_json: PrivateJSONLoader,
) -> tuple[
    list[str],
    list[str],
    dict[tuple[str, str], dict[str, Any]],
    dict[str, str],
]:
    result_root = Path(result_root)
    _assert_owner_only_directory(result_root, "result root")
    inventory, inventory_bytes = load_private_json(
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
    ) or not hmac.compare_digest(
        str(inventory.get("canonicalCommitSHA256")),
        _sha256(commit_bytes),
    ):
        raise MappingError("run inventory does not bind the canonical seal")
    methods = inventory.get("selectedMethods")
    output_hashes = inventory.get("outputSHA256")
    source_hashes = inventory.get("runnerSourceSHA256")
    protocol_hash = (
        source_hashes.get("protocolManifest")
        if isinstance(source_hashes, dict) else None
    )
    corpus_hash = inventory.get("datasetManifestSHA256")
    if not isinstance(methods, list) or not methods \
            or len(set(methods)) != len(methods) \
            or any(method not in METHOD_FILES for method in methods) \
            or not isinstance(output_hashes, dict) \
            or set(output_hashes) != set(methods) \
            or not isinstance(protocol_hash, str) \
            or not SHA256.fullmatch(protocol_hash) \
            or not isinstance(corpus_hash, str) \
            or not SHA256.fullmatch(corpus_hash):
        raise MappingError("run method inventory is invalid")
    records: dict[tuple[str, str], dict[str, Any]] = {}
    common_ids: Optional[set[str]] = None
    ordered_ids: list[str] = []
    for method in methods:
        data = _read_private_bytes(
            result_root / METHOD_FILES[method], f"{method} output"
        )
        expected_hash = output_hashes[method]
        if not isinstance(expected_hash, str) \
                or not SHA256.fullmatch(expected_hash) \
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
        method_ids: set[str] = set()
        for record in values:
            if not isinstance(record, dict) \
                    or record.get("schema") != RECORD_SCHEMA \
                    or record.get("mappingPending") is not True:
                raise MappingError("method output record is invalid")
            identifier = record.get("caseID")
            result = record.get("result")
            if not isinstance(identifier, str) \
                    or not CASE_ID.fullmatch(identifier) \
                    or not isinstance(result, dict) \
                    or result.get("methodID") != method:
                raise MappingError("method output identity is invalid")
            if identifier in method_ids:
                raise MappingError("method output case identifier is duplicated")
            _extract_claims(result)
            method_ids.add(identifier)
            records[(method, identifier)] = result
        actual = method_ids
        if common_ids is None:
            common_ids = actual
            ordered_ids = sorted(actual)
        elif actual != common_ids:
            raise MappingError("methods do not cover identical case identifiers")
    provenance = {
        "protocolHash": protocol_hash,
        "corpusHash": corpus_hash,
        "reportHash": _sha256(inventory_bytes),
    }
    return list(methods), ordered_ids, records, provenance


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
    redaction_namespace = f"{stage}:{method}:{case_id}"
    packet_result = _redact_local_path_lines(
        result, seed=seed, namespace=redaction_namespace
    )
    packet_reference = _redact_local_path_lines(
        reference, seed=seed, namespace=redaction_namespace
    )
    raw_claims, visible, abstention = _extract_claims(packet_result)
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
        "requiredFacts": packet_reference["requiredFacts"],
        "forbiddenInferences": packet_reference["forbiddenInferences"],
        "criticalText": packet_reference["criticalText"],
        "claims": claims,
        "visibleText": visible,
        "abstention": abstention,
        "ambiguity": packet_reference["ambiguity"],
        "abstentionAllowed": packet_reference["abstentionAllowed"],
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
    *,
    load_private_json: PrivateJSONLoader,
    atomic_private_json: PrivateJSONWriter,
) -> dict[str, Any]:
    """Seal primary and concealed duplicate packets after canonical validation."""
    if not isinstance(seed, str) or not seed:
        raise MappingError("mapping seed must be non-empty")
    target = _validate_output_root_path(Path(mapping_root))
    if target.exists():
        raise MappingError("mapping root already exists")
    # This ordering is deliberate: candidate result files are not opened until
    # the v3 canonical seal and reliability gate have both passed.
    labels, labels_bytes, reliability_bytes, commit_bytes = _load_canonical(
        Path(canonical_root), load_private_json
    )
    methods, case_ids, results, public_provenance = _load_run(
        Path(result_root), labels_bytes, reliability_bytes, commit_bytes,
        load_private_json,
    )
    if any(identifier not in labels for identifier in case_ids):
        raise MappingError("candidate case is absent from canonical labels")
    references = {
        identifier: _validate_reference(labels[identifier])
        for identifier in case_ids
    }

    target.parent.mkdir(parents=True, exist_ok=True)
    staging_candidate = target.parent / f".{target.name}.tmp-{uuid.uuid4().hex}"
    try:
        staging = _prepare_output_root(staging_candidate)
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
                            "capability": CLAIM_SOURCE_CAPABILITIES[
                                primary_item["claims"][index]["source"]
                            ],
                        }
                        for index, (hidden_claim, primary_claim) in enumerate(zip(
                            hidden_owner.pop("claimIDs"),
                            primary_owner["claimIDs"],
                        ))
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
            "packetID": "",
            "stage": "primary",
            "sealVerifiedBeforePreparation": True,
            "items": primary_items,
        }
        hidden_packet = {
            "schema": PACKET_SCHEMA,
            "protocol": PROTOCOL,
            "packetID": "",
            "stage": "hidden-duplicate",
            "sealVerifiedBeforePreparation": True,
            "items": hidden_items,
        }
        for packet in (primary_packet, hidden_packet):
            packet_material = json.dumps(
                {key: value for key, value in packet.items() if key != "packetID"},
                sort_keys=True,
                separators=(",", ":"),
                ensure_ascii=False,
            ).encode("utf-8")
            packet["packetID"] = (
                f"packet-{packet['stage']}-" + _sha256(packet_material)[:16]
            )
        forbidden = tuple(methods) + tuple(case_ids)
        _reject_leaks(primary_packet, forbidden_values=forbidden)
        _reject_leaks(hidden_packet, forbidden_values=forbidden)
        primary_bytes = atomic_private_json(
            staging / "primary-packet.json", primary_packet
        )
        hidden_bytes = atomic_private_json(
            staging / "hidden-packet.json", hidden_packet
        )
        owner_mapping = {
            "schema": MAPPING_SCHEMA,
            "protocol": PROTOCOL,
            "seedSHA256": _sha256(seed.encode("utf-8")),
            "selectedMethods": methods,
            "publicProvenance": public_provenance,
            "caseCountPerMethod": EXPECTED_CASES,
            "duplicateCountPerMethod": duplicate_count,
            "primaryPacketSHA256": _sha256(primary_bytes),
            "hiddenPacketSHA256": _sha256(hidden_bytes),
            "primary": primary_owners,
            "hidden": hidden_owners,
        }
        atomic_private_json(staging / "owner-mapping.json", owner_mapping)
        os.replace(staging, target)
        target = _validate_existing_output_root(target)
    except BaseException:
        shutil.rmtree(staging_candidate, ignore_errors=True)
        raise
    return {
        "mappingRoot": str(target),
        "primaryPacket": str(target / "primary-packet.json"),
        "hiddenPacket": str(target / "hidden-packet.json"),
        "primaryArmCount": len(primary_items),
        "hiddenArmCount": len(hidden_items),
    }
