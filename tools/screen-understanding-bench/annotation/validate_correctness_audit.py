#!/usr/bin/python3
"""Fail-closed validation for blinded correctness-audit judgments."""

import argparse
import json
import re
from pathlib import Path


PROTOCOL = "screen-understanding-correctness-audit-v3"
RUBRIC = "screen-understanding-canonical-v2"
BASE_SLOTS = {"surface", "content", "state", "intent", "outcome", "criticalText"}
SAFE_ID = re.compile(r"^[A-Za-z0-9._-]{1,96}$")
REFERENCE_KEYS = {
    "targetType", "requiredFacts", "criticalText", "forbiddenInferences",
    "meaningfulChange", "ambiguity", "abstentionAllowed",
}


def exact_keys(value: object, expected: set[str], subject: str) -> None:
    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError(f"{subject} keys do not match the locked schema")


def contains_forbidden(value: str) -> bool:
    lowered = value.lower()
    return any(fragment in lowered for fragment in [
        "candidateoutput", "methodid", '"case"', '"path"',
        "/users/", "/volumes/", "file://",
    ])


def validate_reference(reference: object, target: str) -> None:
    exact_keys(reference, REFERENCE_KEYS, "packet reference")
    if reference["targetType"] != target:
        raise ValueError("packet reference target type mismatch")
    required = reference["requiredFacts"]
    forbidden = reference["forbiddenInferences"]
    if not isinstance(required, list) or [fact.get("id") for fact in required] != [
        "required.surface", "required.content", "required.state",
    ]:
        raise ValueError("packet reference required slots are invalid")
    if not isinstance(forbidden, list) or [fact.get("id") for fact in forbidden] != [
        "forbidden.intent", "forbidden.outcome",
    ]:
        raise ValueError("packet reference forbidden slots are invalid")
    for fact in required + forbidden:
        if not isinstance(fact, dict) or not {"id", "text"}.issubset(fact) \
                or not set(fact).issubset({"id", "text", "severity"}) \
                or not isinstance(fact["text"], str) or not fact["text"]:
            raise ValueError("packet reference fact is invalid")
    if any("severity" not in fact for fact in forbidden):
        raise ValueError("packet reference forbidden severity is missing")
    critical_text = reference["criticalText"]
    if not isinstance(critical_text, list) or len(critical_text) > 2 \
            or any(not isinstance(text, str) or not text for text in critical_text):
        raise ValueError("packet reference critical text is invalid")
    change = reference["meaningfulChange"]
    if target == "single-frame" and change is not None:
        raise ValueError("single-frame packet reference contains temporal change")
    if target == "temporal-pair" and (not isinstance(change, list) or len(change) > 3):
        raise ValueError("temporal packet reference change is invalid")
    if reference["ambiguity"] not in {"judgeable", "ambiguous", "unjudgeable"} \
            or not isinstance(reference["abstentionAllowed"], bool):
        raise ValueError("packet reference ambiguity decision is invalid")


def validate_packet_item(item: object, tiebreak: bool = False) -> None:
    expected = {"opaqueID", "targetType", "reference", "images"}
    if tiebreak:
        expected.add("disputed")
    exact_keys(item, expected, "packet item")
    identifier = item["opaqueID"]
    if not isinstance(identifier, str) or not SAFE_ID.fullmatch(identifier):
        raise ValueError("packet opaque identifier is invalid")
    target = item["targetType"]
    if target not in {"single-frame", "temporal-pair"}:
        raise ValueError("packet target type is invalid")
    validate_reference(item["reference"], target)
    expected_images = 1 if target == "single-frame" else 2
    images = item["images"]
    if not isinstance(images, list) or len(images) != expected_images:
        raise ValueError("packet images are invalid")
    for image in images:
        path = Path(image) if isinstance(image, str) else None
        if path is None or path.is_absolute() or len(path.parts) != 2 \
                or path.parts[0] != "images" or ".." in path.parts \
                or not path.name.startswith(identifier):
            raise ValueError("packet image alias is invalid")
    if tiebreak:
        disputes = item["disputed"]
        allowed_slots = set(BASE_SLOTS)
        if target == "temporal-pair":
            allowed_slots.add("meaningfulChange")
        allowed_slots.add("ambiguityDecision")
        seen = set()
        if not isinstance(disputes, list) or not disputes:
            raise ValueError("tiebreak disputes are missing")
        for dispute in disputes:
            exact_keys(dispute, {"slot", "field"}, "tiebreak dispute")
            key = (dispute["slot"], dispute["field"])
            valid_fields = {"correct"} if dispute["slot"] == "ambiguityDecision" \
                else {"correct", "materialFalse"}
            if dispute["slot"] not in allowed_slots or dispute["field"] not in valid_fields \
                    or key in seen:
                raise ValueError("tiebreak dispute is invalid")
            seen.add(key)


def load_packet(packet_path: Path) -> dict:
    packet = json.loads(packet_path.read_text(encoding="utf-8"))
    exact_keys(packet, {
        "schema", "protocol", "rubricVersion", "packetID", "items",
    }, "audit packet")
    if packet["schema"] != "screen-understanding-correctness-audit-packet-v3" \
            or packet["protocol"] != PROTOCOL:
        raise ValueError("audit packet protocol mismatch")
    if packet["rubricVersion"] != RUBRIC:
        raise ValueError("audit packet rubric mismatch")
    if not isinstance(packet["packetID"], str) or not SAFE_ID.fullmatch(packet["packetID"]):
        raise ValueError("audit packet identity is missing")
    if not isinstance(packet["items"], list) or not packet["items"]:
        raise ValueError("audit packet items are missing")
    identifiers = set()
    for item in packet["items"]:
        validate_packet_item(item)
        identifier = item["opaqueID"]
        if identifier in identifiers:
            raise ValueError("packet opaque identifiers are invalid")
        identifiers.add(identifier)
    return packet


def validate(packet_path: Path, judgments_path: Path) -> dict:
    packet = load_packet(packet_path)
    output_text = judgments_path.read_text(encoding="utf-8")
    if contains_forbidden(output_text):
        raise ValueError("audit judgments contain a forbidden field or local path")
    output = json.loads(output_text)
    exact_keys(output, {
        "schema", "protocol", "rubricVersion", "packetID", "auditor", "items",
    }, "audit judgments")
    if output["schema"] != "screen-understanding-correctness-audit-judgments-v3" \
            or output["protocol"] != PROTOCOL:
        raise ValueError("audit judgment protocol mismatch")
    if output["rubricVersion"] != RUBRIC or output["rubricVersion"] != packet["rubricVersion"]:
        raise ValueError("audit judgment rubric mismatch")
    if output["packetID"] != packet["packetID"]:
        raise ValueError("audit judgment packet mismatch")
    if not isinstance(output["auditor"], str) or not SAFE_ID.fullmatch(output["auditor"]):
        raise ValueError("audit judgment auditor is missing")

    expected = {item["opaqueID"]: item for item in packet["items"]}
    judgments = output["items"]
    if not isinstance(judgments, list) or len(judgments) != len(expected):
        raise ValueError("audit judgment count does not match the packet")
    by_id = {}
    single_count = 0
    temporal_count = 0
    for judgment in judgments:
        exact_keys(judgment, {"opaqueID", "slots", "ambiguityDecision"}, "audit judgment")
        identifier = judgment["opaqueID"]
        if identifier not in expected or identifier in by_id:
            raise ValueError("audit judgment opaque identifiers are invalid")
        if not isinstance(judgment["ambiguityDecision"], bool):
            raise ValueError("ambiguity decision must be boolean")
        target = expected[identifier]["targetType"]
        expected_slots = set(BASE_SLOTS)
        if target == "temporal-pair":
            expected_slots.add("meaningfulChange")
            temporal_count += 1
        else:
            single_count += 1
        slots = judgment["slots"]
        exact_keys(slots, expected_slots, "audit judgment slots")
        for name, slot in slots.items():
            exact_keys(slot, {"correct", "materialFalse"}, f"{name} judgment")
            if not isinstance(slot["correct"], bool) \
                    or not isinstance(slot["materialFalse"], bool):
                raise ValueError("slot judgments must be boolean")
        by_id[identifier] = judgment
    if set(by_id) != set(expected):
        raise ValueError("audit judgments do not cover the packet")
    return {
        "count": len(by_id),
        "singleFrames": single_count,
        "temporalPairs": temporal_count,
    }


def validate_tiebreak(packet_path: Path, judgments_path: Path) -> dict:
    packet = json.loads(packet_path.read_text(encoding="utf-8"))
    exact_keys(packet, {
        "schema", "protocol", "rubricVersion", "packetID", "items",
    }, "tiebreak packet")
    if packet["schema"] != "screen-understanding-correctness-tiebreak-work-v3" \
            or packet["protocol"] != PROTOCOL or packet["rubricVersion"] != RUBRIC:
        raise ValueError("tiebreak packet metadata mismatch")
    if not isinstance(packet["packetID"], str) or not SAFE_ID.fullmatch(packet["packetID"]):
        raise ValueError("tiebreak packet identity is invalid")
    if not isinstance(packet["items"], list) or not packet["items"]:
        raise ValueError("tiebreak packet items are missing")
    identifiers = set()
    for item in packet["items"]:
        validate_packet_item(item, tiebreak=True)
        if item["opaqueID"] in identifiers:
            raise ValueError("tiebreak packet identifiers are duplicated")
        identifiers.add(item["opaqueID"])
    output_text = judgments_path.read_text(encoding="utf-8")
    if contains_forbidden(output_text):
        raise ValueError("tiebreak judgments contain a forbidden field or local path")
    output = json.loads(output_text)
    exact_keys(output, {
        "schema", "protocol", "rubricVersion", "packetID", "auditor", "items",
    }, "tiebreak judgments")
    if output["schema"] != "screen-understanding-correctness-tiebreak-judgments-v3" \
            or output["protocol"] != PROTOCOL:
        raise ValueError("tiebreak judgment protocol mismatch")
    if output["rubricVersion"] != RUBRIC:
        raise ValueError("tiebreak judgment rubric mismatch")
    if output["packetID"] != packet["packetID"]:
        raise ValueError("tiebreak judgment packet mismatch")
    if not isinstance(output["auditor"], str) or not SAFE_ID.fullmatch(output["auditor"]):
        raise ValueError("tiebreak auditor is missing")

    expected = {item["opaqueID"]: item for item in packet["items"]}
    if len(expected) != len(packet["items"]) or not expected:
        raise ValueError("tiebreak packet identifiers are invalid")
    actual = {}
    if not isinstance(output["items"], list):
        raise ValueError("tiebreak judgment items are invalid")
    for item in output["items"]:
        exact_keys(item, {"opaqueID", "decisions"}, "tiebreak judgment item")
        identifier = item["opaqueID"]
        if identifier not in expected or identifier in actual:
            raise ValueError("tiebreak judgment identifiers are invalid")
        expected_disputes = {
            (dispute["slot"], dispute["field"])
            for dispute in expected[identifier]["disputed"]
        }
        decisions = {}
        for decision in item["decisions"]:
            exact_keys(decision, {"slot", "field", "value"}, "tiebreak decision")
            key = (decision["slot"], decision["field"])
            if key not in expected_disputes or key in decisions \
                    or not isinstance(decision["value"], bool):
                raise ValueError("tiebreak decision is invalid")
            decisions[key] = decision["value"]
        if set(decisions) != expected_disputes:
            raise ValueError("tiebreak decisions do not cover disagreements")
        actual[identifier] = decisions
    if set(actual) != set(expected):
        raise ValueError("tiebreak judgments do not cover the packet")
    return actual


def summarize_tiebreak(result: dict) -> dict:
    return {
        "count": len(result),
        "decisionCount": sum(len(decisions) for decisions in result.values()),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--packet", required=True, type=Path)
    parser.add_argument("--judgments", required=True, type=Path)
    parser.add_argument("--tiebreak", action="store_true")
    args = parser.parse_args()
    if args.tiebreak:
        result = summarize_tiebreak(validate_tiebreak(args.packet, args.judgments))
    else:
        result = validate(args.packet, args.judgments)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
