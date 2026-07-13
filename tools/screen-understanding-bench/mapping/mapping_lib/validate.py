"""Packet, mapper-output, owner-mapping, and public-output validation."""

from __future__ import annotations

import hmac
import math
from pathlib import Path
from typing import Any, Callable, Optional

from .contracts import (
    CAPABILITY_ORDER,
    CASE_ID,
    CLAIM_AGREEMENT_FLOOR,
    CLAIM_SOURCE_CAPABILITIES,
    DECISION_AGREEMENT_FLOOR,
    DUPLICATE_FRACTION,
    EXPECTED_CASES,
    FORBIDDEN_FACT_IDS,
    JUDGMENT_SCHEMA,
    MAPPING_SCHEMA,
    METHOD_FILES,
    PACKET_SCHEMA,
    PROTOCOL,
    PUBLIC_METHOD_METADATA,
    PUBLIC_METRICS,
    PUBLIC_SCHEMA,
    REQUIRED_FACT_IDS,
    SAFE_ID,
    SEVERITY_WEIGHTS,
    SHA256,
    MappingError,
    exact_keys as _exact_keys,
    reject_leaks as _reject_leaks,
    reject_public_leaks as _reject_public_leaks,
    sha256 as _sha256,
)
from .private_io import (
    validate_existing_output_root as _validate_existing_output_root,
)


PrivateJSONLoader = Callable[[Path, str], tuple[dict[str, Any], bytes]]


def _load_packet(
    path: Path,
    load_private_json: PrivateJSONLoader,
) -> tuple[dict[str, Any], bytes]:
    packet, data = load_private_json(path, "mapping packet")
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
        if not isinstance(item["armID"], str) \
                or not SAFE_ID.fullmatch(item["armID"]) \
                or item["armID"] in seen_arms \
                or not isinstance(item["anonymousMethod"], str) \
                or not SAFE_ID.fullmatch(item["anonymousMethod"]):
            raise MappingError("mapping packet arm identity is invalid")
        seen_arms.add(item["armID"])
        required_ids = [fact.get("id") for fact in item["requiredFacts"]]
        forbidden_ids = [
            fact.get("id") for fact in item["forbiddenInferences"]
        ]
        if required_ids != list(REQUIRED_FACT_IDS) \
                or forbidden_ids != list(FORBIDDEN_FACT_IDS):
            raise MappingError("mapping packet reference is invalid")
        if not isinstance(item["criticalText"], list) \
                or any(
                    not isinstance(value, str) for value in item["criticalText"]
                ):
            raise MappingError("mapping packet critical text is invalid")
        if not isinstance(item["visibleText"], list) \
                or any(
                    not isinstance(value, str) for value in item["visibleText"]
                ):
            raise MappingError("mapping packet visible text is invalid")
        if not isinstance(item["abstention"], bool) \
                or not isinstance(item["abstentionAllowed"], bool) \
                or not isinstance(item["ambiguity"], str):
            raise MappingError("mapping packet decision context is invalid")
        if not isinstance(item["claims"], list):
            raise MappingError("mapping packet claims are invalid")
        seen_claims = set()
        for claim in item["claims"]:
            _exact_keys(
                claim, {"claimID", "source", "text"}, "candidate claim"
            )
            if not isinstance(claim["claimID"], str) \
                    or not SAFE_ID.fullmatch(claim["claimID"]) \
                    or claim["claimID"] in seen_claims \
                    or claim["source"] not in {
                        "summary", "atomicFact", "label",
                    } \
                    or not isinstance(claim["text"], str) \
                    or not claim["text"]:
                raise MappingError("candidate claim is invalid")
            seen_claims.add(claim["claimID"])
    return packet, data


def validate_decision(
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
    *,
    load_private_json: PrivateJSONLoader,
) -> dict[str, Any]:
    packet_path = Path(packet_path)
    packet_root = _validate_existing_output_root(packet_path.parent)
    packet, _ = _load_packet(
        packet_root / packet_path.name, load_private_json
    )
    output, _ = load_private_json(Path(output_path), "mapper judgments")
    _exact_keys(output, {
        "schema", "protocol", "packetID", "mapperIdentity", "items",
    }, "mapper judgments")
    identity = output["mapperIdentity"]
    if output["schema"] != JUDGMENT_SCHEMA \
            or output["protocol"] != PROTOCOL \
            or output["packetID"] != packet["packetID"] \
            or not isinstance(identity, str) \
            or not SAFE_ID.fullmatch(identity):
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
            "armID", "claimJudgments", "criticalTextMatched",
            "abstentionCorrect",
        }, "mapper judgment item")
        arm_id = item["armID"]
        if not isinstance(arm_id, str) or arm_id not in packet_items \
                or arm_id in judgments:
            raise MappingError("mapper judgment arm identity is invalid")
        packet_item = packet_items[arm_id]
        required_ids = {
            fact["id"] for fact in packet_item["requiredFacts"]
        }
        forbidden_ids = {
            fact["id"] for fact in packet_item["forbiddenInferences"]
        }
        expected_claims = {
            claim["claimID"] for claim in packet_item["claims"]
        }
        if not isinstance(item["claimJudgments"], list):
            raise MappingError("claim judgments are invalid")
        actual_claims = set()
        for claim in item["claimJudgments"]:
            _exact_keys(claim, {"claimID", "judgment"}, "claim judgment")
            claim_id = claim["claimID"]
            if claim_id not in expected_claims or claim_id in actual_claims:
                raise MappingError("claim judgment identity is invalid")
            actual_claims.add(claim_id)
            validate_decision(
                claim["judgment"], required_ids, forbidden_ids
            )
        if actual_claims != expected_claims:
            raise MappingError("claim judgments do not cover the packet")
        critical = item["criticalTextMatched"]
        if not isinstance(critical, list) \
                or len(critical) != len(packet_item["criticalText"]) \
                or any(not isinstance(value, bool) for value in critical):
            raise MappingError("critical text judgments are invalid")
        if not isinstance(item["abstentionCorrect"], bool):
            raise MappingError("abstention judgment is invalid")
        judgments[arm_id] = item
    if set(judgments) != set(packet_items):
        raise MappingError("mapper judgments do not cover the packet")
    return output


def load_mapping(
    mapping_root: Path,
    load_private_json: PrivateJSONLoader,
) -> tuple[dict, dict, dict]:
    mapping_root = _validate_existing_output_root(Path(mapping_root))
    mapping, _ = load_private_json(
        mapping_root / "owner-mapping.json", "owner mapping"
    )
    primary, primary_bytes = _load_packet(
        mapping_root / "primary-packet.json", load_private_json
    )
    hidden, hidden_bytes = _load_packet(
        mapping_root / "hidden-packet.json", load_private_json
    )
    if mapping.get("schema") != MAPPING_SCHEMA \
            or mapping.get("protocol") != PROTOCOL \
            or primary.get("stage") != "primary" \
            or hidden.get("stage") != "hidden-duplicate" \
            or not hmac.compare_digest(
                str(mapping.get("primaryPacketSHA256")),
                _sha256(primary_bytes),
            ) or not hmac.compare_digest(
                str(mapping.get("hiddenPacketSHA256")),
                _sha256(hidden_bytes),
            ):
        raise MappingError("owner mapping or packet integrity is invalid")
    methods = mapping.get("selectedMethods")
    public_provenance = mapping.get("publicProvenance")
    if isinstance(public_provenance, dict):
        _exact_keys(
            public_provenance,
            {"protocolHash", "corpusHash", "reportHash"},
            "owner mapping public provenance",
        )
    if not isinstance(methods, list) or not methods \
            or len(set(methods)) != len(methods) \
            or any(method not in METHOD_FILES for method in methods) \
            or not isinstance(public_provenance, dict) \
            or any(
                not isinstance(public_provenance.get(key), str)
                or not SHA256.fullmatch(public_provenance[key])
                for key in ("protocolHash", "corpusHash", "reportHash")
            ) \
            or mapping.get("caseCountPerMethod") != EXPECTED_CASES \
            or mapping.get("duplicateCountPerMethod") != math.ceil(
                EXPECTED_CASES * DUPLICATE_FRACTION
            ):
        raise MappingError("owner mapping inventory is invalid")
    primary_owners = mapping.get("primary")
    hidden_owners = mapping.get("hidden")
    if not isinstance(primary_owners, dict) \
            or not isinstance(hidden_owners, dict) \
            or set(primary_owners) != {
                item["armID"] for item in primary["items"]
            } \
            or set(hidden_owners) != {
                item["armID"] for item in hidden["items"]
            }:
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
                or not isinstance(case_id, str) \
                or not CASE_ID.fullmatch(case_id) \
                or case_id in cases_by_method[method] \
                or claim_ids != expected_claims:
            raise MappingError("primary owner mapping inventory is invalid")
        cases_by_method[method].add(case_id)
    if any(
        len(values) != EXPECTED_CASES for values in cases_by_method.values()
    ) or any(
        values != next(iter(cases_by_method.values()))
        for values in cases_by_method.values()
    ):
        raise MappingError(
            "primary owner mapping methods do not share the locked cases"
        )

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
                pair, {"hiddenClaimID", "primaryClaimID", "capability"},
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
        if hidden_claims != expected_hidden \
                or primary_claims != expected_primary:
            raise MappingError(
                "hidden owner mapping claim cross-link is invalid"
            )
        hidden_item = hidden_items[hidden_arm]
        primary_item = primary_items[primary_arm]
        for key in (
            "requiredFacts", "forbiddenInferences", "criticalText",
            "visibleText", "abstention", "ambiguity", "abstentionAllowed",
        ):
            if hidden_item[key] != primary_item[key]:
                raise MappingError(
                    "hidden owner mapping packet cross-link is invalid"
                )
        if [
            {"source": claim["source"], "text": claim["text"]}
            for claim in hidden_item["claims"]
        ] != [
            {"source": claim["source"], "text": claim["text"]}
            for claim in primary_item["claims"]
        ]:
            raise MappingError(
                "hidden owner mapping claim cross-link is invalid"
            )
        expected_capabilities = [
            CLAIM_SOURCE_CAPABILITIES[claim["source"]]
            for claim in primary_item["claims"]
        ]
        if [pair["capability"] for pair in pairs] != expected_capabilities:
            raise MappingError(
                "hidden owner mapping capability cross-link is invalid"
            )
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


def _validate_public_score(value: Any, subject: str) -> None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) \
            or not math.isfinite(float(value)) \
            or not 0.0 <= float(value) <= 1.0:
        raise MappingError(f"{subject} is invalid")


def _validate_public_reliability(value: Any) -> set[str]:
    _exact_keys(value, {
        "duplicateArmCount", "claimJudgmentAgreement",
        "decisionAgreement", "methods", "qualified",
    }, "public aggregate reliability")
    if not isinstance(value["duplicateArmCount"], int) \
            or value["duplicateArmCount"] < 1 \
            or value["qualified"] is not True:
        raise MappingError("public aggregate reliability is invalid")
    _validate_public_score(
        value["claimJudgmentAgreement"], "public aggregate reliability"
    )
    _validate_public_score(
        value["decisionAgreement"], "public aggregate reliability"
    )
    methods = value["methods"]
    if not isinstance(methods, list) or not methods:
        raise MappingError("public aggregate reliability methods are invalid")
    seen_methods = set()
    for method in methods:
        _exact_keys(method, {
            "methodID", "duplicateArmCount", "claimJudgmentAgreement",
            "decisionAgreement", "capabilities", "qualified",
        }, "public aggregate method reliability")
        method_id = method["methodID"]
        if method_id not in METHOD_FILES or method_id in seen_methods \
                or method["duplicateArmCount"] != math.ceil(
                    EXPECTED_CASES * DUPLICATE_FRACTION
                ) \
                or method["qualified"] is not True:
            raise MappingError(
                "public aggregate method reliability is invalid"
            )
        seen_methods.add(method_id)
        _validate_public_score(
            method["claimJudgmentAgreement"],
            "public aggregate method reliability",
        )
        _validate_public_score(
            method["decisionAgreement"],
            "public aggregate method reliability",
        )
        if method["claimJudgmentAgreement"] < CLAIM_AGREEMENT_FLOOR \
                or method["decisionAgreement"] < DECISION_AGREEMENT_FLOOR:
            raise MappingError(
                "public aggregate method reliability is below floor"
            )
        capabilities = method["capabilities"]
        if not isinstance(capabilities, list):
            raise MappingError(
                "public aggregate capability reliability is invalid"
            )
        seen_capabilities = set()
        for capability in capabilities:
            _exact_keys(capability, {
                "capability", "claimCount", "claimJudgmentAgreement",
                "qualified",
            }, "public aggregate capability reliability")
            capability_id = capability["capability"]
            if capability_id not in CAPABILITY_ORDER \
                    or capability_id in seen_capabilities \
                    or not isinstance(capability["claimCount"], int) \
                    or capability["claimCount"] < 1 \
                    or capability["qualified"] is not True:
                raise MappingError(
                    "public aggregate capability reliability is invalid"
                )
            seen_capabilities.add(capability_id)
            _validate_public_score(
                capability["claimJudgmentAgreement"],
                "public aggregate capability reliability",
            )
            if capability["claimJudgmentAgreement"] < CLAIM_AGREEMENT_FLOOR:
                raise MappingError(
                    "public aggregate capability reliability is below floor"
                )
    return seen_methods


def validate_public_output(
    value: Any,
    *,
    forbidden_values: tuple[str, ...] = (),
) -> None:
    _exact_keys(value, {
        "schema", "protocol", "status", "protocolHash", "corpusHash",
        "reportHash", "reliability", "methods",
    }, "public aggregate")
    if value["schema"] != PUBLIC_SCHEMA \
            or value["protocol"] != PROTOCOL \
            or value["status"] != "qualified":
        raise MappingError("public aggregate provenance is invalid")
    for key in ("protocolHash", "corpusHash", "reportHash"):
        digest = value[key]
        if not isinstance(digest, str) or not SHA256.fullmatch(digest):
            raise MappingError("public aggregate provenance hash is invalid")
    reliability_methods = _validate_public_reliability(value["reliability"])
    methods = value["methods"]
    if not isinstance(methods, list) or not methods:
        raise MappingError("public aggregate methods are invalid")
    seen = set()
    for method in methods:
        _exact_keys(method, {
            "methodID", "stratum", "license", "limitationCodes",
            "caseCount", "claimCount", "metrics",
        }, "public aggregate method")
        method_id = method["methodID"]
        public_metadata = PUBLIC_METHOD_METADATA.get(method_id)
        if method_id not in METHOD_FILES or method_id in seen \
                or method["stratum"] != "single-frame" \
                or not isinstance(public_metadata, dict) \
                or method["license"] != public_metadata["license"] \
                or method["limitationCodes"] != list(
                    public_metadata["limitationCodes"]
                ) \
                or not isinstance(method["caseCount"], int) \
                or method["caseCount"] != EXPECTED_CASES \
                or not isinstance(method["claimCount"], int) \
                or method["claimCount"] < 0:
            raise MappingError("public aggregate method inventory is invalid")
        seen.add(method_id)
        metrics = method["metrics"]
        _exact_keys(metrics, set(PUBLIC_METRICS), "public aggregate metrics")
        for key in PUBLIC_METRICS:
            _validate_public_score(metrics[key], "public aggregate metric")
    if seen != reliability_methods:
        raise MappingError(
            "public aggregate reliability inventory is invalid"
        )
    _reject_public_leaks(value, forbidden_values=forbidden_values)
