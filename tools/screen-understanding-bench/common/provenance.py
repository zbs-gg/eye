"""Deterministic, content-only provenance digests for private benchmark evidence."""

from __future__ import annotations

import hashlib
import os
import stat
from pathlib import Path
from typing import Any


HASH_ALGORITHM = "sha256-length-prefixed-tree-v1"
COMMIT_SCHEMA = "screen-understanding-canonical-commit-v3"
FINAL_AUDIT_EXCLUDED_NAMES = frozenset({
    "canonical",
    ".canonical-seal.lock",
})
FINAL_AUDIT_EXCLUDED_PREFIXES = (".canonical.staging-",)


class ProvenanceError(ValueError):
    """Evidence cannot be hashed without ambiguity or unsafe traversal."""


def _frame(digest: Any, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, byteorder="big"))
    digest.update(value)


def file_evidence(path: Path) -> dict[str, int | str]:
    """Return a content digest and byte count for one regular no-follow file."""

    source = path.expanduser().absolute()
    if source.is_symlink():
        raise ProvenanceError("provenance input cannot be a symlink")
    try:
        descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        raise ProvenanceError("provenance input file is unavailable") from error
    digest = hashlib.sha256()
    byte_count = 0
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise ProvenanceError("provenance input must be a regular file")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
                byte_count += len(chunk)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return {"sha256": digest.hexdigest(), "byteCount": byte_count}


def _is_excluded(name: str, names: frozenset[str], prefixes: tuple[str, ...]) -> bool:
    return name in names or any(name.startswith(prefix) for prefix in prefixes)


def _raise_walk_error(error: OSError) -> None:
    raise ProvenanceError("provenance tree could not be read") from error


def tree_evidence(
    root: Path,
    *,
    excluded_top_level_names: frozenset[str] = frozenset(),
    excluded_top_level_prefixes: tuple[str, ...] = (),
) -> dict[str, int | str]:
    """Hash a tree by sorted relative names, entry kinds, sizes, and file digests."""

    original = root.expanduser().absolute()
    if original.is_symlink() or not original.is_dir():
        raise ProvenanceError("provenance input root is unavailable")
    canonical = original.resolve(strict=True)
    digest = hashlib.sha256()
    file_count = 0
    directory_count = 0
    for current_text, directory_names, file_names in os.walk(
        canonical,
        topdown=True,
        onerror=_raise_walk_error,
        followlinks=False,
    ):
        current = Path(current_text)
        if current == canonical:
            directory_names[:] = [
                name for name in directory_names
                if not _is_excluded(
                    name,
                    excluded_top_level_names,
                    excluded_top_level_prefixes,
                )
            ]
            file_names = [
                name for name in file_names
                if not _is_excluded(
                    name,
                    excluded_top_level_names,
                    excluded_top_level_prefixes,
                )
            ]
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            path = current / name
            if path.is_symlink():
                raise ProvenanceError("provenance tree contains a symlink")
            relative = path.relative_to(canonical).as_posix().encode("utf-8")
            _frame(digest, b"directory")
            _frame(digest, relative)
            directory_count += 1
        for name in file_names:
            path = current / name
            evidence = file_evidence(path)
            relative = path.relative_to(canonical).as_posix().encode("utf-8")
            _frame(digest, b"file")
            _frame(digest, relative)
            _frame(digest, bytes.fromhex(str(evidence["sha256"])))
            _frame(digest, str(evidence["byteCount"]).encode("ascii"))
            file_count += 1
    return {
        "sha256": digest.hexdigest(),
        "fileCount": file_count,
        "directoryCount": directory_count,
    }


def final_audit_evidence(root: Path) -> dict[str, int | str]:
    """Hash final-audit evidence while excluding canonical publication ephemera."""

    return tree_evidence(
        root,
        excluded_top_level_names=FINAL_AUDIT_EXCLUDED_NAMES,
        excluded_top_level_prefixes=FINAL_AUDIT_EXCLUDED_PREFIXES,
    )


def build_canonical_commit(
    *,
    labels_path: Path,
    reliability_path: Path,
    finalizer_path: Path,
    source_annotation_root: Path,
    correctness_audit_root: Path,
    aggregate_root: Path,
    final_audit_root: Path,
    final_judgments_path: Path,
    protocol: str,
    rubric_version: str,
    label_count: int,
    duplicate_count: int,
    final_audit_case_count: int,
    final_audit_slot_count: int,
) -> dict[str, Any]:
    """Build the exact path-free canonical commit envelope."""

    return {
        "schema": COMMIT_SCHEMA,
        "protocol": protocol,
        "rubricVersion": rubric_version,
        "hashAlgorithm": HASH_ALGORITHM,
        "candidateOutputsAvailableDuringAnnotation": False,
        "canonical": {
            "labelsSHA256": file_evidence(labels_path)["sha256"],
            "reliabilitySHA256": file_evidence(reliability_path)["sha256"],
        },
        "producer": {
            "finalizerSHA256": file_evidence(finalizer_path)["sha256"],
        },
        "evidence": {
            "sourceAnnotationRoot": tree_evidence(source_annotation_root),
            "correctnessAuditRoot": tree_evidence(correctness_audit_root),
            "aggregateRoot": tree_evidence(aggregate_root),
            "finalAudit": final_audit_evidence(final_audit_root),
            "finalJudgments": file_evidence(final_judgments_path),
        },
        "counts": {
            "labelCount": label_count,
            "duplicateCount": duplicate_count,
            "finalAuditCaseCount": final_audit_case_count,
            "finalAuditSlotCount": final_audit_slot_count,
        },
    }
