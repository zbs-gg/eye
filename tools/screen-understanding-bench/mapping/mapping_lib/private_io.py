"""Owner-only filesystem and bounded JSON operations."""

from __future__ import annotations

import json
import os
import stat
import sys
import uuid
from pathlib import Path
from typing import Any

from .contracts import (
    MAX_JSON_DEPTH,
    MAX_JSON_ITEMS,
    MAX_JSON_STRING_BYTES,
    MAX_PRIVATE_FILE_BYTES,
    MAX_PRIVATE_JSON_BYTES,
    MappingError,
)


BENCHMARK_DIRECTORY = Path(__file__).resolve().parents[2]
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
COMMON_DIRECTORY = BENCHMARK_DIRECTORY / "common"
if str(COMMON_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(COMMON_DIRECTORY))

from private_root import (  # noqa: E402
    PrivateRootError,
    prepare_private_root,
    validate_private_root,
)


def validate_output_root_path(path: Path) -> Path:
    try:
        return validate_private_root(
            path, REPOSITORY_ROOT,
            must_exist=False, require_exclusions=False,
        )
    except PrivateRootError as error:
        raise MappingError(str(error)) from error


def prepare_output_root(path: Path) -> Path:
    try:
        return prepare_private_root(
            path, REPOSITORY_ROOT, apply_backup_exclusion=False
        )
    except PrivateRootError as error:
        raise MappingError(str(error)) from error


def validate_existing_output_root(path: Path) -> Path:
    try:
        return validate_private_root(
            path, REPOSITORY_ROOT, must_exist=True
        )
    except PrivateRootError as error:
        raise MappingError(str(error)) from error


def assert_owner_only_directory(path: Path, subject: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise MappingError(f"{subject} is unavailable") from error
    if path.is_symlink() or not stat.S_ISDIR(metadata.st_mode):
        raise MappingError(f"{subject} is unavailable")
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise MappingError(f"{subject} must use owner-only permissions")


def read_private_bytes(
    path: Path,
    subject: str,
    *,
    max_bytes: int = MAX_PRIVATE_FILE_BYTES,
) -> bytes:
    flags = os.O_RDONLY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise MappingError(f"{subject} is unavailable") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) \
                or metadata.st_uid != os.geteuid() \
                or stat.S_IMODE(metadata.st_mode) & 0o077:
            raise MappingError(
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
            raise MappingError(f"{subject} exceeds the size limit")
        return data
    except MappingError:
        raise
    except OSError as error:
        raise MappingError(f"{subject} is unavailable") from error
    finally:
        os.close(descriptor)


def preflight_json_text(data: bytes, subject: str) -> str:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise MappingError(f"{subject} is not valid JSON") from error
    depth = 0
    items = 0
    string_bytes = 0
    in_string = False
    escaped = False
    for byte in data:
        if in_string:
            if escaped:
                escaped = False
                string_bytes += 1
            elif byte == 0x5C:
                escaped = True
                string_bytes += 1
            elif byte == 0x22:
                in_string = False
            else:
                string_bytes += 1
            if string_bytes > MAX_JSON_STRING_BYTES:
                raise MappingError(f"{subject} exceeds the string limit")
            continue
        if byte == 0x22:
            in_string = True
            string_bytes = 0
        elif byte in (0x5B, 0x7B):
            depth += 1
            items += 1
            if depth > MAX_JSON_DEPTH:
                raise MappingError(f"{subject} exceeds the depth limit")
        elif byte in (0x5D, 0x7D):
            depth -= 1
        elif byte in (0x2C, 0x3A):
            items += 1
        if items > MAX_JSON_ITEMS:
            raise MappingError(f"{subject} exceeds the item limit")
    return text


def load_private_json(path: Path, subject: str) -> tuple[dict[str, Any], bytes]:
    data = read_private_bytes(
        path, subject, max_bytes=MAX_PRIVATE_JSON_BYTES
    )
    text = preflight_json_text(data, subject)
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise MappingError(f"{subject} is not valid JSON") from error
    if not isinstance(value, dict):
        raise MappingError(f"{subject} root must be an object")
    return value, data


def json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        .encode("utf-8") + b"\n"
    )


def atomic_private_json(path: Path, value: Any) -> bytes:
    data = json_bytes(value)
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
        return data
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
