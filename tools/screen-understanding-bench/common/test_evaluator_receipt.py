#!/usr/bin/python3

import json
import os
import tempfile
import unittest
from pathlib import Path

from evaluator_receipt import (
    EvaluatorReceiptError,
    issue_receipt,
    validate_independent_sessions,
    validate_receipt,
)


class EvaluatorReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        os.chmod(self.root, 0o700)
        self.packet = self.root / "packet.json"
        self.output = self.root / "output.json"
        self.packet.write_text('{"packet":1}', encoding="utf-8")
        self.output.write_text('{"output":1}', encoding="utf-8")
        os.chmod(self.packet, 0o600)
        os.chmod(self.output, 0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_receipt_binds_packet_output_and_session_outside_model_payload(self) -> None:
        path = self.root / "receipt.json"
        issued = issue_receipt(
            packet_path=self.packet,
            output_path=self.output,
            receipt_path=path,
            role="correctness-auditor-1",
            session_id="task:/root/auditor-1/turn:1",
            provider="openai",
            model_family="gpt-5",
        )

        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertEqual(
            validate_receipt(
                path, self.packet, self.output, "correctness-auditor-1"
            ),
            issued,
        )
        self.output.write_text('{"output":2}', encoding="utf-8")
        with self.assertRaisesRegex(EvaluatorReceiptError, "does not bind"):
            validate_receipt(
                path, self.packet, self.output, "correctness-auditor-1"
            )

    def test_aliases_cannot_reuse_one_orchestrator_session(self) -> None:
        receipts = [
            {
                "role": "correctness-auditor-1",
                "sessionID": "task:/root/same/turn:1",
            },
            {
                "role": "correctness-auditor-2",
                "sessionID": "task:/root/same/turn:1",
            },
        ]
        with self.assertRaisesRegex(EvaluatorReceiptError, "not independent"):
            validate_independent_sessions(
                receipts,
                {"correctness-auditor-1", "correctness-auditor-2"},
            )

    def test_distinct_session_receipts_qualify_same_model_family(self) -> None:
        receipts = [
            {
                "role": "correctness-auditor-1",
                "sessionID": "task:/root/auditor-1/turn:1",
            },
            {
                "role": "correctness-auditor-2",
                "sessionID": "task:/root/auditor-2/turn:1",
            },
        ]
        result = validate_independent_sessions(
            receipts,
            {"correctness-auditor-1", "correctness-auditor-2"},
        )
        self.assertTrue(result["qualified"])
        self.assertEqual(result["sessionCount"], 2)


if __name__ == "__main__":
    unittest.main()
