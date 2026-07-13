#!/usr/bin/python3

import subprocess
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).parents[3]
ENTRYPOINT = REPOSITORY_ROOT / "scripts" / "verify-screen-understanding.sh"


class VerifyEntrypointTests(unittest.TestCase):
    def test_help_exposes_annotation_and_explicit_method_selection(self) -> None:
        result = subprocess.run(
            [str(ENTRYPOINT), "--help"],
            cwd=REPOSITORY_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--annotation-root PATH", result.stdout)
        self.assertIn("--source-annotation-root PATH", result.stdout)
        self.assertIn("--correctness-audit-root PATH", result.stdout)
        self.assertIn("--aggregate-root PATH", result.stdout)
        self.assertIn("--final-audit-root PATH", result.stdout)
        self.assertIn("--final-judgments PATH", result.stdout)
        self.assertIn("--methods IDS", result.stdout)
        self.assertIn("--result-root PATH", result.stdout)

    def test_help_exposes_explicit_dataset_preparation_surface(self) -> None:
        result = subprocess.run(
            [str(ENTRYPOINT), "--help"],
            cwd=REPOSITORY_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        for option in (
            "--prepare-dataset",
            "--source-root PATH",
            "--output-root PATH",
            "--trace-calendar gregorian",
            "--trace-time-zone IANA",
            "--trace-now-ms UNIX_MS",
            "--trace-minimum-elapsed-ms N",
            "--trace-minimum-activity-count N",
        ):
            self.assertIn(option, result.stdout)

    def test_prepare_dataset_requires_explicit_source_root(self) -> None:
        result = subprocess.run(
            [str(ENTRYPOINT), "--prepare-dataset"],
            cwd=REPOSITORY_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("prepare-dataset requires --source-root", result.stderr)

    def test_dataset_cli_is_headless_and_shares_implementation_with_tests(self) -> None:
        project = (REPOSITORY_ROOT / "project.yml").read_text(encoding="utf-8")
        shared_source = (
            "tools/screen-understanding-bench/dataset/"
            "ScreenUnderstandingDatasetSupport.swift"
        )

        self.assertIn("ScreenUnderstandingDatasetCLI:", project)
        self.assertEqual(project.count(shared_source), 2)

        targets = project.split("\ntargets:\n", 1)[1]
        shipping_target = targets.split("  ZBSEye:\n", 1)[1].split(
            "\n  ScreenUnderstandingDatasetCLI:\n", 1
        )[0]
        self.assertNotIn("ScreenUnderstandingDataset", shipping_target)
        cli_target = targets.split("\n  ScreenUnderstandingDatasetCLI:\n", 1)[1].split(
            "\n  # Unhosted by design", 1
        )[0]
        self.assertIn(shared_source, cli_target)
        self.assertIn("ScreenUnderstandingDatasetCommand.swift", cli_target)
        self.assertIn("dataset/main.swift", cli_target)
        self.assertIn("- package: GRDB", cli_target)
        self.assertNotIn("- target: ZBSEye", cli_target)
        test_target = targets.split("\n  ZBSEyeTests:\n", 1)[1]
        self.assertIn(shared_source, test_target)
        self.assertIn("ScreenUnderstandingDatasetCommand.swift", test_target)

    def test_prepare_mode_delegates_to_dataset_cli_after_clean_source_check(self) -> None:
        source = ENTRYPOINT.read_text(encoding="utf-8")

        prepare_mode = source.split('if [ "$MODE" = "prepare" ]; then', 1)[1].split(
            "\nfi", 1
        )[0]
        self.assertIn("require_clean_source", prepare_mode)
        self.assertIn("-scheme ScreenUnderstandingDatasetCLI", prepare_mode)
        self.assertIn('"$DATASET_CLI"', prepare_mode)

    def test_quality_mode_delegates_to_the_private_builtin_runner(self) -> None:
        source = ENTRYPOINT.read_text(encoding="utf-8")

        self.assertIn(
            "tools/screen-understanding-bench/runner/run_quality.py", source
        )
        for option, variable in (
            ("--source-annotation-root", "SOURCE_ANNOTATION_ROOT"),
            ("--correctness-audit-root", "CORRECTNESS_AUDIT_ROOT"),
            ("--aggregate-root", "AGGREGATE_ROOT"),
            ("--final-audit-root", "FINAL_AUDIT_ROOT"),
            ("--final-judgments", "FINAL_JUDGMENTS"),
        ):
            self.assertIn(f'{option} "${variable}"', source)
        self.assertNotIn("runner execution not yet implemented", source)

    def test_fixture_mode_runs_every_python_suite_without_bytecode(self) -> None:
        source = ENTRYPOINT.read_text(encoding="utf-8")

        self.assertIn("export PYTHONDONTWRITEBYTECODE=1", source)
        for suite in (
            "common", "adapters", "annotation", "mapping", "runner", "sandbox",
        ):
            self.assertIn(
                "-m unittest discover "
                f"-s tools/screen-understanding-bench/{suite} "
                "-p 'test_*.py'",
                source,
            )

    def test_fixture_mode_requires_xcode_success_marker(self) -> None:
        source = ENTRYPOINT.read_text(encoding="utf-8")

        self.assertIn("XC_STATUS=$?", source)
        self.assertIn(r'grep -q "\*\* TEST SUCCEEDED \*\*" "$LOG"', source)


if __name__ == "__main__":
    unittest.main()
