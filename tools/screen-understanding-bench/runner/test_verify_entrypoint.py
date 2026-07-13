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


if __name__ == "__main__":
    unittest.main()
