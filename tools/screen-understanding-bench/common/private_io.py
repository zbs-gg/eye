"""Owner-only I/O and atomic publication for private benchmark roots."""

from __future__ import annotations

import json
import os
import shutil
import uuid
from pathlib import Path

from .private_root import (
    PrivateRootError,
    prepare_private_root,
    validate_private_root,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


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

    if not source.is_file() or source.is_symlink():
        raise ValueError("private copy source must be a regular file")
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    try:
        with source.open("rb") as input_handle, os.fdopen(descriptor, "wb") as output_handle:
            shutil.copyfileobj(input_handle, output_handle)
            output_handle.flush()
            os.fsync(output_handle.fileno())
        destination.chmod(0o600)
    except BaseException:
        destination.unlink(missing_ok=True)
        raise
