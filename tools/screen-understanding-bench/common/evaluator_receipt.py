#!/usr/bin/python3
"""Orchestrator-issued receipts for independent frontier-model eval sessions."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable

BENCHMARK_DIRECTORY = Path(__file__).resolve().parents[1]
if str(BENCHMARK_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(BENCHMARK_DIRECTORY))

from common.private_io import (  # noqa: E402
    atomic_private_json,
    validate_private_input_file,
)
from common.provenance import file_evidence  # noqa: E402


RECEIPT_SCHEMA = "screen-understanding-evaluator-receipt-v1"
ISSUER = "codex-ce-work-orchestrator-v1"
ROLES = frozenset({
    "annotation-pass1",
    "annotation-pass2",
    "correctness-auditor-1",
    "correctness-auditor-2",
    "correctness-tiebreak",
    "final-reference-auditor",
    "claim-mapper-primary",
    "claim-mapper-hidden",
    "claim-adjudicator",
})
PROVIDERS = frozenset({"openai", "anthropic", "local"})
SAFE_ID = re.compile(r"^[A-Za-z0-9._:/-]{1,160}$")


class EvaluatorReceiptError(ValueError):
    """A receipt cannot prove the declared independent evaluation session."""


def _safe_identifier(value: object, subject: str) -> str:
    if not isinstance(value, str) or not SAFE_ID.fullmatch(value):
        raise EvaluatorReceiptError(f"{subject} is invalid")
    return value


def issue_receipt(
    *,
    packet_path: Path,
    output_path: Path,
    receipt_path: Path,
    role: str,
    session_id: str,
    provider: str,
    model_family: str,
) -> dict[str, Any]:
    """Bind one packet/output pair to a caller-supplied orchestrator session identity."""

    if role not in ROLES:
        raise EvaluatorReceiptError("evaluator role is invalid")
    if provider not in PROVIDERS:
        raise EvaluatorReceiptError("model provider is invalid")
    session_id = _safe_identifier(session_id, "session ID")
    model_family = _safe_identifier(model_family, "model family")
    packet = validate_private_input_file(packet_path)
    output = validate_private_input_file(output_path)
    if receipt_path.exists() or receipt_path.is_symlink():
        raise EvaluatorReceiptError("evaluator receipt already exists")
    payload = {
        "schema": RECEIPT_SCHEMA,
        "issuer": ISSUER,
        "role": role,
        "sessionID": session_id,
        "provider": provider,
        "modelFamily": model_family,
        "packetSHA256": file_evidence(packet)["sha256"],
        "outputSHA256": file_evidence(output)["sha256"],
        "candidateOutputsAvailable": False,
    }
    atomic_private_json(receipt_path, payload)
    return payload


def validate_receipt(
    receipt_path: Path,
    packet_path: Path,
    output_path: Path,
    expected_role: str,
) -> dict[str, Any]:
    receipt = validate_private_input_file(receipt_path)
    packet = validate_private_input_file(packet_path)
    output = validate_private_input_file(output_path)
    try:
        payload = json.loads(receipt.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise EvaluatorReceiptError("evaluator receipt is invalid JSON") from error
    expected_keys = {
        "schema", "issuer", "role", "sessionID", "provider", "modelFamily",
        "packetSHA256", "outputSHA256", "candidateOutputsAvailable",
    }
    if not isinstance(payload, dict) or set(payload) != expected_keys \
            or payload["schema"] != RECEIPT_SCHEMA or payload["issuer"] != ISSUER \
            or payload["role"] != expected_role or expected_role not in ROLES \
            or payload["provider"] not in PROVIDERS \
            or payload["candidateOutputsAvailable"] is not False:
        raise EvaluatorReceiptError("evaluator receipt contract is invalid")
    _safe_identifier(payload["sessionID"], "session ID")
    _safe_identifier(payload["modelFamily"], "model family")
    if payload["packetSHA256"] != file_evidence(packet)["sha256"] \
            or payload["outputSHA256"] != file_evidence(output)["sha256"]:
        raise EvaluatorReceiptError("evaluator receipt does not bind these artifacts")
    return payload


def validate_independent_sessions(
    receipts: Iterable[dict[str, Any]],
    required_roles: set[str],
) -> dict[str, Any]:
    values = list(receipts)
    roles = {value.get("role") for value in values if isinstance(value, dict)}
    sessions = [value.get("sessionID") for value in values if isinstance(value, dict)]
    if roles != required_roles or len(values) != len(required_roles):
        raise EvaluatorReceiptError("evaluator receipt roles are incomplete")
    if len(set(sessions)) != len(sessions):
        raise EvaluatorReceiptError("evaluator sessions are not independent")
    return {
        "schema": "screen-understanding-evaluator-independence-v1",
        "issuer": ISSUER,
        "roles": sorted(required_roles),
        "sessionCount": len(sessions),
        "sessionIDsDistinct": True,
        "qualified": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--packet", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--role", required=True, choices=sorted(ROLES))
    parser.add_argument("--session-id", required=True)
    parser.add_argument("--provider", required=True, choices=sorted(PROVIDERS))
    parser.add_argument("--model-family", required=True)
    args = parser.parse_args()
    payload = issue_receipt(
        packet_path=args.packet,
        output_path=args.output,
        receipt_path=args.receipt,
        role=args.role,
        session_id=args.session_id,
        provider=args.provider,
        model_family=args.model_family,
    )
    print(json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
