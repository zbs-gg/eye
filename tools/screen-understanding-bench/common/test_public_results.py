#!/usr/bin/python3

import copy
import json
import unittest
from pathlib import Path

from common.public_results import (
    PublicResultError,
    render_public_decision,
    validate_public_decision,
    validate_public_status,
)


REPOSITORY_ROOT = Path(__file__).parents[3]
RESULTS = REPOSITORY_ROOT / "docs" / "evals" / "screen-understanding-v1-results.json"
MARKDOWN = REPOSITORY_ROOT / "docs" / "evals" / "screen-understanding-v1-results.md"
STATUS = REPOSITORY_ROOT / "docs" / "evals" / "screen-understanding-status-2026-07-13.json"


class PublicResultsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.value = json.loads(RESULTS.read_text(encoding="utf-8"))

    def test_checked_in_decision_is_exact_and_markdown_is_generated(self) -> None:
        self.assertEqual(validate_public_decision(self.value), self.value)
        self.assertEqual(render_public_decision(self.value), MARKDOWN.read_text())
        status = json.loads(STATUS.read_text(encoding="utf-8"))
        self.assertEqual(validate_public_status(status, self.value), status)

    def test_rejects_private_material_in_any_allowed_string(self) -> None:
        for private in (
            "/Users/private/screen.png",
            "/Volumes/Private/corpus",
            "file:///tmp/frame.png",
            "sk-private-token",
            "BEGIN PRIVATE KEY",
            "0123456789abcdef01234567",
        ):
            with self.subTest(private=private):
                value = copy.deepcopy(self.value)
                value["nextGate"] = private
                with self.assertRaises(PublicResultError):
                    validate_public_decision(value)

    def test_rejects_case_level_fields_and_wrong_sample_size(self) -> None:
        value = copy.deepcopy(self.value)
        value["methods"][0]["caseID"] = "0123456789abcdef01234567"
        with self.assertRaises(PublicResultError):
            validate_public_decision(value)

    def test_rejects_stale_public_status(self) -> None:
        status = json.loads(STATUS.read_text(encoding="utf-8"))
        status["qualityConclusion"] = "not-run"
        with self.assertRaisesRegex(PublicResultError, "status"):
            validate_public_status(status, self.value)
        value = copy.deepcopy(self.value)
        value["methods"][0]["duplicateArmCount"] = 9
        with self.assertRaises(PublicResultError):
            validate_public_decision(value)

    def test_rejects_free_form_status_evidence_and_quality_reason(self) -> None:
        status = json.loads(STATUS.read_text(encoding="utf-8"))
        status["methods"][0]["evidence"] = "A reviewer wrote a custom explanation."
        with self.assertRaisesRegex(PublicResultError, "evidence"):
            validate_public_status(status, self.value)

        status = json.loads(STATUS.read_text(encoding="utf-8"))
        status["qualityReason"] = "A custom public conclusion."
        with self.assertRaisesRegex(PublicResultError, "reason"):
            validate_public_status(status, self.value)

    def test_rejects_embedded_case_identifier_in_status_text(self) -> None:
        status = json.loads(STATUS.read_text(encoding="utf-8"))
        status["methods"][0]["evidence"] = (
            "Aggregate result includes case 0123456789abcdef01234567."
        )
        with self.assertRaises(PublicResultError):
            validate_public_status(status, self.value)


if __name__ == "__main__":
    unittest.main()
