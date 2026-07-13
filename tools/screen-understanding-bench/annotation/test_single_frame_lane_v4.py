import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


DIRECTORY = Path(__file__).parent
BENCHMARK = DIRECTORY.parent


def load(name: str):
    path = DIRECTORY / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SingleFrameLaneV4Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        os.chmod(self.root, 0o700)
        self.lane = load("single_frame_lane_v4")
        self.receipts = self._load_common("evaluator_receipt")
        self.sources = self._write_sources()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_prepares_two_derived_corrections_and_seals_200_single_labels(self):
        correction = self.root / "correction"
        prepared = self.lane.prepare_correction(self.sources, correction, "lane-seed")
        self.assertEqual(prepared["mergeRequiredCount"], 2)
        packet = json.loads((correction / "packet.json").read_text())
        self.assertEqual(len(packet["items"]), 2)
        packet_text = (correction / "packet.json").read_text().lower()
        for token in [*self.single_duplicates, '"case"', '"pass"', '"selectedreference"']:
            self.assertNotIn(token.lower(), packet_text)

        correction_output = self._write_corrections(correction / "packet.json")
        correction_receipt = self._issue(
            correction / "packet.json", correction_output,
            "reference-correction", "task:/root/correction/turn:1",
        )
        audit = self.root / "final-audit"
        manifest = self.lane.prepare_audit(
            self.sources,
            correction,
            correction_output,
            correction_receipt,
            audit,
            "final-seed",
        )
        self.assertEqual(manifest["caseCount"], 30)
        self.assertEqual(manifest["draftLabelCount"], 200)
        self.assertLess(manifest["ignoredTemporalJoint"], 0.90)
        packet_path = audit / "packet" / "packet.json"
        final_packet = json.loads(packet_path.read_text())
        self.assertEqual(len(final_packet["items"]), 30)
        final_text = packet_path.read_text().lower()
        for token in [*self.single_duplicates, '"case"', '"pass"', '"candidateoutput"']:
            self.assertNotIn(token.lower(), final_text)

        judgments = self._write_final_judgments(packet_path)
        final_receipt = self._issue(
            packet_path, judgments,
            "final-reference-auditor", "task:/root/final/turn:1",
        )
        writes = []
        original = self.lane.atomic_private_json

        def record(path, value):
            writes.append(path.name)
            return original(path, value)

        with mock.patch.object(self.lane, "atomic_private_json", side_effect=record):
            result = self.lane.seal(
                self.sources,
                correction,
                correction_output,
                correction_receipt,
                audit,
                judgments,
                final_receipt,
            )
        self.assertEqual(result["labelCount"], 200)
        self.assertEqual(result["duplicateCount"], 30)
        self.assertEqual(result["materialFalseCount"], 0)
        self.assertEqual(result["ambiguityErrorCount"], 0)
        canonical = audit / "canonical"
        labels = json.loads((canonical / "labels.json").read_text())
        self.assertEqual(len(labels["labels"]), 200)
        self.assertTrue(all(item["locked"] for item in labels["labels"]))
        reliability = json.loads((canonical / "reliability.json").read_text())
        self.assertGreaterEqual(reliability["rawJointSingleFrame"], 0.90)
        self.assertNotIn("rawJointTemporal", reliability)
        self.assertEqual(writes[-1], "commit.json")
        for name in ["labels.json", "reliability.json", "commit.json"]:
            self.assertEqual(os.stat(canonical / name).st_mode & 0o777, 0o600)
        provenance = self._load_common("provenance")
        commit = json.loads((canonical / "commit.json").read_text())
        self.assertEqual(
            commit["evidence"]["finalAudit"],
            provenance.final_audit_evidence(audit),
        )

    def test_recomputes_selection_and_rejects_temporal_gate_as_a_requirement(self):
        aggregate = self.sources.aggregate_root
        result = json.loads((aggregate / "result.json").read_text())
        self.assertFalse(result["rawJointGate"]["qualified"])
        self.assertLess(result["joint"]["temporalPair"], 0.90)
        self.lane.prepare_correction(self.sources, self.root / "accepted", "seed")

        selection_path = aggregate / "selection.json"
        selection = json.loads(selection_path.read_text())
        single = next(item for item in selection["items"] if item["targetType"] == "single-frame")
        single["selectedReference"] = "pass1" if single["selectedReference"] != "pass1" else "pass2"
        selection_path.write_text(json.dumps(selection))
        with self.assertRaisesRegex(ValueError, "selection|recomputed"):
            self.lane.prepare_correction(self.sources, self.root / "tampered", "seed")
        self.assertFalse((self.root / "tampered").exists())

    def test_extra_duplicate_can_enter_the_independent_correction_pass(self):
        selection = json.loads(
            (self.sources.aggregate_root / "selection.json").read_text()
        )["items"]
        extra = next(
            item["case"] for item in selection
            if item["targetType"] == "single-frame"
            and item["selectedReference"] != "merge-required"
        )
        correction = self.root / "correction-with-feedback"
        prepared = self.lane.prepare_correction(
            self.sources, correction, "feedback-seed", {extra}
        )
        self.assertEqual(prepared["mergeRequiredCount"], 2)
        self.assertEqual(prepared["additionalCorrectionCount"], 1)
        self.assertEqual(prepared["correctionCount"], 3)

        output = self._write_corrections(correction / "packet.json")
        receipt = self._issue(
            correction / "packet.json", output,
            "reference-correction", "task:/root/feedback/turn:1",
        )
        audit = self.root / "feedback-audit"
        manifest = self.lane.prepare_audit(
            self.sources, correction, output, receipt, audit, "feedback-audit"
        )
        self.assertEqual(manifest["mergeRequiredCount"], 2)
        self.assertEqual(manifest["additionalCorrectionCount"], 1)
        self.assertEqual(manifest["correctionCount"], 3)
        drafts = json.loads((audit / "draft-labels.json").read_text())["labels"]
        corrected = next(item for item in drafts if item["case"] == extra)
        self.assertEqual(corrected["annotation"]["mode"], "frontier-correction")

    def test_receipt_tamper_and_reused_sessions_fail_closed(self):
        payload = json.loads(self.sources.auditor_two_receipt.read_text())
        payload["sessionID"] = json.loads(self.sources.auditor_one_receipt.read_text())["sessionID"]
        self.sources.auditor_two_receipt.write_text(json.dumps(payload))
        with self.assertRaisesRegex(ValueError, "bind|independent"):
            self.lane.prepare_correction(self.sources, self.root / "bad", "seed")

        self.sources = self._write_sources(prefix="fresh-")
        correction = self.root / "correction-fresh"
        self.lane.prepare_correction(self.sources, correction, "seed")
        output = self._write_corrections(correction / "packet.json", "fresh-correction.json")
        reused = json.loads(self.sources.auditor_one_receipt.read_text())["sessionID"]
        receipt = self._issue(correction / "packet.json", output, "reference-correction", reused)
        with self.assertRaisesRegex(ValueError, "independent"):
            self.lane.prepare_audit(
                self.sources, correction, output, receipt,
                self.root / "bad-audit", "seed",
            )

        output = self._write_corrections(
            correction / "packet.json", "independent-correction.json"
        )
        receipt = self._issue(
            correction / "packet.json", output,
            "reference-correction", "task:/root/correction-fresh/turn:1",
        )
        audit = self.root / "fresh-audit"
        self.lane.prepare_audit(
            self.sources, correction, output, receipt, audit, "seed"
        )
        judgments = self._write_final_judgments(audit / "packet" / "packet.json")
        final_receipt = self._issue(
            audit / "packet" / "packet.json", judgments,
            "final-reference-auditor", "task:/root/correction-fresh/turn:1",
        )
        with self.assertRaisesRegex(ValueError, "independent"):
            self.lane.seal(
                self.sources, correction, output, receipt,
                audit, judgments, final_receipt,
            )

    def test_correction_leaks_and_final_errors_never_publish_canonical(self):
        correction = self.root / "correction"
        self.lane.prepare_correction(self.sources, correction, "seed")
        output = self._write_corrections(correction / "packet.json")
        payload = json.loads(output.read_text())
        payload["candidateOutput"] = "/Users/private/result.json"
        output.write_text(json.dumps(payload))
        receipt = self._issue(
            correction / "packet.json", output,
            "reference-correction", "task:/root/correction/turn:1",
        )
        with self.assertRaisesRegex(ValueError, "forbidden|keys"):
            self.lane.prepare_audit(
                self.sources, correction, output, receipt,
                self.root / "leaky-audit", "seed",
            )

        output = self._write_corrections(correction / "packet.json", "clean-correction.json")
        receipt = self._issue(
            correction / "packet.json", output,
            "reference-correction", "task:/root/correction/turn:2",
        )
        audit = self.root / "audit"
        self.lane.prepare_audit(self.sources, correction, output, receipt, audit, "seed")
        judgments = self._write_final_judgments(audit / "packet" / "packet.json")
        values = json.loads(judgments.read_text())
        values["items"][0]["slots"]["surface"]["materialFalse"] = True
        judgments.write_text(json.dumps(values))
        final_receipt = self._issue(
            audit / "packet" / "packet.json", judgments,
            "final-reference-auditor", "task:/root/final/turn:1",
        )
        with self.assertRaisesRegex(ValueError, "zero-error|material"):
            self.lane.seal(
                self.sources, correction, output, receipt,
                audit, judgments, final_receipt,
            )
        self.assertFalse((audit / "canonical").exists())

    def test_rejects_repo_output_and_symlinked_source_file(self):
        with self.assertRaises(ValueError):
            self.lane.prepare_correction(
                self.sources,
                DIRECTORY / "must-not-create-single-frame-v4",
                "seed",
            )
        target = self.sources.annotation_root / "labels" / "pass1" / "all.json"
        payload = json.loads(target.read_text())
        payload["labels"][0]["candidateOutput"] = "hidden"
        target.write_text(json.dumps(payload))
        with self.assertRaisesRegex(ValueError, "source v2 label"):
            self.lane.prepare_correction(self.sources, self.root / "extra-field", "seed")
        payload["labels"][0].pop("candidateOutput")
        target.write_text(json.dumps(payload))
        saved = self.root / "saved-labels.json"
        target.rename(saved)
        target.symlink_to(saved)
        with self.assertRaises(ValueError):
            self.lane.prepare_correction(self.sources, self.root / "symlink", "seed")

    def test_cli_help_exposes_all_three_stages(self):
        import subprocess

        script = DIRECTORY / "single_frame_lane_v4.py"
        result = subprocess.run(
            ["/usr/bin/python3", str(script), "--help"],
            check=True,
            capture_output=True,
            text=True,
        )
        for command in ["prepare-correction", "prepare-audit", "seal"]:
            self.assertIn(command, result.stdout)

    def _load_common(self, name: str):
        path = BENCHMARK / "common" / f"{name}.py"
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def _write_sources(self, prefix: str = ""):
        legacy = load("aggregate_correctness_audit")
        annotation = self.root / f"{prefix}annotation"
        for path in [
            annotation / "labels" / "pass1",
            annotation / "labels" / "pass2",
            annotation / "batches",
            annotation / "renders",
        ]:
            path.mkdir(parents=True, exist_ok=True)
        os.chmod(annotation, 0o700)
        singles = [f"{index:024x}" for index in range(1, 201)]
        temporal = [f"{1000 + index:024x}" for index in range(1, 101)]
        single_duplicates = singles[:30]
        temporal_duplicates = temporal[:15]
        self.single_duplicates = single_duplicates
        duplicates = single_duplicates + temporal_duplicates
        pass1_labels = [self._label(identifier, "single-frame", 1) for identifier in singles]
        pass1_labels += [self._label(identifier, "temporal-pair", 1) for identifier in temporal]
        pass2_labels = [
            self._label(identifier, "single-frame" if identifier in single_duplicates else "temporal-pair", 2)
            for identifier in duplicates
        ]
        self._write_label_batch(annotation / "labels" / "pass1" / "all.json", 1, pass1_labels)
        self._write_label_batch(annotation / "labels" / "pass2" / "all.json", 2, pass2_labels)
        pass1_work = []
        pass2_work = []
        for identifier in singles + temporal:
            target = "single-frame" if identifier in singles else "temporal-pair"
            work = self._work_item(annotation, identifier, target)
            pass1_work.append(work)
            if identifier in duplicates:
                pass2_work.append(work)
        self._write_work(annotation / "batches" / "pass1-all.json", 1, pass1_work)
        self._write_work(annotation / "batches" / "pass2-all.json", 2, pass2_work)

        correctness = self.root / f"{prefix}correctness"
        for slot in ["auditor-01", "auditor-02"]:
            (correctness / "packets" / slot / "images").mkdir(parents=True)
        os.chmod(correctness, 0o700)
        mappings = {"auditor-01": {}, "auditor-02": {}}
        packets = {"auditor-01": [], "auditor-02": []}
        for auditor_number in (1, 2):
            slot = f"auditor-{auditor_number:02d}"
            for index, identifier in enumerate(duplicates):
                target = "single-frame" if identifier in single_duplicates else "temporal-pair"
                for pass_number in (1, 2):
                    opaque = f"a{auditor_number}-{index:02d}-p{pass_number}"
                    mappings[slot][opaque] = {
                        "case": identifier,
                        "sourceReference": f"pass{pass_number}",
                        "pass": pass_number,
                        "targetType": target,
                    }
                    images = []
                    for image_number in range(1 if target == "single-frame" else 2):
                        relative = f"images/{opaque}-{image_number}.jpg"
                        (correctness / "packets" / slot / relative).write_bytes(b"image")
                        images.append(relative)
                    reference = self._reference(target, f"Surface {pass_number}")
                    packets[slot].append({
                        "opaqueID": opaque,
                        "targetType": target,
                        "reference": reference,
                        "images": images,
                    })
            (correctness / "packets" / slot / "packet.json").write_text(json.dumps({
                "schema": "screen-understanding-correctness-audit-packet-v3",
                "protocol": "screen-understanding-correctness-audit-v3",
                "rubricVersion": "screen-understanding-canonical-v2",
                "packetID": f"packet-{slot}",
                "items": packets[slot],
            }))
        (correctness / "owner-mapping.json").write_text(json.dumps({
            "schema": "screen-understanding-correctness-audit-mapping-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "seedSHA256": "a" * 64,
            "auditors": mappings,
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
        outputs = []
        for auditor_number in (1, 2):
            slot = f"auditor-{auditor_number:02d}"
            judgments = []
            for item in packets[slot]:
                slots = ["surface", "content", "state", "intent", "outcome", "criticalText"]
                if item["targetType"] == "temporal-pair":
                    slots.append("meaningfulChange")
                judgment = {
                    "opaqueID": item["opaqueID"],
                    "slots": {name: {"correct": True, "materialFalse": False} for name in slots},
                    "ambiguityDecision": True,
                }
                owner = mappings[slot][item["opaqueID"]]
                if owner["case"] in single_duplicates[:2]:
                    judgment["slots"]["surface"]["correct"] = False
                if owner["case"] == single_duplicates[2] and owner["pass"] == 1:
                    judgment["slots"]["surface"]["correct"] = False
                if owner["targetType"] == "temporal-pair" and owner["case"] in temporal_duplicates[:12]:
                    judgment["slots"]["surface"]["correct"] = False
                judgments.append(judgment)
            output = self.root / f"{prefix}auditor-{auditor_number}.json"
            output.write_text(json.dumps({
                "schema": "screen-understanding-correctness-audit-judgments-v3",
                "protocol": "screen-understanding-correctness-audit-v3",
                "rubricVersion": "screen-understanding-canonical-v2",
                "packetID": f"packet-{slot}",
                "auditor": f"frontier-auditor-{auditor_number}",
                "items": judgments,
            }))
            outputs.append(output)
        aggregate = self.root / f"{prefix}aggregate"
        legacy.aggregate(correctness, outputs[0], outputs[1], aggregate)
        one_receipt = self._issue(
            correctness / "packets" / "auditor-01" / "packet.json",
            outputs[0], "correctness-auditor-1", f"task:/root/{prefix}auditor-1/turn:1",
        )
        two_receipt = self._issue(
            correctness / "packets" / "auditor-02" / "packet.json",
            outputs[1], "correctness-auditor-2", f"task:/root/{prefix}auditor-2/turn:1",
        )
        for private_root in [annotation, correctness, aggregate]:
            for path in private_root.rglob("*"):
                if path.is_dir():
                    os.chmod(path, 0o700)
                elif path.is_file():
                    os.chmod(path, 0o600)
        for output in outputs:
            os.chmod(output, 0o600)
        return self.lane.V3EvidencePaths(
            annotation, correctness, aggregate,
            outputs[0], one_receipt, outputs[1], two_receipt,
        )

    def _write_label_batch(self, path: Path, pass_number: int, labels: list[dict]) -> None:
        path.write_text(json.dumps({
            "schema": "screen-understanding-label-batch-v1",
            "pass": pass_number,
            "annotator": f"frontier-pass-{pass_number}",
            "rubricVersion": "screen-understanding-canonical-v2",
            "labels": labels,
        }))

    def _write_work(self, path: Path, pass_number: int, items: list[dict]) -> None:
        path.write_text(json.dumps({
            "schema": "screen-understanding-annotation-batch-v1",
            "pass": pass_number,
            "annotatorSlot": f"frontier-{pass_number}",
            "rubricVersion": "screen-understanding-canonical-v2",
            "candidateOutputsAvailable": False,
            "items": items,
        }))

    def _work_item(self, annotation: Path, identifier: str, target: str) -> dict:
        if target == "single-frame":
            name = f"private-{identifier}.jpg"
            (annotation / "renders" / name).write_bytes(b"single")
            return {"id": identifier, "targetType": target, "image": f"renders/{name}"}
        before = f"private-{identifier}-before.jpg"
        after = f"private-{identifier}-after.jpg"
        (annotation / "renders" / before).write_bytes(b"before")
        (annotation / "renders" / after).write_bytes(b"after")
        return {
            "id": identifier, "targetType": target,
            "beforeImage": f"renders/{before}",
            "afterImage": f"renders/{after}", "deltaMs": 1000,
        }

    def _label(self, identifier: str, target: str, pass_number: int) -> dict:
        return {
            "case": identifier,
            **self._reference(target, f"Surface {pass_number}"),
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

    def _reference(self, target: str, surface: str) -> dict:
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
            "meaningfulChange": None if target == "single-frame" else [],
            "ambiguity": "judgeable",
            "abstentionAllowed": False,
        }

    def _write_corrections(self, packet_path: Path, name: str = "corrections.json") -> Path:
        packet = json.loads(packet_path.read_text())
        path = self.root / name
        path.write_text(json.dumps({
            "schema": "screen-understanding-single-frame-corrections-v4",
            "protocol": "screen-understanding-single-frame-lane-v4",
            "rubricVersion": "screen-understanding-canonical-v2",
            "packetID": packet["packetID"],
            "producer": "frontier-vlm",
            "mode": "correction",
            "annotator": "frontier-corrector",
            "blindedToCandidateOutputs": True,
            "candidateOutputsAvailable": False,
            "items": [
                {"opaqueID": item["opaqueID"], **self._reference("single-frame", "Corrected")}
                for item in packet["items"]
            ],
        }))
        os.chmod(path, 0o600)
        return path

    def _write_final_judgments(self, packet_path: Path) -> Path:
        packet = json.loads(packet_path.read_text())
        path = self.root / "final-judgments.json"
        path.write_text(json.dumps({
            "schema": "screen-understanding-single-frame-final-judgments-v4",
            "protocol": "screen-understanding-single-frame-lane-v4",
            "rubricVersion": "screen-understanding-canonical-v2",
            "packetID": packet["packetID"],
            "auditor": "fresh-final-auditor",
            "items": [{
                "opaqueID": item["opaqueID"],
                "slots": {
                    name: {"correct": True, "materialFalse": False}
                    for name in ["surface", "content", "state", "intent", "outcome", "criticalText"]
                },
                "ambiguityDecision": True,
            } for item in packet["items"]],
        }))
        os.chmod(path, 0o600)
        return path

    def _issue(self, packet: Path, output: Path, role: str, session: str) -> Path:
        receipt = self.root / f"receipt-{role}-{len(list(self.root.glob('receipt-*.json')))}.json"
        self.receipts.issue_receipt(
            packet_path=packet,
            output_path=output,
            receipt_path=receipt,
            role=role,
            session_id=session,
            provider="openai",
            model_family="gpt-5",
            legacy=True,
        )
        return receipt


if __name__ == "__main__":
    unittest.main()
