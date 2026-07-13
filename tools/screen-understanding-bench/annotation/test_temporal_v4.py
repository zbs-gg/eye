#!/usr/bin/python3

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


from annotation.temporal_v4.pipeline import (
    AUDIT_OUTPUT_SCHEMA,
    FINAL_OUTPUT_SCHEMA,
    FIXED_FORBIDDEN_FACTS,
    LABEL_OUTPUT_SCHEMA,
    PROTOCOL,
    RUBRIC,
    TIEBREAK_OUTPUT_SCHEMA,
    aggregate,
    finalize,
    prepare,
    prepare_audit,
    prepare_final,
    validate_audit,
    validate_labels,
)
from common.evaluator_receipt import issue_receipt
from common.private_io import (
    snapshot_private_file as real_snapshot_private_file,
    snapshot_private_tree as real_snapshot_private_tree,
)
from common.provenance import file_evidence, tree_evidence


class TemporalV4Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        os.chmod(self.root, 0o700)
        self.corpus = self._make_corpus()
        self.work = self.root / "work"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_json(self, path: Path, value: object) -> None:
        path.write_text(
            json.dumps(value, sort_keys=True, ensure_ascii=False),
            encoding="utf-8",
        )
        os.chmod(path, 0o600)

    def _make_corpus(self) -> Path:
        corpus = self.root / "corpus"
        cases = corpus / "cases"
        cases.mkdir(parents=True, mode=0o700)
        pairs = []
        for index in range(100):
            before = f"{index * 2 + 1:024x}"
            after = f"{index * 2 + 2:024x}"
            for identifier, suffix in ((before, b"before"), (after, b"after")):
                case_root = cases / identifier
                case_root.mkdir(mode=0o700)
                image = case_root / "image.heic"
                image.write_bytes(index.to_bytes(2, "big") + suffix)
                os.chmod(image, 0o600)
            pairs.append({
                "id": f"{10_000 + index:024x}",
                "beforeCaseID": before,
                "afterCaseID": after,
                "deltaMs": 1_000,
                "strata": ["temporal-change"],
            })
        self._write_json(corpus / "manifest.json", {
            "singleFrameCaseIDs": [],
            "temporalPairs": pairs,
            "splitSHA256": "a" * 64,
        })
        return corpus

    def _label(self, opaque_id: str, pass_number: int) -> dict:
        return {
            "opaqueID": opaque_id,
            "requiredFacts": [
                {"id": "required.surface", "text": "A browser window is visible."},
                {"id": "required.content", "text": "A document is visible."},
                {"id": "required.state", "text": "The document is selected."},
            ],
            "criticalText": [],
            "forbiddenInferences": copy.deepcopy(FIXED_FORBIDDEN_FACTS),
            "meaningfulChange": [
                {"id": "change.primary", "text": "The selected document changed."}
            ],
            "ambiguity": "judgeable",
            "abstentionAllowed": False,
            "pass": pass_number,
            "locked": False,
        }

    def _label_output(self, packet_path: Path, annotator: str) -> dict:
        packet = json.loads(packet_path.read_text(encoding="utf-8"))
        return {
            "schema": LABEL_OUTPUT_SCHEMA,
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "packetID": packet["packetID"],
            "pass": packet["pass"],
            "annotator": annotator,
            "candidateOutputsAvailable": False,
            "labels": [
                self._label(item["opaqueID"], packet["pass"])
                for item in packet["items"]
            ],
        }

    def _write_labels_and_receipt(
        self,
        packet_path: Path,
        payload: dict,
        name: str,
        role: str,
        session: str,
    ) -> tuple[Path, Path]:
        output = self.root / f"{name}-labels.json"
        receipt = self.root / f"{name}-receipt.json"
        self._write_json(output, payload)
        issue_receipt(
            packet_path=packet_path,
            output_path=output,
            receipt_path=receipt,
            role=role,
            session_id=session,
            provider="openai",
            model_family="gpt-5",
            legacy=True,
        )
        return output, receipt

    def _prepare_passes(
        self,
        *,
        pass2_session: str = "task:/root/pass2/turn:1",
    ) -> tuple[Path, Path, Path, Path]:
        if not self.work.exists():
            prepare(self.corpus, self.work, "temporal-v4-seed")
        paths = []
        for pass_number, session in (
            (1, "task:/root/pass1/turn:1"),
            (2, pass2_session),
        ):
            packet = self.work / "packets" / f"pass{pass_number}.json"
            payload = self._label_output(packet, f"frontier-pass-{pass_number}")
            paths.extend(self._write_labels_and_receipt(
                packet,
                payload,
                f"source-pass{pass_number}",
                f"annotation-pass{pass_number}",
                session,
            ))
        return tuple(paths)

    def _prepare_audit_fixture(self) -> tuple[Path, tuple[Path, Path, Path, Path]]:
        pass_artifacts = self._prepare_passes()
        audit = self.root / "correctness-audit"
        prepare_audit(
            self.work,
            *pass_artifacts,
            audit,
            "temporal-v4-audit-seed",
        )
        return audit, pass_artifacts

    def _audit_output(self, packet_path: Path, auditor: str) -> dict:
        packet = json.loads(packet_path.read_text(encoding="utf-8"))
        return {
            "schema": AUDIT_OUTPUT_SCHEMA,
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "packetID": packet["packetID"],
            "auditor": auditor,
            "candidateOutputsAvailable": False,
            "items": [
                {
                    "opaqueID": item["opaqueID"],
                    "slots": {
                        slot: {"correct": True, "materialFalse": False}
                        for slot in (
                            "surface", "content", "state", "primaryChange",
                            "ambiguityAbstention",
                        )
                    },
                }
                for item in packet["items"]
            ],
        }

    def _write_audit_and_receipt(
        self,
        packet: Path,
        payload: dict,
        prefix: str,
        role: str,
        session: str,
    ) -> tuple[Path, Path]:
        output = self.root / f"{prefix}-audit.json"
        receipt = self.root / f"{prefix}-audit-receipt.json"
        self._write_json(output, payload)
        issue_receipt(
            packet_path=packet,
            output_path=output,
            receipt_path=receipt,
            role=role,
            session_id=session,
            provider="openai",
            model_family="gpt-5",
            legacy=True,
        )
        return output, receipt

    def _prepared_auditors(self, audit: Path) -> tuple[Path, Path, Path, Path]:
        artifacts = []
        for number in (1, 2):
            packet = audit / "packets" / f"auditor-{number:02d}" / "packet.json"
            payload = self._audit_output(packet, f"auditor-{number}")
            artifacts.extend(self._write_audit_and_receipt(
                packet,
                payload,
                f"auditor-{number}",
                f"correctness-auditor-{number}",
                f"task:/root/auditor-{number}/turn:1",
            ))
        return tuple(artifacts)

    def _complete_aggregate(self) -> tuple[Path, Path]:
        audit, _ = self._prepare_audit_fixture()
        aggregate_root = self.root / "aggregate"
        aggregate(
            audit,
            *self._prepared_auditors(audit),
            aggregate_root,
        )
        return audit, aggregate_root

    def _final_output(self, packet_path: Path, auditor: str) -> dict:
        packet = json.loads(packet_path.read_text(encoding="utf-8"))
        return {
            "schema": FINAL_OUTPUT_SCHEMA,
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "packetID": packet["packetID"],
            "auditor": auditor,
            "candidateOutputsAvailable": False,
            "items": [
                {
                    "opaqueID": item["opaqueID"],
                    "slots": {
                        slot: {"correct": True, "materialFalse": False}
                        for slot in (
                            "surface", "content", "state", "primaryChange",
                            "ambiguityAbstention",
                        )
                    },
                }
                for item in packet["items"]
            ],
        }

    def _set_audit_slot(
        self,
        audit: Path,
        payload: dict,
        auditor_number: int,
        pair: str,
        pass_number: int,
        slot: str,
        *,
        correct: bool,
        material_false: bool = False,
    ) -> None:
        mapping = json.loads((audit / "owner-mapping.json").read_text())
        owners = mapping["auditors"][f"auditor-{auditor_number:02d}"]
        opaque = next(
            opaque_id for opaque_id, owner in owners.items()
            if owner["pair"] == pair and owner["pass"] == pass_number
        )
        item = next(value for value in payload["items"] if value["opaqueID"] == opaque)
        item["slots"][slot] = {
            "correct": correct,
            "materialFalse": material_false,
        }

    def test_prepare_is_deterministic_blinded_and_locks_100_plus_15(self) -> None:
        result = prepare(self.corpus, self.work, "temporal-v4-seed")
        second = self.root / "work-two"
        prepare(self.corpus, second, "temporal-v4-seed")

        pass1 = json.loads((self.work / "packets" / "pass1.json").read_text())
        pass2 = json.loads((self.work / "packets" / "pass2.json").read_text())
        mapping = json.loads((self.work / "owner-mapping.json").read_text())
        self.assertEqual((result["pass1Count"], result["pass2Count"]), (100, 15))
        self.assertEqual((len(pass1["items"]), len(pass2["items"])), (100, 15))
        self.assertEqual(pass1, json.loads((second / "packets" / "pass1.json").read_text()))
        self.assertEqual(pass2, json.loads((second / "packets" / "pass2.json").read_text()))
        self.assertFalse(set(mapping["passes"]["pass1"]) & set(mapping["passes"]["pass2"]))
        owner_tokens = {
            pair["id"] for pair in json.loads(
                (self.corpus / "manifest.json").read_text()
            )["temporalPairs"]
        }
        packet_text = (self.work / "packets" / "pass1.json").read_text() + \
            (self.work / "packets" / "pass2.json").read_text()
        self.assertFalse(any(token in packet_text for token in owner_tokens))
        self.assertNotIn('"candidateOutput":', packet_text)
        self.assertIn('"candidateOutputsAvailable": false', packet_text)
        self.assertEqual(os.stat(self.work).st_mode & 0o777, 0o700)
        self.assertTrue(all(
            os.stat(path).st_mode & 0o777 == 0o600
            for path in self.work.rglob("*") if path.is_file()
        ))

    def test_validate_labels_accepts_exact_temporal_contract_and_receipt(self) -> None:
        prepare(self.corpus, self.work, "temporal-v4-seed")
        packet = self.work / "packets" / "pass1.json"
        payload = self._label_output(packet, "frontier-pass-one")
        output, receipt = self._write_labels_and_receipt(
            packet,
            payload,
            "pass1",
            "annotation-pass1",
            "task:/root/pass1/turn:1",
        )

        result = validate_labels(packet, output, receipt, "annotation-pass1")

        self.assertEqual(result["count"], 100)
        self.assertEqual(result["receipt"]["role"], "annotation-pass1")

    def test_validate_labels_rejects_wrong_slots_text_change_and_abstention(self) -> None:
        prepare(self.corpus, self.work, "temporal-v4-seed")
        packet = self.work / "packets" / "pass2.json"
        base = self._label_output(packet, "frontier-pass-two")
        mutations = {
            "required slots": lambda value: value["labels"][0]["requiredFacts"][0].update(
                {"id": "required.other"}
            ),
            "fixed forbidden text": lambda value: value["labels"][0]["forbiddenInferences"][0].update(
                {"text": "A rewritten inference."}
            ),
            "critical text": lambda value: value["labels"][0].update(
                {"criticalText": ["visible text"]}
            ),
            "primary change": lambda value: value["labels"][0]["meaningfulChange"][0].update(
                {"id": "change.secondary"}
            ),
            "abstention": lambda value: value["labels"][0].update(
                {"ambiguity": "ambiguous", "abstentionAllowed": False}
            ),
        }
        for index, (message, mutate) in enumerate(mutations.items()):
            with self.subTest(message=message):
                payload = copy.deepcopy(base)
                mutate(payload)
                output, receipt = self._write_labels_and_receipt(
                    packet,
                    payload,
                    f"invalid-{index}",
                    "annotation-pass2",
                    f"task:/root/invalid-{index}/turn:1",
                )
                with self.assertRaisesRegex(ValueError, message):
                    validate_labels(packet, output, receipt, "annotation-pass2")

    def test_no_change_is_valid_but_still_keeps_a_change_decision_slot(self) -> None:
        prepare(self.corpus, self.work, "temporal-v4-seed")
        packet = self.work / "packets" / "pass2.json"
        payload = self._label_output(packet, "frontier-pass-two")
        payload["labels"][0]["meaningfulChange"] = []
        output, receipt = self._write_labels_and_receipt(
            packet,
            payload,
            "no-change",
            "annotation-pass2",
            "task:/root/no-change/turn:1",
        )

        result = validate_labels(packet, output, receipt, "annotation-pass2")

        self.assertEqual(result["opportunityCount"], 15 * 5)

    def test_receipt_tamper_is_rejected(self) -> None:
        prepare(self.corpus, self.work, "temporal-v4-seed")
        packet = self.work / "packets" / "pass2.json"
        payload = self._label_output(packet, "frontier-pass-two")
        output, receipt = self._write_labels_and_receipt(
            packet,
            payload,
            "tamper",
            "annotation-pass2",
            "task:/root/tamper/turn:1",
        )
        payload["labels"][0]["requiredFacts"][0]["text"] = "Tampered."
        self._write_json(output, payload)

        with self.assertRaisesRegex(ValueError, "bind"):
            validate_labels(packet, output, receipt, "annotation-pass2")

    def test_prepare_audit_builds_two_blinded_30_reference_packets(self) -> None:
        audit, _ = self._prepare_audit_fixture()

        manifest = json.loads((audit / "audit-manifest.json").read_text())
        self.assertEqual(
            (manifest["pairCount"], manifest["referenceCount"], manifest["opportunityCount"]),
            (15, 30, 75),
        )
        owner_pairs = {
            owner["pair"]
            for owner in json.loads((audit / "owner-mapping.json").read_text())[
                "auditors"
            ]["auditor-01"].values()
        }
        for number in (1, 2):
            packet_path = audit / "packets" / f"auditor-{number:02d}" / "packet.json"
            packet = json.loads(packet_path.read_text())
            self.assertEqual(len(packet["items"]), 30)
            self.assertFalse(any(value in packet_path.read_text() for value in owner_pairs))
            self.assertFalse(packet["candidateOutputsAvailable"])

    def test_pass_receipts_must_use_distinct_sessions(self) -> None:
        pass_artifacts = self._prepare_passes(
            pass2_session="task:/root/pass1/turn:1"
        )

        with self.assertRaisesRegex(ValueError, "independent"):
            prepare_audit(
                self.work,
                *pass_artifacts,
                self.root / "bad-audit",
                "temporal-v4-audit-seed",
            )
        self.assertFalse((self.root / "bad-audit").exists())
        self.assertFalse(any(
            path.name.startswith(".bad-audit.staging-")
            for path in self.root.iterdir()
        ))

    def test_validate_audit_rejects_wrong_slots_and_receipt_tamper(self) -> None:
        audit, _ = self._prepare_audit_fixture()
        packet = audit / "packets" / "auditor-01" / "packet.json"
        payload = self._audit_output(packet, "auditor-one")
        del payload["items"][0]["slots"]["primaryChange"]
        output, receipt = self._write_audit_and_receipt(
            packet,
            payload,
            "wrong-slots",
            "correctness-auditor-1",
            "task:/root/wrong-slots/turn:1",
        )
        with self.assertRaisesRegex(ValueError, "slots"):
            validate_audit(
                packet, output, receipt, "correctness-auditor-1"
            )

        valid = self._audit_output(packet, "auditor-one")
        output, receipt = self._write_audit_and_receipt(
            packet,
            valid,
            "tampered-audit",
            "correctness-auditor-1",
            "task:/root/tampered-audit/turn:1",
        )
        valid["items"][0]["slots"]["surface"]["correct"] = False
        self._write_json(output, valid)
        with self.assertRaisesRegex(ValueError, "bind"):
            validate_audit(
                packet, output, receipt, "correctness-auditor-1"
            )

    def test_aggregate_uses_exact_75_denominator_and_locked_selection(self) -> None:
        audit, _ = self._prepare_audit_fixture()
        mapping = json.loads((audit / "owner-mapping.json").read_text())
        pairs = sorted({
            owner["pair"]
            for owner in mapping["auditors"]["auditor-01"].values()
        })
        artifacts = []
        for number in (1, 2):
            packet = audit / "packets" / f"auditor-{number:02d}" / "packet.json"
            payload = self._audit_output(packet, f"auditor-{number}")
            self._set_audit_slot(
                audit, payload, number, pairs[1], 1, "surface", correct=False
            )
            self._set_audit_slot(
                audit, payload, number, pairs[2], 1, "surface", correct=False
            )
            self._set_audit_slot(
                audit, payload, number, pairs[2], 2, "content", correct=False
            )
            artifacts.extend(self._write_audit_and_receipt(
                packet,
                payload,
                f"selection-auditor-{number}",
                f"correctness-auditor-{number}",
                f"task:/root/selection-auditor-{number}/turn:1",
            ))

        result = aggregate(audit, *artifacts, self.root / "aggregate")
        selection = json.loads(
            (self.root / "aggregate" / "selection.json").read_text()
        )
        by_pair = {item["pair"]: item for item in selection["items"]}

        self.assertEqual(result["opportunityCount"], 75)
        self.assertEqual(by_pair[pairs[0]]["selectedReference"], "pass1")
        self.assertEqual(by_pair[pairs[1]]["selectedReference"], "pass2")
        self.assertEqual(by_pair[pairs[2]]["selectedReference"], "merge")

    def test_joint_floor_accepts_68_of_75_and_rejects_67(self) -> None:
        audit, _ = self._prepare_audit_fixture()
        mapping = json.loads((audit / "owner-mapping.json").read_text())
        pass2_owners = sorted(
            (
                (owner["pair"], slot)
                for owner in mapping["auditors"]["auditor-01"].values()
                if owner["pass"] == 2
                for slot in (
                    "surface", "content", "state", "primaryChange",
                    "ambiguityAbstention",
                )
            )
        )
        for wrong_count, qualified in ((7, True), (8, False)):
            artifacts = []
            for number in (1, 2):
                packet = audit / "packets" / f"auditor-{number:02d}" / "packet.json"
                payload = self._audit_output(packet, f"auditor-{number}-{wrong_count}")
                for pair, slot in pass2_owners[:wrong_count]:
                    self._set_audit_slot(
                        audit, payload, number, pair, 2, slot, correct=False
                    )
                artifacts.extend(self._write_audit_and_receipt(
                    packet,
                    payload,
                    f"floor-{wrong_count}-auditor-{number}",
                    f"correctness-auditor-{number}",
                    f"task:/root/floor-{wrong_count}-auditor-{number}/turn:1",
                ))
            result = aggregate(
                audit,
                *artifacts,
                self.root / f"aggregate-{wrong_count}",
            )
            self.assertEqual(result["jointCorrectCount"], 75 - wrong_count)
            self.assertEqual(result["rawJointGate"]["qualified"], qualified)

    def test_disagreement_only_tiebreak_and_global_session_independence(self) -> None:
        audit, _ = self._prepare_audit_fixture()
        artifacts = list(self._prepared_auditors(audit))
        auditor_two = json.loads(artifacts[2].read_text())
        auditor_two["items"][0]["slots"]["surface"]["correct"] = False
        artifacts[2].unlink()
        artifacts[3].unlink()
        artifacts[2], artifacts[3] = self._write_audit_and_receipt(
            audit / "packets" / "auditor-02" / "packet.json",
            auditor_two,
            "auditor-2-disagreement",
            "correctness-auditor-2",
            "task:/root/auditor-2-disagreement/turn:1",
        )
        pending_root = self.root / "aggregate-pending"
        pending = aggregate(audit, *artifacts, pending_root)
        self.assertEqual(pending["state"], "tiebreak-required")
        tiebreak_packet = pending_root / "tiebreak" / "packet.json"
        packet = json.loads(tiebreak_packet.read_text())
        self.assertEqual(len(packet["items"]), 1)
        self.assertEqual(len(packet["items"][0]["disputed"]), 1)
        tiebreak_output = self.root / "tiebreak-output.json"
        tiebreak_receipt = self.root / "tiebreak-receipt.json"
        self._write_json(tiebreak_output, {
            "schema": TIEBREAK_OUTPUT_SCHEMA,
            "protocol": PROTOCOL,
            "rubricVersion": RUBRIC,
            "packetID": packet["packetID"],
            "auditor": "tiebreak-auditor",
            "candidateOutputsAvailable": False,
            "items": [{
                "opaqueID": packet["items"][0]["opaqueID"],
                "decisions": [{
                    **packet["items"][0]["disputed"][0],
                    "value": True,
                }],
            }],
        })
        issue_receipt(
            packet_path=tiebreak_packet,
            output_path=tiebreak_output,
            receipt_path=tiebreak_receipt,
            role="correctness-tiebreak",
            session_id="task:/root/tiebreak/turn:1",
            provider="openai",
            model_family="gpt-5",
            legacy=True,
        )
        complete = aggregate(
            audit,
            *artifacts,
            self.root / "aggregate-complete",
            tiebreak_output,
            tiebreak_receipt,
        )
        self.assertEqual(complete["state"], "complete")
        self.assertEqual(complete["jointCorrectCount"], 75)

        reused_output = self.root / "reused-auditor.json"
        reused_receipt = self.root / "reused-auditor-receipt.json"
        packet_two = audit / "packets" / "auditor-02" / "packet.json"
        self._write_json(reused_output, self._audit_output(packet_two, "reused"))
        issue_receipt(
            packet_path=packet_two,
            output_path=reused_output,
            receipt_path=reused_receipt,
            role="correctness-auditor-2",
            session_id="task:/root/pass1/turn:1",
            provider="openai",
            model_family="gpt-5",
            legacy=True,
        )
        with self.assertRaisesRegex(ValueError, "independent"):
            aggregate(
                audit,
                artifacts[0],
                artifacts[1],
                reused_output,
                reused_receipt,
                self.root / "aggregate-reused",
            )

    def test_prepare_and_finalize_fresh_15_pair_75_opportunity_audit(self) -> None:
        _, aggregate_root = self._complete_aggregate()
        final_audit = self.root / "final-audit"
        manifest = prepare_final(
            self.work,
            aggregate_root,
            final_audit,
            "temporal-v4-final-seed",
        )
        packet = final_audit / "packet" / "packet.json"
        packet_payload = json.loads(packet.read_text())
        owner_pairs = {
            item["pair"]
            for item in json.loads(
                (aggregate_root / "selected-labels.json").read_text()
            )["items"]
        }
        self.assertEqual(
            (manifest["pairCount"], manifest["opportunityCount"]),
            (15, 75),
        )
        self.assertEqual(len(packet_payload["items"]), 15)
        self.assertFalse(any(pair in packet.read_text() for pair in owner_pairs))
        output = self.root / "final-output.json"
        receipt = self.root / "final-receipt.json"
        self._write_json(output, self._final_output(packet, "fresh-final-auditor"))
        issue_receipt(
            packet_path=packet,
            output_path=output,
            receipt_path=receipt,
            role="final-reference-auditor",
            session_id="task:/root/final-auditor/turn:1",
            provider="openai",
            model_family="gpt-5",
            legacy=True,
        )

        result = finalize(
            final_audit,
            output,
            receipt,
            self.root / "temporal-final",
        )
        labels = json.loads(
            (self.root / "temporal-final" / "labels.json").read_text()
        )
        reliability = json.loads(
            (self.root / "temporal-final" / "reliability.json").read_text()
        )
        self.assertTrue(result["qualified"])
        expected_pairs = {
            item["id"]
            for item in json.loads((self.corpus / "manifest.json").read_text())[
                "temporalPairs"
            ]
        }
        self.assertEqual(result["pairCount"], 100)
        self.assertEqual(len(labels["labels"]), 100)
        self.assertEqual({label["pair"] for label in labels["labels"]}, expected_pairs)
        self.assertTrue(all(label["locked"] is True for label in labels["labels"]))
        self.assertTrue(all(
            label["annotation"]["producer"] == "frontier-vlm"
            and label["annotation"]["rubricVersion"]
                == "screen-understanding-temporal-v4"
            and label["annotation"]["blindedToCandidateOutputs"] is True
            and label["annotation"]["candidateOutputsAvailable"] is False
            for label in labels["labels"]
        ))
        self.assertEqual(
            sum(label["annotation"]["mode"] == "pass1-base"
                for label in labels["labels"]),
            85,
        )
        self.assertEqual(reliability["finalAudit"]["opportunityCount"], 75)
        self.assertEqual(reliability["finalAudit"]["materialFalseCount"], 0)

    def test_final_audit_rejects_material_error_and_reused_session(self) -> None:
        _, aggregate_root = self._complete_aggregate()
        final_audit = self.root / "final-audit"
        prepare_final(
            self.work,
            aggregate_root,
            final_audit,
            "temporal-v4-final-seed",
        )
        packet = final_audit / "packet" / "packet.json"
        material = self._final_output(packet, "fresh-final-auditor")
        material["items"][0]["slots"]["surface"] = {
            "correct": False,
            "materialFalse": True,
        }
        output = self.root / "material-output.json"
        receipt = self.root / "material-receipt.json"
        self._write_json(output, material)
        issue_receipt(
            packet_path=packet,
            output_path=output,
            receipt_path=receipt,
            role="final-reference-auditor",
            session_id="task:/root/material-final/turn:1",
            provider="openai",
            model_family="gpt-5",
            legacy=True,
        )
        with self.assertRaisesRegex(ValueError, "zero material"):
            finalize(final_audit, output, receipt, self.root / "bad-final")
        self.assertFalse((self.root / "bad-final").exists())

        reused_output = self.root / "reused-final-output.json"
        reused_receipt = self.root / "reused-final-receipt.json"
        self._write_json(
            reused_output,
            self._final_output(packet, "reused-final-auditor"),
        )
        issue_receipt(
            packet_path=packet,
            output_path=reused_output,
            receipt_path=reused_receipt,
            role="final-reference-auditor",
            session_id="task:/root/pass1/turn:1",
            provider="openai",
            model_family="gpt-5",
            legacy=True,
        )
        with self.assertRaisesRegex(ValueError, "independent"):
            finalize(
                final_audit,
                reused_output,
                reused_receipt,
                self.root / "reused-final",
            )

    def test_finalize_never_mixes_paths_replaced_after_snapshot(self) -> None:
        _, aggregate_root = self._complete_aggregate()
        final_audit = self.root / "final-audit"
        prepare_final(
            self.work,
            aggregate_root,
            final_audit,
            "temporal-v4-final-seed",
        )
        packet = final_audit / "packet" / "packet.json"
        output = self.root / "stable-final-output.json"
        receipt = self.root / "stable-final-receipt.json"
        self._write_json(output, self._final_output(packet, "snapshot-auditor-a"))
        issue_receipt(
            packet_path=packet,
            output_path=output,
            receipt_path=receipt,
            role="final-reference-auditor",
            session_id="task:/root/snapshot-final/turn:1",
            provider="openai",
            model_family="gpt-5",
            legacy=True,
        )
        output_a = output.read_bytes()
        tree_mutated = False
        output_mutated = False

        def snapshot_tree_then_replace(source, destination, subject, **kwargs):
            nonlocal tree_mutated
            result = real_snapshot_private_tree(
                source, destination, subject, **kwargs
            )
            if source.resolve() == final_audit.resolve() and not tree_mutated:
                tree_mutated = True
                self._write_json(
                    final_audit / "final-audit-manifest.json",
                    {"schema": "replacement-b"},
                )
            return result

        def snapshot_file_then_replace(source, destination, subject, **kwargs):
            nonlocal output_mutated
            result = real_snapshot_private_file(
                source, destination, subject, **kwargs
            )
            if source.resolve() == output.resolve() and not output_mutated:
                output_mutated = True
                self._write_json(
                    output,
                    self._final_output(packet, "replacement-auditor-b"),
                )
            return result

        published = self.root / "snapshot-final"
        with patch(
            "annotation.temporal_v4.pipeline.snapshot_private_tree",
            side_effect=snapshot_tree_then_replace,
        ), patch(
            "annotation.temporal_v4.pipeline.snapshot_private_file",
            side_effect=snapshot_file_then_replace,
        ):
            result = finalize(final_audit, output, receipt, published)

        reliability = json.loads((published / "reliability.json").read_text())
        commit = json.loads((published / "commit.json").read_text())
        evidence_output = published / "evidence" / "final-output.json"
        self.assertTrue(result["qualified"])
        self.assertEqual(reliability["finalAudit"]["auditor"], "snapshot-auditor-a")
        self.assertEqual(evidence_output.read_bytes(), output_a)
        self.assertEqual(
            commit["evidence"]["finalOutput"],
            file_evidence(evidence_output),
        )
        self.assertNotEqual(
            commit["evidence"]["finalAuditRoot"],
            tree_evidence(final_audit),
        )

    def test_prepare_final_rejects_below_floor_and_tampered_selection(self) -> None:
        audit, _ = self._prepare_audit_fixture()
        mapping = json.loads((audit / "owner-mapping.json").read_text())
        pass2_owners = sorted(
            (
                (owner["pair"], slot)
                for owner in mapping["auditors"]["auditor-01"].values()
                if owner["pass"] == 2
                for slot in (
                    "surface", "content", "state", "primaryChange",
                    "ambiguityAbstention",
                )
            )
        )
        artifacts = []
        for number in (1, 2):
            packet = audit / "packets" / f"auditor-{number:02d}" / "packet.json"
            payload = self._audit_output(packet, f"floor-final-{number}")
            for pair, slot in pass2_owners[:8]:
                self._set_audit_slot(
                    audit, payload, number, pair, 2, slot, correct=False
                )
            artifacts.extend(self._write_audit_and_receipt(
                packet,
                payload,
                f"floor-final-{number}",
                f"correctness-auditor-{number}",
                f"task:/root/floor-final-{number}/turn:1",
            ))
        below = self.root / "below-floor"
        aggregate(audit, *artifacts, below)
        with self.assertRaisesRegex(ValueError, "0.90"):
            prepare_final(
                self.work,
                below,
                self.root / "below-final",
                "temporal-v4-final-seed",
            )

        aggregate_root = self.root / "tamper-aggregate"
        aggregate(audit, *self._prepared_auditors(audit), aggregate_root)
        selected = json.loads(
            (aggregate_root / "selected-labels.json").read_text()
        )
        selected["items"][0]["reference"]["requiredFacts"][0]["text"] = "Tampered."
        self._write_json(aggregate_root / "selected-labels.json", selected)
        with self.assertRaisesRegex(ValueError, "artifact"):
            prepare_final(
                self.work,
                aggregate_root,
                self.root / "tampered-final",
                "temporal-v4-final-seed",
            )

    def test_cli_exposes_every_temporal_v4_phase(self) -> None:
        result = subprocess.run(
            [sys.executable, "-m", "annotation.temporal_v4", "--help"],
            cwd=Path(__file__).parents[1],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        for phase in (
            "prepare", "validate-labels", "prepare-audit", "validate-audit",
            "aggregate", "prepare-final", "finalize",
        ):
            self.assertIn(phase, result.stdout)
            phase_help = subprocess.run(
                [sys.executable, "-m", "annotation.temporal_v4", phase, "--help"],
                cwd=Path(__file__).parents[1],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(phase_help.returncode, 0, phase_help.stderr)


if __name__ == "__main__":
    unittest.main()
