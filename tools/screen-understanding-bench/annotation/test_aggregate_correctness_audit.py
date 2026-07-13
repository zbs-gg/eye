import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("aggregate_correctness_audit.py")


def load_module():
    spec = importlib.util.spec_from_file_location("aggregate_correctness_audit", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AggregateCorrectnessAuditTests(unittest.TestCase):
    def test_counts_285_opportunities_and_enforces_each_stratum_floor(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audit, one, two = self.write_audit(root, 30, 15)
            for output in [one, two]:
                payload = json.loads(output.read_text())
                temporal = [
                    item for item in payload["items"]
                    if item["opaqueID"].startswith("a1-t") or item["opaqueID"].startswith("a2-t")
                ]
                for item in temporal[:22]:
                    item["slots"]["surface"] = {"correct": False, "materialFalse": False}
                output.write_text(json.dumps(payload))

            result_root = root / "result"
            result = module.aggregate(audit, one, two, result_root)

            self.assertEqual(result["pairedOpportunityCount"], 285)
            self.assertGreaterEqual(result["joint"]["overall"], 0.90)
            self.assertLess(result["joint"]["temporalPair"], 0.90)
            self.assertFalse(result["rawJointGate"]["qualified"])
            self.assertEqual(result["finalReferenceAudit"]["state"], "pending")
            self.assertIsNone(result["finalReferenceAudit"]["criticalErrorCount"])

    def test_material_false_is_an_error_and_selects_clean_reference(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audit, one, two = self.write_audit(root, 30, 15)
            for output in [one, two]:
                payload = json.loads(output.read_text())
                first = next(item for item in payload["items"] if item["opaqueID"].endswith("p1"))
                first["slots"]["surface"] = {"correct": True, "materialFalse": True}
                output.write_text(json.dumps(payload))

            result = module.aggregate(audit, one, two, root / "result")
            self.assertEqual(result["materialFalseCount"]["pass1"], 1)
            selections = json.loads((root / "result" / "selection.json").read_text())
            self.assertEqual(selections["items"][0]["selectedReference"], "pass2")

    def test_emits_only_disagreements_then_accepts_blinded_tiebreak(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audit, one, two = self.write_audit(root, 30, 15)
            payload = json.loads(two.read_text())
            first = next(item for item in payload["items"] if item["opaqueID"].endswith("p1"))
            first["slots"]["surface"]["correct"] = False
            two.write_text(json.dumps(payload))

            pending_root = root / "pending"
            pending = module.aggregate(audit, one, two, pending_root)
            self.assertEqual(pending["state"], "tiebreak-required")
            work_path = pending_root / "tiebreak" / "packet.json"
            work = json.loads(work_path.read_text())
            self.assertEqual(len(work["items"]), 1)
            self.assertEqual(work["items"][0]["disputed"], [
                {"slot": "surface", "field": "correct"},
            ])
            self.assertNotIn("000000000000000000000001", work_path.read_text())

            tiebreak = root / "tiebreak.json"
            tiebreak.write_text(json.dumps({
                "schema": "screen-understanding-correctness-tiebreak-judgments-v3",
                "protocol": "screen-understanding-correctness-audit-v3",
                "rubricVersion": "screen-understanding-canonical-v2",
                "packetID": work["packetID"],
                "auditor": "frontier-tiebreak-01",
                "items": [{
                    "opaqueID": work["items"][0]["opaqueID"],
                    "decisions": [{"slot": "surface", "field": "correct", "value": True}],
                }],
            }))
            final = module.aggregate(audit, one, two, root / "final", tiebreak)
            self.assertEqual(final["state"], "complete")
            self.assertEqual(final["pass1"]["overall"], 1.0)

    def test_metadata_mismatch_fails_closed(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audit, one, two = self.write_audit(root, 30, 15)
            payload = json.loads(two.read_text())
            payload["rubricVersion"] = "wrong"
            two.write_text(json.dumps(payload))
            with self.assertRaisesRegex(ValueError, "rubric"):
                module.aggregate(audit, one, two, root / "result")

    def test_rejects_an_undercount_in_the_locked_duplicate_set(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audit, one, two = self.write_audit(root, 29, 15)
            with self.assertRaisesRegex(ValueError, "45-case"):
                module.aggregate(audit, one, two, root / "result")

    def write_audit(self, root: Path, singles: int, temporal: int) -> tuple[Path, Path, Path]:
        audit = root / "audit"
        (audit / "packets" / "auditor-01" / "images").mkdir(parents=True)
        (audit / "packets" / "auditor-02" / "images").mkdir(parents=True)
        mappings = {"auditor-01": {}, "auditor-02": {}}
        packets = {"auditor-01": [], "auditor-02": []}
        all_cases = [
            (f"{index + 1:024x}", "single-frame") for index in range(singles)
        ] + [
            (f"{100 + index:024x}", "temporal-pair") for index in range(temporal)
        ]
        for auditor_number in (1, 2):
            auditor = f"auditor-{auditor_number:02d}"
            prefix = f"a{auditor_number}"
            for case_index, (case_id, target) in enumerate(all_cases):
                kind = "s" if target == "single-frame" else "t"
                for pass_number in (1, 2):
                    opaque = f"{prefix}-{kind}{case_index:02d}-p{pass_number}"
                    mappings[auditor][opaque] = {
                        "case": case_id,
                        "sourceReference": f"pass{pass_number}",
                        "pass": pass_number,
                        "targetType": target,
                    }
                    image_count = 1 if target == "single-frame" else 2
                    images = [f"images/{opaque}-{number}.jpg" for number in range(image_count)]
                    for image in images:
                        (audit / "packets" / auditor / image).write_bytes(b"image")
                    packets[auditor].append({
                        "opaqueID": opaque,
                        "targetType": target,
                        "reference": self.reference(target),
                        "images": images,
                    })
            (audit / "packets" / auditor / "packet.json").write_text(json.dumps({
                "schema": "screen-understanding-correctness-audit-packet-v3",
                "protocol": "screen-understanding-correctness-audit-v3",
                "rubricVersion": "screen-understanding-canonical-v2",
                "packetID": f"packet-{auditor_number}",
                "items": packets[auditor],
            }))
        (audit / "owner-mapping.json").write_text(json.dumps({
            "schema": "screen-understanding-correctness-audit-mapping-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "seedSHA256": "a" * 64,
            "auditors": mappings,
        }))
        (audit / "audit-manifest.json").write_text(json.dumps({
            "schema": "screen-understanding-correctness-audit-manifest-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "caseCount": len(all_cases),
            "singleFrameCount": singles,
            "temporalPairCount": temporal,
            "referenceCount": len(all_cases) * 2,
            "pairedOpportunityCount": singles * 6 + temporal * 7,
            "auditorCount": 2,
            "candidateOutputsAvailable": False,
        }))
        outputs = []
        for auditor_number in (1, 2):
            auditor = f"auditor-{auditor_number:02d}"
            output = root / f"judgments-{auditor_number}.json"
            output.write_text(json.dumps({
                "schema": "screen-understanding-correctness-audit-judgments-v3",
                "protocol": "screen-understanding-correctness-audit-v3",
                "rubricVersion": "screen-understanding-canonical-v2",
                "packetID": f"packet-{auditor_number}",
                "auditor": f"frontier-auditor-{auditor_number}",
                "items": [self.judgment(item) for item in packets[auditor]],
            }))
            outputs.append(output)
        return audit, outputs[0], outputs[1]

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

    def judgment(self, packet_item: dict) -> dict:
        names = ["surface", "content", "state", "intent", "outcome", "criticalText"]
        if packet_item["targetType"] == "temporal-pair":
            names.append("meaningfulChange")
        return {
            "opaqueID": packet_item["opaqueID"],
            "slots": {name: {"correct": True, "materialFalse": False} for name in names},
            "ambiguityDecision": True,
        }


if __name__ == "__main__":
    unittest.main()
