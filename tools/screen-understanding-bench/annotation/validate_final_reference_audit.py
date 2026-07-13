#!/usr/bin/python3
"""Validate the fresh, single-auditor final reference audit."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
if str(BENCHMARK_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCHMARK_ROOT))

from annotation import validate_correctness_audit as correctness_validator


SAFE_ID = re.compile(r"^[A-Za-z0-9._-]{1,96}$")


def validate_forbidden_auditors(values: list[str] | tuple[str, ...]) -> set[str]:
    auditors = list(values)
    if len(auditors) < 2 or len(set(auditors)) != len(auditors) \
            or any(not isinstance(value, str) or not SAFE_ID.fullmatch(value) for value in auditors):
        raise ValueError("forbidden auditors must record distinct prior identities")
    return set(auditors)


def validate(
    packet_path: Path,
    judgments_path: Path,
    forbidden_auditors: list[str] | tuple[str, ...],
) -> dict:
    counts = correctness_validator.validate(packet_path, judgments_path)
    if counts != {"count": 45, "singleFrames": 30, "temporalPairs": 15}:
        raise ValueError("final audit must match the locked 45/30/15 set")
    forbidden = validate_forbidden_auditors(forbidden_auditors)
    output = json.loads(judgments_path.read_text(encoding="utf-8"))
    auditor = output["auditor"]
    if auditor in forbidden:
        raise ValueError("final auditor must be fresh and distinct from all prior auditors")

    slot_count = 0
    slot_error_count = 0
    ambiguity_error_count = 0
    material_false_count = 0
    for item in output["items"]:
        slot_count += len(item["slots"])
        for slot in item["slots"].values():
            material_false_count += int(slot["materialFalse"])
            slot_error_count += int(not slot["correct"] or slot["materialFalse"])
        ambiguity_error_count += int(not item["ambiguityDecision"])
    if slot_count != 285:
        raise ValueError("final audit must cover exactly 285 reference slots")
    critical_error_count = slot_error_count + ambiguity_error_count
    return {
        "auditor": auditor,
        "caseCount": 45,
        "singleFrameCount": 30,
        "temporalPairCount": 15,
        "slotCount": slot_count,
        "slotErrorCount": slot_error_count,
        "materialFalseCount": material_false_count,
        "ambiguityErrorCount": ambiguity_error_count,
        "criticalErrorCount": critical_error_count,
        "qualified": critical_error_count == 0,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--packet", required=True, type=Path)
    parser.add_argument("--judgments", required=True, type=Path)
    parser.add_argument("--forbidden-auditor", action="append", default=[])
    args = parser.parse_args()
    result = validate(args.packet, args.judgments, args.forbidden_auditor)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
