#!/usr/bin/python3

import contextlib
import hashlib
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path


BENCHMARK_ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(BENCHMARK_ROOT))
sys.path.insert(0, str(Path(__file__).parent))

from common.provenance import build_canonical_commit  # noqa: E402
import run_quality as runner_module  # noqa: E402
from run_quality import RunnerError, _vision_result, run_quality  # noqa: E402
from run_quality import (  # noqa: E402
    calculate_builtin_artifact_identity,
    expected_builtin_artifact,
)


class FakeVisionBackend:
    def classify(self, jobs):
        return {
            case_id: [
                {"identifier": "window", "confidence": 0.75},
                {"identifier": "computer screen", "confidence": 0.95},
            ]
            for case_id, _ in jobs
        }


class BuiltInRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.corpus = self.base / "corpus"
        self.annotations = self.base / "annotations"
        self.source_annotations = self.base / "source-annotations"
        self.correctness_audit = self.base / "correctness-audit"
        self.aggregate = self.base / "aggregate"
        self.final_judgments = self.base / "final-judgments.json"
        self._make_fixture()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_runner_reads_only_locked_test_single_frame_cases(self) -> None:
        result_root = self._result_root("test-only")

        inventory = run_quality(
            self.corpus,
            self.annotations,
            result_root,
            "metadata-ax-ocr",
            **self._evidence_args(),
        )

        self.assertEqual(inventory["split"], "testSingleFrames")
        self.assertEqual(inventory["caseCount"], 60)
        records = self._records(result_root, "metadata-ax-ocr")
        self.assertEqual(len(records), 60)
        self.assertTrue(all(record["mappingPending"] is True for record in records))

    def test_quality_rejects_missing_commit_before_case_access(self) -> None:
        shutil.rmtree(self.corpus / "cases")
        (self.annotations / "canonical" / "commit.json").unlink()

        with self.assertRaisesRegex(ValueError, "commit"):
            run_quality(
                self.corpus,
                self.annotations,
                self._result_root("missing-commit"),
                "metadata-ax-ocr",
                **self._evidence_args(),
            )

    def test_quality_rejects_tampered_final_judgments_before_case_access(self) -> None:
        shutil.rmtree(self.corpus / "cases")
        self._write_private_json(
            self.final_judgments,
            {"auditor": "tampered-final-auditor"},
        )

        with self.assertRaisesRegex(ValueError, "provenance evidence"):
            run_quality(
                self.corpus,
                self.annotations,
                self._result_root("tampered-judgments"),
                "metadata-ax-ocr",
                **self._evidence_args(),
            )

    def test_builtin_artifact_identity_is_method_and_source_bound(self) -> None:
        runner = b"runner-source"
        worker = b"vision-worker"

        metadata = calculate_builtin_artifact_identity(
            "metadata-ax-ocr", runner, worker
        )
        metadata_after_worker_drift = calculate_builtin_artifact_identity(
            "metadata-ax-ocr", runner, worker + b"-changed"
        )
        vision = calculate_builtin_artifact_identity(
            "apple-vision", runner, worker
        )
        vision_after_worker_drift = calculate_builtin_artifact_identity(
            "apple-vision", runner, worker + b"-changed"
        )

        self.assertEqual(metadata, metadata_after_worker_drift)
        self.assertNotEqual(metadata, vision)
        self.assertNotEqual(vision, vision_after_worker_drift)

    def test_checked_in_builtin_pins_match_exact_runner_sources(self) -> None:
        adapter_manifest = json.loads(
            (Path(__file__).parents[1] / "adapters" / "manifest.json")
            .read_text(encoding="utf-8")
        )
        protocol = json.loads(
            (Path(__file__).parents[3] / "docs/evals/screen-understanding-v1.json")
            .read_text(encoding="utf-8")
        )
        adapters = {item["id"]: item for item in adapter_manifest["adapters"]}
        methods = {item["id"]: item for item in protocol["methods"]}
        runner_source = Path(runner_module.__file__).read_bytes()
        worker_source = Path(runner_module.__file__).with_name(
            "apple_vision_batch.swift"
        ).read_bytes()

        for method_id in (
            "metadata-ax-ocr", "apple-vision", "deterministic-hybrid"
        ):
            revision, identity = expected_builtin_artifact(
                method_id, runner_source, worker_source
            )
            self.assertEqual(adapters[method_id]["artifactRevision"], revision)
            self.assertEqual(adapters[method_id]["artifactIdentitySHA256"], identity)
            self.assertEqual(methods[method_id]["artifactRevision"], revision)
            self.assertEqual(methods[method_id]["artifactSHA256"], identity)

    def test_runner_source_drift_fails_before_case_access(self) -> None:
        shutil.rmtree(self.corpus / "cases")
        drifted_source = self.base / "drifted-runner.py"
        drifted_source.write_bytes(
            Path(runner_module.__file__).read_bytes() + b"\n# source drift\n"
        )

        with self.assertRaisesRegex(RunnerError, "artifact identity"):
            run_quality(
                self.corpus,
                self.annotations,
                self._result_root("source-drift"),
                "metadata-ax-ocr",
                **self._evidence_args(),
                runner_source=drifted_source,
            )

    def test_tampered_adapter_pin_fails_before_case_access(self) -> None:
        shutil.rmtree(self.corpus / "cases")
        source_manifest = Path(__file__).parents[1] / "adapters" / "manifest.json"
        manifest = json.loads(source_manifest.read_text(encoding="utf-8"))
        manifest["adapters"][0]["artifactIdentitySHA256"] = "0" * 64
        tampered_manifest = self.base / "tampered-adapters.json"
        tampered_manifest.write_text(
            json.dumps(manifest, sort_keys=True, separators=(",", ":")),
            encoding="utf-8",
        )

        with self.assertRaisesRegex(RunnerError, "artifact identity"):
            run_quality(
                self.corpus,
                self.annotations,
                self._result_root("manifest-drift"),
                "metadata-ax-ocr",
                **self._evidence_args(),
                adapter_manifest=tampered_manifest,
            )

    def test_traversal_and_hash_tampering_fail_closed(self) -> None:
        manifest_path = self.corpus / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        test_id = manifest["splits"]["testSingleFrames"][0]
        case = next(item for item in manifest["cases"] if item["id"] == test_id)
        case["mediaFile"] = "../outside.heic"
        self._write_private_json(manifest_path, manifest)

        with self.assertRaisesRegex(RunnerError, "integrity"):
            run_quality(
                self.corpus,
                self.annotations,
                self._result_root("traversal"),
                "metadata-ax-ocr",
                **self._evidence_args(),
            )

        self._make_fixture(replace=True)
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        test_id = manifest["splits"]["testSingleFrames"][0]
        (self.corpus / "cases" / test_id / "context.json").write_text(
            '{"text":"tampered"}', encoding="utf-8"
        )
        with self.assertRaisesRegex(RunnerError, "integrity"):
            run_quality(
                self.corpus,
                self.annotations,
                self._result_root("tampered"),
                "metadata-ax-ocr",
                **self._evidence_args(),
            )

    def test_outputs_are_deterministic_and_hybrid_is_exact_union(self) -> None:
        first = self._result_root("first")
        second = self._result_root("second")
        methods = "metadata-ax-ocr,apple-vision,deterministic-hybrid"

        run_quality(
            self.corpus, self.annotations, first, methods,
            **self._evidence_args(),
            vision_backend=FakeVisionBackend(),
        )
        run_quality(
            self.corpus, self.annotations, second, methods,
            **self._evidence_args(),
            vision_backend=FakeVisionBackend(),
        )

        for name in (
            "metadata-ax-ocr.jsonl", "apple-vision.jsonl",
            "deterministic-hybrid.jsonl", "run-inventory.json",
        ):
            self.assertEqual((first / name).read_bytes(), (second / name).read_bytes())

        baseline = self._records(first, "metadata-ax-ocr")[0]["result"]
        vision = self._records(first, "apple-vision")[0]["result"]
        hybrid = self._records(first, "deterministic-hybrid")[0]["result"]
        for key in ("summary", "atomicFacts", "visibleText"):
            self.assertEqual(hybrid[key], baseline[key])
        self.assertEqual(hybrid["labels"], vision["labels"])
        self.assertEqual(hybrid["confidence"], vision["confidence"])
        self.assertEqual(
            hybrid["runtimeMetadata"]["labelConfidences"],
            vision["runtimeMetadata"]["labelConfidences"],
        )

    def test_vision_labels_are_thresholded_ranked_and_capped(self) -> None:
        result = _vision_result([
            {"identifier": "zeta", "confidence": 0.50},
            {"identifier": "charlie", "confidence": 0.90},
            {"identifier": "bravo", "confidence": 0.90},
            {"identifier": "delta", "confidence": 0.80},
            {"identifier": "echo", "confidence": 0.70},
            {"identifier": "foxtrot", "confidence": 0.60},
            {"identifier": "noise", "confidence": 0.009},
        ])

        self.assertEqual(
            result["labels"],
            ["bravo", "charlie", "delta", "echo", "foxtrot"],
        )
        self.assertEqual(
            [item["confidence"] for item in result["runtimeMetadata"]["labelConfidences"]],
            [0.90, 0.90, 0.80, 0.70, 0.60],
        )
        self.assertEqual(result["confidence"], 0.90)

    def test_outputs_are_owner_only_and_inventory_hashes_match(self) -> None:
        result_root = self._result_root("permissions")
        inventory = run_quality(
            self.corpus,
            self.annotations,
            result_root,
            "metadata-ax-ocr",
            **self._evidence_args(),
        )

        for name in ("metadata-ax-ocr.jsonl", "run-inventory.json"):
            path = result_root / name
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        expected = hashlib.sha256(
            (result_root / "metadata-ax-ocr.jsonl").read_bytes()
        ).hexdigest()
        self.assertEqual(inventory["outputSHA256"]["metadata-ax-ocr"], expected)
        self.assertEqual(
            inventory["canonicalCommitSHA256"],
            hashlib.sha256(
                (self.annotations / "canonical" / "commit.json").read_bytes()
            ).hexdigest(),
        )
        self.assertEqual(inventory["commitFile"], "run-inventory.json")
        self.assertTrue(inventory["complete"])
        self.assertFalse(inventory["partialOutputsValidWithoutInventory"])

    def test_inventory_is_the_last_commit_and_partial_outputs_are_invalid(self) -> None:
        result_root = self._result_root("partial-commit")
        original_replace = runner_module.os.replace

        def fail_inventory_commit(source, destination):
            destination_path = Path(destination)
            if destination_path.parent.resolve() == result_root.resolve() \
                    and destination_path.name == "run-inventory.json":
                raise OSError("synthetic final commit failure")
            return original_replace(source, destination)

        with mock.patch.object(runner_module.os, "replace", side_effect=fail_inventory_commit):
            with self.assertRaisesRegex(RunnerError, "commit"):
                run_quality(
                    self.corpus,
                    self.annotations,
                    result_root,
                    "metadata-ax-ocr",
                    **self._evidence_args(),
                )

        self.assertTrue((result_root / "metadata-ax-ocr.jsonl").is_file())
        self.assertFalse((result_root / "run-inventory.json").exists())

    def test_stdout_and_errors_do_not_leak_case_content(self) -> None:
        marker = "PRIVATE-SCREEN-CONTENT-MUST-NOT-LEAK"
        manifest = json.loads((self.corpus / "manifest.json").read_text(encoding="utf-8"))
        test_id = manifest["splits"]["testSingleFrames"][0]
        context_path = self.corpus / "cases" / test_id / "context.json"
        context = json.loads(context_path.read_text(encoding="utf-8"))
        context["text"] = marker
        self._write_private_json(context_path, context)
        case = next(item for item in manifest["cases"] if item["id"] == test_id)
        case["contextSHA256"] = hashlib.sha256(context_path.read_bytes()).hexdigest()
        self._write_private_json(self.corpus / "manifest.json", manifest)
        stdout = io.StringIO()
        stderr = io.StringIO()

        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            run_quality(
                self.corpus,
                self.annotations,
                self._result_root("no-leak"),
                "metadata-ax-ocr",
                **self._evidence_args(),
            )

        self.assertNotIn(marker, stdout.getvalue())
        self.assertNotIn(marker, stderr.getvalue())

    def test_baseline_excludes_timestamp_monitor_and_unlisted_context(self) -> None:
        result_root = self._result_root("excluded")
        run_quality(
            self.corpus,
            self.annotations,
            result_root,
            "metadata-ax-ocr",
            **self._evidence_args(),
        )
        encoded = json.dumps(self._records(result_root, "metadata-ax-ocr"))

        self.assertNotIn("timestampMs", encoded)
        self.assertNotIn("monitorID", encoded)
        self.assertNotIn("browserURL", encoded)
        self.assertNotIn("private.example", encoded)
        baseline = self._records(result_root, "metadata-ax-ocr")[0]["result"]
        self.assertFalse(any(
            fact.startswith("textSource=") for fact in baseline["atomicFacts"]
        ))
        self.assertEqual(
            baseline["runtimeMetadata"]["textSources"], ["ax", "ocr"]
        )

    @staticmethod
    def _canonical_label(identifier: str, target_type: str) -> dict:
        return {
            "case": identifier,
            "targetType": target_type,
            "requiredFacts": [
                {"id": "required.surface", "text": "A computer surface is visible"},
                {"id": "required.content", "text": "Content is present"},
                {"id": "required.state", "text": "The surface is active"},
            ],
            "criticalText": [],
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
            "meaningfulChange": None if target_type == "single-frame" else [],
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
        }

    def _make_fixture(self, *, replace: bool = False) -> None:
        if replace:
            for root in (
                self.corpus,
                self.annotations,
                self.source_annotations,
                self.correctness_audit,
                self.aggregate,
            ):
                if root.exists():
                    shutil.rmtree(root)
            self.final_judgments.unlink(missing_ok=True)
        canonical = self.annotations / "canonical"
        self.corpus.mkdir(mode=0o700)
        canonical.mkdir(parents=True, mode=0o700)
        os.chmod(self.annotations, 0o700)
        (self.corpus / ".metadata_never_index").touch()
        (self.annotations / ".metadata_never_index").touch()
        (canonical / ".metadata_never_index").touch()

        singles = [f"{index:024x}" for index in range(200)]
        pairs = [f"{index + 10_000:024x}" for index in range(100)]
        contexts = [f"{index + 20_000:024x}" for index in range(200)]
        temporal = [
            {
                "id": pair_id,
                "beforeCaseID": contexts[index * 2],
                "afterCaseID": contexts[index * 2 + 1],
                "deltaMs": 1_000,
                "strata": ["fixture"],
            }
            for index, pair_id in enumerate(pairs)
        ]
        splits = {
            "tuneSingleFrames": singles[:100],
            "validationSingleFrames": singles[100:140],
            "testSingleFrames": singles[140:],
            "tuneTemporalPairs": pairs[:50],
            "validationTemporalPairs": pairs[50:70],
            "testTemporalPairs": pairs[70:],
        }
        cases = [{"id": identifier} for identifier in singles + contexts]
        for index, identifier in enumerate(splits["testSingleFrames"]):
            case = next(item for item in cases if item["id"] == identifier)
            case_root = self.corpus / "cases" / identifier
            case_root.mkdir(parents=True, mode=0o700)
            context = {
                "appName": "Editor",
                "windowTitle": f"Document {index}",
                "browserURL": "https://private.example/secret",
                "monitorID": "private-display",
                "text": f"Visible fixture text {index}",
                "textSources": ["ocr", "ax"],
                "timestampMs": 1_000 + index,
            }
            context_path = case_root / "context.json"
            self._write_private_json(context_path, context)
            media_path = case_root / "image.heic"
            media_path.write_bytes(b"synthetic-image-" + str(index).encode("ascii"))
            os.chmod(media_path, 0o600)
            case.update({
                "contextSHA256": hashlib.sha256(context_path.read_bytes()).hexdigest(),
                "mediaFile": f"cases/{identifier}/image.heic",
                "mediaSHA256": hashlib.sha256(media_path.read_bytes()).hexdigest(),
                "strata": ["fixture"],
                "baselineOnly": False,
            })
        manifest = {
            "protocolID": "screen-understanding-v1",
            "revision": 1,
            "snapshotSHA256": "a" * 64,
            "splitSHA256": "b" * 64,
            "singleFrameCaseIDs": singles,
            "baselineOnlyCaseIDs": [],
            "temporalPairs": temporal,
            "cases": cases,
            "splits": splits,
        }
        self._write_private_json(self.corpus / "manifest.json", manifest)

        labels = [
            self._canonical_label(identifier, "single-frame")
            for identifier in singles
        ] + [
            self._canonical_label(identifier, "temporal-pair")
            for identifier in pairs
        ]
        self._write_private_json(canonical / "labels.json", {
            "schema": "screen-understanding-canonical-labels-v3",
            "protocol": "screen-understanding-correctness-audit-v3",
            "rubricVersion": "screen-understanding-canonical-v2",
            "candidateOutputsAvailableDuringAnnotation": False,
            "labels": labels,
        })
        self._write_private_json(canonical / "reliability.json", {
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
        })
        for evidence_root in (
            self.source_annotations,
            self.correctness_audit,
            self.aggregate,
        ):
            evidence_root.mkdir(mode=0o700)
            (evidence_root / ".metadata_never_index").touch()
            self._write_private_json(
                evidence_root / "evidence.json", {"fixture": True}
            )
        self._write_private_json(
            self.annotations / "audit-manifest.json", {"fixture": True}
        )
        self._write_private_json(
            self.final_judgments, {"auditor": "fresh-final-auditor"}
        )
        self._write_private_json(
            canonical / "commit.json",
            build_canonical_commit(
                labels_path=canonical / "labels.json",
                reliability_path=canonical / "reliability.json",
                finalizer_path=(
                    BENCHMARK_ROOT / "annotation" /
                    "finalize_correctness_canonical.py"
                ),
                source_annotation_root=self.source_annotations,
                correctness_audit_root=self.correctness_audit,
                aggregate_root=self.aggregate,
                final_audit_root=self.annotations,
                final_judgments_path=self.final_judgments,
                protocol="screen-understanding-correctness-audit-v3",
                rubric_version="screen-understanding-canonical-v2",
                label_count=300,
                duplicate_count=45,
                final_audit_case_count=45,
                final_audit_slot_count=285,
            ),
        )

    def _evidence_args(self) -> dict:
        return {
            "source_annotation_root": self.source_annotations,
            "correctness_audit_root": self.correctness_audit,
            "aggregate_root": self.aggregate,
            "final_audit_root": self.annotations,
            "final_judgments": self.final_judgments,
        }

    def _result_root(self, name: str) -> Path:
        path = self.base / name
        path.mkdir(mode=0o700)
        return path

    def _records(self, root: Path, method: str):
        return [
            json.loads(line)
            for line in (root / f"{method}.jsonl").read_text(encoding="utf-8").splitlines()
        ]

    @staticmethod
    def _write_private_json(path: Path, value: object) -> None:
        path.write_text(
            json.dumps(value, sort_keys=True, separators=(",", ":")),
            encoding="utf-8",
        )
        os.chmod(path, 0o600)


if __name__ == "__main__":
    unittest.main()
