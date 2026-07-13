#!/usr/bin/python3
"""Prepare blinded claim mapping packets and deterministically score judgments."""

# ruff: noqa: E402, F401 -- compatibility exports and path bootstrap are public.

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
import uuid
from pathlib import Path
from typing import Any, Optional


BENCHMARK_DIRECTORY = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
RUNNER_DIRECTORY = BENCHMARK_DIRECTORY / "runner"
COMMON_DIRECTORY = BENCHMARK_DIRECTORY / "common"
sys.path.insert(0, str(RUNNER_DIRECTORY))
sys.path.insert(0, str(COMMON_DIRECTORY))

from mapping_lib import aggregate as _aggregate
from mapping_lib import prepare as _prepare
from mapping_lib import private_io as _private_io
from mapping_lib import validate as _validate
from mapping_lib.contracts import (
    ADJUDICATION_OWNER_SCHEMA,
    ADJUDICATION_PACKET_SCHEMA,
    ADJUDICATION_SCHEMA,
    AGGREGATE_RESULT_SCHEMA,
    CAPABILITY_ORDER,
    CASE_ID,
    CLAIM_AGREEMENT_FLOOR,
    CLAIM_SOURCE_CAPABILITIES,
    DECISION_AGREEMENT_FLOOR,
    DUPLICATE_FRACTION,
    EXPECTED_CASES,
    FORBIDDEN_FACT_IDS,
    FORBIDDEN_FRAGMENTS,
    JUDGMENT_SCHEMA,
    MAPPING_SCHEMA,
    MAX_JSON_DEPTH,
    MAX_JSON_ITEMS,
    MAX_JSON_STRING_BYTES,
    MAX_PRIVATE_FILE_BYTES,
    MAX_PRIVATE_JSON_BYTES,
    METHOD_FILES,
    PACKET_FORBIDDEN_KEYS,
    PACKET_SCHEMA,
    PROTOCOL,
    PUBLIC_METHOD_METADATA,
    PUBLIC_METRICS,
    PUBLIC_SCHEMA,
    RECORD_SCHEMA,
    REQUIRED_FACT_IDS,
    RUBRIC,
    RUN_SCHEMA,
    SAFE_ID,
    SEVERITY_WEIGHTS,
    SHA256,
    MappingError,
)

# These are intentional compatibility seams. Existing callers and fault-
# injection tests patch them on this facade, so every workflow passes the
# current objects into the internal modules rather than capturing them there.
_load_private_json = _private_io.load_private_json
_atomic_private_json = _private_io.atomic_private_json
PrivateRootError = _private_io.PrivateRootError
prepare_private_root = _private_io.prepare_private_root
validate_private_root = _private_io.validate_private_root


def prepare_mapping(
    canonical_root: Path,
    result_root: Path,
    mapping_root: Path,
    seed: str,
) -> dict[str, Any]:
    """Seal primary and concealed duplicate packets after canonical validation."""
    return _prepare.prepare_mapping(
        canonical_root,
        result_root,
        mapping_root,
        seed,
        load_private_json=_load_private_json,
        atomic_private_json=_atomic_private_json,
    )


def validate_mapper_output(
    packet_path: Path,
    output_path: Path,
    forbidden_identity: Optional[str] = None,
) -> dict[str, Any]:
    return _validate.validate_mapper_output(
        packet_path,
        output_path,
        forbidden_identity,
        load_private_json=_load_private_json,
    )


def validate_public_output(
    value: Any,
    *,
    forbidden_values: tuple[str, ...] = (),
) -> None:
    _validate.validate_public_output(
        value, forbidden_values=forbidden_values
    )


def aggregate_mappings(
    mapping_root: Path,
    primary_output_path: Path,
    hidden_output_path: Path,
    aggregate_root: Path,
    adjudication_output_path: Optional[Path] = None,
) -> dict[str, Any]:
    return _aggregate.aggregate_mappings(
        mapping_root,
        primary_output_path,
        hidden_output_path,
        aggregate_root,
        adjudication_output_path,
        load_private_json=_load_private_json,
        atomic_private_json=_atomic_private_json,
    )


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
                args.canonical_root,
                args.result_root,
                args.mapping_root,
                args.seed,
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
                args.mapping_root,
                args.primary_output,
                args.hidden_output,
                args.aggregate_root,
                args.adjudication_output,
            )
    except MappingError as error:
        print(f"claim mapping failed: {error}", file=sys.stderr)
        return 2
    print(json.dumps(output, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
