"""Reliability gating, adjudication, scoring, and transactional publication."""

from __future__ import annotations

import hmac
import os
import shutil
import uuid
from pathlib import Path
from typing import Any, Callable, Optional

from common.evaluator_receipt import (
    validate_independent_sessions,
    validate_receipt,
)

from .contracts import (
    ADJUDICATION_OWNER_SCHEMA,
    ADJUDICATION_PACKET_SCHEMA,
    ADJUDICATION_SCHEMA,
    AGGREGATE_RESULT_SCHEMA,
    CAPABILITY_ORDER,
    CLAIM_AGREEMENT_FLOOR,
    CLAIM_SOURCE_CAPABILITIES,
    DECISION_AGREEMENT_FLOOR,
    EXPECTED_CASES,
    METHOD_CAPABILITIES,
    PROTOCOL,
    PUBLIC_METHOD_METADATA,
    PUBLIC_SCHEMA,
    SAFE_ID,
    SEVERITY_WEIGHTS,
    UNSUPPORTED_SEVERITY_BY_SOURCE,
    MappingError,
    exact_keys as _exact_keys,
    reject_leaks as _reject_leaks,
    sha256 as _sha256,
    token as _token,
)
from .private_io import (
    json_bytes as _json_bytes,
    prepare_output_root as _prepare_output_root,
    read_private_bytes as _read_private_bytes,
    validate_existing_output_root as _validate_existing_output_root,
    validate_output_root_path as _validate_output_root_path,
)
from .validate import (
    load_mapping,
    validate_decision,
    validate_mapper_output_with_evidence,
    validate_public_output,
)


PrivateJSONLoader = Callable[[Path, str], tuple[dict[str, Any], bytes]]
PrivateJSONWriter = Callable[[Path, Any], bytes]


def _write_aggregate_result(
    root: Path,
    status: str,
    reliability: dict[str, Any],
    atomic_private_json: PrivateJSONWriter,
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
        "schema": AGGREGATE_RESULT_SCHEMA,
        "protocol": PROTOCOL,
        "status": status,
        "reliability": reliability,
        "adjudication": adjudication,
        "publicAggregate": public,
    }
    path = root / "aggregate-result.json"
    atomic_private_json(path, payload)
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
    overall = {
        "claimEqual": 0,
        "claimTotal": 0,
        "decisionEqual": 0,
        "decisionTotal": 0,
    }
    by_method = {
        method: {
            "duplicateArmCount": 0,
            "claimEqual": 0,
            "claimTotal": 0,
            "decisionEqual": 0,
            "decisionTotal": 0,
            "capabilities": {},
        }
        for method in mapping["selectedMethods"]
    }
    differences = []
    for hidden_arm, owner in mapping["hidden"].items():
        method_stats = by_method[owner["methodID"]]
        method_stats["duplicateArmCount"] += 1
        primary_arm = owner["primaryArmID"]
        left = primary[primary_arm]
        right = hidden[hidden_arm]
        left_claims = _claim_map(left)
        right_claims = _claim_map(right)
        claim_differences = []
        for pair in owner["claimPairs"]:
            primary_claim = pair["primaryClaimID"]
            hidden_claim = pair["hiddenClaimID"]
            capability_stats = method_stats["capabilities"].setdefault(
                pair["capability"], {"claimEqual": 0, "claimTotal": 0}
            )
            overall["claimTotal"] += 1
            method_stats["claimTotal"] += 1
            capability_stats["claimTotal"] += 1
            if left_claims[primary_claim] == right_claims[hidden_claim]:
                overall["claimEqual"] += 1
                method_stats["claimEqual"] += 1
                capability_stats["claimEqual"] += 1
            else:
                claim_differences.append({
                    "primaryClaimID": primary_claim,
                    "hiddenClaimID": hidden_claim,
                })
        critical_differences = []
        for index, (left_value, right_value) in enumerate(zip(
            left["criticalTextMatched"], right["criticalTextMatched"]
        )):
            overall["decisionTotal"] += 1
            method_stats["decisionTotal"] += 1
            if left_value == right_value:
                overall["decisionEqual"] += 1
                method_stats["decisionEqual"] += 1
            else:
                critical_differences.append(index)
        overall["decisionTotal"] += 1
        method_stats["decisionTotal"] += 1
        abstention_difference = (
            left["abstentionCorrect"] != right["abstentionCorrect"]
        )
        if not abstention_difference:
            overall["decisionEqual"] += 1
            method_stats["decisionEqual"] += 1
        if claim_differences or critical_differences or abstention_difference:
            differences.append({
                "primaryArmID": primary_arm,
                "hiddenArmID": hidden_arm,
                "claimDifferences": claim_differences,
                "criticalDifferences": critical_differences,
                "abstentionDifference": abstention_difference,
            })
    claim_agreement = (
        overall["claimEqual"] / overall["claimTotal"]
        if overall["claimTotal"] else 1.0
    )
    decision_agreement = (
        overall["decisionEqual"] / overall["decisionTotal"]
        if overall["decisionTotal"] else 1.0
    )
    method_reliability = []
    for method_id in mapping["selectedMethods"]:
        stats = by_method[method_id]
        method_claim_agreement = (
            stats["claimEqual"] / stats["claimTotal"]
            if stats["claimTotal"] else 1.0
        )
        method_decision_agreement = (
            stats["decisionEqual"] / stats["decisionTotal"]
            if stats["decisionTotal"] else 1.0
        )
        capabilities = []
        expected_capabilities = set(METHOD_CAPABILITIES[method_id]) | set(
            stats["capabilities"]
        )
        for capability in CAPABILITY_ORDER:
            if capability not in expected_capabilities:
                continue
            capability_stats = stats["capabilities"].get(capability)
            if capability_stats is None:
                capability_agreement = 0.0
                claim_count = 0
            else:
                claim_count = capability_stats["claimTotal"]
                capability_agreement = (
                    capability_stats["claimEqual"] / claim_count
                )
            capabilities.append({
                "capability": capability,
                "claimCount": claim_count,
                "claimJudgmentAgreement": capability_agreement,
                "qualified": (
                    claim_count > 0
                    and capability_agreement >= CLAIM_AGREEMENT_FLOOR
                ),
            })
        method_reliability.append({
            "methodID": method_id,
            "duplicateArmCount": stats["duplicateArmCount"],
            "claimJudgmentAgreement": method_claim_agreement,
            "decisionAgreement": method_decision_agreement,
            "capabilities": capabilities,
            "qualified": (
                method_claim_agreement >= CLAIM_AGREEMENT_FLOOR
                and method_decision_agreement >= DECISION_AGREEMENT_FLOOR
                and all(item["qualified"] for item in capabilities)
            ),
        })
    reliability = {
        "duplicateArmCount": len(mapping["hidden"]),
        "claimJudgmentAgreement": claim_agreement,
        "decisionAgreement": decision_agreement,
        "methods": method_reliability,
        "qualified": all(
            method["qualified"] for method in method_reliability
        ),
    }
    return reliability, differences


def _build_adjudication(
    aggregate_root: Path,
    mapping: dict,
    primary_packet: dict,
    differences: list[dict[str, Any]],
    case_ids: tuple[str, ...],
    atomic_private_json: PrivateJSONWriter,
) -> tuple[Path, Path, dict[str, Any]]:
    primary_items = {item["armID"]: item for item in primary_packet["items"]}
    seed_hash = mapping["seedSHA256"]
    work = []
    owners = {}
    for difference in sorted(
        differences, key=lambda value: value["primaryArmID"]
    ):
        arm_id = difference["primaryArmID"]
        source = primary_items[arm_id]
        source_claims = {
            claim["claimID"]: claim for claim in source["claims"]
        }
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
            seed_hash,
            "adjudication-packet",
            _sha256(_json_bytes(differences)),
            16,
        ),
        "items": work,
    }
    forbidden = tuple(mapping["selectedMethods"]) + case_ids
    _reject_leaks(packet, forbidden_values=forbidden)
    packet_path = aggregate_root / "adjudication-packet.json"
    packet_bytes = atomic_private_json(packet_path, packet)
    owner = {
        "schema": ADJUDICATION_OWNER_SCHEMA,
        "protocol": PROTOCOL,
        "packetSHA256": _sha256(packet_bytes),
        "items": owners,
    }
    owner_path = aggregate_root / "adjudication-owner.json"
    atomic_private_json(owner_path, owner)
    return packet_path, owner_path, packet


def _apply_adjudication(
    packet_path: Path,
    owner_path: Path,
    output_path: Path,
    primary_output: dict[str, Any],
    prior_identities: set[str],
    load_private_json: PrivateJSONLoader,
) -> tuple[str, str]:
    packet, packet_bytes = load_private_json(
        packet_path, "adjudication packet"
    )
    owner, _ = load_private_json(owner_path, "adjudication owner mapping")
    output, output_bytes = load_private_json(output_path, "adjudication output")
    if owner.get("schema") != ADJUDICATION_OWNER_SCHEMA \
            or owner.get("protocol") != PROTOCOL \
            or not hmac.compare_digest(
                str(owner.get("packetSHA256")), _sha256(packet_bytes)
            ):
        raise MappingError("adjudication owner mapping is invalid")
    _exact_keys(output, {
        "schema", "protocol", "packetID", "adjudicatorIdentity", "items",
    }, "adjudication output")
    identity = output["adjudicatorIdentity"]
    if output["schema"] != ADJUDICATION_SCHEMA \
            or output["protocol"] != PROTOCOL \
            or output["packetID"] != packet.get("packetID") \
            or not isinstance(identity, str) \
            or not SAFE_ID.fullmatch(identity) \
            or identity in prior_identities:
        raise MappingError("adjudicator identity must be fresh")
    _reject_leaks(output, subject="adjudication output")
    packet_items = {
        item["adjudicationID"]: item for item in packet.get("items", [])
    }
    owner_items = owner.get("items")
    if not isinstance(owner_items, dict) \
            or set(owner_items) != set(packet_items) \
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
        forbidden_ids = {
            fact["id"] for fact in item["forbiddenInferences"]
        }
        claim_owner = {
            pair["adjudicationClaimID"]: pair["primaryClaimID"]
            for pair in mapping["claimMap"]
        }
        actual_claims = set()
        primary_arm = primary_items[mapping["primaryArmID"]]
        primary_claims = {
            claim["claimID"]: claim
            for claim in primary_arm["claimJudgments"]
        }
        adjudication_claims = {
            claim["claimID"]: claim for claim in item["claimJudgments"]
        }
        for claim in result["claimJudgments"]:
            _exact_keys(claim, {"claimID", "judgment"}, "adjudicated claim")
            claim_id = claim["claimID"]
            if claim_id not in claim_owner or claim_id in actual_claims:
                raise MappingError("adjudicated claim identity is invalid")
            actual_claims.add(claim_id)
            validate_decision(
                claim["judgment"], required_ids, forbidden_ids
            )
            claim_source = adjudication_claims[claim_id]["source"]
            if "unsupported" in claim["judgment"] \
                    and claim["judgment"]["unsupported"] \
                        != UNSUPPORTED_SEVERITY_BY_SOURCE[claim_source]:
                raise MappingError(
                    "unsupported severity does not match the claim source"
                )
            primary_claims[claim_owner[claim_id]]["judgment"] = (
                claim["judgment"]
            )
        if actual_claims != set(claim_owner):
            raise MappingError(
                "adjudication does not cover disputed claims"
            )
        critical = result["criticalTextMatched"]
        if not isinstance(critical, list) \
                or len(critical) != len(mapping["criticalIndices"]) \
                or any(not isinstance(value, bool) for value in critical):
            raise MappingError(
                "adjudicated critical text decisions are invalid"
            )
        for index, value in zip(mapping["criticalIndices"], critical):
            primary_arm["criticalTextMatched"][index] = value
        if mapping["abstentionDisagreement"]:
            if not isinstance(result["abstentionCorrect"], bool):
                raise MappingError(
                    "adjudicated abstention decision is invalid"
                )
            primary_arm["abstentionCorrect"] = result["abstentionCorrect"]
        elif result["abstentionCorrect"] is not None:
            raise MappingError(
                "adjudication includes an undisputed abstention"
            )
    if seen != set(packet_items):
        raise MappingError(
            "adjudication does not cover every disagreement"
        )
    return _sha256(packet_bytes), _sha256(output_bytes)


def _score(
    mapping: dict,
    primary_packet: dict,
    primary_output: dict,
    reliability: dict[str, Any],
    forbidden_values: tuple[str, ...],
    method_ids: Optional[set[str]] = None,
) -> dict[str, Any]:
    packet_items = {
        item["armID"]: item for item in primary_packet["items"]
    }
    judgments = _judgment_map(primary_output)
    methods = []
    for method_id in mapping["selectedMethods"]:
        if method_ids is not None and method_id not in method_ids:
            continue
        arms = [
            arm_id for arm_id, owner in mapping["primary"].items()
            if owner["methodID"] == method_id
        ]
        if len(arms) != EXPECTED_CASES:
            raise MappingError(
                "method score does not meet the locked case minimum"
            )
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
            decisions = [
                claim["judgment"] for claim in judgment["claimJudgments"]
            ]
            for decision in decisions:
                claim_count += 1
                if "matchedRequired" in decision:
                    matched.add(decision["matchedRequired"])
                elif "matchedForbidden" in decision:
                    hallucination_weight += SEVERITY_WEIGHTS[
                        forbidden_severity[decision["matchedForbidden"]]
                    ]
                elif "unsupported" in decision:
                    hallucination_weight += SEVERITY_WEIGHTS[
                        decision["unsupported"]
                    ]
            required_hits += len(matched & required)
            required_total += len(required)
            critical_hits += sum(judgment["criticalTextMatched"])
            critical_total += len(judgment["criticalTextMatched"])
            abstention_hits += int(judgment["abstentionCorrect"])
        required_recall = required_hits / required_total
        critical_recall = (
            critical_hits / critical_total if critical_total else 1.0
        )
        hallucination = min(
            1.0, hallucination_weight / max(1, claim_count)
        )
        abstention_accuracy = abstention_hits / len(arms)
        overall = (
            required_recall + critical_recall + (1.0 - hallucination)
            + abstention_accuracy
        ) / 4.0
        public_metadata = PUBLIC_METHOD_METADATA[method_id]
        methods.append({
            "methodID": method_id,
            "stratum": "single-image",
            "license": public_metadata["license"],
            "limitationCodes": list(public_metadata["limitationCodes"]),
            "caseCount": len(arms),
            "claimCount": claim_count,
            "metrics": {
                "requiredFactRecall": required_recall,
                "criticalTextRecall": critical_recall,
                "severityWeightedHallucination": hallucination,
                "abstentionAccuracy": abstention_accuracy,
                "overall": overall,
            },
        })
    public = {
        "schema": PUBLIC_SCHEMA,
        "protocol": PROTOCOL,
        "status": "qualified",
        **mapping["publicProvenance"],
        "reliability": reliability,
        "methods": methods,
    }
    validate_public_output(public, forbidden_values=forbidden_values)
    return public


def _qualified_public_reliability(
    reliability: dict[str, Any],
    mapping: dict[str, Any],
    primary_packet: dict[str, Any],
) -> tuple[dict[str, Any], set[str]] | tuple[None, set[str]]:
    methods = [
        method for method in reliability["methods"]
        if method["qualified"]
    ]
    method_ids = {method["methodID"] for method in methods}
    if not methods:
        return None, method_ids
    claim_total = sum(
        capability["claimCount"]
        for method in methods
        for capability in method["capabilities"]
    )
    claim_equal = sum(
        round(
            capability["claimJudgmentAgreement"]
            * capability["claimCount"]
        )
        for method in methods
        for capability in method["capabilities"]
    )
    primary_items = {
        item["armID"]: item for item in primary_packet["items"]
    }
    decision_total = 0
    for owner in mapping["hidden"].values():
        if owner["methodID"] in method_ids:
            decision_total += (
                len(primary_items[owner["primaryArmID"]]["criticalText"]) + 1
            )
    decision_equal = sum(
        round(method["decisionAgreement"] * sum(
            len(primary_items[owner["primaryArmID"]]["criticalText"]) + 1
            for owner in mapping["hidden"].values()
            if owner["methodID"] == method["methodID"]
        ))
        for method in methods
    )
    return {
        "duplicateArmCount": sum(method["duplicateArmCount"] for method in methods),
        "claimJudgmentAgreement": (
            claim_equal / claim_total if claim_total else 1.0
        ),
        "decisionAgreement": decision_equal / decision_total,
        "methods": methods,
        "qualified": True,
    }, method_ids


def aggregate_mappings(
    mapping_root: Path,
    primary_output_path: Path,
    hidden_output_path: Path,
    aggregate_root: Path,
    adjudication_output_path: Optional[Path] = None,
    primary_receipt_path: Optional[Path] = None,
    hidden_receipt_path: Optional[Path] = None,
    adjudication_receipt_path: Optional[Path] = None,
    *,
    load_private_json: PrivateJSONLoader,
    atomic_private_json: PrivateJSONWriter,
) -> dict[str, Any]:
    target = _validate_output_root_path(Path(aggregate_root))
    if target.exists():
        raise MappingError("aggregate root already exists")
    mapping_root = _validate_existing_output_root(Path(mapping_root))
    mapping, primary_packet, hidden_packet = load_mapping(
        mapping_root, load_private_json
    )
    primary_output, primary_packet_sha256, primary_output_sha256 = (
        validate_mapper_output_with_evidence(
        mapping_root / "primary-packet.json",
        Path(primary_output_path),
        load_private_json=load_private_json,
        )
    )
    hidden_output, hidden_packet_sha256, hidden_output_sha256 = (
        validate_mapper_output_with_evidence(
        mapping_root / "hidden-packet.json",
        Path(hidden_output_path),
        primary_output["mapperIdentity"],
        load_private_json=load_private_json,
        )
    )
    primary_receipt_path = primary_receipt_path or Path(
        primary_output_path
    ).with_suffix(".receipt.json")
    hidden_receipt_path = hidden_receipt_path or Path(
        hidden_output_path
    ).with_suffix(".receipt.json")
    mapper_receipts = [
        validate_receipt(
            primary_receipt_path,
            mapping_root / "primary-packet.json",
            Path(primary_output_path),
            "claim-mapper-primary",
            expected_packet_sha256=primary_packet_sha256,
            expected_output_sha256=primary_output_sha256,
        ),
        validate_receipt(
            hidden_receipt_path,
            mapping_root / "hidden-packet.json",
            Path(hidden_output_path),
            "claim-mapper-hidden",
            expected_packet_sha256=hidden_packet_sha256,
            expected_output_sha256=hidden_output_sha256,
        ),
    ]
    validate_independent_sessions(
        mapper_receipts, {"claim-mapper-primary", "claim-mapper-hidden"}
    )
    case_ids = tuple(sorted({
        owner["caseID"] for owner in mapping["primary"].values()
    }))
    forbidden_values = tuple(mapping["selectedMethods"]) + case_ids
    _reject_leaks(
        primary_output,
        forbidden_values=forbidden_values,
        subject="mapper judgments",
    )
    _reject_leaks(
        hidden_output,
        forbidden_values=forbidden_values,
        subject="mapper judgments",
    )
    reliability, differences = _duplicate_agreement(
        mapping, primary_output, hidden_output
    )
    public_reliability, qualified_method_ids = _qualified_public_reliability(
        reliability, mapping, primary_packet
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    staging_candidate = target.parent / f".{target.name}.tmp-{uuid.uuid4().hex}"
    published = False
    result: dict[str, Any] = {
        "status": "qualified",
        "reliability": reliability,
    }
    try:
        staging = _prepare_output_root(staging_candidate)
        packet_path = None
        owner_path = None
        if differences:
            packet_path, owner_path, _ = _build_adjudication(
                staging,
                mapping,
                primary_packet,
                differences,
                case_ids,
                atomic_private_json,
            )
            result["adjudicationPacket"] = str(packet_path)
        if not reliability["qualified"] and not qualified_method_ids:
            result["status"] = "inconclusive"
            result["aggregateResult"] = str(_write_aggregate_result(
                staging,
                result["status"],
                reliability,
                atomic_private_json,
                packet_path,
            ))
        elif differences and adjudication_output_path is None:
            result["status"] = (
                "adjudication-required" if reliability["qualified"]
                else "partial-adjudication-required"
            )
            result["aggregateResult"] = str(_write_aggregate_result(
                staging,
                result["status"],
                reliability,
                atomic_private_json,
                packet_path,
            ))
        else:
            if differences:
                assert packet_path is not None and owner_path is not None
                adjudication_packet_sha256, adjudication_output_sha256 = _apply_adjudication(
                    packet_path,
                    owner_path,
                    Path(adjudication_output_path),
                    primary_output,
                    {
                        primary_output["mapperIdentity"],
                        hidden_output["mapperIdentity"],
                    },
                    load_private_json,
                )
                adjudication_receipt_path = adjudication_receipt_path or Path(
                    adjudication_output_path
                ).with_suffix(".receipt.json")
                adjudicator_receipt = validate_receipt(
                    adjudication_receipt_path,
                    packet_path,
                    Path(adjudication_output_path),
                    "claim-adjudicator",
                    expected_packet_sha256=adjudication_packet_sha256,
                    expected_output_sha256=adjudication_output_sha256,
                )
                validate_independent_sessions(
                    [*mapper_receipts, adjudicator_receipt],
                    {
                        "claim-mapper-primary", "claim-mapper-hidden",
                        "claim-adjudicator",
                    },
                )
            declassification_secrets = (
                mapping["seedSHA256"],
                mapping["primaryPacketSHA256"],
                mapping["hiddenPacketSHA256"],
                primary_output["mapperIdentity"],
                hidden_output["mapperIdentity"],
                *case_ids,
            )
            selected_reliability = (
                reliability if reliability["qualified"] else public_reliability
            )
            assert selected_reliability is not None
            public = _score(
                mapping,
                primary_packet,
                primary_output,
                selected_reliability,
                declassification_secrets,
                None if reliability["qualified"] else qualified_method_ids,
            )
            if not reliability["qualified"]:
                result["status"] = "partial-qualified"
            public_path = staging / "public-aggregate.json"
            atomic_private_json(public_path, public)
            result["publicAggregate"] = str(public_path)
            result["aggregateResult"] = str(_write_aggregate_result(
                staging,
                result["status"],
                reliability,
                atomic_private_json,
                packet_path,
                public_path,
            ))
        os.replace(staging, target)
        published = True
        target = _validate_existing_output_root(target)
    except BaseException:
        shutil.rmtree(staging_candidate, ignore_errors=True)
        if published:
            shutil.rmtree(target, ignore_errors=True)
        raise
    for key in ("adjudicationPacket", "publicAggregate", "aggregateResult"):
        if key in result:
            result[key] = str(target / Path(result[key]).name)
    return result
