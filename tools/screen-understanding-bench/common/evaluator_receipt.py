#!/usr/bin/python3
"""Authenticated orchestrator receipts for independent frontier evaluations.

Strict flow (required for every new claim-mapping receipt):

1. The orchestrator calls :func:`preissue_challenge` before exposing the packet.
2. After the evaluator writes its output, the orchestrator calls
   :func:`issue_receipt` with the returned one-time challenge ID.
3. Consumers call :func:`validate_receipt` with the same authority root, either
   explicitly or through ``ZBS_EYE_EVAL_RECEIPT_AUTHORITY_ROOT``.

The authority root must be outside packet/output/mapping roots. It contains the
HMAC key, pending/consumed challenge records, and one-time session claims; none
of those secrets are written into mapper-visible artifacts. Legacy v1 receipts
are available only through explicit ``legacy=True`` / ``allow_legacy=True``.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import secrets
import sys
from pathlib import Path
from typing import Any, Iterable

BENCHMARK_DIRECTORY = Path(__file__).resolve().parents[1]
if str(BENCHMARK_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(BENCHMARK_DIRECTORY))

from common.private_io import (  # noqa: E402
    atomic_private_json,
    load_private_json,
    make_private_directory,
    read_private_bytes,
    validate_private_input_file,
)
from common.private_root import (  # noqa: E402
    prepare_private_root,
    validate_private_root,
)
from common.provenance import file_evidence  # noqa: E402


LEGACY_RECEIPT_SCHEMA = "screen-understanding-evaluator-receipt-v1"
RECEIPT_SCHEMA = "screen-understanding-evaluator-receipt-v2"
CHALLENGE_SCHEMA = "screen-understanding-evaluator-challenge-v1"
SESSION_CLAIM_SCHEMA = "screen-understanding-evaluator-session-claim-v1"
ISSUER = "codex-ce-work-orchestrator-v2"
LEGACY_ISSUER = "codex-ce-work-orchestrator-v1"
AUTHORITY_ENVIRONMENT = "ZBS_EYE_EVAL_RECEIPT_AUTHORITY_ROOT"
ROLES = frozenset({
    "annotation-pass1",
    "annotation-pass2",
    "reference-correction",
    "correctness-auditor-1",
    "correctness-auditor-2",
    "correctness-tiebreak",
    "final-reference-auditor",
    "claim-mapper-primary",
    "claim-mapper-hidden",
    "claim-adjudicator",
})
CLAIM_MAPPING_ROLES = frozenset({
    "claim-mapper-primary", "claim-mapper-hidden", "claim-adjudicator",
})
PROVIDERS = frozenset({"openai", "anthropic", "local"})
SAFE_ID = re.compile(r"^[A-Za-z0-9._:/-]{1,160}$")
CHALLENGE_ID = re.compile(r"^[a-f0-9]{64}$")
HMAC_KEY_BYTES = 32
REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


class EvaluatorReceiptError(ValueError):
    """A receipt cannot prove the declared independent evaluation session."""


def _safe_identifier(value: object, subject: str) -> str:
    if not isinstance(value, str) or not SAFE_ID.fullmatch(value):
        raise EvaluatorReceiptError(f"{subject} is invalid")
    return value


def _canonical_bytes(value: dict[str, Any]) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")


def _signature(key: bytes, value: dict[str, Any]) -> str:
    return hmac.new(key, _canonical_bytes(value), hashlib.sha256).hexdigest()


def _resolve_authority_root(authority_root: Path | None) -> Path:
    selected = authority_root
    if selected is None:
        configured = os.environ.get(AUTHORITY_ENVIRONMENT)
        if not configured:
            raise EvaluatorReceiptError(
                f"receipt authority root is required via API or {AUTHORITY_ENVIRONMENT}"
            )
        selected = Path(configured)
    return selected.expanduser().absolute()


def _is_within(candidate: Path, parent: Path) -> bool:
    try:
        candidate.relative_to(parent)
    except ValueError:
        return False
    return True


def _reject_visible_authority(authority: Path, artifact: Path) -> None:
    artifact_root = artifact.expanduser().absolute().parent.resolve(strict=True)
    authority_canonical = authority.resolve(strict=False)
    if _is_within(authority_canonical, artifact_root) \
            or _is_within(artifact_root, authority_canonical):
        raise EvaluatorReceiptError(
            "receipt authority must be outside mapper-visible artifact roots"
        )


def _write_private_bytes(path: Path, value: bytes) -> None:
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def _exclusive_private_json(path: Path, value: dict[str, Any]) -> None:
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def _prepare_authority(authority_root: Path) -> Path:
    if authority_root.exists():
        authority = validate_private_root(
            authority_root, REPOSITORY_ROOT, must_exist=True,
            require_exclusions=False,
        )
    else:
        authority = prepare_private_root(
            authority_root, REPOSITORY_ROOT, apply_backup_exclusion=False
        )
    for name in ("pending", "consumed", "sessions"):
        child = authority / name
        if child.exists():
            metadata = child.stat()
            if child.is_symlink() or not child.is_dir() \
                    or metadata.st_uid != os.geteuid() \
                    or metadata.st_mode & 0o077:
                raise EvaluatorReceiptError("receipt authority storage is unsafe")
        else:
            make_private_directory(child)
    key_path = authority / "hmac.key"
    if not key_path.exists():
        try:
            _write_private_bytes(key_path, secrets.token_bytes(HMAC_KEY_BYTES))
        except FileExistsError:
            pass
    _load_authority_key(authority)
    return authority


def _load_authority(authority_root: Path) -> Path:
    return validate_private_root(
        authority_root, REPOSITORY_ROOT, must_exist=True,
        require_exclusions=False,
    )


def _load_authority_key(authority: Path) -> bytes:
    try:
        key = read_private_bytes(
            authority / "hmac.key", "evaluator receipt HMAC key",
            max_bytes=HMAC_KEY_BYTES,
        )
    except ValueError as error:
        raise EvaluatorReceiptError("evaluator receipt HMAC key is invalid") from error
    if len(key) != HMAC_KEY_BYTES:
        raise EvaluatorReceiptError("evaluator receipt HMAC key is invalid")
    return key


def _key_id(key: bytes) -> str:
    return hashlib.sha256(key).hexdigest()


def _challenge_path(authority: Path, state: str, challenge_id: str) -> Path:
    if not CHALLENGE_ID.fullmatch(challenge_id):
        raise EvaluatorReceiptError("challenge ID is invalid")
    return authority / state / f"{challenge_id}.json"


def _session_path(authority: Path, key: bytes, session_id: str) -> Path:
    digest = hmac.new(key, session_id.encode("utf-8"), hashlib.sha256).hexdigest()
    return authority / "sessions" / f"{digest}.json"


def _load_signed_record(
    path: Path,
    subject: str,
    key: bytes,
    expected_schema: str,
    expected_keys: set[str],
) -> dict[str, Any]:
    try:
        value, _ = load_private_json(path, subject)
    except ValueError as error:
        raise EvaluatorReceiptError(f"{subject} is invalid") from error
    if set(value) != expected_keys | {"signature"}:
        raise EvaluatorReceiptError(f"{subject} contract is invalid")
    signature = value.pop("signature", None)
    if value.get("schema") != expected_schema \
            or not isinstance(signature, str) \
            or not hmac.compare_digest(signature, _signature(key, value)):
        raise EvaluatorReceiptError(f"{subject} signature is invalid")
    value["signature"] = signature
    return value


def preissue_challenge(
    *,
    packet_path: Path,
    role: str,
    authority_root: Path | None = None,
) -> dict[str, Any]:
    """Pre-issue a random, packet-and-role-bound challenge before evaluation."""

    if role not in ROLES:
        raise EvaluatorReceiptError("evaluator role is invalid")
    packet = validate_private_input_file(packet_path)
    authority_location = _resolve_authority_root(authority_root)
    _reject_visible_authority(authority_location, packet)
    authority = _prepare_authority(authority_location)
    key = _load_authority_key(authority)
    while True:
        challenge_id = secrets.token_hex(32)
        path = _challenge_path(authority, "pending", challenge_id)
        payload: dict[str, Any] = {
            "schema": CHALLENGE_SCHEMA,
            "issuer": ISSUER,
            "challengeID": challenge_id,
            "role": role,
            "packetSHA256": file_evidence(packet)["sha256"],
            "authorityKeyID": _key_id(key),
        }
        payload["signature"] = _signature(key, payload)
        try:
            _exclusive_private_json(path, payload)
            return payload
        except FileExistsError:
            continue


def _issue_legacy_receipt(
    *,
    packet: Path,
    output: Path,
    receipt_path: Path,
    role: str,
    session_id: str,
    provider: str,
    model_family: str,
) -> dict[str, Any]:
    payload = {
        "schema": LEGACY_RECEIPT_SCHEMA,
        "issuer": LEGACY_ISSUER,
        "role": role,
        "sessionID": session_id,
        "provider": provider,
        "modelFamily": model_family,
        "packetSHA256": file_evidence(packet)["sha256"],
        "outputSHA256": file_evidence(output)["sha256"],
        "candidateOutputsAvailable": role in CLAIM_MAPPING_ROLES,
    }
    atomic_private_json(receipt_path, payload)
    return payload


def issue_receipt(
    *,
    packet_path: Path,
    output_path: Path,
    receipt_path: Path,
    role: str,
    session_id: str,
    provider: str,
    model_family: str,
    challenge_id: str | None = None,
    authority_root: Path | None = None,
    legacy: bool = False,
) -> dict[str, Any]:
    """Consume a pre-issued challenge and bind it to one exact output/session."""

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
    if legacy:
        if role in CLAIM_MAPPING_ROLES:
            raise EvaluatorReceiptError("claim-mapping receipts cannot use legacy mode")
        return _issue_legacy_receipt(
            packet=packet, output=output, receipt_path=receipt_path, role=role,
            session_id=session_id, provider=provider, model_family=model_family,
        )
    if challenge_id is None:
        raise EvaluatorReceiptError("pre-issued challenge ID is required")

    authority_location = _resolve_authority_root(authority_root)
    for artifact in (packet, output, receipt_path):
        _reject_visible_authority(authority_location, artifact)
    authority = _load_authority(authority_location)
    key = _load_authority_key(authority)
    pending_path = _challenge_path(authority, "pending", challenge_id)
    consumed_path = _challenge_path(authority, "consumed", challenge_id)
    if consumed_path.exists() or not pending_path.exists():
        raise EvaluatorReceiptError("challenge is missing or already consumed")
    challenge = _load_signed_record(
        pending_path, "evaluator challenge", key, CHALLENGE_SCHEMA,
        {
            "schema", "issuer", "challengeID", "role", "packetSHA256",
            "authorityKeyID",
        },
    )
    expected_challenge = {
        "schema": CHALLENGE_SCHEMA,
        "issuer": ISSUER,
        "challengeID": challenge_id,
        "role": role,
        "packetSHA256": file_evidence(packet)["sha256"],
        "authorityKeyID": _key_id(key),
        "signature": challenge["signature"],
    }
    if challenge != expected_challenge:
        raise EvaluatorReceiptError("challenge does not bind this role and packet")

    session_path = _session_path(authority, key, session_id)
    session_claim: dict[str, Any] = {
        "schema": SESSION_CLAIM_SCHEMA,
        "issuer": ISSUER,
        "sessionID": session_id,
        "role": role,
        "challengeID": challenge_id,
        "authorityKeyID": _key_id(key),
    }
    session_claim["signature"] = _signature(key, session_claim)
    try:
        _exclusive_private_json(session_path, session_claim)
    except FileExistsError as error:
        raise EvaluatorReceiptError("evaluator session was already used") from error

    consumed = False
    try:
        pending_path.rename(consumed_path)
        consumed = True
        payload: dict[str, Any] = {
            "schema": RECEIPT_SCHEMA,
            "issuer": ISSUER,
            "role": role,
            "sessionID": session_id,
            "provider": provider,
            "modelFamily": model_family,
            "packetSHA256": file_evidence(packet)["sha256"],
            "outputSHA256": file_evidence(output)["sha256"],
            "candidateOutputsAvailable": role in CLAIM_MAPPING_ROLES,
            "challengeID": challenge_id,
            "authorityKeyID": _key_id(key),
        }
        payload["signature"] = _signature(key, payload)
        atomic_private_json(receipt_path, payload)
        return payload
    except BaseException:
        if not consumed:
            session_path.unlink(missing_ok=True)
        raise


def _validate_legacy_receipt(
    payload: dict[str, Any],
    packet: Path,
    output: Path,
    expected_role: str,
) -> dict[str, Any]:
    expected_keys = {
        "schema", "issuer", "role", "sessionID", "provider", "modelFamily",
        "packetSHA256", "outputSHA256", "candidateOutputsAvailable",
    }
    if set(payload) != expected_keys \
            or payload["schema"] != LEGACY_RECEIPT_SCHEMA \
            or payload["issuer"] != LEGACY_ISSUER \
            or payload["role"] != expected_role or expected_role not in ROLES \
            or expected_role in CLAIM_MAPPING_ROLES \
            or payload["provider"] not in PROVIDERS \
            or payload["candidateOutputsAvailable"] is not False:
        raise EvaluatorReceiptError("legacy evaluator receipt contract is invalid")
    _safe_identifier(payload["sessionID"], "session ID")
    _safe_identifier(payload["modelFamily"], "model family")
    if payload["packetSHA256"] != file_evidence(packet)["sha256"] \
            or payload["outputSHA256"] != file_evidence(output)["sha256"]:
        raise EvaluatorReceiptError("evaluator receipt does not bind these artifacts")
    return payload


def validate_receipt(
    receipt_path: Path,
    packet_path: Path,
    output_path: Path,
    expected_role: str,
    *,
    authority_root: Path | None = None,
    allow_legacy: bool = False,
) -> dict[str, Any]:
    receipt = validate_private_input_file(receipt_path)
    packet = validate_private_input_file(packet_path)
    output = validate_private_input_file(output_path)
    try:
        payload, _ = load_private_json(receipt, "evaluator receipt")
    except ValueError as error:
        raise EvaluatorReceiptError("evaluator receipt is invalid JSON") from error
    if payload.get("schema") == LEGACY_RECEIPT_SCHEMA:
        if not allow_legacy:
            raise EvaluatorReceiptError("legacy evaluator receipt was not explicitly allowed")
        return _validate_legacy_receipt(payload, packet, output, expected_role)

    expected_keys = {
        "schema", "issuer", "role", "sessionID", "provider", "modelFamily",
        "packetSHA256", "outputSHA256", "candidateOutputsAvailable",
        "challengeID", "authorityKeyID", "signature",
    }
    if not isinstance(payload, dict) or set(payload) != expected_keys \
            or payload["schema"] != RECEIPT_SCHEMA or payload["issuer"] != ISSUER \
            or payload["role"] != expected_role or expected_role not in ROLES \
            or payload["provider"] not in PROVIDERS \
            or payload["candidateOutputsAvailable"] \
                is not (expected_role in CLAIM_MAPPING_ROLES):
        raise EvaluatorReceiptError("evaluator receipt contract is invalid")
    session_id = _safe_identifier(payload["sessionID"], "session ID")
    _safe_identifier(payload["modelFamily"], "model family")
    challenge_id = payload["challengeID"]
    if not isinstance(challenge_id, str) or not CHALLENGE_ID.fullmatch(challenge_id):
        raise EvaluatorReceiptError("evaluator receipt contract is invalid")

    authority_location = _resolve_authority_root(authority_root)
    for artifact in (packet, output, receipt):
        _reject_visible_authority(authority_location, artifact)
    authority = _load_authority(authority_location)
    key = _load_authority_key(authority)
    unsigned = dict(payload)
    signature = unsigned.pop("signature")
    if payload["authorityKeyID"] != _key_id(key) \
            or not hmac.compare_digest(signature, _signature(key, unsigned)):
        raise EvaluatorReceiptError("evaluator receipt signature is invalid")
    if payload["packetSHA256"] != file_evidence(packet)["sha256"] \
            or payload["outputSHA256"] != file_evidence(output)["sha256"]:
        raise EvaluatorReceiptError("evaluator receipt does not bind these artifacts")

    challenge = _load_signed_record(
        _challenge_path(authority, "consumed", challenge_id),
        "consumed evaluator challenge", key, CHALLENGE_SCHEMA,
        {
            "schema", "issuer", "challengeID", "role", "packetSHA256",
            "authorityKeyID",
        },
    )
    if challenge["challengeID"] != challenge_id \
            or challenge["role"] != expected_role \
            or challenge["packetSHA256"] != payload["packetSHA256"] \
            or challenge["authorityKeyID"] != payload["authorityKeyID"]:
        raise EvaluatorReceiptError("consumed challenge does not bind this receipt")
    session_claim = _load_signed_record(
        _session_path(authority, key, session_id),
        "evaluator session claim", key, SESSION_CLAIM_SCHEMA,
        {
            "schema", "issuer", "sessionID", "role", "challengeID",
            "authorityKeyID",
        },
    )
    if session_claim["sessionID"] != session_id \
            or session_claim["role"] != expected_role \
            or session_claim["challengeID"] != challenge_id \
            or session_claim["authorityKeyID"] != payload["authorityKeyID"]:
        raise EvaluatorReceiptError("session claim does not bind this receipt")
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
    challenges = [
        value.get("challengeID") for value in values if "challengeID" in value
    ]
    if challenges and (len(challenges) != len(values)
                       or len(set(challenges)) != len(challenges)):
        raise EvaluatorReceiptError("evaluator challenges are not independent")
    return {
        "schema": "screen-understanding-evaluator-independence-v1",
        "issuer": ISSUER,
        "roles": sorted(required_roles),
        "sessionCount": len(sessions),
        "sessionIDsDistinct": True,
        "challengeIDsDistinct": True,
        "qualified": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Pre-issue and consume authenticated evaluator challenges."
    )
    commands = parser.add_subparsers(dest="command", required=True)
    preissue = commands.add_parser("preissue")
    preissue.add_argument("--packet", required=True, type=Path)
    preissue.add_argument("--role", required=True, choices=sorted(ROLES))
    preissue.add_argument("--authority-root", required=True, type=Path)

    issue = commands.add_parser("issue")
    issue.add_argument("--packet", required=True, type=Path)
    issue.add_argument("--output", required=True, type=Path)
    issue.add_argument("--receipt", required=True, type=Path)
    issue.add_argument("--role", required=True, choices=sorted(ROLES))
    issue.add_argument("--session-id", required=True)
    issue.add_argument("--provider", required=True, choices=sorted(PROVIDERS))
    issue.add_argument("--model-family", required=True)
    issue.add_argument("--challenge-id", required=True)
    issue.add_argument("--authority-root", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "preissue":
        payload = preissue_challenge(
            packet_path=args.packet,
            role=args.role,
            authority_root=args.authority_root,
        )
    else:
        payload = issue_receipt(
            packet_path=args.packet,
            output_path=args.output,
            receipt_path=args.receipt,
            role=args.role,
            session_id=args.session_id,
            provider=args.provider,
            model_family=args.model_family,
            challenge_id=args.challenge_id,
            authority_root=args.authority_root,
        )
    print(json.dumps(payload, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
