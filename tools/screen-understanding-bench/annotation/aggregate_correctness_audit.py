#!/usr/bin/python3
"""Aggregate two blinded correctness audits and a boolean-only tiebreak."""

from __future__ import annotations

import argparse
import hashlib
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
SLOT_ORDER = [
    "surface", "content", "state", "intent", "outcome", "criticalText",
    "meaningfulChange",
]


def validation_module():
    path = Path(__file__).with_name("validate_correctness_audit.py")
    spec = importlib.util.spec_from_file_location("validate_correctness_audit_v3", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def make_directory(path: Path) -> None:
    path.mkdir(mode=0o700)
    path.chmod(0o700)


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


def copy_private(source: Path, destination: Path) -> None:
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    try:
        with source.open("rb") as input_handle, os.fdopen(descriptor, "wb") as output_handle:
            shutil.copyfileobj(input_handle, output_handle)
            output_handle.flush()
            os.fsync(output_handle.fileno())
        destination.chmod(0o600)
    except BaseException:
        destination.unlink(missing_ok=True)
        raise


def exact_keys(value: object, expected: set[str], subject: str) -> None:
    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError(f"{subject} keys do not match the locked schema")


def load_audit(root: Path, judgment_paths: tuple[Path, Path]) -> tuple[dict, dict, list[dict]]:
    validator = validation_module()
    manifest = json.loads((root / "audit-manifest.json").read_text(encoding="utf-8"))
    exact_keys(manifest, {
        "schema", "protocol", "rubricVersion", "caseCount", "singleFrameCount",
        "temporalPairCount", "referenceCount", "pairedOpportunityCount",
        "auditorCount", "candidateOutputsAvailable",
    }, "audit manifest")
    if manifest["schema"] != "screen-understanding-correctness-audit-manifest-v3" \
            or manifest["protocol"] != PROTOCOL:
        raise ValueError("audit manifest protocol mismatch")
    if manifest["rubricVersion"] != RUBRIC:
        raise ValueError("audit manifest rubric mismatch")
    if manifest["auditorCount"] != 2 or manifest["candidateOutputsAvailable"] is not False:
        raise ValueError("audit manifest provenance is invalid")

    mapping = json.loads((root / "owner-mapping.json").read_text(encoding="utf-8"))
    exact_keys(mapping, {
        "schema", "protocol", "rubricVersion", "seedSHA256", "auditors",
    }, "owner mapping")
    if mapping["schema"] != "screen-understanding-correctness-audit-mapping-v3" \
            or mapping["protocol"] != PROTOCOL:
        raise ValueError("owner mapping protocol mismatch")
    if mapping["rubricVersion"] != RUBRIC:
        raise ValueError("owner mapping rubric mismatch")
    if not isinstance(mapping["seedSHA256"], str) \
            or not re.fullmatch(r"[0-9a-f]{64}", mapping["seedSHA256"]):
        raise ValueError("owner mapping seed is invalid")
    if set(mapping["auditors"]) != {"auditor-01", "auditor-02"}:
        raise ValueError("owner mapping auditor slots are invalid")

    loaded = []
    auditor_names = set()
    canonical_keys = None
    for index, judgment_path in enumerate(judgment_paths, start=1):
        slot = f"auditor-{index:02d}"
        packet_path = root / "packets" / slot / "packet.json"
        validator.validate(packet_path, judgment_path)
        packet = validator.load_packet(packet_path)
        output_text = judgment_path.read_text(encoding="utf-8")
        output = json.loads(output_text)
        if output["auditor"] in auditor_names:
            raise ValueError("independent auditors must have distinct identities")
        auditor_names.add(output["auditor"])
        slot_mapping = mapping["auditors"][slot]
        packet_items = {item["opaqueID"]: item for item in packet["items"]}
        judgments = {item["opaqueID"]: item for item in output["items"]}
        if set(slot_mapping) != set(packet_items) or set(judgments) != set(packet_items):
            raise ValueError("mapping, packet, and judgments do not cover the same opaque set")
        by_key = {}
        for opaque_id, owner in slot_mapping.items():
            exact_keys(owner, {
                "case", "sourceReference", "pass", "targetType",
            }, "owner mapping item")
            identifier = owner["case"]
            pass_number = owner["pass"]
            target = owner["targetType"]
            if not isinstance(identifier, str) or not CASE_ID.fullmatch(identifier):
                raise ValueError("owner mapping case is invalid")
            if pass_number not in {1, 2} \
                    or owner["sourceReference"] != f"pass{pass_number}":
                raise ValueError("owner mapping pass is invalid")
            if packet_items[opaque_id]["targetType"] != target:
                raise ValueError("owner mapping target type mismatch")
            key = (identifier, pass_number)
            if key in by_key:
                raise ValueError("owner mapping reference is duplicated")
            by_key[key] = {
                "judgment": judgments[opaque_id],
                "packetItem": packet_items[opaque_id],
                "targetType": target,
                "opaqueID": opaque_id,
            }
        keys = set(by_key)
        if canonical_keys is None:
            canonical_keys = keys
        elif keys != canonical_keys:
            raise ValueError("auditor mappings do not cover the same references")
        if any(case_id in output_text for case_id, _ in keys):
            raise ValueError("audit judgments expose an owner case identifier")
        loaded.append({"auditor": output["auditor"], "byKey": by_key, "root": packet_path.parent})

    case_ids = {identifier for identifier, _ in canonical_keys or set()}
    expected_reference_count = len(case_ids) * 2
    expected_single = sum(
        loaded[0]["byKey"][(identifier, 1)]["targetType"] == "single-frame"
        for identifier in case_ids
    )
    expected_temporal = len(case_ids) - expected_single
    expected_opportunities = expected_single * 6 + expected_temporal * 7
    if (len(case_ids), expected_single, expected_temporal, expected_opportunities) \
            != (45, 30, 15, 285):
        raise ValueError("audit does not match the locked 45-case duplicate protocol")
    if (
        manifest["caseCount"] != len(case_ids)
        or manifest["referenceCount"] != expected_reference_count
        or manifest["singleFrameCount"] != expected_single
        or manifest["temporalPairCount"] != expected_temporal
        or manifest["pairedOpportunityCount"] != expected_opportunities
    ):
        raise ValueError("audit manifest counts do not match owner mapping")
    for key in canonical_keys or set():
        left = loaded[0]["byKey"][key]
        right = loaded[1]["byKey"][key]
        if left["targetType"] != right["targetType"] \
                or left["packetItem"]["reference"] != right["packetItem"]["reference"]:
            raise ValueError("auditors did not receive the same underlying reference")
    return manifest, mapping, loaded


def boolean_fields(judgment: dict) -> dict[tuple[str, str], bool]:
    values = {}
    for slot in SLOT_ORDER:
        if slot in judgment["slots"]:
            values[(slot, "correct")] = judgment["slots"][slot]["correct"]
            values[(slot, "materialFalse")] = judgment["slots"][slot]["materialFalse"]
    values[("ambiguityDecision", "correct")] = judgment["ambiguityDecision"]
    return values


def disagreements(loaded: list[dict]) -> dict[tuple[str, int], list[tuple[str, str]]]:
    differences = {}
    for key in loaded[0]["byKey"]:
        first = boolean_fields(loaded[0]["byKey"][key]["judgment"])
        second = boolean_fields(loaded[1]["byKey"][key]["judgment"])
        if set(first) != set(second):
            raise ValueError("auditor judgment shapes do not match")
        fields = [field for field in first if first[field] != second[field]]
        if fields:
            differences[key] = fields
    return differences


def build_tiebreak(
    staging: Path,
    seed_hash: str,
    differences: dict,
    loaded: list[dict],
) -> tuple[Path, dict]:
    tiebreak_root = staging / "tiebreak"
    make_directory(tiebreak_root)
    make_directory(tiebreak_root / "images")
    work_items = []
    owner_mapping = {}
    for key in sorted(differences):
        identifier, pass_number = key
        source = loaded[0]["byKey"][key]
        opaque_id = "tie-" + digest(
            f"{seed_hash}:tiebreak:{identifier}:{pass_number}"
        )[:24]
        images = []
        for index, relative in enumerate(source["packetItem"]["images"], start=1):
            source_path = (loaded[0]["root"] / relative).resolve(strict=True)
            if loaded[0]["root"] not in source_path.parents \
                    or not source_path.is_file() or source_path.is_symlink():
                raise ValueError("tiebreak source image is invalid")
            suffix = source_path.suffix.lower()
            destination_relative = f"images/{opaque_id}-{index}{suffix}"
            copy_private(source_path, tiebreak_root / destination_relative)
            images.append(destination_relative)
        disputes = [
            {"slot": slot, "field": field}
            for slot, field in differences[key]
        ]
        work_items.append({
            "opaqueID": opaque_id,
            "targetType": source["targetType"],
            "reference": source["packetItem"]["reference"],
            "images": images,
            "disputed": disputes,
        })
        owner_mapping[opaque_id] = {
            "case": identifier,
            "sourceReference": f"pass{pass_number}",
            "pass": pass_number,
            "targetType": source["targetType"],
        }
    work_items.sort(key=lambda item: digest(f"{seed_hash}:tie-order:{item['opaqueID']}"))
    packet = {
        "schema": "screen-understanding-correctness-tiebreak-work-v3",
        "protocol": PROTOCOL,
        "rubricVersion": RUBRIC,
        "packetID": "tiebreak-" + digest(f"{seed_hash}:packet")[:24],
        "items": work_items,
    }
    serialized = json.dumps(packet, ensure_ascii=False, sort_keys=True)
    if any(identifier in serialized for identifier, _ in differences):
        raise ValueError("tiebreak packet exposes an owner case identifier")
    atomic_private_json(tiebreak_root / "packet.json", packet)
    mapping_payload = {
        "schema": "screen-understanding-correctness-tiebreak-mapping-v3",
        "protocol": PROTOCOL,
        "rubricVersion": RUBRIC,
        "items": owner_mapping,
    }
    atomic_private_json(staging / "tiebreak-owner-mapping.json", mapping_payload)
    return tiebreak_root / "packet.json", owner_mapping


def resolved_boolean_fields(
    differences: dict,
    loaded: list[dict],
    tiebreak_values: dict,
    tiebreak_mapping: dict,
) -> dict[tuple[str, int], dict[tuple[str, str], bool]]:
    reverse_tiebreak = {
        (owner["case"], owner["pass"]): opaque_id
        for opaque_id, owner in tiebreak_mapping.items()
    }
    resolved = {}
    for key in loaded[0]["byKey"]:
        first = boolean_fields(loaded[0]["byKey"][key]["judgment"])
        second = boolean_fields(loaded[1]["byKey"][key]["judgment"])
        combined = {}
        for field, first_value in first.items():
            second_value = second[field]
            if first_value == second_value:
                combined[field] = first_value
            else:
                opaque_id = reverse_tiebreak.get(key)
                if opaque_id is None:
                    raise ValueError("tiebreak mapping does not cover a disagreement")
                combined[field] = tiebreak_values[opaque_id][field]
        resolved[key] = combined
    return resolved


def safe_rate(numerator: int, denominator: int) -> float | None:
    return numerator / denominator if denominator else None


def score(resolved: dict, targets: dict) -> tuple[dict, dict, dict, dict]:
    counts = {
        "overall": 0, "singleFrame": 0, "temporalPair": 0,
    }
    correct = {
        1: {key: 0 for key in counts},
        2: {key: 0 for key in counts},
        "joint": {key: 0 for key in counts},
    }
    material = {1: 0, 2: 0}
    by_case = {}
    case_ids = sorted({identifier for identifier, _ in resolved})
    for identifier in case_ids:
        target = targets[identifier]
        stratum = "singleFrame" if target == "single-frame" else "temporalPair"
        slot_names = SLOT_ORDER[:-1] if target == "single-frame" else SLOT_ORDER
        full = {}
        for pass_number in (1, 2):
            fields = resolved[(identifier, pass_number)]
            full[pass_number] = bool(fields[("ambiguityDecision", "correct")])
            for slot in slot_names:
                is_correct = fields[(slot, "correct")] \
                    and not fields[(slot, "materialFalse")]
                material[pass_number] += int(fields[(slot, "materialFalse")])
                correct[pass_number]["overall"] += int(is_correct)
                correct[pass_number][stratum] += int(is_correct)
                full[pass_number] = full[pass_number] and is_correct
        for slot in slot_names:
            joint = all(
                resolved[(identifier, pass_number)][(slot, "correct")]
                and not resolved[(identifier, pass_number)][(slot, "materialFalse")]
                for pass_number in (1, 2)
            )
            correct["joint"]["overall"] += int(joint)
            correct["joint"][stratum] += int(joint)
            counts["overall"] += 1
            counts[stratum] += 1
        selected = "pass1" if full[1] else "pass2" if full[2] else "merge-required"
        by_case[identifier] = {
            "targetType": target,
            "selectedReference": selected,
            "selectedFinalAudit": "pending",
        }
    rates = {}
    for source in [1, 2, "joint"]:
        rates[source] = {
            key: safe_rate(correct[source][key], counts[key]) for key in counts
        }
    return rates, counts, material, by_case


def aggregate(
    audit_root: Path,
    auditor_one: Path,
    auditor_two: Path,
    output_root: Path,
    tiebreak_output: Path | None = None,
) -> dict:
    audit = audit_root.resolve(strict=True)
    output = output_root.resolve(strict=False)
    if output.exists():
        raise ValueError("correctness aggregation output already exists")
    manifest, mapping, loaded = load_audit(audit, (auditor_one, auditor_two))
    differences = disagreements(loaded)
    if not differences and tiebreak_output is not None:
        raise ValueError("tiebreak output was supplied without disagreements")

    staging = output.parent / f".{output.name}.staging-{uuid.uuid4().hex}"
    make_directory(staging)
    try:
        tiebreak_values = {}
        tiebreak_mapping = {}
        if differences:
            packet_path, tiebreak_mapping = build_tiebreak(
                staging,
                mapping["seedSHA256"],
                differences,
                loaded,
            )
            if tiebreak_output is None:
                pending = {
                    "schema": "screen-understanding-correctness-audit-result-v3",
                    "protocol": PROTOCOL,
                    "rubricVersion": RUBRIC,
                    "state": "tiebreak-required",
                    "disputedReferenceCount": len(differences),
                    "disputedBooleanCount": sum(len(value) for value in differences.values()),
                }
                atomic_private_json(staging / "result.json", pending)
                staging.rename(output)
                output.chmod(0o700)
                return pending
            validator = validation_module()
            tiebreak_values = validator.validate_tiebreak(packet_path, tiebreak_output)
            third = json.loads(tiebreak_output.read_text(encoding="utf-8"))
            third_text = tiebreak_output.read_text(encoding="utf-8")
            if any(identifier in third_text for identifier, _ in differences):
                raise ValueError("tiebreak judgments expose an owner case identifier")
            if third["auditor"] in {loaded[0]["auditor"], loaded[1]["auditor"]}:
                raise ValueError("tiebreak auditor must be independent")

        resolved = resolved_boolean_fields(
            differences,
            loaded,
            tiebreak_values,
            tiebreak_mapping,
        )
        targets = {
            identifier: loaded[0]["byKey"][(identifier, 1)]["targetType"]
            for identifier, _ in resolved
        }
        rates, counts, material, selections = score(resolved, targets)
        if counts["overall"] != manifest["pairedOpportunityCount"]:
            raise ValueError("paired opportunity count changed during aggregation")
        joint = rates["joint"]
        gate_checks = {
            "overall": joint["overall"] is not None and joint["overall"] >= RAW_JOINT_FLOOR,
            "singleFrame": joint["singleFrame"] is None or joint["singleFrame"] >= RAW_JOINT_FLOOR,
            "temporalPair": joint["temporalPair"] is None or joint["temporalPair"] >= RAW_JOINT_FLOOR,
        }
        selection_payload = {
            "schema": "screen-understanding-correctness-selection-v3",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "items": [
                {"case": identifier, **selections[identifier]}
                for identifier in sorted(selections)
            ],
        }
        atomic_private_json(staging / "selection.json", selection_payload)
        result = {
            "schema": "screen-understanding-correctness-audit-result-v3",
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "state": "complete",
            "pairedOpportunityCount": counts["overall"],
            "pass1": rates[1],
            "pass2": rates[2],
            "joint": joint,
            "materialFalseCount": {
                "pass1": material[1],
                "pass2": material[2],
            },
            "selection": {
                "pass1": sum(value["selectedReference"] == "pass1" for value in selections.values()),
                "pass2": sum(value["selectedReference"] == "pass2" for value in selections.values()),
                "mergeRequired": sum(
                    value["selectedReference"] == "merge-required"
                    for value in selections.values()
                ),
            },
            "rawJointGate": {
                "minimum": RAW_JOINT_FLOOR,
                **gate_checks,
                "qualified": all(gate_checks.values()),
            },
            "finalReferenceAudit": {
                "state": "pending",
                "criticalErrorCount": None,
                "requiredCriticalErrorCount": 0,
                "qualified": False,
            },
            "qualified": False,
        }
        atomic_private_json(staging / "result.json", result)
        staging.rename(output)
        output.chmod(0o700)
        return result
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audit-root", required=True, type=Path)
    parser.add_argument("--auditor-one", required=True, type=Path)
    parser.add_argument("--auditor-two", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--tiebreak-output", type=Path)
    args = parser.parse_args()
    result = aggregate(
        args.audit_root,
        args.auditor_one,
        args.auditor_two,
        args.output_root,
        args.tiebreak_output,
    )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
