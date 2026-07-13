import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate_correctness_audit.py")


def load_module():
    spec = importlib.util.spec_from_file_location("validate_correctness_audit", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ValidateCorrectnessAuditTests(unittest.TestCase):
    def test_accepts_exact_boolean_only_judgments(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            packet, output = self.write_inputs(Path(temporary))
            result = module.validate(packet, output)
            self.assertEqual(result, {"count": 2, "singleFrames": 1, "temporalPairs": 1})

    def test_fails_closed_on_metadata_mismatch_and_leaks(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            packet, output = self.write_inputs(Path(temporary))
            payload = json.loads(output.read_text())
            payload["packetID"] = "wrong"
            output.write_text(json.dumps(payload))
            with self.assertRaisesRegex(ValueError, "packet"):
                module.validate(packet, output)

            packet, output = self.write_inputs(Path(temporary), suffix="-leak")
            payload = json.loads(output.read_text())
            payload["items"][0]["note"] = "/Users/private candidateOutput"
            output.write_text(json.dumps(payload))
            with self.assertRaisesRegex(ValueError, "forbidden|schema"):
                module.validate(packet, output)

    def test_fails_closed_on_wrong_slot_shape(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            packet, output = self.write_inputs(Path(temporary))
            payload = json.loads(output.read_text())
            del payload["items"][1]["slots"]["meaningfulChange"]
            output.write_text(json.dumps(payload))
            with self.assertRaisesRegex(ValueError, "slots"):
                module.validate(packet, output)

    def write_inputs(self, root: Path, suffix: str = "") -> tuple[Path, Path]:
        packet = root / f"packet{suffix}.json"
        output = root / f"judgments{suffix}.json"
        packet.write_text(json.dumps({
            "schema": "screen-understanding-correctness-audit-packet-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "packetID": "packet-01",
            "items": [
                {"opaqueID": "audit-a", "targetType": "single-frame", "reference": self.reference("single-frame"), "images": ["images/audit-a.jpg"]},
                {"opaqueID": "audit-b", "targetType": "temporal-pair", "reference": self.reference("temporal-pair"), "images": ["images/audit-b-1.jpg", "images/audit-b-2.jpg"]},
            ],
        }))
        output.write_text(json.dumps({
            "schema": "screen-understanding-correctness-audit-judgments-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "packetID": "packet-01",
            "auditor": "frontier-correctness-auditor-01",
            "items": [
                self.judgment("audit-a", False),
                self.judgment("audit-b", True),
            ],
        }))
        return packet, output

    def reference(self, target: str) -> dict:
        return {
            "targetType": target,
            "requiredFacts": [
                {"id": "required.surface", "text": "Surface"},
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

    def judgment(self, opaque_id: str, temporal: bool) -> dict:
        names = ["surface", "content", "state", "intent", "outcome", "criticalText"]
        if temporal:
            names.append("meaningfulChange")
        return {
            "opaqueID": opaque_id,
            "slots": {
                name: {"correct": True, "materialFalse": False}
                for name in names
            },
            "ambiguityDecision": True,
        }


if __name__ == "__main__":
    unittest.main()
