import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


BENCHMARK_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = BENCHMARK_ROOT.parents[1]
if str(BENCHMARK_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCHMARK_ROOT))

from common import private_io
from common.private_root import PrivateRootError


class PrivatePipelineTests(unittest.TestCase):
    def test_annotation_is_an_explicit_importable_package(self) -> None:
        import annotation
        import annotation.aggregate_correctness_audit
        import annotation.finalize_correctness_canonical
        import annotation.prepare_final_reference_audit
        import annotation.validate_final_reference_audit

        self.assertIsNotNone(annotation.__file__)

    @mock.patch("common.private_root._filesystem_type", return_value="apfs")
    def test_output_rejects_cloud_repo_and_symlink_roots(self, _) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            unsafe = [
                base / "Library" / "CloudStorage" / "vendor" / "output",
                REPOSITORY_ROOT / ".private-annotation-output",
            ]
            real = base / "real"
            real.mkdir(mode=0o700)
            linked = base / "linked"
            linked.symlink_to(real, target_is_directory=True)
            unsafe.append(linked / "output")

            for output in unsafe:
                with self.subTest(output=output):
                    with self.assertRaises(PrivateRootError):
                        private_io.prepare_private_output(output)

    @mock.patch("common.private_root._filesystem_type", return_value="apfs")
    def test_input_validation_is_read_only(self, _) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source"
            source.mkdir(mode=0o755)
            source.chmod(0o755)

            validated = private_io.validate_private_input(source)

            self.assertEqual(validated, source.resolve())
            self.assertEqual(stat.S_IMODE(source.stat().st_mode), 0o755)
            self.assertFalse((source / ".metadata_never_index").exists())

    @mock.patch("common.private_root._filesystem_type", return_value="apfs")
    def test_input_file_validation_is_read_only_and_rejects_symlinks(self, _) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "source.json"
            source.write_text("{}", encoding="utf-8")
            source.chmod(0o644)

            validated = private_io.validate_private_input_file(source)

            self.assertEqual(validated, source.resolve())
            self.assertEqual(stat.S_IMODE(source.stat().st_mode), 0o644)
            linked = source.with_name("linked.json")
            linked.symlink_to(source)
            with self.assertRaises(PrivateRootError):
                private_io.validate_private_input_file(linked)

    @mock.patch("common.private_root._filesystem_type", return_value="apfs")
    def test_publish_revalidates_owner_only_root_after_rename(self, _) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output, staging = private_io.prepare_private_output(
                Path(temporary) / "output"
            )
            private_io.atomic_private_json(staging / "result.json", {"ok": True})

            with mock.patch(
                "common.private_io.validate_private_root",
                wraps=private_io.validate_private_root,
            ) as validate:
                published = private_io.publish_private_output(staging, output)

            self.assertEqual(published, output)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
            self.assertEqual(
                stat.S_IMODE((output / ".metadata_never_index").stat().st_mode),
                0o600,
            )
            self.assertEqual(stat.S_IMODE((output / "result.json").stat().st_mode), 0o600)
            self.assertEqual(
                validate.call_args_list[-1],
                mock.call(output, private_io.REPOSITORY_ROOT, must_exist=True),
            )


if __name__ == "__main__":
    unittest.main()
