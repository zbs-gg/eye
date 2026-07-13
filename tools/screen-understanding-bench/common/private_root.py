#!/usr/bin/python3
"""Fail-closed validation for private corpus, annotation, and result roots."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path


SYNC_FRAGMENTS = (
    "/Library/Mobile Documents/",
    "/Library/CloudStorage/",
)
NETWORK_FILESYSTEMS = {
    "afpfs",
    "autofs",
    "nfs",
    "smbfs",
    "webdav",
}


class PrivateRootError(ValueError):
    """The selected root cannot safely contain personal benchmark material."""


def _existing_ancestor(path: Path) -> Path:
    candidate = path
    while not candidate.exists():
        parent = candidate.parent
        if parent == candidate:
            raise PrivateRootError("private root has no accessible ancestor")
        candidate = parent
    return candidate


def _reject_symlink_components(path: Path) -> None:
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current /= component
        if not current.exists() and not current.is_symlink():
            break
        if current.is_symlink() and current not in {Path("/var"), Path("/tmp")}:
            raise PrivateRootError("private root contains a symlinked path component")


def _filesystem_type(path: Path) -> str | None:
    mount_tool = Path("/sbin/mount")
    if not mount_tool.exists():
        return None
    result = subprocess.run(
        [str(mount_tool)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise PrivateRootError("private root filesystem could not be identified")
    target = path.resolve(strict=True)
    matches: list[tuple[int, str]] = []
    for line in result.stdout.splitlines():
        before_options, separator, options = line.rpartition(" (")
        if not separator or not options.endswith(")"):
            continue
        _, on_separator, mountpoint = before_options.partition(" on ")
        if not on_separator:
            continue
        mounted = Path(mountpoint.replace("\\040", " "))
        if target == mounted or mounted in target.parents:
            filesystem = options[:-1].split(",", 1)[0].strip().lower()
            matches.append((len(mounted.parts), filesystem))
    if not matches:
        raise PrivateRootError("private root mount could not be identified")
    return max(matches)[1]


def _reject_publicly_writable_ancestors(path: Path) -> None:
    current = path
    while True:
        metadata = current.stat()
        if stat.S_IMODE(metadata.st_mode) & 0o022:
            raise PrivateRootError("private root has a group/world-writable ancestor")
        if metadata.st_uid == os.getuid() and stat.S_IMODE(metadata.st_mode) & 0o077 == 0:
            return
        if current.parent == current:
            raise PrivateRootError("private root has no owner-only ancestor")
        current = current.parent


def validate_private_root(
    path: Path,
    repository_root: Path,
    *,
    must_exist: bool,
    require_exclusions: bool = True,
) -> Path:
    """Return a canonical safe root or reject it before private bytes are opened."""

    original = path.expanduser().absolute()
    _reject_symlink_components(original)
    existing = _existing_ancestor(original)
    canonical = original.resolve(strict=must_exist)
    repository = repository_root.expanduser().resolve(strict=True)

    canonical_text = f"{canonical}/"
    if any(fragment in canonical_text for fragment in SYNC_FRAGMENTS):
        raise PrivateRootError("private root cannot be inside a sync-backed folder")
    if canonical == repository or canonical in repository.parents \
            or repository in canonical.parents:
        raise PrivateRootError("private root and repository must be disjoint")

    filesystem = _filesystem_type(existing)
    if filesystem in NETWORK_FILESYSTEMS or (
        filesystem is not None and filesystem.startswith("fuse")
    ):
        raise PrivateRootError("private root cannot use a network or FUSE filesystem")
    _reject_publicly_writable_ancestors(existing)

    if must_exist:
        if not canonical.is_dir() or canonical.is_symlink():
            raise PrivateRootError("private root is not a regular directory")
        metadata = canonical.stat()
        if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
            raise PrivateRootError("private root must be owner-owned with mode 700")
        if require_exclusions and not (canonical / ".metadata_never_index").is_file():
            raise PrivateRootError("private root is not excluded from Spotlight")
    return canonical


def prepare_private_root(
    path: Path,
    repository_root: Path,
    *,
    apply_backup_exclusion: bool = True,
) -> Path:
    """Create a new owner-only root and install local index/backup exclusions."""

    target = validate_private_root(
        path,
        repository_root,
        must_exist=False,
        require_exclusions=False,
    )
    if target.exists():
        raise PrivateRootError("private output root already exists")
    target.mkdir(mode=0o700)
    target.chmod(0o700)
    marker = target / ".metadata_never_index"
    descriptor = os.open(
        marker,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    os.close(descriptor)

    if apply_backup_exclusion and Path("/usr/bin/tmutil").exists():
        result = subprocess.run(
            ["/usr/bin/tmutil", "addexclusion", "-p", str(target)],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise PrivateRootError("private root could not be excluded from backup")
    return validate_private_root(target, repository_root, must_exist=True)
