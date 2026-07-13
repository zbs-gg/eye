"""Owner-only I/O and atomic publication for private benchmark roots."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import uuid
from pathlib import Path

from .private_root import (
    PrivateRootError,
    prepare_private_root,
    validate_private_root,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
MAX_PRIVATE_JSON_BYTES = 16 * 1024 * 1024
MAX_PRIVATE_FILE_BYTES = 64 * 1024 * 1024


def validate_private_input(path: Path) -> Path:
    """Validate an existing input root without chmod, markers, or other writes."""

    canonical = validate_private_root(
        path,
        REPOSITORY_ROOT,
        must_exist=False,
        require_exclusions=False,
    )
    if not canonical.is_dir() or canonical.is_symlink():
        raise PrivateRootError("private input root is not a regular directory")
    return canonical


def validate_private_input_file(path: Path) -> Path:
    """Validate a regular input file and its storage without changing either."""

    original = path.expanduser().absolute()
    parent = validate_private_input(original.parent)
    if original.is_symlink() or not original.is_file():
        raise PrivateRootError("private input must be a regular file")
    canonical = original.resolve(strict=True)
    if canonical.parent != parent:
        raise PrivateRootError("private input file escapes its validated directory")
    return canonical


def validate_private_output(path: Path) -> Path:
    """Validate a not-yet-created private output path without writing to it."""

    output = validate_private_root(
        path,
        REPOSITORY_ROOT,
        must_exist=False,
        require_exclusions=False,
    )
    if output.exists():
        raise PrivateRootError("private output root already exists")
    return output


def read_private_bytes(
    path: Path,
    subject: str,
    *,
    max_bytes: int = MAX_PRIVATE_JSON_BYTES,
) -> bytes:
    """Read one owner-only regular file without following links or exceeding a bound."""

    source = validate_private_input_file(path)
    flags = os.O_RDONLY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        descriptor = os.open(source, flags)
    except OSError as error:
        raise PrivateRootError(f"{subject} is unavailable") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) \
                or metadata.st_uid != os.geteuid() \
                or stat.S_IMODE(metadata.st_mode) & 0o077:
            raise PrivateRootError(
                f"{subject} must be an owner-only regular file"
            )
        chunks = []
        remaining = max_bytes + 1
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > max_bytes:
            raise PrivateRootError(f"{subject} exceeds the size limit")
        final_metadata = os.fstat(descriptor)
        stable_fields = (
            "st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns",
        )
        if any(
            getattr(metadata, field) != getattr(final_metadata, field)
            for field in stable_fields
        ):
            raise PrivateRootError(f"{subject} changed while it was read")
        return data
    except PrivateRootError:
        raise
    except OSError as error:
        raise PrivateRootError(f"{subject} is unavailable") from error
    finally:
        os.close(descriptor)


def load_private_json(path: Path, subject: str) -> tuple[dict, str]:
    """Load a bounded owner-only JSON object and return its exact source text."""

    data = read_private_bytes(path, subject)
    try:
        text = data.decode("utf-8")
        value = json.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PrivateRootError(f"{subject} is not valid JSON") from error
    if not isinstance(value, dict):
        raise PrivateRootError(f"{subject} must be an object")
    return value, text


def atomic_private_bytes(path: Path, data: bytes) -> None:
    """Atomically write exact owner-only bytes without following links."""

    if not isinstance(data, bytes):
        raise TypeError("private payload must be bytes")
    temporary = path.with_name(f".{path.name}.tmp-{uuid.uuid4().hex}")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        path.chmod(0o600)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def snapshot_private_file(
    source: Path,
    destination: Path,
    subject: str,
    *,
    max_bytes: int = MAX_PRIVATE_FILE_BYTES,
) -> bytes:
    """Read one bounded source once and atomically preserve those exact bytes."""

    if destination.exists() or destination.is_symlink():
        raise PrivateRootError(f"{subject} snapshot already exists")
    data = read_private_bytes(source, subject, max_bytes=max_bytes)
    atomic_private_bytes(destination, data)
    return data


def prepare_private_temporary(parent: Path, label: str) -> Path:
    """Create an owner-only temporary root next to a validated private output."""

    if not label or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789-" for character in label):
        raise ValueError("private temporary label is invalid")
    target = parent / f".{label}-{uuid.uuid4().hex}"
    return prepare_private_root(
        target,
        REPOSITORY_ROOT,
        apply_backup_exclusion=False,
    )


def _snapshot_tree_pass(
    source: Path,
    destination: Path | None,
    subject: str,
    *,
    max_file_bytes: int,
) -> dict[str, tuple[str, int]]:
    """Read one complete bounded tree pass, optionally preserving exact bytes."""

    def raise_walk_error(error: OSError) -> None:
        raise PrivateRootError(f"{subject} could not be snapshotted") from error

    entries: dict[str, tuple[str, int]] = {}
    for current_text, directory_names, file_names in os.walk(
        source,
        topdown=True,
        onerror=raise_walk_error,
        followlinks=False,
    ):
        current = Path(current_text)
        relative_parent = current.relative_to(source)
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            path = current / name
            if path.is_symlink() or not path.is_dir():
                raise PrivateRootError(f"{subject} contains an unsafe directory")
            metadata = path.stat()
            if metadata.st_uid != os.geteuid() \
                    or stat.S_IMODE(metadata.st_mode) & 0o077:
                raise PrivateRootError(f"{subject} directories must be owner-only")
            relative = (relative_parent / name).as_posix()
            entries[relative] = ("directory", 0)
            if destination is not None:
                make_private_directory(destination / relative)
        for name in file_names:
            path = current / name
            relative = (relative_parent / name).as_posix()
            data = read_private_bytes(
                path,
                f"{subject} file {relative}",
                max_bytes=max_file_bytes,
            )
            entries[relative] = (hashlib.sha256(data).hexdigest(), len(data))
            if destination is not None:
                atomic_private_bytes(destination / relative, data)
    return entries


def snapshot_private_tree(
    source: Path,
    destination: Path,
    subject: str,
    *,
    max_file_bytes: int = MAX_PRIVATE_FILE_BYTES,
) -> Path:
    """Create a stable bounded tree snapshot or fail if two passes disagree."""

    canonical = validate_private_input(source)
    if destination.exists() or destination.is_symlink():
        raise PrivateRootError(f"{subject} snapshot already exists")
    make_private_directory(destination)
    try:
        copied = _snapshot_tree_pass(
            canonical,
            destination,
            subject,
            max_file_bytes=max_file_bytes,
        )
        confirmed = _snapshot_tree_pass(
            canonical,
            None,
            subject,
            max_file_bytes=max_file_bytes,
        )
        if copied != confirmed:
            raise PrivateRootError(f"{subject} changed while it was snapshotted")
        return destination
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise


def prepare_private_output(path: Path) -> tuple[Path, Path]:
    """Validate a new output path and create its owner-only sibling staging root."""

    output = validate_private_output(path)
    staging = output.parent / f".{output.name}.staging-{uuid.uuid4().hex}"
    try:
        prepared = prepare_private_root(
            staging,
            REPOSITORY_ROOT,
            apply_backup_exclusion=False,
        )
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return output, prepared


def publish_private_output(staging: Path, output: Path) -> Path:
    """Atomically rename a staging root and strictly revalidate the published root."""

    staging = validate_private_root(staging, REPOSITORY_ROOT, must_exist=True)
    output = validate_private_root(
        output,
        REPOSITORY_ROOT,
        must_exist=False,
        require_exclusions=False,
    )
    if output.exists():
        raise PrivateRootError("private output root already exists")
    staging.rename(output)
    try:
        return validate_private_root(output, REPOSITORY_ROOT, must_exist=True)
    except BaseException:
        if output.exists() and not staging.exists():
            output.rename(staging)
        raise


def make_private_directory(path: Path) -> None:
    """Create an owner-only child directory inside a validated private root."""

    path.mkdir(mode=0o700)
    path.chmod(0o700)


def atomic_private_json(path: Path, value: object) -> None:
    """Write JSON through an owner-only no-follow temporary file and atomic replace."""

    temporary = path.with_name(f".{path.name}.tmp-{uuid.uuid4().hex}")
    descriptor = os.open(
        temporary,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True, ensure_ascii=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        path.chmod(0o600)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def copy_private(source: Path, destination: Path) -> None:
    """Copy a regular input file into a new owner-only no-follow destination."""

    snapshot_private_file(
        source,
        destination,
        "private copy source",
    )
