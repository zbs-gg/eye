"""Locked schemas, limits, identifiers, and leak guards."""

from __future__ import annotations

import hashlib
import re
from typing import Any


PROTOCOL = "screen-understanding-correctness-audit-v3"
RUBRIC = "screen-understanding-canonical-v2"
PACKET_SCHEMA = "screen-understanding-claim-mapping-packet-v1"
MAPPING_SCHEMA = "screen-understanding-claim-owner-mapping-v1"
JUDGMENT_SCHEMA = "screen-understanding-claim-judgments-v1"
ADJUDICATION_PACKET_SCHEMA = "screen-understanding-claim-adjudication-packet-v1"
ADJUDICATION_SCHEMA = "screen-understanding-claim-adjudication-v1"
ADJUDICATION_OWNER_SCHEMA = "screen-understanding-claim-adjudication-owner-v1"
AGGREGATE_RESULT_SCHEMA = "screen-understanding-claim-aggregate-result-v1"
PUBLIC_SCHEMA = "screen-understanding-public-claim-scores-v1"
RUN_SCHEMA = "screen-understanding-built-in-run-v1"
RECORD_SCHEMA = "screen-understanding-built-in-output-v1"
EXPECTED_CASES = 60
# Sixty locked cases need at least fifteen duplicate summary decisions per method.
DUPLICATE_FRACTION = 0.25
CLAIM_AGREEMENT_FLOOR = 0.90
DECISION_AGREEMENT_FLOOR = 0.80
METHOD_FILES = {
    "metadata-ax-ocr": "metadata-ax-ocr.jsonl",
    "apple-vision": "apple-vision.jsonl",
    "deterministic-hybrid": "deterministic-hybrid.jsonl",
}
CLAIM_SOURCE_CAPABILITIES = {
    "summary": "summary",
    "atomicFact": "atomic-facts",
    "label": "labels",
}
CAPABILITY_ORDER = ("summary", "atomic-facts", "labels")
PUBLIC_METRICS = (
    "requiredFactRecall", "criticalTextRecall",
    "severityWeightedHallucination", "abstentionAccuracy", "overall",
)
PUBLIC_METHOD_METADATA = {
    "metadata-ax-ocr": {
        "license": "AGPL-3.0-or-later",
        "limitationCodes": (
            "built-in-baseline", "single-image-only",
            "accessibility-ocr-signals",
        ),
    },
    "apple-vision": {
        "license": "Apple-SDK",
        "limitationCodes": (
            "built-in-baseline", "single-image-only",
            "apple-vision-signals",
        ),
    },
    "deterministic-hybrid": {
        "license": "AGPL-3.0-or-later",
        "limitationCodes": (
            "built-in-baseline", "single-image-only",
            "deterministic-signal-fusion",
        ),
    },
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
MAX_PRIVATE_FILE_BYTES = 64 * 1024 * 1024
MAX_PRIVATE_JSON_BYTES = 16 * 1024 * 1024
MAX_JSON_DEPTH = 32
MAX_JSON_ITEMS = 250_000
MAX_JSON_STRING_BYTES = 256 * 1024
PACKET_FORBIDDEN_KEYS = {
    "methodid", "caseid", "candidateoutput", "candidateoutputs",
    "timing", "timings", "split", "splits",
}


class MappingError(ValueError):
    """The private mapping pipeline must fail closed."""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def token(seed: str, namespace: str, value: str, length: int = 24) -> str:
    return hashlib.sha256(
        f"{seed}:{namespace}:{value}".encode("utf-8")
    ).hexdigest()[:length]


def exact_keys(value: Any, expected: set[str], subject: str) -> None:
    if not isinstance(value, dict) or set(value) != expected:
        raise MappingError(f"{subject} keys do not match the locked schema")


def reject_leaks(
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
            reject_leaks(
                child, forbidden_values=forbidden_values, subject=subject
            )
    elif isinstance(value, list):
        for child in value:
            reject_leaks(
                child, forbidden_values=forbidden_values, subject=subject
            )
    elif isinstance(value, str):
        if any(fragment in value for fragment in FORBIDDEN_FRAGMENTS) \
                or any(identifier in value for identifier in forbidden_values):
            raise MappingError(f"{subject} contains a private identifier or path")


def reject_public_leaks(
    value: Any,
    *,
    forbidden_values: tuple[str, ...] = (),
) -> None:
    """Allow methodID only inside the locked aggregate method object."""
    forbidden = {
        "caseid", "claimid", "text", "raw", "rawoutput", "errors",
        "owner", "ownermapping", "packetid", "armid", "candidateoutput",
        "candidateoutputs", "timing", "timings", "split", "splits",
    }
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if lowered in forbidden or "timestamp" in lowered \
                    or "error" in lowered or lowered.endswith("path") \
                    or lowered.endswith("paths"):
                raise MappingError("public aggregate contains a forbidden field")
            reject_public_leaks(child, forbidden_values=forbidden_values)
    elif isinstance(value, list):
        for child in value:
            reject_public_leaks(child, forbidden_values=forbidden_values)
    elif isinstance(value, str):
        if any(fragment in value for fragment in FORBIDDEN_FRAGMENTS):
            raise MappingError("public aggregate contains a private path")
        if any(secret and secret in value for secret in forbidden_values):
            raise MappingError("public aggregate contains a private identifier")
