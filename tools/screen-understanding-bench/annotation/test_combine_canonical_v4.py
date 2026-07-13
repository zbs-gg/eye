#!/usr/bin/python3
"""Tests for combining independently sealed single and temporal references."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

from annotation.combine_canonical_v4 import combine
from common.provenance import file_evidence
from runner.preflight import validate_seal


class CombineCanonicalV4Tests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.corpus = self._root("corpus")
        self.single = self._root("single")
        self.temporal = self._root("temporal")
        self.temporal_audit = self._root("temporal-audit")
        (self.temporal_audit / "evidence.json").write_text("{}\n")
        os.chmod(self.temporal_audit / "evidence.json", 0o600)

        self.single_ids = [f"{index:024x}" for index in range(200)]
        self.pair_ids = [f"{index + 10_000:024x}" for index in range(100)]
        temporal_case_ids = [f"{index + 20_000:024x}" for index in range(200)]
        pairs = [
            {
                "id": pair,
                "beforeCaseID": temporal_case_ids[index * 2],
                "afterCaseID": temporal_case_ids[index * 2 + 1],
                "deltaMs": 1_000,
                "strata": ["fixture"],
            }
            for index, pair in enumerate(self.pair_ids)
        ]
        manifest = {
            "protocolID": "screen-understanding-v1",
            "revision": "fixture",
            "snapshotSHA256": "a" * 64,
            "splitSHA256": "b" * 64,
            "singleFrameCaseIDs": self.single_ids,
            "temporalPairs": pairs,
            "cases": [
                {"id": identifier}
                for identifier in [*self.single_ids, *temporal_case_ids]
            ],
            "splits": {
                "tuneSingleFrames": self.single_ids[:100],
                "validationSingleFrames": self.single_ids[100:140],
                "testSingleFrames": self.single_ids[140:],
                "tuneTemporalPairs": self.pair_ids[:50],
                "validationTemporalPairs": self.pair_ids[50:70],
                "testTemporalPairs": self.pair_ids[70:],
            },
        }
        self._json(self.corpus / "manifest.json", manifest)
        self._write_single()
        self._write_temporal()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _root(self, name: str) -> Path:
        path = self.root / name
        path.mkdir(mode=0o700)
        os.chmod(path, 0o700)
        (path / ".metadata_never_index").touch()
        os.chmod(path / ".metadata_never_index", 0o600)
        return path

    @staticmethod
    def _json(path: Path, value: object) -> None:
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        os.chmod(path, 0o600)

    @staticmethod
    def _reference(identifier: str, target: str, annotation: dict) -> dict:
        return {
            "case": identifier,
            "targetType": target,
            "requiredFacts": [
                {"id": "required.surface", "text": "A visible computer surface"},
                {"id": "required.content", "text": "Visible content"},
                {"id": "required.state", "text": "A visible state"},
            ],
            "criticalText": [] if target == "temporal-pair" else ["Exact text"],
            "forbiddenInferences": [
                {
                    "id": "forbidden.intent",
                    "text": "Intent is not visible",
                    "severity": "critical",
                },
                {
                    "id": "forbidden.outcome",
                    "text": "Outcome is not visible",
                    "severity": "major",
                },
            ],
            "meaningfulChange": (
                None if target == "single-frame"
                else [{"id": "change.primary", "text": "The visible state changed"}]
            ),
            "ambiguity": "judgeable",
            "abstentionAllowed": False,
            "locked": True,
            "annotation": annotation,
        }

    def _write_single(self) -> None:
        canonical = self.single / "canonical"
        canonical.mkdir(mode=0o700)
        labels = {
            "schema": "screen-understanding-single-frame-labels-v4",
            "protocol": "screen-understanding-single-frame-lane-v4",
            "rubricVersion": "screen-understanding-canonical-v2",
            "candidateOutputsAvailableDuringAnnotation": False,
            "labels": [
                self._reference(identifier, "single-frame", {
                    "producer": "frontier-vlm",
                    "mode": "pass1-base",
                    "annotator": "frontier-single",
                    "rubricVersion": "screen-understanding-canonical-v2",
                    "blindedToCandidateOutputs": True,
                    "candidateOutputsAvailable": False,
                })
                for identifier in self.single_ids
            ],
        }
        reliability = {
            "schema": "screen-understanding-single-frame-reliability-v4",
            "protocol": "screen-understanding-single-frame-lane-v4",
            "rubricVersion": "screen-understanding-canonical-v2",
            "duplicateCount": 30,
            "rawJointMinimum": 0.90,
            "rawJointSingleFrame": 165 / 180,
            "finalReferenceAudit": {
                "caseCount": 30,
                "slotCount": 180,
                "materialFalseCount": 0,
                "ambiguityErrorCount": 0,
                "slotErrorCount": 0,
                "qualified": True,
            },
            "qualified": True,
        }
        self._json(canonical / "labels.json", labels)
        self._json(canonical / "reliability.json", reliability)
        self._json(canonical / "commit.json", {
            "schema": "screen-understanding-single-frame-commit-v4",
            "protocol": "screen-understanding-single-frame-lane-v4",
            "rubricVersion": "screen-understanding-canonical-v2",
            "canonical": {
                "labelsSHA256": file_evidence(canonical / "labels.json")["sha256"],
                "reliabilitySHA256": file_evidence(canonical / "reliability.json")["sha256"],
            },
        })

    def _write_temporal(self) -> None:
        labels = []
        for identifier in self.pair_ids:
            label = self._reference(identifier, "temporal-pair", {
                "producer": "frontier-vlm",
                "mode": "pass1-base",
                "annotator": "frontier-temporal",
                "rubricVersion": "screen-understanding-temporal-v4",
                "blindedToCandidateOutputs": True,
                "candidateOutputsAvailable": False,
            })
            label["pair"] = label.pop("case")
            labels.append(label)
        self._json(self.temporal / "labels.json", {
            "schema": "screen-understanding-temporal-final-labels-v4",
            "protocol": "screen-understanding-temporal-annotation-v4",
            "rubricVersion": "screen-understanding-temporal-v4",
            "candidateOutputsAvailable": False,
            "labels": labels,
        })
        self._json(self.temporal / "reliability.json", {
            "schema": "screen-understanding-temporal-reliability-v4",
            "protocol": "screen-understanding-temporal-annotation-v4",
            "rubricVersion": "screen-understanding-temporal-v4",
            "rawJoint": {
                "minimum": 0.90,
                "correctCount": 70,
                "opportunityCount": 75,
                "rate": 70 / 75,
                "qualified": True,
            },
            "finalAudit": {
                "auditor": "fresh-temporal-auditor",
                "pairCount": 15,
                "opportunityCount": 75,
                "materialFalseCount": 0,
                "incorrectCount": 0,
                "qualified": True,
            },
            "independence": {"qualified": True},
            "candidateOutputsAvailable": False,
            "qualified": True,
        })
        self._json(self.temporal / "result.json", {"qualified": True, "pairCount": 100})

    def test_combines_300_labels_and_binds_255_audit_slots(self) -> None:
        output = self.root / "combined"
        result = combine(
            self.corpus,
            self.single,
            self.temporal,
            self.temporal_audit,
            output,
        )
        labels = json.loads((output / "canonical" / "labels.json").read_text())
        reliability = json.loads(
            (output / "canonical" / "reliability.json").read_text()
        )
        self.assertEqual(result["labelCount"], 300)
        self.assertEqual(len(labels["labels"]), 300)
        self.assertEqual(reliability["finalReferenceAudit"]["slotCount"], 255)
        self.assertAlmostEqual(
            reliability["rawJoint"]["overall"],
            (165 + 70) / 255,
        )
        summary = validate_seal(
            self.corpus,
            output,
            source_annotation_root=self.single,
            correctness_audit_root=self.temporal_audit,
            aggregate_root=output / "aggregate-evidence",
            final_audit_root=output,
            final_judgments=output / "final-judgments.json",
        )
        self.assertEqual(summary["labelCount"], 300)

    def test_rejects_an_unqualified_temporal_source_without_publishing(self) -> None:
        reliability = json.loads((self.temporal / "reliability.json").read_text())
        reliability["qualified"] = False
        self._json(self.temporal / "reliability.json", reliability)
        output = self.root / "bad-combined"
        with self.assertRaisesRegex(ValueError, "temporal reliability"):
            combine(
                self.corpus,
                self.single,
                self.temporal,
                self.temporal_audit,
                output,
            )
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
