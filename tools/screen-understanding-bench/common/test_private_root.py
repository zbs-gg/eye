#!/usr/bin/python3

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from private_root import PrivateRootError, prepare_private_root, validate_private_root


class PrivateRootTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.repository = self.base / "repository"
        self.repository.mkdir(mode=0o700)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @mock.patch("private_root._filesystem_type", return_value="apfs")
    def test_prepares_owner_only_spotlight_excluded_root(self, _) -> None:
        target = prepare_private_root(
            self.base / "private",
            self.repository,
            apply_backup_exclusion=False,
        )

        self.assertEqual(os.stat(target).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(target / ".metadata_never_index").st_mode & 0o777, 0o600)
        self.assertEqual(
            validate_private_root(target, self.repository, must_exist=True),
            target,
        )

    @mock.patch("private_root._filesystem_type", return_value="apfs")
    def test_rejects_repository_overlap_in_both_directions(self, _) -> None:
        with self.assertRaisesRegex(PrivateRootError, "disjoint"):
            validate_private_root(
                self.repository / "private",
                self.repository,
                must_exist=False,
                require_exclusions=False,
            )
        with self.assertRaisesRegex(PrivateRootError, "disjoint"):
            validate_private_root(
                self.base,
                self.repository,
                must_exist=True,
                require_exclusions=False,
            )

    @mock.patch("private_root._filesystem_type", return_value="smbfs")
    def test_rejects_network_filesystem(self, _) -> None:
        with self.assertRaisesRegex(PrivateRootError, "network"):
            validate_private_root(
                self.base / "private",
                self.repository,
                must_exist=False,
                require_exclusions=False,
            )

    @mock.patch("private_root._filesystem_type", return_value="apfs")
    def test_rejects_sync_and_symlinked_roots(self, _) -> None:
        sync = self.base / "Library" / "CloudStorage" / "vendor" / "private"
        with self.assertRaisesRegex(PrivateRootError, "sync-backed"):
            validate_private_root(
                sync,
                self.repository,
                must_exist=False,
                require_exclusions=False,
            )

        real = self.base / "real"
        real.mkdir(mode=0o700)
        linked = self.base / "linked"
        linked.symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(PrivateRootError, "symlinked"):
            validate_private_root(
                linked / "private",
                self.repository,
                must_exist=False,
                require_exclusions=False,
            )


if __name__ == "__main__":
    unittest.main()
