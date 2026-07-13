#!/usr/bin/python3

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import common.private_io as private_io
from common.private_io import (
    MAX_PRIVATE_JSON_BYTES,
    PrivateRootError,
    load_private_json,
    snapshot_private_tree,
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

    def test_tree_snapshot_fails_closed_when_passes_observe_different_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            source = root / "source"
            source.mkdir(mode=0o700)
            value = source / "value.json"
            value.write_bytes(b'{"version":"A"}\n')
            os.chmod(value, 0o600)
            destination = root / "snapshot"
            real_pass = private_io._snapshot_tree_pass

            def mutate_between_passes(*args, **kwargs):
                result = real_pass(*args, **kwargs)
                if args[1] is not None:
                    value.write_bytes(b'{"version":"B"}\n')
                    os.chmod(value, 0o600)
                return result

            with patch.object(
                private_io,
                "_snapshot_tree_pass",
                side_effect=mutate_between_passes,
            ):
                with self.assertRaisesRegex(PrivateRootError, "changed"):
                    snapshot_private_tree(source, destination, "mutable fixture")

            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
