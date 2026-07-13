import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


DIRECTORY = Path(__file__).parent


def load(name: str):
    path = DIRECTORY / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FinalReferenceToolingTests(unittest.TestCase):
    def test_prepares_300_drafts_and_one_blinded_45_case_packet(self):
        prepare = load("prepare_final_reference_audit")
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            annotation, correctness, aggregate = self.inputs(base, merge=True)
            corrections = self.write_corrections(base, {self.duplicate_ids[-1]})
            output = base / "final-audit"

            result = prepare.prepare(
                annotation,
                correctness,
                aggregate,
                output,
                "final-seed",
                corrections,
                ["prior-auditor-1", "prior-auditor-2", "prior-tiebreak"],
            )

            self.assertEqual(result["caseCount"], 45)
            self.assertEqual(result["singleFrameCount"], 30)
            self.assertEqual(result["temporalPairCount"], 15)
            self.assertEqual(result["slotCount"], 285)
            packet_path = output / "packet" / "packet.json"
            packet = json.loads(packet_path.read_text())
            self.assertEqual(len(packet["items"]), 45)
            packet_text = packet_path.read_text().lower()
            for forbidden in [
                '"case"', '"pass"', '"preference"', '"candidateoutput"',
                "/users/", "/volumes/", "file://",
            ]:
                self.assertNotIn(forbidden, packet_text)
            for identifier in self.duplicate_ids:
                self.assertNotIn(identifier, packet_text)
            for basename in self.source_basenames:
                self.assertNotIn(basename.lower(), packet_text)
            self.assertTrue(all(
                set(item) == {"opaqueID", "targetType", "reference", "images"}
                for item in packet["items"]
            ))

            draft = json.loads((output / "draft-final-labels.json").read_text())
            self.assertEqual(len(draft["labels"]), 300)
            self.assertFalse(draft["locked"])
            self.assertTrue(all(label["locked"] is False for label in draft["labels"]))
            by_id = {label["case"]: label for label in draft["labels"]}
            self.assertEqual(by_id[self.duplicate_ids[0]]["annotation"]["mode"], "selected-pass2")
            self.assertEqual(by_id[self.duplicate_ids[-1]]["annotation"]["mode"], "frontier-correction")
            self.assertEqual(
                by_id[self.duplicate_ids[-1]]["requiredFacts"][0]["text"],
                "Corrected surface",
            )
            self.assertEqual(os.stat(packet_path).st_mode & 0o777, 0o600)

    def test_requires_exact_merge_corrections_and_a_qualified_raw_gate(self):
        prepare = load("prepare_final_reference_audit")
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            annotation, correctness, aggregate = self.inputs(base, merge=True)
            with self.assertRaisesRegex(ValueError, "correction"):
                prepare.prepare(
                    annotation, correctness, aggregate, base / "missing", "seed", None,
                    ["prior-1", "prior-2"],
                )
            self.assertFalse((base / "missing").exists())

            corrections = self.write_corrections(
                base,
                {self.duplicate_ids[-1], self.duplicate_ids[-2]},
                name="extra.json",
            )
            with self.assertRaisesRegex(ValueError, "correction"):
                prepare.prepare(
                    annotation, correctness, aggregate, base / "extra", "seed", corrections,
                    ["prior-1", "prior-2"],
                )

            result_path = aggregate / "result.json"
            result = json.loads(result_path.read_text())
            result["rawJointGate"]["qualified"] = False
            result_path.write_text(json.dumps(result))
            exact = self.write_corrections(
                base, {self.duplicate_ids[-1]}, name="exact.json"
            )
            with self.assertRaisesRegex(ValueError, "raw joint"):
                prepare.prepare(
                    annotation, correctness, aggregate, base / "unqualified", "seed", exact,
                    ["prior-1", "prior-2"],
                )

    def test_validator_rejects_reused_auditor_and_output_leaks(self):
        prepare = load("prepare_final_reference_audit")
        validator = load("validate_final_reference_audit")
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            annotation, correctness, aggregate = self.inputs(base)
            audit = base / "audit"
            prepare.prepare(
                annotation, correctness, aggregate, audit, "seed", None,
                ["prior-1", "prior-2", "prior-tie"],
            )
            packet = audit / "packet" / "packet.json"
            judgments = self.write_judgments(packet, base / "judgments.json", "prior-2")
            with self.assertRaisesRegex(ValueError, "fresh|distinct"):
                validator.validate(packet, judgments, ["prior-1", "prior-2", "prior-tie"])

            judgments = self.write_judgments(packet, base / "fresh.json", "fresh-final")
            result = validator.validate(
                packet, judgments, ["prior-1", "prior-2", "prior-tie"]
            )
            self.assertEqual(result["slotCount"], 285)
            self.assertEqual(result["criticalErrorCount"], 0)

            payload = json.loads(judgments.read_text())
            payload["candidateOutput"] = "/Users/private"
            judgments.write_text(json.dumps(payload))
            with self.assertRaisesRegex(ValueError, "forbidden"):
                validator.validate(packet, judgments, ["prior-1", "prior-2"])

    def test_final_error_leaves_no_seal_then_success_seals_owner_labels_only(self):
        prepare = load("prepare_final_reference_audit")
        finalize = load("finalize_correctness_canonical")
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            annotation, correctness, aggregate = self.inputs(base)
            audit = base / "audit"
            prepare.prepare(
                annotation, correctness, aggregate, audit, "seed", None,
                ["prior-1", "prior-2", "prior-tie"],
            )
            packet = audit / "packet" / "packet.json"
            bad = self.write_judgments(packet, base / "bad.json", "fresh-final")
            payload = json.loads(bad.read_text())
            payload["items"][0]["slots"]["surface"]["correct"] = False
            bad.write_text(json.dumps(payload))
            with self.assertRaisesRegex(ValueError, "critical"):
                finalize.finalize(annotation, correctness, aggregate, audit, bad)
            self.assertFalse((audit / "canonical").exists())

            good = self.write_judgments(packet, base / "good.json", "fresh-final")
            result = finalize.finalize(annotation, correctness, aggregate, audit, good)
            self.assertEqual(result["labelCount"], 300)
            self.assertEqual(result["slotCount"], 285)
            self.assertEqual(result["criticalErrorCount"], 0)
            self.assertTrue(result["qualified"])
            labels_path = audit / "canonical" / "labels.json"
            labels = json.loads(labels_path.read_text())
            self.assertEqual(labels["schema"], "screen-understanding-canonical-labels-v3")
            self.assertEqual(len(labels["labels"]), 300)
            self.assertTrue(all(label["locked"] for label in labels["labels"]))
            reliability = json.loads((audit / "canonical" / "reliability.json").read_text())
            self.assertTrue(reliability["qualified"])
            self.assertGreaterEqual(reliability["rawJoint"]["overall"], 0.90)
            self.assertEqual(reliability["finalReferenceAudit"]["criticalErrorCount"], 0)
            canonical_text = labels_path.read_text().lower()
            self.assertNotIn('"opaqueid"', canonical_text)
            self.assertNotIn('"images"', canonical_text)
            self.assertNotIn("/users/", canonical_text)
            self.assertEqual(os.stat(labels_path).st_mode & 0o777, 0o600)
            with self.assertRaisesRegex(ValueError, "already exists"):
                finalize.finalize(annotation, correctness, aggregate, audit, good)

    def test_seal_rejects_a_tampered_selected_reference_and_packet(self):
        prepare = load("prepare_final_reference_audit")
        finalize = load("finalize_correctness_canonical")
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            annotation, correctness, aggregate = self.inputs(base)
            audit = base / "audit"
            prepare.prepare(
                annotation, correctness, aggregate, audit, "seed", None,
                ["prior-1", "prior-2"],
            )
            owner = json.loads((audit / "owner-mapping.json").read_text())
            opaque = next(
                opaque_id for opaque_id, value in owner["items"].items()
                if value["case"] == self.duplicate_ids[0]
            )
            draft_path = audit / "draft-final-labels.json"
            draft = json.loads(draft_path.read_text())
            label = next(
                item for item in draft["labels"]
                if item["case"] == self.duplicate_ids[0]
            )
            label["requiredFacts"][0]["text"] = "Tampered selected reference"
            draft_path.write_text(json.dumps(draft))
            packet_path = audit / "packet" / "packet.json"
            packet = json.loads(packet_path.read_text())
            packet_item = next(item for item in packet["items"] if item["opaqueID"] == opaque)
            packet_item["reference"]["requiredFacts"][0]["text"] = "Tampered selected reference"
            packet_path.write_text(json.dumps(packet))
            judgments = self.write_judgments(packet_path, base / "judgments.json", "fresh-final")

            with self.assertRaisesRegex(ValueError, "exact locked source"):
                finalize.finalize(annotation, correctness, aggregate, audit, judgments)
            self.assertFalse((audit / "canonical").exists())

    def inputs(self, base: Path, merge: bool = False) -> tuple[Path, Path, Path]:
        annotation = base / "annotation-v2"
        for path in [
            annotation / "labels" / "pass1",
            annotation / "labels" / "pass2",
            annotation / "batches",
            annotation / "renders",
        ]:
            path.mkdir(parents=True, exist_ok=True)
        all_ids = [f"{index:024x}" for index in range(1, 301)]
        singles = all_ids[:30]
        temporal = all_ids[30:45]
        self.duplicate_ids = singles + temporal
        self.source_basenames = set()
        pass1 = []
        pass2 = []
        work = []
        for index, identifier in enumerate(all_ids):
            target = "temporal-pair" if identifier in temporal else "single-frame"
            pass1.append(self.label(identifier, target, 1))
            if identifier in self.duplicate_ids:
                pass2.append(self.label(identifier, target, 2))
                if target == "single-frame":
                    name = f"private-source-{index}.jpg"
                    (annotation / "renders" / name).write_bytes(b"single")
                    self.source_basenames.add(name)
                    work.append({
                        "id": identifier,
                        "targetType": target,
                        "image": f"renders/{name}",
                    })
                else:
                    before = f"private-before-{index}.jpg"
                    after = f"private-after-{index}.jpg"
                    (annotation / "renders" / before).write_bytes(b"before")
                    (annotation / "renders" / after).write_bytes(b"after")
                    self.source_basenames.update({before, after})
                    work.append({
                        "id": identifier,
                        "targetType": target,
                        "beforeImage": f"renders/{before}",
                        "afterImage": f"renders/{after}",
                    })
        self.write_batch(annotation / "labels" / "pass1" / "batch.json", 1, pass1)
        self.write_batch(annotation / "labels" / "pass2" / "batch.json", 2, pass2)
        (annotation / "batches" / "pass2-batch.json").write_text(json.dumps({
            "schema": "screen-understanding-annotation-batch-v1",
            "pass": 2,
            "annotatorSlot": "hidden",
            "rubricVersion": "screen-understanding-canonical-v2",
            "candidateOutputsAvailable": False,
            "items": work,
        }))

        correctness = base / "correctness-audit"
        correctness.mkdir()
        auditor_mappings = {}
        for auditor_number in (1, 2):
            auditor_mappings[f"auditor-{auditor_number:02d}"] = {
                f"opaque-{auditor_number}-{index:02d}-{pass_number}": {
                    "case": identifier,
                    "sourceReference": f"pass{pass_number}",
                    "pass": pass_number,
                    "targetType": "temporal-pair" if identifier in temporal else "single-frame",
                }
                for index, identifier in enumerate(self.duplicate_ids)
                for pass_number in (1, 2)
            }
        (correctness / "owner-mapping.json").write_text(json.dumps({
            "schema": "screen-understanding-correctness-audit-mapping-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "seedSHA256": "a" * 64,
            "auditors": auditor_mappings,
        }))
        (correctness / "audit-manifest.json").write_text(json.dumps({
            "schema": "screen-understanding-correctness-audit-manifest-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "caseCount": 45,
            "singleFrameCount": 30,
            "temporalPairCount": 15,
            "referenceCount": 90,
            "pairedOpportunityCount": 285,
            "auditorCount": 2,
            "candidateOutputsAvailable": False,
        }))

        aggregate = base / "aggregate"
        aggregate.mkdir()
        selections = []
        for index, identifier in enumerate(self.duplicate_ids):
            selected = "pass2" if index == 0 else "pass1"
            if merge and index == len(self.duplicate_ids) - 1:
                selected = "merge-required"
            selections.append({
                "case": identifier,
                "targetType": "temporal-pair" if identifier in temporal else "single-frame",
                "selectedReference": selected,
                "selectedFinalAudit": "pending",
            })
        (aggregate / "selection.json").write_text(json.dumps({
            "schema": "screen-understanding-correctness-selection-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "items": selections,
        }))
        (aggregate / "result.json").write_text(json.dumps({
            "schema": "screen-understanding-correctness-audit-result-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "state": "complete",
            "pairedOpportunityCount": 285,
            "joint": {"overall": 0.94, "singleFrame": 0.95, "temporalPair": 0.92},
            "rawJointGate": {
                "minimum": 0.90,
                "overall": True,
                "singleFrame": True,
                "temporalPair": True,
                "qualified": True,
            },
            "qualified": False,
        }))
        return annotation, correctness, aggregate

    def write_batch(self, path: Path, pass_number: int, labels: list[dict]) -> None:
        path.write_text(json.dumps({
            "schema": "screen-understanding-label-batch-v1",
            "pass": pass_number,
            "annotator": f"frontier-pass-{pass_number}",
            "rubricVersion": "screen-understanding-canonical-v2",
            "labels": labels,
        }))

    def label(self, identifier: str, target: str, pass_number: int) -> dict:
        return {
            "case": identifier,
            **self.reference(target, f"Surface {pass_number}"),
            "pass": pass_number,
            "locked": False,
            "annotation": {
                "producer": "frontier-vlm",
                "annotator": f"frontier-pass-{pass_number}",
                "rubricVersion": "screen-understanding-canonical-v2",
                "blindedToCandidateOutputs": True,
                "candidateOutputsAvailable": False,
            },
        }

    def reference(self, target: str, surface: str) -> dict:
        return {
            "targetType": target,
            "requiredFacts": [
                {"id": "required.surface", "text": surface},
                {"id": "required.content", "text": "Content"},
                {"id": "required.state", "text": "State"},
            ],
            "criticalText": [],
            "forbiddenInferences": [
                {"id": "forbidden.intent", "text": "Intent", "severity": "critical"},
                {"id": "forbidden.outcome", "text": "Outcome", "severity": "major"},
            ],
            "meaningfulChange": [] if target == "temporal-pair" else None,
            "ambiguity": "judgeable",
            "abstentionAllowed": False,
        }

    def write_corrections(
        self, base: Path, identifiers: set[str], name: str = "corrections.json"
    ) -> Path:
        path = base / name
        path.write_text(json.dumps({
            "schema": "screen-understanding-corrections-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "producer": "frontier-vlm",
            "mode": "correction",
            "annotator": "frontier-corrector",
            "blindedToCandidateOutputs": True,
            "candidateOutputsAvailable": False,
            "items": [
                {
                    "case": identifier,
                    **self.reference(
                        "temporal-pair" if identifier in self.duplicate_ids[30:] else "single-frame",
                        "Corrected surface",
                    ),
                }
                for identifier in sorted(identifiers)
            ],
        }))
        return path

    def write_judgments(self, packet_path: Path, path: Path, auditor: str) -> Path:
        packet = json.loads(packet_path.read_text())
        items = []
        for item in packet["items"]:
            slots = ["surface", "content", "state", "intent", "outcome", "criticalText"]
            if item["targetType"] == "temporal-pair":
                slots.append("meaningfulChange")
            items.append({
                "opaqueID": item["opaqueID"],
                "slots": {
                    slot: {"correct": True, "materialFalse": False}
                    for slot in slots
                },
                "ambiguityDecision": True,
            })
        path.write_text(json.dumps({
            "schema": "screen-understanding-correctness-audit-judgments-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "packetID": packet["packetID"],
            "auditor": auditor,
            "items": items,
        }))
        return path


if __name__ == "__main__":
    unittest.main()
