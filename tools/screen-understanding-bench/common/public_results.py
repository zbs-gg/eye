#!/usr/bin/python3
"""Fail-closed validation and rendering for the checked-in public eval decision."""

from __future__ import annotations

import copy
import json
import re
import sys
from pathlib import Path
from typing import Any


SCHEMA = "screen-understanding-public-decision-v1"
PROTOCOL = "screen-understanding-v1"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
CASE_ID = re.compile(r"^[0-9a-f]{24}$")
BUILTIN_CAPABILITIES = {
    "metadata-ax-ocr": ("summary", "atomicFacts"),
    "apple-vision": ("labels",),
    "deterministic-hybrid": ("summary", "atomicFacts", "labels"),
}
THIRD_PARTY_METHODS = (
    "florence-2-base",
    "smolvlm-256m-instruct",
    "lfm2-vl-450m",
    "fastvlm-0.5b",
    "smolvlm2-256m-video-instruct",
    "omniparser-v2",
)
EXPECTED_NEXT_GATE = (
    "redesign claim mapping so structured metadata and unsupported-claim severity "
    "are interpreted deterministically, then repeat independent concealed mapping; "
    "establish a proven local sandbox before any downloaded model receives private inputs"
)
FORBIDDEN_FRAGMENTS = (
    "/Users/", "/Volumes/", "file://", "sk-", "BEGIN PRIVATE KEY",
)


class PublicResultError(ValueError):
    """A checked-in result is unsafe, inconsistent, or outside the locked contract."""


def _exact_keys(value: Any, expected: set[str], subject: str) -> None:
    if not isinstance(value, dict) or set(value) != expected:
        raise PublicResultError(f"{subject} keys do not match the locked contract")


def _score(value: Any, subject: str) -> None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) \
            or value < 0.0 or value > 1.0:
        raise PublicResultError(f"{subject} is not a score")


def _reject_private_material(value: Any) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            lowered = key.lower()
            if lowered in {
                "caseid", "armid", "claimid", "packetid", "caption", "raw",
                "rawoutput", "candidateoutput", "candidateoutputs", "timestamp",
                "path", "paths", "text", "visibletext", "criticaltext",
            } or lowered.endswith("path") or lowered.endswith("paths"):
                raise PublicResultError("public result contains a forbidden field")
            _reject_private_material(child)
    elif isinstance(value, list):
        for child in value:
            _reject_private_material(child)
    elif isinstance(value, str):
        if any(fragment in value for fragment in FORBIDDEN_FRAGMENTS) \
                or CASE_ID.fullmatch(value):
            raise PublicResultError("public result contains private material")


def validate_public_decision(value: Any) -> dict[str, Any]:
    """Validate the exact aggregate-only inconclusive decision currently publishable."""

    _exact_keys(value, {
        "schema", "protocol", "status", "corpus", "referenceReliability",
        "methods", "securityUnsupportedReason",
        "privateCorpusOpenedByThirdPartyAdapter", "protocolHash",
        "qualityScorePublished", "nextGate",
    }, "public result")
    if value["schema"] != SCHEMA or value["protocol"] != PROTOCOL \
            or value["status"] != "inconclusive" \
            or value["securityUnsupportedReason"] \
                != "strict-sandbox-boundary-unavailable-on-qualification-mac" \
            or value["privateCorpusOpenedByThirdPartyAdapter"] is not False \
            or value["qualityScorePublished"] is not False \
            or value["nextGate"] != EXPECTED_NEXT_GATE \
            or not isinstance(value["protocolHash"], str) \
            or not SHA256.fullmatch(value["protocolHash"]):
        raise PublicResultError("public result metadata is invalid")

    corpus = value["corpus"]
    _exact_keys(corpus, {
        "singleImageCount", "temporalPairCount", "qualityTestSingleImageCount",
        "corpusHash",
    }, "public corpus")
    if corpus["singleImageCount"] != 200 or corpus["temporalPairCount"] != 100 \
            or corpus["qualityTestSingleImageCount"] != 60 \
            or not isinstance(corpus["corpusHash"], str) \
            or not SHA256.fullmatch(corpus["corpusHash"]):
        raise PublicResultError("public corpus metadata is invalid")

    reliability = value["referenceReliability"]
    _exact_keys(reliability, {
        "singleImageRawJoint", "temporalRawJoint", "combinedRawJoint",
        "finalAuditCaseCount", "finalAuditSlotCount", "finalAuditErrorCount",
    }, "reference reliability")
    for key in ("singleImageRawJoint", "temporalRawJoint", "combinedRawJoint"):
        _score(reliability[key], f"reference reliability {key}")
    if reliability["finalAuditCaseCount"] != 45 \
            or reliability["finalAuditSlotCount"] != 255 \
            or reliability["finalAuditErrorCount"] != 0:
        raise PublicResultError("reference audit counts are invalid")

    methods = value["methods"]
    expected_ids = (*BUILTIN_CAPABILITIES, *THIRD_PARTY_METHODS)
    if not isinstance(methods, list) or len(methods) != len(expected_ids) \
            or tuple(
                method.get("methodID") if isinstance(method, dict) else None
                for method in methods
            ) != expected_ids:
        raise PublicResultError("public method inventory is invalid")
    for method in methods[:len(BUILTIN_CAPABILITIES)]:
        _exact_keys(method, {
            "methodID", "status", "duplicateArmCount", "claimJudgmentAgreement",
            "decisionAgreement", "capabilityAgreement", "limitationCodes",
        }, "built-in public result")
        method_id = method["methodID"]
        if method["status"] != "mapping-inconclusive" \
                or method["duplicateArmCount"] != 15 \
                or method["decisionAgreement"] != 1.0 \
                or method["limitationCodes"] != [
                    "claim-mapping-agreement-below-0.90", "quality-score-withheld",
                ]:
            raise PublicResultError("built-in public result is invalid")
        _score(method["claimJudgmentAgreement"], "claim agreement")
        capability = method["capabilityAgreement"]
        _exact_keys(
            capability, set(BUILTIN_CAPABILITIES[method_id]),
            "capability agreement",
        )
        for score in capability.values():
            _score(score, "capability agreement")
    for method in methods[len(BUILTIN_CAPABILITIES):]:
        _exact_keys(method, {"methodID", "status"}, "unsupported public result")
        if method["status"] != "security-unsupported":
            raise PublicResultError("unsupported public result is invalid")

    _reject_private_material(value)
    return copy.deepcopy(value)


def render_public_decision(value: Any) -> str:
    """Render the sole checked-in Markdown view from the validated JSON."""

    document = validate_public_decision(value)
    reliability = document["referenceReliability"]
    method_rows = []
    evidence = {
        "metadata-ax-ocr": (
            "{claim:.2%} claim agreement across 15 concealed arms; "
            "summary {summary:.2%}, atomic facts {atomicFacts:.2%}."
        ),
        "apple-vision": "{labels:.2%} label agreement across 15 concealed arms.",
        "deterministic-hybrid": (
            "{claim:.2%} claim agreement; summary {summary:.2%}, atomic facts "
            "{atomicFacts:.2%}, labels {labels:.2%}."
        ),
    }
    display = {
        "metadata-ax-ocr": "Metadata + AX/OCR",
        "apple-vision": "Apple Vision",
        "deterministic-hybrid": "Deterministic hybrid",
    }
    for method in document["methods"][:3]:
        values = {
            "claim": method["claimJudgmentAgreement"],
            **method["capabilityAgreement"],
        }
        method_rows.append(
            f"| {display[method['methodID']]} | Mapping inconclusive | "
            f"{evidence[method['methodID']].format(**values)} |"
        )
    method_rows.append(
        "| Downloaded micro-models and OmniParser | Security unsupported | "
        "The strict local sandbox boundary was not proven on the qualification Mac, "
        "so no third-party adapter received private inputs. |"
    )
    return "\n".join([
        "# Screen understanding evaluation: first public run",
        "",
        "Status: **inconclusive**. This report contains aggregate metrics only. The private frames, temporal pairs,",
        "references, raw model outputs, judgments, local paths, timestamps, and case identifiers are not published.",
        "",
        "## What is already trustworthy",
        "",
        f"- The private reference set contains {document['corpus']['singleImageCount']} single images and {document['corpus']['temporalPairCount']} temporal pairs.",
        f"- Independent frontier-model annotation and audit reached {reliability['singleImageRawJoint']:.2%} raw joint reliability for single images",
        f"  and {reliability['temporalRawJoint']:.2%} for temporal pairs. A fresh final audit covered {reliability['finalAuditCaseCount']} cases and",
        f"  {reliability['finalAuditSlotCount']} reference slots with zero remaining errors. The frontier model is evaluation infrastructure only and is absent from ZBS Eye.",
        "- All three zero-download methods completed the locked 60-image test split offline: stored metadata plus",
        "  AX/OCR, Apple Vision classification, and their deterministic hybrid.",
        "",
        "## Result",
        "",
        "| Method | Outcome | Evidence |",
        "|---|---|---|",
        *method_rows,
        "",
        "No candidate quality score is published. The earlier 9-arm pilot was under the locked minimum cell size.",
        "After increasing the concealed sample to 15 arms per method, independent mappers disagreed about whether",
        "structured claims satisfy natural-language reference facts and about unsupported-claim severity. Repeating",
        "judges until one run passes would invalidate the evaluation.",
        "",
        "## Next gate",
        "",
        document["nextGate"] + ".",
        "",
        "Machine-readable aggregates and allowed hashes are in",
        "[`screen-understanding-v1-results.json`](screen-understanding-v1-results.json).",
        "",
    ])


def validate_public_status(value: Any, decision: dict[str, Any]) -> dict[str, Any]:
    """Cross-check the small current-status artifact against the decision source."""

    _exact_keys(value, {
        "protocolID", "date", "methods", "qualityConclusion", "qualityReason",
        "containsPersonalCorpus", "containsCaseMaterial",
    }, "public status")
    if value["protocolID"] != PROTOCOL or value["date"] != "2026-07-13" \
            or value["qualityConclusion"] != decision["status"] \
            or not isinstance(value["qualityReason"], str) \
            or not value["qualityReason"].strip() \
            or value["containsPersonalCorpus"] is not False \
            or value["containsCaseMaterial"] is not False:
        raise PublicResultError("public status metadata is invalid")
    expected = [
        (
            method["methodID"], method["status"],
            method["methodID"] in BUILTIN_CAPABILITIES,
        )
        for method in decision["methods"]
    ]
    methods = value["methods"]
    if not isinstance(methods, list) or len(methods) != len(expected):
        raise PublicResultError("public status method inventory is invalid")
    actual = []
    for method in methods:
        _exact_keys(
            method, {"id", "status", "evidence", "privateCorpusAccess"},
            "public status method",
        )
        if not isinstance(method["evidence"], str) or not method["evidence"].strip():
            raise PublicResultError("public status evidence is invalid")
        actual.append((method["id"], method["status"], method["privateCorpusAccess"]))
    if actual != expected:
        raise PublicResultError("public status disagrees with the decision artifact")
    _reject_private_material(value)
    return copy.deepcopy(value)


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        raise SystemExit(
            "usage: public_results.py RESULTS.json RESULTS.md STATUS.json"
        )
    json_path = Path(argv[1])
    markdown_path = Path(argv[2])
    status_path = Path(argv[3])
    try:
        value = json.loads(json_path.read_text(encoding="utf-8"))
        rendered = render_public_decision(value)
        actual = markdown_path.read_text(encoding="utf-8")
        status = json.loads(status_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PublicResultError("public result artifacts are unreadable") from error
    if actual != rendered:
        raise PublicResultError("public Markdown does not match the validated JSON")
    validate_public_status(status, value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
