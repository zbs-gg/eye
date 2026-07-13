#!/usr/bin/python3

import hashlib
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).parent))

from claim_mapping import (  # noqa: E402
    MappingError,
    aggregate_mappings,
    prepare_mapping,
    validate_mapper_output,
    validate_public_output,
)


METHODS = ("metadata-ax-ocr", "apple-vision", "deterministic-hybrid")


class ClaimMappingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.canonical = self.base / "canonical"
        self.results = self.base / "results"
        self.canonical.mkdir(mode=0o700)
        self.results.mkdir(mode=0o700)
        self.case_ids = [f"{index + 1:024x}" for index in range(60)]
        self._write_fixture()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_inventory_tamper_fails_closed(self) -> None:
        with (self.results / "metadata-ax-ocr.jsonl").open("ab") as handle:
            handle.write(b"{}\n")

        with self.assertRaisesRegex(MappingError, "output hash"):
            prepare_mapping(
                self.canonical, self.results, self.base / "mapping", "seed-1"
            )

    def test_canonical_reliability_gate_precedes_candidate_result_access(self) -> None:
        reliability_path = self.canonical / "reliability.json"
        reliability = self._load(reliability_path)
        reliability["qualified"] = False
        self._write_private(reliability_path, reliability)
        for method in METHODS:
            (self.results / f"{method}.jsonl").unlink()

        with self.assertRaisesRegex(MappingError, "reliability is not qualified"):
            prepare_mapping(
                self.canonical, self.results,
                self.base / "mapping-unqualified", "seed-unqualified",
            )

    def test_packets_are_blinded_and_visible_text_is_not_a_claim(self) -> None:
        prepared = self._prepare("seed-blind")
        primary = self._load(prepared["primaryPacket"])
        hidden = self._load(prepared["hiddenPacket"])

        serialized = json.dumps([primary, hidden], sort_keys=True)
        for method in METHODS:
            self.assertNotIn(method, serialized)
        for case_id in self.case_ids:
            self.assertNotIn(case_id, serialized)
        for forbidden in (
            "methodID", "caseID", "candidateOutput", "timing", "split",
            "/Users/", "/Volumes/", "file://",
        ):
            self.assertNotIn(forbidden, serialized)
        first = primary["items"][0]
        self.assertEqual(first["visibleText"], ["Exact OCR text"])
        claim_texts = [claim["text"] for claim in first["claims"]]
        self.assertNotIn("Exact OCR text", claim_texts)
        self.assertIn("label:computer screen", claim_texts)

    def test_hidden_duplicates_are_deterministic_stratified_fifteen_percent(self) -> None:
        first = self._prepare("stable-seed", "mapping-a")
        second = self._prepare("stable-seed", "mapping-b")
        first_hidden = self._load(first["hiddenPacket"])
        second_hidden = self._load(second["hiddenPacket"])
        first_primary = self._load(first["primaryPacket"])

        self.assertEqual(first_hidden, second_hidden)
        self.assertEqual(len(first_primary["items"]), 180)
        self.assertEqual(len(first_hidden["items"]), 27)
        counts = {}
        for item in first_hidden["items"]:
            counts[item["anonymousMethod"]] = counts.get(item["anonymousMethod"], 0) + 1
        self.assertEqual(sorted(counts.values()), [9, 9, 9])
        self.assertTrue(
            set(item["anonymousMethod"] for item in first_primary["items"])
            .isdisjoint(item["anonymousMethod"] for item in first_hidden["items"])
        )
        self.assertNotEqual(
            [item["armID"] for item in first_primary["items"][:27]],
            [item["armID"] for item in first_hidden["items"]],
        )

    def test_judgment_schema_is_exact_and_mapper_identities_must_differ(self) -> None:
        prepared = self._prepare("schema-seed")
        primary = self._load(prepared["primaryPacket"])
        hidden = self._load(prepared["hiddenPacket"])
        output = self._judgments(primary, "frontier-mapper-01")
        output["items"][0]["claimJudgments"][0]["judgment"] = {
            "matchedRequired": "required.surface",
            "ambiguous": True,
        }
        invalid = self.base / "invalid.json"
        self._write_private(invalid, output)

        with self.assertRaisesRegex(MappingError, "exactly one"):
            validate_mapper_output(Path(prepared["primaryPacket"]), invalid)

        first = self._write_judgments(primary, "frontier-mapper-01", "primary.json")
        second = self._write_judgments(hidden, "frontier-mapper-01", "hidden.json")
        with self.assertRaisesRegex(MappingError, "distinct"):
            aggregate_mappings(
                Path(prepared["mappingRoot"]), first, second,
                self.base / "aggregate-same-identity",
            )

    def test_reliability_below_floor_is_inconclusive(self) -> None:
        prepared = self._prepare("low-reliability")
        primary = self._load(prepared["primaryPacket"])
        hidden = self._load(prepared["hiddenPacket"])
        first = self._write_judgments(primary, "frontier-mapper-01", "primary-low.json")
        hidden_output = self._judgments(hidden, "frontier-mapper-02")
        for item in hidden_output["items"][:10]:
            for claim in item["claimJudgments"]:
                claim["judgment"] = {"unsupported": "critical"}
            item["criticalTextMatched"] = [False]
            item["abstentionCorrect"] = False
        second = self.base / "hidden-low.json"
        self._write_private(second, hidden_output)

        result = aggregate_mappings(
            Path(prepared["mappingRoot"]), first, second,
            self.base / "aggregate-low",
        )

        self.assertEqual(result["status"], "inconclusive")
        aggregate_result = self._load(result["aggregateResult"])
        self.assertEqual(aggregate_result["status"], "inconclusive")
        self.assertEqual(aggregate_result["reliability"], result["reliability"])
        self.assertEqual(
            set(aggregate_result["adjudication"]), {"file", "sha256"}
        )
        self.assertIsNone(aggregate_result["publicAggregate"])
        self.assertFalse(result["reliability"]["qualified"])
        self.assertNotIn("publicAggregate", result)
        adjudication = self._load(result["adjudicationPacket"])
        self.assertGreater(len(adjudication["items"]), 0)
        self.assertLess(len(adjudication["items"]), len(hidden["items"]))

    def test_adjudication_contains_only_disagreements_and_uses_fresh_identity(self) -> None:
        prepared = self._prepare("tie-seed")
        primary = self._load(prepared["primaryPacket"])
        hidden = self._load(prepared["hiddenPacket"])
        first = self._write_judgments(primary, "frontier-mapper-01", "primary-tie.json")
        hidden_output = self._judgments(hidden, "frontier-mapper-02")
        hidden_output["items"][0]["claimJudgments"][0]["judgment"] = {
            "matchedForbidden": "forbidden.intent"
        }
        second = self.base / "hidden-tie.json"
        self._write_private(second, hidden_output)

        pending = aggregate_mappings(
            Path(prepared["mappingRoot"]), first, second,
            self.base / "aggregate-pending",
        )
        self.assertEqual(pending["status"], "adjudication-required")
        pending_result = self._load(pending["aggregateResult"])
        self.assertEqual(pending_result["status"], "adjudication-required")
        self.assertEqual(
            set(pending_result["adjudication"]), {"file", "sha256"}
        )
        self.assertIsNone(pending_result["publicAggregate"])
        packet = self._load(pending["adjudicationPacket"])
        self.assertEqual(len(packet["items"]), 1)
        self.assertEqual(len(packet["items"][0]["claimJudgments"]), 1)

        stale = self._adjudication(packet, "frontier-mapper-01")
        stale_path = self.base / "stale-adjudication.json"
        self._write_private(stale_path, stale)
        with self.assertRaisesRegex(MappingError, "fresh"):
            aggregate_mappings(
                Path(prepared["mappingRoot"]), first, second,
                self.base / "aggregate-stale", stale_path,
            )

        adjudication = self._adjudication(packet, "frontier-adjudicator-03")
        adjudication_path = self.base / "adjudication.json"
        self._write_private(adjudication_path, adjudication)
        complete = aggregate_mappings(
            Path(prepared["mappingRoot"]), first, second,
            self.base / "aggregate-complete", adjudication_path,
        )
        self.assertEqual(complete["status"], "qualified")
        complete_result = self._load(complete["aggregateResult"])
        self.assertEqual(complete_result["status"], "qualified")
        self.assertEqual(
            set(complete_result["adjudication"]), {"file", "sha256"}
        )
        self.assertEqual(
            set(complete_result["publicAggregate"]), {"file", "sha256"}
        )

    def test_owner_mapping_duplicate_cross_links_fail_closed(self) -> None:
        prepared = self._prepare("cross-link-seed")
        mapping_root = Path(prepared["mappingRoot"])
        owner_path = mapping_root / "owner-mapping.json"
        owner = self._load(owner_path)
        hidden_owner = next(iter(owner["hidden"].values()))
        hidden_owner["primaryArmID"] = next(
            arm_id for arm_id in owner["primary"]
            if arm_id != hidden_owner["primaryArmID"]
        )
        self._write_private(owner_path, owner)
        primary = self._load(prepared["primaryPacket"])
        hidden = self._load(prepared["hiddenPacket"])
        first = self._write_judgments(primary, "frontier-mapper-01", "primary-cross.json")
        second = self._write_judgments(hidden, "frontier-mapper-02", "hidden-cross.json")

        with self.assertRaisesRegex(MappingError, "cross-link"):
            aggregate_mappings(
                mapping_root, first, second, self.base / "aggregate-cross"
            )

    def test_scores_are_deterministic_and_method_ids_return_only_in_aggregate(self) -> None:
        prepared = self._prepare("score-seed")
        primary = self._load(prepared["primaryPacket"])
        hidden = self._load(prepared["hiddenPacket"])
        first = self._write_judgments(primary, "frontier-mapper-01", "primary-score.json")
        second = self._write_judgments(hidden, "frontier-mapper-02", "hidden-score.json")

        left = aggregate_mappings(
            Path(prepared["mappingRoot"]), first, second,
            self.base / "aggregate-left",
        )
        right = aggregate_mappings(
            Path(prepared["mappingRoot"]), first, second,
            self.base / "aggregate-right",
        )
        left_public = self._load(left["publicAggregate"])
        right_public = self._load(right["publicAggregate"])

        self.assertEqual(left_public, right_public)
        self.assertEqual(
            [method["methodID"] for method in left_public["methods"]],
            list(METHODS),
        )
        for method in left_public["methods"]:
            self.assertEqual(method["caseCount"], 60)
            self.assertAlmostEqual(method["requiredFactRecall"], 2 / 3)
            self.assertEqual(method["criticalTextRecall"], 1.0)
            self.assertAlmostEqual(method["severityWeightedHallucination"], 0.25 / 3)
            self.assertEqual(method["abstentionAccuracy"], 1.0)
            expected = ((2 / 3) + 1.0 + (1.0 - 0.25 / 3) + 1.0) / 4
            self.assertAlmostEqual(method["overall"], expected)

        packet_text = Path(prepared["primaryPacket"]).read_text(encoding="utf-8")
        mapper_text = first.read_text(encoding="utf-8")
        for method in METHODS:
            self.assertNotIn(method, packet_text)
            self.assertNotIn(method, mapper_text)

    def test_public_output_rejects_private_or_case_level_fields(self) -> None:
        payload = {
            "schema": "screen-understanding-public-claim-scores-v1",
            "protocol": "screen-understanding-correctness-audit-v3",
            "status": "qualified",
            "reliability": {
                "duplicateArmCount": 27,
                "claimJudgmentAgreement": 1.0,
                "decisionAgreement": 1.0,
                "qualified": True,
            },
            "methods": [{
                "methodID": "metadata-ax-ocr",
                "caseCount": 60,
                "claimCount": 180,
                "requiredFactRecall": 1.0,
                "criticalTextRecall": 1.0,
                "severityWeightedHallucination": 0.0,
                "abstentionAccuracy": 1.0,
                "overall": 1.0,
                "caseID": self.case_ids[0],
            }],
        }
        with self.assertRaisesRegex(MappingError, "public aggregate"):
            validate_public_output(payload)

    def test_private_artifacts_are_owner_only(self) -> None:
        prepared = self._prepare("permission-seed")
        self.assertEqual(
            stat.S_IMODE(Path(prepared["mappingRoot"]).stat().st_mode), 0o700
        )
        for name in ("primary-packet.json", "hidden-packet.json", "owner-mapping.json"):
            self.assertEqual(
                stat.S_IMODE((Path(prepared["mappingRoot"]) / name).stat().st_mode),
                0o600,
            )
        primary = self._load(prepared["primaryPacket"])
        hidden = self._load(prepared["hiddenPacket"])
        first = self._write_judgments(primary, "frontier-mapper-01", "primary-mode.json")
        second = self._write_judgments(hidden, "frontier-mapper-02", "hidden-mode.json")
        result = aggregate_mappings(
            Path(prepared["mappingRoot"]), first, second,
            self.base / "aggregate-mode",
        )
        self.assertEqual(
            stat.S_IMODE((self.base / "aggregate-mode").stat().st_mode), 0o700
        )
        self.assertEqual(
            stat.S_IMODE(Path(result["publicAggregate"]).stat().st_mode), 0o600
        )
        self.assertEqual(
            stat.S_IMODE(Path(result["aggregateResult"]).stat().st_mode), 0o600
        )

    def _prepare(self, seed: str, name: str = "mapping") -> dict:
        return prepare_mapping(
            self.canonical, self.results, self.base / name, seed
        )

    def _write_fixture(self) -> None:
        labels = []
        for index in range(300):
            identifier = f"{index + 1:024x}"
            labels.append({
                "case": identifier,
                "targetType": "single-frame",
                "requiredFacts": [
                    {"id": "required.surface", "text": "A computer surface is visible"},
                    {"id": "required.content", "text": "Content is present"},
                    {"id": "required.state", "text": "The surface is active"},
                ],
                "criticalText": ["Exact OCR text"],
                "forbiddenInferences": [
                    {"id": "forbidden.intent", "text": "User intent", "severity": "critical"},
                    {"id": "forbidden.outcome", "text": "Future outcome", "severity": "major"},
                ],
                "meaningfulChange": None,
                "ambiguity": "judgeable",
                "abstentionAllowed": False,
                "locked": True,
                "annotation": {
                    "producer": "frontier-vlm",
                    "mode": "frontier-correction",
                    "annotator": "frontier-reference-03",
                    "rubricVersion": "screen-understanding-canonical-v2",
                    "blindedToCandidateOutputs": True,
                    "candidateOutputsAvailable": False,
                },
            })
        labels_document = {
            "schema": "screen-understanding-canonical-labels-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "candidateOutputsAvailableDuringAnnotation": False,
            "labels": labels,
        }
        reliability = {
            "schema": "screen-understanding-canonical-reliability-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "duplicateCount": 45,
            "rawJoint": {
                "minimum": 0.90,
                "overall": 0.95,
                "singleFrame": 0.95,
                "temporalPair": 0.95,
            },
            "finalReferenceAudit": {
                "auditor": "fresh-final-auditor",
                "caseCount": 45,
                "slotCount": 285,
                "materialFalseCount": 0,
                "ambiguityErrorCount": 0,
                "criticalErrorCount": 0,
                "requiredCriticalErrorCount": 0,
                "qualified": True,
            },
            "qualified": True,
        }
        labels_bytes = self._write_private(self.canonical / "labels.json", labels_document)
        reliability_bytes = self._write_private(
            self.canonical / "reliability.json", reliability
        )

        output_hashes = {}
        for method in METHODS:
            records = []
            for identifier in self.case_ids:
                records.append({
                    "schema": "screen-understanding-built-in-output-v1",
                    "caseID": identifier,
                    "mappingPending": True,
                    "result": {
                        "methodID": method,
                        "capabilities": [
                            "summary", "atomic-facts", "visible-text", "labels",
                            "abstention", "runtime-metadata",
                        ],
                        "summary": "A computer window is visible",
                        "atomicFacts": ["Content is present"],
                        "visibleText": ["Exact OCR text"],
                        "labels": ["computer screen"],
                        "abstention": False,
                        "runtimeMetadata": {"networkUsed": False},
                    },
                })
            data = b"".join(
                json.dumps(record, sort_keys=True, separators=(",", ":"))
                .encode("utf-8") + b"\n"
                for record in records
            )
            path = self.results / f"{method}.jsonl"
            path.write_bytes(data)
            os.chmod(path, 0o600)
            output_hashes[method] = hashlib.sha256(data).hexdigest()
        inventory = {
            "schema": "screen-understanding-built-in-run-v1",
            "protocolID": "screen-understanding-v1",
            "split": "testSingleFrames",
            "caseCount": 60,
            "selectedMethods": list(METHODS),
            "mappingPending": True,
            "complete": True,
            "commitFile": "run-inventory.json",
            "partialOutputsValidWithoutInventory": False,
            "datasetManifestSHA256": "a" * 64,
            "canonicalLabelsSHA256": hashlib.sha256(labels_bytes).hexdigest(),
            "canonicalReliabilitySHA256": hashlib.sha256(reliability_bytes).hexdigest(),
            "methodArtifacts": {
                method: {
                    "artifactRevision": "runner-fixture",
                    "artifactIdentitySHA256": "b" * 64,
                }
                for method in METHODS
            },
            "runnerSourceSHA256": {"orchestrator": "c" * 64},
            "outputSHA256": output_hashes,
        }
        self._write_private(self.results / "run-inventory.json", inventory)

    def _judgments(self, packet: dict, identity: str) -> dict:
        items = []
        for item in packet["items"]:
            claim_judgments = []
            for claim in item["claims"]:
                if claim["source"] == "summary":
                    decision = {"matchedRequired": "required.surface"}
                elif claim["source"] == "atomicFact":
                    decision = {"matchedRequired": "required.content"}
                else:
                    decision = {"unsupported": "minor"}
                claim_judgments.append({
                    "claimID": claim["claimID"],
                    "judgment": decision,
                })
            items.append({
                "armID": item["armID"],
                "claimJudgments": claim_judgments,
                "criticalTextMatched": [True for _ in item["criticalText"]],
                "abstentionCorrect": True,
            })
        return {
            "schema": "screen-understanding-claim-judgments-v1",
            "protocol": "screen-understanding-correctness-audit-v3",
            "packetID": packet["packetID"],
            "mapperIdentity": identity,
            "items": items,
        }

    def _write_judgments(self, packet: dict, identity: str, name: str) -> Path:
        path = self.base / name
        self._write_private(path, self._judgments(packet, identity))
        return path

    def _adjudication(self, packet: dict, identity: str) -> dict:
        items = []
        for item in packet["items"]:
            items.append({
                "adjudicationID": item["adjudicationID"],
                "claimJudgments": [
                    {
                        "claimID": claim["claimID"],
                        "judgment": {"matchedRequired": "required.surface"},
                    }
                    for claim in item["claimJudgments"]
                ],
                "criticalTextMatched": [True for _ in item["criticalTextDisagreements"]],
                "abstentionCorrect": (
                    True if item["abstentionDisagreement"] else None
                ),
            })
        return {
            "schema": "screen-understanding-claim-adjudication-v1",
            "protocol": "screen-understanding-correctness-audit-v3",
            "packetID": packet["packetID"],
            "adjudicatorIdentity": identity,
            "items": items,
        }

    @staticmethod
    def _write_private(path: Path, value: object) -> bytes:
        data = (
            json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
        ).encode("utf-8")
        path.write_bytes(data)
        os.chmod(path, 0o600)
        return data

    @staticmethod
    def _load(path) -> dict:
        return json.loads(Path(path).read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
