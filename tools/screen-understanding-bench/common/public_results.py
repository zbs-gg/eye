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
CASE_ID = re.compile(r"(?<![0-9a-f])[0-9a-f]{24}(?![0-9a-f])", re.IGNORECASE)
EMAIL = re.compile(r"\b[^\s@]+@[^\s@]+\.[^\s@]+\b")
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
    "retain Apple Vision only as a lightweight label baseline, redesign metadata "
    "and hybrid scene claims, and prove a local sandbox before any downloaded "
    "micro-model receives private inputs"
)
FORBIDDEN_FRAGMENTS = (
    "/Users/", "/Volumes/", "file://", "sk-", "BEGIN PRIVATE KEY",
)
PUBLIC_QUALITY_REASON = (
    "Apple Vision label mapping cleared the reliability floor; metadata and "
    "hybrid quality scores remain withheld, and downloaded micro-models were "
    "not run."
)
PUBLIC_STATUS_EVIDENCE = {
    "metadata-ax-ocr": (
        "Locked 60-case run completed; summary and atomic-fact mapping did not "
        "both clear the reliability floor."
    ),
    "apple-vision": (
        "Locked 60-case run completed; independent label mapping cleared the "
        "reliability floor."
    ),
    "deterministic-hybrid": (
        "Locked 60-case run completed; summary mapping did not clear the "
        "reliability floor."
    ),
    "florence-2-base": (
        "Inherited OS filesystem boundary could not be proven on the "
        "qualification host."
    ),
    "smolvlm-256m-instruct": (
        "Inherited OS filesystem boundary could not be proven on the "
        "qualification host."
    ),
    "lfm2-vl-450m": (
        "Inherited OS filesystem boundary could not be proven on the "
        "qualification host."
    ),
    "fastvlm-0.5b": (
        "Research-only method; inherited OS filesystem boundary could not "
        "be proven."
    ),
    "smolvlm2-256m-video-instruct": (
        "Inherited OS filesystem boundary could not be proven on the "
        "qualification host."
    ),
    "omniparser-v2": (
        "Parser-only method; inherited OS filesystem boundary could not be "
        "proven."
    ),
}


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
                or CASE_ID.search(value) or EMAIL.search(value):
            raise PublicResultError("public result contains private material")


def validate_public_decision(value: Any) -> dict[str, Any]:
    """Validate the exact aggregate-only partial decision currently publishable."""

    _exact_keys(value, {
        "schema", "protocol", "status", "corpus", "referenceReliability",
        "methods", "securityUnsupportedReason",
        "privateCorpusOpenedByThirdPartyAdapter", "protocolHash",
        "qualityScorePublished", "nextGate",
    }, "public result")
    if value["schema"] != SCHEMA or value["protocol"] != PROTOCOL \
            or value["status"] != "partial-qualified" \
            or value["securityUnsupportedReason"] \
                != "strict-sandbox-boundary-unavailable-on-qualification-mac" \
            or value["privateCorpusOpenedByThirdPartyAdapter"] is not False \
            or value["qualityScorePublished"] is not True \
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
        method_id = method["methodID"]
        common_keys = {
            "methodID", "status", "duplicateArmCount", "claimJudgmentAgreement",
            "decisionAgreement", "capabilityAgreement", "limitationCodes",
        }
        _exact_keys(
            method,
            common_keys | ({"quality"} if method_id == "apple-vision" else set()),
            "built-in public result",
        )
        if method["duplicateArmCount"] != 15 or method["decisionAgreement"] != 1.0:
            raise PublicResultError("built-in public result is invalid")
        if method_id == "apple-vision":
            if method["status"] != "qualified" \
                    or method["claimJudgmentAgreement"] != 1.0 \
                    or method["limitationCodes"] != [
                        "built-in-baseline", "single-image-only",
                        "apple-vision-signals",
                    ]:
                raise PublicResultError("qualified Apple Vision result is invalid")
            quality = method["quality"]
            _exact_keys(quality, {"caseCount", "claimCount", "metrics"}, "quality")
            if quality["caseCount"] != 60 or quality["claimCount"] != 289:
                raise PublicResultError("qualified Apple Vision sample is invalid")
            metrics = quality["metrics"]
            _exact_keys(metrics, {
                "requiredFactRecall", "criticalTextRecall",
                "severityWeightedHallucination", "abstentionAccuracy", "overall",
            }, "quality metrics")
            for score in metrics.values():
                _score(score, "quality metric")
        elif method["status"] != "mapping-inconclusive" \
                or method["limitationCodes"] != [
                    "claim-mapping-agreement-below-0.90", "quality-score-withheld",
                ]:
            raise PublicResultError("inconclusive built-in result is invalid")
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
        if method["methodID"] == "apple-vision":
            metrics = method["quality"]["metrics"]
            outcome = "Qualified label baseline"
            detail = (
                f"100.00% concealed label agreement; overall {metrics['overall']:.2%}, "
                f"required-fact recall {metrics['requiredFactRecall']:.2%}, critical-text "
                f"recall {metrics['criticalTextRecall']:.2%}, severity-weighted "
                f"hallucination {metrics['severityWeightedHallucination']:.2%}."
            )
        else:
            outcome = "Mapping inconclusive"
            detail = evidence[method["methodID"]].format(**values)
        method_rows.append(f"| {display[method['methodID']]} | {outcome} | {detail} |")
    method_rows.append(
        "| Downloaded micro-models and OmniParser | Security unsupported | "
        "The strict local sandbox boundary was not proven on the qualification Mac, "
        "so no third-party adapter received private inputs. |"
    )
    return "\n".join([
        "# Screen understanding evaluation: first public run",
        "",
        "Status: **partial-qualified**. This report contains aggregate metrics only. The private frames, temporal pairs,",
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
        "Only Apple Vision receives a published quality score. Its label decisions were perfectly reproducible on the",
        "concealed sample, but zero required-fact and critical-text recall make it unsuitable as a scene-description",
        "layer by itself. Metadata + AX/OCR and the hybrid remain score-withheld because at least one capability stayed",
        "below the pre-registered 90% mapping-agreement floor. Repeating judges until they pass is forbidden.",
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
            or value["containsPersonalCorpus"] is not False \
            or value["containsCaseMaterial"] is not False:
        raise PublicResultError("public status metadata is invalid")
    if value["qualityReason"] != PUBLIC_QUALITY_REASON:
        raise PublicResultError("public status quality reason is invalid")
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
        if method["evidence"] != PUBLIC_STATUS_EVIDENCE.get(method["id"]):
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
