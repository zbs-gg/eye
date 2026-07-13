import importlib.util
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("prepare_correctness_audit.py")


def load_module():
    spec = importlib.util.spec_from_file_location("prepare_correctness_audit", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PrepareCorrectnessAuditTests(unittest.TestCase):
    def test_creates_two_independently_blinded_deterministic_packets(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            annotation = self.make_annotation_root(base)
            first = base / "audit-one"
            second = base / "audit-two"
            different = base / "audit-different-seed"

            result = module.prepare_audit(annotation, first, "audit-seed")
            module.prepare_audit(annotation, second, "audit-seed")
            module.prepare_audit(annotation, different, "different-seed")

            self.assertEqual(result["caseCount"], 45)
            self.assertEqual(result["referenceCount"], 90)
            self.assertEqual(result["pairedOpportunityCount"], 285)
            packets = []
            for number in (1, 2):
                path = first / "packets" / f"auditor-{number:02d}" / "packet.json"
                packet = json.loads(path.read_text())
                packets.append(packet)
                self.assertEqual(packet["protocol"], "screen-understanding-correctness-audit-v3")
                self.assertEqual(packet["rubricVersion"], "screen-understanding-canonical-v2")
                self.assertEqual(len(packet["items"]), 90)
                text = path.read_text()
                self.assertNotIn('"candidateOutput"', text)
                self.assertNotIn('"annotator"', text)
                self.assertNotIn('"pass"', text)
                for case_id in self.case_ids:
                    self.assertNotIn(case_id, text)
                for item in packet["items"]:
                    self.assertEqual(set(item), {
                        "opaqueID", "targetType", "reference", "images",
                    })
                    self.assertTrue(all(
                        Path(image).name.startswith(item["opaqueID"])
                        for image in item["images"]
                    ))

            aliases_one = [item["opaqueID"] for item in packets[0]["items"]]
            aliases_two = [item["opaqueID"] for item in packets[1]["items"]]
            self.assertTrue(set(aliases_one).isdisjoint(aliases_two))
            self.assertNotEqual(aliases_one, aliases_two)
            self.assertEqual(
                (first / "owner-mapping.json").read_text(),
                (second / "owner-mapping.json").read_text(),
            )
            self.assertNotEqual(
                (first / "owner-mapping.json").read_text(),
                (different / "owner-mapping.json").read_text(),
            )
            for number in (1, 2):
                self.assertEqual(
                    (first / "packets" / f"auditor-{number:02d}" / "packet.json").read_text(),
                    (second / "packets" / f"auditor-{number:02d}" / "packet.json").read_text(),
                )
            self.assertEqual(stat.S_IMODE((first / "owner-mapping.json").stat().st_mode), 0o600)
            self.assertTrue((first / ".metadata_never_index").is_file())
            self.assertTrue(all(
                stat.S_IMODE(path.stat().st_mode) == 0o700
                for path in [first, first / "packets", *[p for p in first.rglob("*") if p.is_dir()]]
            ))
            self.assertTrue(all(
                stat.S_IMODE(path.stat().st_mode) == 0o600
                for path in first.rglob("*") if path.is_file()
            ))

    def test_existing_output_and_non_v2_inputs_fail_closed(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            annotation = self.make_annotation_root(base)
            output = base / "audit"
            output.mkdir()
            with self.assertRaisesRegex(ValueError, "already exists"):
                module.prepare_audit(annotation, output, "seed")

            output.rmdir()
            batch = annotation / "labels" / "pass1" / "batch-01.json"
            payload = json.loads(batch.read_text())
            payload["rubricVersion"] = "screen-understanding-canonical-v1"
            batch.write_text(json.dumps(payload))
            with self.assertRaisesRegex(ValueError, "rubric"):
                module.prepare_audit(annotation, output, "seed")

    def test_rejects_an_undercount_in_the_locked_duplicate_set(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            annotation = self.make_annotation_root(base)
            work_path = annotation / "batches" / "pass2-01.json"
            work = json.loads(work_path.read_text())
            work["items"].pop()
            work_path.write_text(json.dumps(work))
            with self.assertRaisesRegex(ValueError, "locked 30/15"):
                module.prepare_audit(annotation, base / "audit", "seed")

    def make_annotation_root(self, base: Path) -> Path:
        root = base / "annotations"
        for path in [
            root / "labels" / "pass1",
            root / "labels" / "pass2",
            root / "batches",
            root / "renders",
        ]:
            path.mkdir(parents=True, exist_ok=True)
        singles = [f"{index:024x}" for index in range(1, 31)]
        temporal = [f"{100 + index:024x}" for index in range(15)]
        self.case_ids = singles + temporal
        pass1 = []
        pass2 = []
        work = []
        for index, identifier in enumerate(singles):
            render = f"{1000 + index:024x}.jpg"
            (root / "renders" / render).write_bytes(b"single")
            pass1.append(self.label(identifier, "single-frame", 1))
            pass2.append(self.label(identifier, "single-frame", 2))
            work.append({
                "id": identifier,
                "targetType": "single-frame",
                "image": f"renders/{render}",
            })
        for index, identifier in enumerate(temporal):
            before = f"{2000 + index * 2:024x}.jpg"
            after = f"{2001 + index * 2:024x}.jpg"
            (root / "renders" / before).write_bytes(b"before")
            (root / "renders" / after).write_bytes(b"after")
            pass1.append(self.label(identifier, "temporal-pair", 1))
            pass2.append(self.label(identifier, "temporal-pair", 2))
            work.append({
                "id": identifier,
                "targetType": "temporal-pair",
                "beforeImage": f"renders/{before}",
                "afterImage": f"renders/{after}",
                "deltaMs": 1000,
            })
        self.write_labels(root / "labels" / "pass1" / "batch-01.json", 1, pass1)
        self.write_labels(root / "labels" / "pass2" / "batch-01.json", 2, pass2)
        (root / "batches" / "pass2-01.json").write_text(json.dumps({
            "schema": "screen-understanding-annotation-batch-v1",
            "pass": 2,
            "annotatorSlot": "hidden",
            "rubricVersion": "screen-understanding-canonical-v2",
            "candidateOutputsAvailable": False,
            "items": work,
        }))
        return root

    def write_labels(self, path: Path, pass_number: int, labels: list[dict]) -> None:
        path.write_text(json.dumps({
            "schema": "screen-understanding-label-batch-v1",
            "pass": pass_number,
            "annotator": f"frontier-{pass_number}",
            "rubricVersion": "screen-understanding-canonical-v2",
            "labels": labels,
        }))

    def label(self, identifier: str, target: str, pass_number: int) -> dict:
        return {
            "case": identifier,
            "targetType": target,
            "requiredFacts": [
                {"id": "required.surface", "text": f"Surface {pass_number}"},
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
            "pass": pass_number,
            "locked": False,
            "annotation": {
                "producer": "frontier-vlm",
                "annotator": f"frontier-{pass_number}",
                "rubricVersion": "screen-understanding-canonical-v2",
                "blindedToCandidateOutputs": True,
                "candidateOutputsAvailable": False,
            },
        }


if __name__ == "__main__":
    unittest.main()
