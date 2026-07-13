#!/usr/bin/python3

import json
import os
import tempfile
import unittest
from pathlib import Path

from evaluator_receipt import (
    EvaluatorReceiptError,
    issue_receipt,
    preissue_challenge,
    validate_independent_sessions,
    validate_receipt,
)


class EvaluatorReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        os.chmod(self.root, 0o700)
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir(mode=0o700)
        self.authority = self.root / "authority"
        self.packet = self.artifacts / "packet.json"
        self.output = self.artifacts / "output.json"
        self.packet.write_text('{"packet":1}', encoding="utf-8")
        self.output.write_text('{"output":1}', encoding="utf-8")
        os.chmod(self.packet, 0o600)
        os.chmod(self.output, 0o600)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _issue(
        self,
        *,
        role: str = "claim-mapper-primary",
        session_id: str = "task:/root/auditor-1/turn:1",
        receipt_name: str = "receipt.json",
    ) -> tuple[dict, dict, Path]:
        challenge = preissue_challenge(
            packet_path=self.packet,
            role=role,
            authority_root=self.authority,
        )
        path = self.artifacts / receipt_name
        issued = issue_receipt(
            packet_path=self.packet,
            output_path=self.output,
            receipt_path=path,
            role=role,
            session_id=session_id,
            provider="openai",
            model_family="gpt-5",
            challenge_id=challenge["challengeID"],
            authority_root=self.authority,
        )
        return challenge, issued, path

    def test_receipt_binds_preissued_challenge_output_and_session(self) -> None:
        challenge, issued, path = self._issue()

        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertFalse(
            (self.authority / "pending" / f'{challenge["challengeID"]}.json').exists()
        )
        self.assertTrue(
            (self.authority / "consumed" / f'{challenge["challengeID"]}.json').is_file()
        )
        self.assertEqual(
            validate_receipt(
                path,
                self.packet,
                self.output,
                "claim-mapper-primary",
                authority_root=self.authority,
            ),
            issued,
        )
        self.output.write_text('{"output":2}', encoding="utf-8")
        with self.assertRaisesRegex(EvaluatorReceiptError, "does not bind"):
            validate_receipt(
                path,
                self.packet,
                self.output,
                "claim-mapper-primary",
                authority_root=self.authority,
            )

    def test_claim_mapper_requires_preissued_challenge(self) -> None:
        with self.assertRaisesRegex(EvaluatorReceiptError, "challenge ID is required"):
            issue_receipt(
                packet_path=self.packet,
                output_path=self.output,
                receipt_path=self.artifacts / "receipt.json",
                role="claim-mapper-primary",
                session_id="task:/root/auditor-1/turn:1",
                provider="openai",
                model_family="gpt-5",
                authority_root=self.authority,
            )

    def test_same_challenge_cannot_issue_a_second_receipt(self) -> None:
        challenge, _, _ = self._issue()
        with self.assertRaisesRegex(EvaluatorReceiptError, "already consumed"):
            issue_receipt(
                packet_path=self.packet,
                output_path=self.output,
                receipt_path=self.artifacts / "replay.json",
                role="claim-mapper-primary",
                session_id="task:/root/auditor-2/turn:1",
                provider="openai",
                model_family="gpt-5",
                challenge_id=challenge["challengeID"],
                authority_root=self.authority,
            )

    def test_challenge_cannot_be_rebound_to_changed_packet_or_role(self) -> None:
        challenge = preissue_challenge(
            packet_path=self.packet,
            role="claim-mapper-primary",
            authority_root=self.authority,
        )
        self.packet.write_text('{"packet":2}', encoding="utf-8")
        os.chmod(self.packet, 0o600)
        with self.assertRaisesRegex(EvaluatorReceiptError, "does not bind"):
            issue_receipt(
                packet_path=self.packet,
                output_path=self.output,
                receipt_path=self.artifacts / "changed-packet.json",
                role="claim-mapper-primary",
                session_id="task:/root/changed/turn:1",
                provider="openai",
                model_family="gpt-5",
                challenge_id=challenge["challengeID"],
                authority_root=self.authority,
            )

        self.packet.write_text('{"packet":1}', encoding="utf-8")
        os.chmod(self.packet, 0o600)
        with self.assertRaisesRegex(EvaluatorReceiptError, "does not bind"):
            issue_receipt(
                packet_path=self.packet,
                output_path=self.output,
                receipt_path=self.artifacts / "changed-role.json",
                role="claim-mapper-hidden",
                session_id="task:/root/changed-role/turn:1",
                provider="openai",
                model_family="gpt-5",
                challenge_id=challenge["challengeID"],
                authority_root=self.authority,
            )

    def test_same_session_cannot_issue_with_a_fresh_challenge(self) -> None:
        self._issue(session_id="task:/root/same/turn:1")
        challenge = preissue_challenge(
            packet_path=self.packet,
            role="claim-mapper-primary",
            authority_root=self.authority,
        )
        with self.assertRaisesRegex(EvaluatorReceiptError, "session was already used"):
            issue_receipt(
                packet_path=self.packet,
                output_path=self.output,
                receipt_path=self.artifacts / "session-replay.json",
                role="claim-mapper-primary",
                session_id="task:/root/same/turn:1",
                provider="openai",
                model_family="gpt-5",
                challenge_id=challenge["challengeID"],
                authority_root=self.authority,
            )
        self.assertTrue(
            (self.authority / "pending" / f'{challenge["challengeID"]}.json').is_file()
        )

    def test_tampered_signed_receipt_is_rejected(self) -> None:
        _, _, path = self._issue()
        value = json.loads(path.read_text(encoding="utf-8"))
        value["modelFamily"] = "different-model"
        path.write_text(json.dumps(value), encoding="utf-8")
        os.chmod(path, 0o600)
        with self.assertRaisesRegex(EvaluatorReceiptError, "signature is invalid"):
            validate_receipt(
                path,
                self.packet,
                self.output,
                "claim-mapper-primary",
                authority_root=self.authority,
            )

    def test_missing_consumed_challenge_is_rejected(self) -> None:
        challenge, _, path = self._issue()
        consumed = self.authority / "consumed" / f'{challenge["challengeID"]}.json'
        consumed.unlink()
        with self.assertRaisesRegex(EvaluatorReceiptError, "consumed evaluator challenge"):
            validate_receipt(
                path,
                self.packet,
                self.output,
                "claim-mapper-primary",
                authority_root=self.authority,
            )

    def test_authority_cannot_be_inside_mapper_visible_root(self) -> None:
        with self.assertRaisesRegex(EvaluatorReceiptError, "outside mapper-visible"):
            preissue_challenge(
                packet_path=self.packet,
                role="claim-mapper-primary",
                authority_root=self.artifacts / "authority",
            )

    def test_legacy_receipt_requires_explicit_opt_in_and_rejects_mapping(self) -> None:
        path = self.artifacts / "legacy.json"
        issued = issue_receipt(
            packet_path=self.packet,
            output_path=self.output,
            receipt_path=path,
            role="correctness-auditor-1",
            session_id="task:/root/legacy/turn:1",
            provider="openai",
            model_family="gpt-5",
            legacy=True,
        )
        with self.assertRaisesRegex(EvaluatorReceiptError, "not explicitly allowed"):
            validate_receipt(
                path, self.packet, self.output, "correctness-auditor-1"
            )
        self.assertEqual(
            validate_receipt(
                path,
                self.packet,
                self.output,
                "correctness-auditor-1",
                allow_legacy=True,
            ),
            issued,
        )
        with self.assertRaisesRegex(EvaluatorReceiptError, "cannot use legacy"):
            issue_receipt(
                packet_path=self.packet,
                output_path=self.output,
                receipt_path=self.artifacts / "forbidden-legacy.json",
                role="claim-mapper-primary",
                session_id="task:/root/legacy-mapper/turn:1",
                provider="openai",
                model_family="gpt-5",
                legacy=True,
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
                "challengeID": "a" * 64,
            },
            {
                "role": "correctness-auditor-2",
                "sessionID": "task:/root/auditor-2/turn:1",
                "challengeID": "b" * 64,
            },
        ]
        result = validate_independent_sessions(
            receipts,
            {"correctness-auditor-1", "correctness-auditor-2"},
        )
        self.assertTrue(result["qualified"])
        self.assertEqual(result["sessionCount"], 2)
        self.assertTrue(result["challengeIDsDistinct"])


if __name__ == "__main__":
    unittest.main()
