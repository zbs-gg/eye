#!/usr/bin/python3

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).parent))

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
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.corpus_root = root / "corpus"
        self.annotation_root = root / "annotations"
        canonical_root = self.annotation_root / "canonical"
        self.corpus_root.mkdir(mode=0o700)
        canonical_root.mkdir(parents=True, mode=0o700)
        os.chmod(self.annotation_root, 0o700)

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

        labels = []
        for identifier in single_ids + pair_ids:
            labels.append({
                "case": identifier,
                "locked": True,
                "annotation": {
                    "rubricVersion": "screen-understanding-canonical-v2",
                    "blindedToCandidateOutputs": True,
                    "candidateOutputsAvailable": False,
                },
            })
        self.labels_path = canonical_root / "labels.json"
        self._write_private_json(self.labels_path, {
            "schema": "screen-understanding-canonical-labels-v2",
            "rubricVersion": "screen-understanding-canonical-v2",
            "candidateOutputsAvailableDuringAnnotation": False,
            "labels": labels,
        })
        self.reliability_path = canonical_root / "reliability.json"
        self._write_private_json(self.reliability_path, {
            "schema": "screen-understanding-canonical-reliability-v2",
            "duplicateCount": 45,
            "factAgreement": 0.93,
            "decisionAgreement": 0.91,
            "minimumFactAgreement": 0.90,
            "minimumDecisionAgreement": 0.80,
            "qualified": True,
        })

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_private_json(self, path: Path, value: object) -> None:
        path.write_text(json.dumps(value), encoding="utf-8")
        os.chmod(path, 0o600)

    def test_valid_v2_seal_matches_all_manifest_cases(self) -> None:
        summary = validate_seal(self.corpus_root, self.annotation_root)

        self.assertEqual(summary, {
            "labelCount": 300,
            "singleFrameCount": 200,
            "temporalPairCount": 100,
            "rubricVersion": "screen-understanding-canonical-v2",
        })

    def test_tampered_label_lock_is_rejected(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["locked"] = False
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "locked"):
            validate_seal(self.corpus_root, self.annotation_root)

    def test_tampered_label_identifier_is_rejected(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["case"] = "f" * 24
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "manifest"):
            validate_seal(self.corpus_root, self.annotation_root)

    def test_unqualified_reliability_is_rejected(self) -> None:
        reliability = json.loads(self.reliability_path.read_text(encoding="utf-8"))
        reliability["qualified"] = False
        self._write_private_json(self.reliability_path, reliability)

        with self.assertRaisesRegex(PreflightError, "qualified"):
            validate_seal(self.corpus_root, self.annotation_root)

    def test_world_readable_seal_is_rejected(self) -> None:
        os.chmod(self.labels_path, 0o604)

        with self.assertRaisesRegex(PreflightError, "owner-only"):
            validate_seal(self.corpus_root, self.annotation_root)

    def test_private_path_field_is_rejected(self) -> None:
        labels = json.loads(self.labels_path.read_text(encoding="utf-8"))
        labels["labels"][0]["sourcePath"] = "/private/example"
        self._write_private_json(self.labels_path, labels)

        with self.assertRaisesRegex(PreflightError, "path"):
            validate_seal(self.corpus_root, self.annotation_root)


if __name__ == "__main__":
    unittest.main()
