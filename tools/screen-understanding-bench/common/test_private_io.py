#!/usr/bin/python3

import json
import os
import tempfile
import unittest
from pathlib import Path

from common.private_io import (
    MAX_PRIVATE_JSON_BYTES,
    PrivateRootError,
    load_private_json,
)


class PrivateIOTests(unittest.TestCase):
    def test_loads_an_owner_only_json_object(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            source = root / "value.json"
            source.write_text(json.dumps({"ok": True}) + "\n")
            os.chmod(source, 0o600)

            value, text = load_private_json(source, "fixture")

            self.assertEqual(value, {"ok": True})
            self.assertEqual(text, '{"ok": true}\n')

    def test_rejects_oversized_json_before_parsing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            source = root / "huge.json"
            with source.open("wb") as handle:
                handle.write(b'{"value":"')
                handle.write(b"x" * MAX_PRIVATE_JSON_BYTES)
                handle.write(b'"}\n')
            os.chmod(source, 0o600)

            with self.assertRaisesRegex(PrivateRootError, "size limit"):
                load_private_json(source, "oversized frontier output")


if __name__ == "__main__":
    unittest.main()
