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
        self.assertIn("--methods IDS", result.stdout)
        self.assertIn("--result-root PATH", result.stdout)

    def test_quality_mode_delegates_to_the_private_builtin_runner(self) -> None:
        source = ENTRYPOINT.read_text(encoding="utf-8")

        self.assertIn(
            "tools/screen-understanding-bench/runner/run_quality.py", source
        )
        self.assertNotIn("runner execution not yet implemented", source)

    def test_fixture_mode_runs_every_python_suite_without_bytecode(self) -> None:
        source = ENTRYPOINT.read_text(encoding="utf-8")

        self.assertIn("export PYTHONDONTWRITEBYTECODE=1", source)
        for suite in ("annotation", "mapping", "runner"):
            self.assertIn(
                "-m unittest discover "
                f"-s tools/screen-understanding-bench/{suite} "
                "-p 'test_*.py'",
                source,
            )


if __name__ == "__main__":
    unittest.main()
