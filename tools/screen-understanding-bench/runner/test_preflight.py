#!/usr/bin/python3

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


BENCHMARK_ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))
sys.path.insert(0, str(Path(__file__).parent))

from common.provenance import build_canonical_commit  # noqa: E402
from preflight import (  # noqa: E402
    PreflightError,
    UnsupportedMethodError,
    parse_method_ids,
    select_methods,
    validate_seal,
)


BUILT_INS = [
    {"id": "metadata-ax-ocr", "status": "built-in"},
    {"id": "apple-vision", "status": "built-in"},
    {"id": "deterministic-hybrid", "status": "built-in"},
]


class MethodSelectionTests(unittest.TestCase):
    def test_method_parsing_is_ordered_and_deterministic(self) -> None:
        self.assertEqual(
            parse_method_ids(" apple-vision,metadata-ax-ocr,deterministic-hybrid "),
            ("apple-vision", "metadata-ax-ocr", "deterministic-hybrid"),
        )
        with self.assertRaisesRegex(PreflightError, "duplicated"):
            parse_method_ids("apple-vision,apple-vision")

    def test_selected_built_ins_ignore_unselected_unsupported_methods(self) -> None:
        manifest = {
            "adapters": BUILT_INS + [
                {"id": "smolvlm-256m-instruct", "status": "security-unsupported"}
            ]
        }

        selected = select_methods(manifest, "apple-vision,metadata-ax-ocr")

        self.assertEqual([entry["id"] for entry in selected], [
            "apple-vision",
            "metadata-ax-ocr",
        ])

    def test_selected_security_unsupported_method_is_blocked(self) -> None:
        manifest = {
            "adapters": BUILT_INS + [
                {"id": "smolvlm-256m-instruct", "status": "security-unsupported"}
            ]
        }

        with self.assertRaisesRegex(UnsupportedMethodError, "security-unsupported"):
            select_methods(manifest, "smolvlm-256m-instruct")

    def test_builtin_status_is_restricted_to_the_locked_allowlist(self) -> None:
        manifest = {
            "adapters": BUILT_INS + [
                {"id": "unexpected-native-runtime", "status": "built-in"}
            ]
        }

        with self.assertRaisesRegex(PreflightError, "allowlist"):
            select_methods(manifest, "unexpected-native-runtime")


class CanonicalSealTests(unittest.TestCase):
    @staticmethod
    def _canonical_label(
        identifier: str,
        target_type: str,
        mode: str,
    ) -> dict:
        return {
            "case": identifier,
            "targetType": target_type,
            "requiredFacts": [
                {"id": "required.surface", "text": "A computer surface is visible"},
                {"id": "required.content", "text": "Content is present"},
                {"id": "required.state", "text": "The surface is active"},
            ],
            "criticalText": ["Exact text"],
            "forbiddenInferences": [
                {
                    "id": "forbidden.intent",
                    "text": "User intent is not established",
                    "severity": "critical",
                },
                {
                    "id": "forbidden.outcome",
                    "text": "The outcome is not established",
                    "severity": "major",
                },
            ],
            "meaningfulChange": None if target_type == "single-frame" else [
                {"id": "change.state", "text": "The visible state changes"}
            ],
            "ambiguity": "judgeable",
            "abstentionAllowed": False,
            "locked": True,
            "annotation": {
                "producer": "frontier-vlm",
                "mode": mode,
                "annotator": "frontier-reference-03",
                "rubricVersion": (
                    "screen-understanding-canonical-v2"
                    if target_type == "single-frame"
                    else "screen-understanding-temporal-v4"
                ),
                "blindedToCandidateOutputs": True,
                "candidateOutputsAvailable": False,
            },
        }

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.corpus_root = root / "corpus"
        self.annotation_root = root / "annotations"
        canonical_root = self.annotation_root / "canonical"
        self.corpus_root.mkdir(mode=0o700)
        canonical_root.mkdir(parents=True, mode=0o700)
        os.chmod(self.annotation_root, 0o700)
        (self.corpus_root / ".metadata_never_index").touch()
        (self.annotation_root / ".metadata_never_index").touch()

        single_ids = [f"{index:024x}" for index in range(200)]
        pair_ids = [f"{index + 10_000:024x}" for index in range(100)]
        case_ids = single_ids + [
            f"{index + 20_000:024x}" for index in range(200)
        ]
        temporal_pairs = []
        for index, pair_id in enumerate(pair_ids):
            temporal_pairs.append({
                "id": pair_id,
                "beforeCaseID": case_ids[200 + index * 2],
                "afterCaseID": case_ids[200 + index * 2 + 1],
                "deltaMs": 1_000,
                "strata": ["fixture"],
            })

        manifest = {
            "protocolID": "screen-understanding-v1",
            "revision": "fixture",
            "snapshotSHA256": "a" * 64,
            "splitSHA256": "b" * 64,
            "singleFrameCaseIDs": single_ids,
            "temporalPairs": temporal_pairs,
            "cases": [{"id": identifier} for identifier in case_ids],
            "splits": {
                "tuneSingleFrames": single_ids[:100],
                "validationSingleFrames": single_ids[100:140],
                "testSingleFrames": single_ids[140:],
                "tuneTemporalPairs": pair_ids[:50],
                "validationTemporalPairs": pair_ids[50:70],
                "testTemporalPairs": pair_ids[70:],
            },
        }
        self.manifest_path = self.corpus_root / "manifest.json"
        self._write_private_json(self.manifest_path, manifest)

        modes = (
            "pass1-base",
            "selected-pass1",
            "selected-pass2",
            "frontier-correction",
        )
        targets = [
            *(zip(single_ids, ["single-frame"] * len(single_ids))),
            *(zip(pair_ids, ["temporal-pair"] * len(pair_ids))),
        ]
        labels = [
            self._canonical_label(identifier, target_type, modes[index % len(modes)])
            for index, (identifier, target_type) in enumerate(targets)
        ]
        self.labels_path = canonical_root / "labels.json"
        self._write_private_json(self.labels_path, {
            "schema": "screen-understanding-canonical-labels-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "candidateOutputsAvailableDuringAnnotation": False,
            "labels": labels,
        })
        self.reliability_path = canonical_root / "reliability.json"
        self._write_private_json(self.reliability_path, {
            "schema": "screen-understanding-canonical-reliability-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "duplicateCount": 45,
            "rawJoint": {
                "minimum": 0.90,
                "overall": 0.93,
                "singleFrame": 0.94,
                "temporalPair": 0.91,
            },
            "finalReferenceAudit": {
                "auditor": "fresh-final-auditor",
                "caseCount": 45,
                "slotCount": 255,
                "materialFalseCount": 0,
                "ambiguityErrorCount": 0,
                "criticalErrorCount": 0,
                "requiredCriticalErrorCount": 0,
                "qualified": True,
            },
            "qualified": True,
        })
        self.source_annotation_root = root / "source-annotations"
        self.correctness_audit_root = root / "correctness-audit"
        self.aggregate_root = root / "aggregate"
        for evidence_root in (
            self.source_annotation_root,
            self.correctness_audit_root,
            self.aggregate_root,
        ):
            evidence_root.mkdir(mode=0o700)
            (evidence_root / ".metadata_never_index").touch()
            self._write_private_json(
                evidence_root / "evidence.json", {"fixture": True}
            )
        self.final_audit_root = self.annotation_root
        self._write_private_json(
            self.final_audit_root / "audit-manifest.json", {"fixture": True}
        )
        self.final_judgments = root / "final-judgments.json"
        self._write_private_json(
            self.final_judgments, {"auditor": "fresh-final-auditor"}
        )
        self.commit_path = canonical_root / "commit.json"
        self._write_private_json(
            self.commit_path,
            build_canonical_commit(
                labels_path=self.labels_path,
                reliability_path=self.reliability_path,
                finalizer_path=(
                    BENCHMARK_ROOT / "annotation" /
                    "combine_canonical_v4.py"
                ),
                source_annotation_root=self.source_annotation_root,
                correctness_audit_root=self.correctness_audit_root,
                aggregate_root=self.aggregate_root,
                final_audit_root=self.final_audit_root,
                final_judgments_path=self.final_judgments,
                protocol="screen-understanding-correctness-audit-v3",
                rubric_version="screen-understanding-canonical-v2",
                label_count=300,
                duplicate_count=45,
                final_audit_case_count=45,
                final_audit_slot_count=255,
            ),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_private_json(self, path: Path, value: object) -> None:
        path.write_text(json.dumps(value), encoding="utf-8")
        os.chmod(path, 0o600)

    def _validate(self) -> dict:
        return validate_seal(
            self.corpus_root,
            self.annotation_root,
            source_annotation_root=self.source_annotation_root,
            correctness_audit_root=self.correctness_audit_root,
            aggregate_root=self.aggregate_root,
            final_audit_root=self.final_audit_root,
            final_judgments=self.final_judgments,
        )

    def test_valid_v3_seal_matches_all_manifest_cases(self) -> None:
        summary = self._validate()

        self.assertEqual(summary["labelCount"], 300)
        self.assertEqual(summary["singleFrameCount"], 200)
        self.assertEqual(summary["temporalPairCount"], 100)
        self.assertEqual(
            summary["rubricVersion"], "screen-understanding-canonical-v2"
        )
        for key in (
            "datasetManifestSHA256", "canonicalLabelsSHA256",
            "canonicalReliabilitySHA256", "canonicalCommitSHA256",
        ):
            self.assertRegex(summary[key], r"^[0-9a-f]{64}$")

    def test_shaped_seal_without_commit_is_rejected(self) -> None:
        self.commit_path.unlink()
        with self.assertRaisesRegex(PreflightError, "commit"):
            self._validate()

    def test_explicit_evidence_is_required(self) -> None:
        with self.assertRaisesRegex(PreflightError, "explicit provenance evidence"):
            validate_seal(self.corpus_root, self.annotation_root)

    def test_semantically_valid_evidence_tamper_is_rejected(self) -> None:
        self._write_private_json(
            self.source_annotation_root / "evidence.json",
            {"fixture": False},
        )

        with self.assertRaisesRegex(PreflightError, "provenance evidence"):
            self._validate()

    def test_missing_evidence_exclusion_is_rejected_before_acceptance(self) -> None:
        (self.aggregate_root / ".metadata_never_index").unlink()

        with self.assertRaisesRegex(PreflightError, "Spotlight"):
            self._validate()

    def test_tampered_label_lock_is_rejected(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["locked"] = False
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "locked"):
            self._validate()

    def test_tampered_label_identifier_is_rejected(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["case"] = "f" * 24
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "manifest"):
            self._validate()

    def test_unexpected_envelope_field_is_rejected(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["unexpected"] = True
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "envelope"):
            self._validate()

    def test_missing_label_field_is_rejected(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0].pop("requiredFacts")
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "label fields"):
            self._validate()

    def test_unexpected_annotation_field_is_rejected(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["annotation"]["unexpected"] = True
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "annotation fields"):
            self._validate()

    def test_missing_annotation_field_is_rejected(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["annotation"].pop("mode")
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "annotation fields"):
            self._validate()

    def test_invalid_annotation_mode_is_rejected(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["annotation"]["mode"] = "hand-built"
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "provenance"):
            self._validate()

    def test_non_scalar_annotation_mode_fails_closed(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["annotation"]["mode"] = ["pass1-base"]
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "provenance"):
            self._validate()

    def test_required_fact_slots_are_exact(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["requiredFacts"][0]["id"] = "required.other"
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "required fact slots"):
            self._validate()

    def test_forbidden_fact_requires_severity(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["forbiddenInferences"][0].pop("severity")
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "severity"):
            self._validate()

    def test_non_scalar_fact_severity_fails_closed(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["forbiddenInferences"][0]["severity"] = ["critical"]
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "severity"):
            self._validate()

    def test_label_target_must_match_manifest(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["targetType"] = "temporal-pair"
        labels["labels"][0]["meaningfulChange"] = []
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "target type"):
            self._validate()

    def test_single_frame_rejects_temporal_change(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["meaningfulChange"] = []
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "temporal change"):
            self._validate()

    def test_temporal_change_ids_must_be_unique(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        temporal = labels["labels"][200]
        temporal["meaningfulChange"] = [
            {"id": "change.state", "text": "First change"},
            {"id": "change.state", "text": "Duplicate slot"},
        ]
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "change fact identifiers"):
            self._validate()

    def test_unqualified_reliability_is_rejected(self) -> None:
        reliability = json.loads(self.reliability_path.read_text(encoding="utf-8"))
        reliability["qualified"] = False
        self._write_private_json(self.reliability_path, reliability)

        with self.assertRaisesRegex(PreflightError, "qualified"):
            self._validate()

    def test_v2_seal_is_rejected_after_correctness_protocol_upgrade(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels.pop("protocol")
        labels["schema"] = "screen-understanding-canonical-labels-v2"
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "schema"):
            self._validate()

    def test_final_reference_error_is_rejected(self) -> None:
        reliability = json.loads(self.reliability_path.read_text(encoding="utf-8"))
        reliability["finalReferenceAudit"]["criticalErrorCount"] = 1
        reliability["finalReferenceAudit"]["qualified"] = False
        self._write_private_json(self.reliability_path, reliability)

        with self.assertRaisesRegex(PreflightError, "final reference"):
            self._validate()

    def test_world_readable_seal_is_rejected(self) -> None:
        os.chmod(self.labels_path, 0o604)

        with self.assertRaisesRegex(PreflightError, "owner-only"):
            self._validate()

    def test_dataset_root_requires_exclusions_before_labels_are_read(self) -> None:
        (self.corpus_root / ".metadata_never_index").unlink()
        self.labels_path.write_text("not-json", encoding="utf-8")

        with self.assertRaisesRegex(PreflightError, "Spotlight"):
            self._validate()

    def test_annotation_root_requires_exclusions(self) -> None:
        (self.annotation_root / ".metadata_never_index").unlink()

        with self.assertRaisesRegex(PreflightError, "Spotlight"):
            self._validate()

    def test_private_path_field_is_rejected(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["sourcePath"] = "/private/example"
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "path"):
            self._validate()


class CanonicalLabelSchemaTests(unittest.TestCase):
    def test_schema_locks_v3_envelope_label_and_annotation_fields(self) -> None:
        schema_path = Path(__file__).parents[1] / "schemas" / "labels.schema.json"
        schema = json.loads(schema_path.read_text(encoding="utf-8"))

        envelope_fields = {
            "schema",
            "protocol",
            "rubricVersion",
            "candidateOutputsAvailableDuringAnnotation",
            "labels",
        }
        self.assertEqual(set(schema["required"]), envelope_fields)
        self.assertEqual(set(schema["properties"]), envelope_fields)
        self.assertFalse(schema["additionalProperties"])
        self.assertEqual(
            schema["properties"]["schema"]["const"],
            "screen-understanding-canonical-labels-v3",
        )
        self.assertEqual(
            schema["properties"]["protocol"]["const"],
            "screen-understanding-correctness-audit-v3",
        )
        self.assertEqual(
            schema["properties"]["rubricVersion"]["const"],
            "screen-understanding-canonical-v2",
        )
        self.assertEqual(schema["properties"]["labels"]["minItems"], 300)
        self.assertEqual(schema["properties"]["labels"]["maxItems"], 300)

        label = schema["$defs"]["label"]
        label_fields = {
            "case",
            "targetType",
            "requiredFacts",
            "criticalText",
            "forbiddenInferences",
            "meaningfulChange",
            "ambiguity",
            "abstentionAllowed",
            "locked",
            "annotation",
        }
        self.assertEqual(set(label["required"]), label_fields)
        self.assertEqual(set(label["properties"]), label_fields)
        self.assertFalse(label["additionalProperties"])

        annotation = schema["$defs"]["annotation"]
        annotation_fields = {
            "producer",
            "mode",
            "annotator",
            "rubricVersion",
            "blindedToCandidateOutputs",
            "candidateOutputsAvailable",
        }
        self.assertEqual(set(annotation["required"]), annotation_fields)
        self.assertEqual(set(annotation["properties"]), annotation_fields)
        self.assertFalse(annotation["additionalProperties"])
        self.assertEqual(set(annotation["properties"]["mode"]["enum"]), {
            "pass1-base",
            "selected-pass1",
            "selected-pass2",
            "selected-merge",
            "frontier-correction",
        })


if __name__ == "__main__":
    unittest.main()
