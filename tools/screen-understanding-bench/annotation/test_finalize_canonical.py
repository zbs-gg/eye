import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("finalize_canonical.py")


def load_module():
    spec = importlib.util.spec_from_file_location("finalize_canonical", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FinalizeCanonicalTests(unittest.TestCase):
    def test_seals_selected_and_merged_references(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_inputs(root)

            result = module.finalize(root)

            self.assertTrue(result["qualified"])
            self.assertEqual(result["labelCount"], 2)
            labels = json.loads((root / "canonical" / "labels.json").read_text())["labels"]
            by_id = {label["case"]: label for label in labels}
            self.assertEqual(by_id["a" * 24]["requiredFacts"][0]["text"], "Reference B")
            self.assertEqual(by_id["b" * 24]["requiredFacts"][0]["text"], "Merged")
            self.assertTrue(all(label["locked"] for label in labels))
            self.assertEqual(os.stat(root / "canonical" / "labels.json").st_mode & 0o777, 0o600)
            self.assertTrue((root / "canonical" / ".metadata_never_index").is_file())

    def test_fails_closed_below_reliability_floor(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_inputs(root, fact_agreement=0.89)
            with self.assertRaisesRegex(ValueError, "reliability floor"):
                module.finalize(root)
            self.assertFalse((root / "canonical").exists())

    def test_fails_closed_on_candidate_or_path_leak(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_inputs(root)
            decisions = root / "adjudication" / "decisions.json"
            payload = json.loads(decisions.read_text())
            payload["candidateOutput"] = "/Users/private"
            decisions.write_text(json.dumps(payload))
            with self.assertRaisesRegex(ValueError, "forbidden"):
                module.finalize(root)

    def write_inputs(self, root: Path, fact_agreement: float = 0.95):
        (root / "labels" / "pass1").mkdir(parents=True)
        (root / "adjudication").mkdir()
        first = self.label("a" * 24, "Pass 1")
        second = self.label("b" * 24, "Second")
        (root / "labels" / "pass1" / "batch-01.json").write_text(json.dumps({
            "schema": "screen-understanding-label-batch-v1",
            "pass": 1,
            "annotator": "frontier-01",
            "rubricVersion": "screen-understanding-canonical-v2",
            "labels": [first, second],
        }))
        reference_a = self.reference("Reference A")
        reference_b = self.reference("Reference B")
        (root / "adjudication" / "work.json").write_text(json.dumps({
            "schema": "screen-understanding-adjudication-work-v1",
            "rubricVersion": "screen-understanding-canonical-v2",
            "candidateOutputsAvailable": False,
            "items": [{
                "id": "a" * 24,
                "targetType": "single-frame",
                "referenceA": reference_a,
                "referenceB": reference_b,
            }, {
                "id": "b" * 24,
                "targetType": "single-frame",
                "referenceA": reference_a,
                "referenceB": reference_b,
            }],
        }))
        (root / "adjudication" / "decisions.json").write_text(json.dumps({
            "schema": "screen-understanding-adjudication-decisions-v2",
            "annotator": "frontier-adjudicator-01",
            "rubricVersion": "screen-understanding-canonical-v2",
            "candidateOutputsAvailable": False,
            "items": [{
                "id": "a" * 24,
                "factAgreement": fact_agreement,
                "decisionAgreement": True,
                "preference": "B",
            }, {
                "id": "b" * 24,
                "factAgreement": fact_agreement,
                "decisionAgreement": True,
                "preference": "merge",
            }],
            "overrides": {"b" * 24: self.reference("Merged")},
        }))

    def label(self, identifier: str, text: str) -> dict:
        value = self.reference(text)
        return {
            "case": identifier,
            **value,
            "pass": 1,
            "locked": False,
            "annotation": {
                "producer": "frontier-vlm",
                "annotator": "frontier-01",
                "rubricVersion": "screen-understanding-canonical-v2",
                "blindedToCandidateOutputs": True,
                "candidateOutputsAvailable": False,
            },
        }

    def reference(self, text: str) -> dict:
        return {
            "targetType": "single-frame",
            "requiredFacts": [
                {"id": "required.surface", "text": text},
                {"id": "required.content", "text": "Content"},
                {"id": "required.state", "text": "State"},
            ],
            "criticalText": [],
            "forbiddenInferences": [
                {"id": "forbidden.intent", "text": "Intent", "severity": "critical"},
                {"id": "forbidden.outcome", "text": "Outcome", "severity": "major"},
            ],
            "meaningfulChange": None,
            "ambiguity": "judgeable",
            "abstentionAllowed": False,
        }


if __name__ == "__main__":
    unittest.main()
