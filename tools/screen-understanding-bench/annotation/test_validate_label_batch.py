import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate_label_batch.py")


def load_module():
    spec = importlib.util.spec_from_file_location("validate_label_batch", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ValidateLabelBatchTests(unittest.TestCase):
    def test_valid_blinded_batch_matches_work_ids(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / "work.json"
            labels = root / "labels.json"
            work.write_text(json.dumps({
                "pass": 1,
                "items": [{"id": "a" * 24, "targetType": "single-frame"}],
            }))
            labels.write_text(json.dumps({
                "schema": "screen-understanding-label-batch-v1",
                "pass": 1,
                "annotator": "codex-frontier-01",
                "rubricVersion": "screen-understanding-canonical-v1",
                "labels": [self.label("a" * 24)],
            }))
            result = module.validate(work, labels)
            self.assertEqual(result, {"count": 1, "singleFrames": 1, "temporalPairs": 0})

    def test_candidate_output_and_missing_ids_fail_closed(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            work = root / "work.json"
            labels = root / "labels.json"
            work.write_text(json.dumps({
                "pass": 1,
                "items": [{"id": "a" * 24, "targetType": "single-frame"}],
            }))
            payload = {
                "schema": "screen-understanding-label-batch-v1",
                "pass": 1,
                "annotator": "codex-frontier-01",
                "rubricVersion": "screen-understanding-canonical-v1",
                "labels": [self.label("b" * 24)],
                "candidateOutput": "forbidden",
            }
            labels.write_text(json.dumps(payload))
            with self.assertRaises(ValueError):
                module.validate(work, labels)

    def label(self, identifier: str) -> dict:
        return {
            "case": identifier,
            "targetType": "single-frame",
            "requiredFacts": [
                {"id": "required.01", "text": "A window is visible"},
                {"id": "required.02", "text": "Text is visible", "severity": "minor"},
                {"id": "required.03", "text": "A toolbar is visible", "severity": "minor"},
            ],
            "criticalText": [],
            "forbiddenInferences": [
                {"id": "forbidden.01", "text": "The user intends to submit", "severity": "critical"},
                {"id": "forbidden.02", "text": "The action succeeded", "severity": "major"},
            ],
            "meaningfulChange": None,
            "ambiguity": "judgeable",
            "abstentionAllowed": False,
            "pass": 1,
            "locked": False,
            "annotation": {
                "producer": "frontier-vlm",
                "annotator": "codex-frontier-01",
                "rubricVersion": "screen-understanding-canonical-v1",
                "blindedToCandidateOutputs": True,
                "candidateOutputsAvailable": False,
            },
        }


if __name__ == "__main__":
    unittest.main()
