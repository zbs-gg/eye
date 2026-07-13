#!/usr/bin/python3
"""Generate private, deterministic built-in outputs for the locked test split."""

import argparse
import hashlib
import hmac
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable, Optional


sys.path.insert(0, str(Path(__file__).parent))

from preflight import (  # noqa: E402
    PreflightError,
    UnsupportedMethodError,
    _load_json,
    select_methods,
    validate_seal,
)


RUN_SCHEMA = "screen-understanding-built-in-run-v1"
RECORD_SCHEMA = "screen-understanding-built-in-output-v1"
LOCKED_SPLIT = "testSingleFrames"
EXPECTED_TEST_CASES = 60
NETWORK_DENY_PROFILE = "(version 1)\n(allow default)\n(deny network*)"
MINIMUM_VISION_CONFIDENCE = 0.01
MAXIMUM_VISION_LABELS = 5
METHOD_FILES = {
    "metadata-ax-ocr": "metadata-ax-ocr.jsonl",
    "apple-vision": "apple-vision.jsonl",
    "deterministic-hybrid": "deterministic-hybrid.jsonl",
}
BUILT_IN_ARTIFACT_METHODS = frozenset(METHOD_FILES)
VISION_DEPENDENT_METHODS = frozenset({
    "apple-vision",
    "deterministic-hybrid",
})
NATIVE_RUNTIME_IDENTITY_KEYS = (
    "macOSVersion",
    "macOSBuild",
    "hardwareModel",
    "architecture",
    "xcodeVersion",
    "swiftCompilerVersion",
    "sdkVersion",
    "visionFrameworkBundleVersion",
)
VISION_FRAMEWORK_INFO = Path(
    "/System/Library/Frameworks/Vision.framework/Resources/Info.plist"
)


class RunnerError(ValueError):
    """The private built-in run must stop without echoing case data."""


def _hash_component(digest: Any, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, byteorder="big"))
    digest.update(value)


def calculate_builtin_artifact_identity(
    method_id: str,
    runner_source: bytes,
    vision_worker_source: bytes,
) -> str:
    """Bind a built-in method to exactly the source bytes it executes."""
    if method_id not in BUILT_IN_ARTIFACT_METHODS:
        raise RunnerError("built-in artifact method is invalid")
    digest = hashlib.sha256()
    _hash_component(digest, method_id.encode("utf-8"))
    _hash_component(digest, runner_source)
    if method_id in VISION_DEPENDENT_METHODS:
        _hash_component(digest, vision_worker_source)
    return digest.hexdigest()


def expected_builtin_artifact(
    method_id: str,
    runner_source: bytes,
    vision_worker_source: bytes,
) -> tuple[str, str]:
    identity = calculate_builtin_artifact_identity(
        method_id, runner_source, vision_worker_source
    )
    return f"runner-{identity[:12]}", identity


def _read_checked_in_source(path: Path) -> bytes:
    try:
        if path.is_symlink() or not path.is_file():
            raise RunnerError("built-in artifact source is unavailable")
        return path.read_bytes()
    except RunnerError:
        raise
    except OSError as error:
        raise RunnerError("built-in artifact source is unavailable") from error


def _validate_builtin_artifact_pins(
    selected: tuple[dict[str, Any], ...],
    protocol_document: dict[str, Any],
    runner_source_path: Path,
    vision_worker_source_path: Path,
) -> tuple[dict[str, dict[str, str]], bytes, bytes]:
    methods = protocol_document.get("methods")
    if not isinstance(methods, list) or any(not isinstance(item, dict) for item in methods):
        raise RunnerError("built-in artifact protocol is invalid")
    protocol_by_id = {item.get("id"): item for item in methods}
    if len(protocol_by_id) != len(methods):
        raise RunnerError("built-in artifact protocol is invalid")
    runner_source = _read_checked_in_source(runner_source_path)
    needs_vision = any(
        entry["id"] in VISION_DEPENDENT_METHODS for entry in selected
    )
    vision_source = (
        _read_checked_in_source(vision_worker_source_path) if needs_vision else b""
    )
    validated: dict[str, dict[str, str]] = {}
    for entry in selected:
        method_id = entry["id"]
        revision, identity = expected_builtin_artifact(
            method_id, runner_source, vision_source
        )
        protocol_method = protocol_by_id.get(method_id)
        if not isinstance(protocol_method, dict) \
                or entry.get("artifactRevision") != revision \
                or entry.get("artifactIdentitySHA256") != identity \
                or protocol_method.get("artifactRevision") != revision \
                or protocol_method.get("artifactSHA256") != identity:
            raise RunnerError("built-in artifact identity verification failed")
        validated[method_id] = {
            "artifactRevision": revision,
            "artifactIdentitySHA256": identity,
        }
    return validated, runner_source, vision_source


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _runtime_command(command: list[str]) -> str:
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
    }
    try:
        result = subprocess.run(
            command,
            env=environment,
            check=False,
            capture_output=True,
            timeout=30,
        )
        value = result.stdout.decode("utf-8").strip()
    except (OSError, subprocess.TimeoutExpired, UnicodeDecodeError) as error:
        raise RunnerError("native runtime identity collection failed") from error
    if result.returncode != 0 or not value:
        raise RunnerError("native runtime identity collection failed")
    return value


def collect_native_runtime_identity() -> dict[str, str]:
    """Collect the exact local native stack separately from source pins."""
    return {
        "macOSVersion": _runtime_command([
            "/usr/bin/sw_vers", "-productVersion",
        ]),
        "macOSBuild": _runtime_command([
            "/usr/bin/sw_vers", "-buildVersion",
        ]),
        "hardwareModel": _runtime_command([
            "/usr/sbin/sysctl", "-n", "hw.model",
        ]),
        "architecture": _runtime_command(["/usr/bin/uname", "-m"]),
        "xcodeVersion": _runtime_command(["/usr/bin/xcodebuild", "-version"]),
        "swiftCompilerVersion": _runtime_command([
            "/usr/bin/xcrun", "swiftc", "--version",
        ]),
        "sdkVersion": _runtime_command([
            "/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version",
        ]),
        "visionFrameworkBundleVersion": _runtime_command([
            "/usr/bin/plutil", "-extract", "CFBundleVersion", "raw", "-o", "-",
            str(VISION_FRAMEWORK_INFO),
        ]),
    }


def _validated_native_runtime_identity(
    collector: Callable[[], dict[str, str]],
) -> dict[str, str]:
    try:
        value = collector()
    except RunnerError:
        raise
    except Exception as error:
        raise RunnerError("native runtime identity collection failed") from error
    if not isinstance(value, dict) \
            or set(value) != set(NATIVE_RUNTIME_IDENTITY_KEYS) \
            or any(
                not isinstance(value[key], str) or not value[key].strip()
                for key in NATIVE_RUNTIME_IDENTITY_KEYS
            ):
        raise RunnerError("native runtime identity is invalid")
    return {key: value[key] for key in NATIVE_RUNTIME_IDENTITY_KEYS}


def _assert_owner_only_directory(path: Path) -> Path:
    try:
        if path.is_symlink() or not path.is_dir():
            raise RunnerError("result root is unavailable")
        mode = stat.S_IMODE(path.stat().st_mode)
    except OSError as error:
        raise RunnerError("result root is unavailable") from error
    if mode & 0o077:
        raise RunnerError("result root must use owner-only permissions")
    return path.resolve()


def _paths_overlap(first: Path, second: Path) -> bool:
    return first == second or first in second.parents or second in first.parents


def _read_private_regular(path: Path) -> bytes:
    flags = os.O_RDONLY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise RunnerError("case integrity verification failed") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise RunnerError("case integrity verification failed")
        if stat.S_IMODE(metadata.st_mode) & 0o077:
            raise RunnerError("case integrity verification failed")
        chunks = []
        while True:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
    except RunnerError:
        raise
    except OSError as error:
        raise RunnerError("case integrity verification failed") from error
    finally:
        os.close(descriptor)


def _verified_case_paths(
    corpus_root: Path,
    case: dict[str, Any],
    expected_id: str,
) -> tuple[Path, str, dict[str, Any]]:
    if case.get("id") != expected_id or case.get("baselineOnly") is not False:
        raise RunnerError("locked test split integrity verification failed")
    case_root = corpus_root / "cases" / expected_id
    try:
        if case_root.is_symlink() or not case_root.is_dir():
            raise RunnerError("case integrity verification failed")
        if case_root.resolve().parent != (corpus_root / "cases").resolve():
            raise RunnerError("case integrity verification failed")
    except OSError as error:
        raise RunnerError("case integrity verification failed") from error

    context_path = case_root / "context.json"
    media_file = case.get("mediaFile")
    if not isinstance(media_file, str):
        raise RunnerError("case integrity verification failed")
    relative = PurePosixPath(media_file)
    if relative.is_absolute() or relative.parts != (
        "cases", expected_id, "image.heic"
    ):
        raise RunnerError("case integrity verification failed")
    media_path = corpus_root.joinpath(*relative.parts)
    try:
        if context_path.resolve().parent != case_root.resolve() \
                or media_path.resolve().parent != case_root.resolve():
            raise RunnerError("case integrity verification failed")
    except (OSError, RuntimeError) as error:
        raise RunnerError("case integrity verification failed") from error

    context_data = _read_private_regular(context_path)
    media_data = _read_private_regular(media_path)
    expected_context_hash = case.get("contextSHA256")
    expected_media_hash = case.get("mediaSHA256")
    if not isinstance(expected_context_hash, str) \
            or not isinstance(expected_media_hash, str) \
            or not hmac.compare_digest(_sha256(context_data), expected_context_hash) \
            or not hmac.compare_digest(_sha256(media_data), expected_media_hash):
        raise RunnerError("case integrity verification failed")
    try:
        context = json.loads(context_data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RunnerError("case context is invalid") from error
    if not isinstance(context, dict):
        raise RunnerError("case context is invalid")
    _validate_context(context)
    return media_path, expected_media_hash, context


def _materialize_verified_media(
    inputs: list[tuple[str, Path, str, dict[str, Any]]],
    scratch: Path,
) -> list[tuple[str, Path]]:
    jobs = []
    for case_id, media_path, expected_hash, _ in inputs:
        media_data = _read_private_regular(media_path)
        if not hmac.compare_digest(_sha256(media_data), expected_hash):
            raise RunnerError("case integrity verification failed")
        copy_path = scratch / f"{case_id}.heic"
        _write_owner_only_atomic(copy_path, media_data)
        try:
            copy_path.chmod(0o400)
        except OSError as error:
            raise RunnerError("case integrity verification failed") from error
        jobs.append((case_id, copy_path))
    return jobs


def _validate_context(context: dict[str, Any]) -> None:
    for key in ("appName", "windowTitle"):
        if context.get(key) is not None and not isinstance(context.get(key), str):
            raise RunnerError("case context is invalid")
    if not isinstance(context.get("text"), str):
        raise RunnerError("case context is invalid")
    sources = context.get("textSources")
    if not isinstance(sources, list) or any(not isinstance(item, str) for item in sources):
        raise RunnerError("case context is invalid")


def _baseline_result(context: dict[str, Any]) -> dict[str, Any]:
    app_name = context.get("appName")
    window_title = context.get("windowTitle")
    text = context["text"]
    sources = sorted(set(context["textSources"]))
    summary_parts = [value for value in (app_name, window_title) if value]
    atomic_facts = []
    if app_name:
        atomic_facts.append(f"appName={app_name}")
    if window_title:
        atomic_facts.append(f"windowTitle={window_title}")
    has_evidence = bool(summary_parts or text or sources)
    return {
        "methodID": "metadata-ax-ocr",
        "capabilities": [
            "summary", "atomic-facts", "visible-text", "confidence",
            "abstention", "errors", "runtime-metadata",
        ],
        "summary": " · ".join(summary_parts) if summary_parts else None,
        "atomicFacts": atomic_facts,
        "visibleText": [text] if text else [],
        "confidence": 1.0 if has_evidence else None,
        "abstention": not has_evidence,
        "errors": [],
        "runtimeMetadata": {
            "networkUsed": False,
            "textSources": sources,
        },
    }


def _normalize_vision(value: Any) -> tuple[list[dict[str, Any]], list[str]]:
    errors: list[str] = []
    labels_value = value
    if isinstance(value, dict):
        labels_value = value.get("labels")
        raw_errors = value.get("errors", [])
        if not isinstance(raw_errors, list) or any(
            error not in {"classification-failed", "image-decode-failed"}
            for error in raw_errors
        ):
            raise RunnerError("native Vision output is invalid")
        errors = list(raw_errors)
    if not isinstance(labels_value, list):
        raise RunnerError("native Vision output is invalid")
    labels: list[dict[str, Any]] = []
    for item in labels_value:
        if not isinstance(item, dict) or not isinstance(item.get("identifier"), str):
            raise RunnerError("native Vision output is invalid")
        confidence = item.get("confidence")
        if isinstance(confidence, bool) or not isinstance(confidence, (int, float)) \
                or not 0.0 <= float(confidence) <= 1.0:
            raise RunnerError("native Vision output is invalid")
        if float(confidence) >= MINIMUM_VISION_CONFIDENCE:
            labels.append({
                "identifier": item["identifier"],
                "confidence": float(confidence),
            })
    labels.sort(key=lambda item: (-item["confidence"], item["identifier"]))
    labels = labels[:MAXIMUM_VISION_LABELS]
    return labels, errors


def _vision_result(value: Any) -> dict[str, Any]:
    labels, errors = _normalize_vision(value)
    confidences = [item["confidence"] for item in labels]
    return {
        "methodID": "apple-vision",
        "capabilities": [
            "labels", "confidence", "abstention", "errors", "runtime-metadata",
        ],
        "labels": [item["identifier"] for item in labels],
        "confidence": max(confidences) if confidences else None,
        "abstention": not labels,
        "errors": errors,
        "runtimeMetadata": {
            "labelConfidences": labels,
            "networkUsed": False,
        },
    }


def _hybrid_result(
    baseline: dict[str, Any], vision: dict[str, Any]
) -> dict[str, Any]:
    return {
        "methodID": "deterministic-hybrid",
        "capabilities": [
            "summary", "atomic-facts", "visible-text", "labels", "confidence",
            "abstention", "errors", "runtime-metadata",
        ],
        "summary": baseline["summary"],
        "atomicFacts": baseline["atomicFacts"],
        "visibleText": baseline["visibleText"],
        "labels": vision["labels"],
        "confidence": vision["confidence"],
        "abstention": baseline["abstention"] and vision["abstention"],
        "errors": vision["errors"],
        "runtimeMetadata": {
            "labelConfidences": vision["runtimeMetadata"]["labelConfidences"],
            "networkUsed": False,
            "textSources": baseline["runtimeMetadata"]["textSources"],
        },
    }


def _record(case_id: str, result: dict[str, Any]) -> dict[str, Any]:
    return {
        "schema": RECORD_SCHEMA,
        "caseID": case_id,
        "mappingPending": True,
        "result": result,
    }


def _json_bytes(value: Any, *, lines: bool = False) -> bytes:
    if lines:
        return b"".join(
            json.dumps(item, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
            .encode("utf-8") + b"\n"
            for item in value
        )
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        .encode("utf-8") + b"\n"
    )


def _write_owner_only_atomic(path: Path, data: bytes) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except OSError as error:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass
        raise RunnerError("private result write failed") from error


def _commit_staged_run(
    staging: Path,
    result_root: Path,
    method_files: list[str],
) -> None:
    """Commit the inventory last; outputs without it are an invalid partial run."""
    inventory_name = "run-inventory.json"
    names = [*method_files, inventory_name]
    destinations = [result_root / name for name in names]
    try:
        for name in method_files:
            os.replace(staging / name, result_root / name)
        os.replace(staging / inventory_name, result_root / inventory_name)
    except OSError as error:
        for destination in reversed(destinations):
            try:
                destination.unlink(missing_ok=True)
            except OSError:
                pass
        raise RunnerError("private result commit failed") from error


def _run_bounded_process_group(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: float,
    subject: str,
) -> subprocess.CompletedProcess[bytes]:
    """Run a local command and reap its whole descendant group on timeout."""

    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=0.5)
        except subprocess.TimeoutExpired:
            pass
        # The direct child may exit on SIGTERM while a descendant ignores it
        # after closing inherited stdio. Always kill the original process
        # group after the grace period, even when communicate() returned.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=0.5)
        except subprocess.TimeoutExpired:
            try:
                process.kill()
            except ProcessLookupError:
                pass
            process.communicate()
        raise RunnerError(f"{subject} timed out")
    return subprocess.CompletedProcess(
        command, process.returncode, stdout=stdout, stderr=stderr
    )


class NativeVisionBackend:
    """Compile and run the native Apple Vision JSONL worker without network access."""

    def __init__(
        self,
        source: Optional[Path] = None,
        source_bytes: Optional[bytes] = None,
    ) -> None:
        if source is not None and source_bytes is not None:
            raise RunnerError("native Vision source configuration is invalid")
        self.source = source or Path(__file__).with_name("apple_vision_batch.swift")
        self.source_bytes = source_bytes

    def classify(self, jobs: Iterable[tuple[str, Path]]) -> dict[str, Any]:
        ordered_jobs = list(jobs)
        with tempfile.TemporaryDirectory(prefix="zbs-eye-vision-") as directory:
            scratch = Path(directory)
            os.chmod(scratch, 0o700)
            source_path = self.source
            if self.source_bytes is not None:
                source_path = scratch / "apple_vision_batch.swift"
                _write_owner_only_atomic(source_path, self.source_bytes)
            job_path = scratch / "jobs.jsonl"
            job_data = _json_bytes((
                {"caseID": case_id, "imagePath": str(image_path)}
                for case_id, image_path in ordered_jobs
            ), lines=True)
            _write_owner_only_atomic(job_path, job_data)
            binary = scratch / "apple-vision-batch"
            environment = {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": str(scratch),
                "TMPDIR": str(scratch),
                "LANG": "C",
                "LC_ALL": "C",
                "HF_HUB_OFFLINE": "1",
                "TRANSFORMERS_OFFLINE": "1",
                "ZBS_EYE_ALLOW_MODEL_DOWNLOADS": "0",
            }
            compile_result = _run_bounded_process_group(
                [
                    "/usr/bin/sandbox-exec", "-p", NETWORK_DENY_PROFILE,
                    "/usr/bin/xcrun", "swiftc", str(source_path),
                    "-framework", "Vision", "-framework", "ImageIO",
                    "-framework", "CoreGraphics", "-o", str(binary),
                ],
                cwd=scratch,
                env=environment,
                timeout=300,
                subject="native Vision compiler",
            )
            if compile_result.returncode != 0:
                raise RunnerError("native Vision compiler failed")
            run_result = _run_bounded_process_group(
                [
                    "/usr/bin/sandbox-exec", "-p", NETWORK_DENY_PROFILE,
                    str(binary), str(job_path),
                ],
                cwd=scratch,
                env=environment,
                timeout=600,
                subject="native Vision execution",
            )
            if run_result.returncode != 0:
                raise RunnerError("native Vision execution failed")
            try:
                raw_records = [
                    json.loads(line)
                    for line in run_result.stdout.decode("utf-8").splitlines()
                    if line
                ]
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise RunnerError("native Vision output is invalid") from error
        expected_ids = [case_id for case_id, _ in ordered_jobs]
        actual_ids = [
            record.get("caseID") if isinstance(record, dict) else None
            for record in raw_records
        ]
        if actual_ids != expected_ids:
            raise RunnerError("native Vision output order is invalid")
        return {
            case_id: {
                "labels": record.get("labels"),
                "errors": record.get("errors"),
            }
            for case_id, record in zip(expected_ids, raw_records)
        }


def run_quality(
    dataset_root: Path,
    annotation_root: Path,
    result_root: Path,
    methods: str,
    *,
    source_annotation_root: Path,
    correctness_audit_root: Path,
    aggregate_root: Path,
    final_audit_root: Path,
    final_judgments: Path,
    vision_backend: Optional[Any] = None,
    adapter_manifest: Optional[Path] = None,
    protocol_manifest: Optional[Path] = None,
    runner_source: Optional[Path] = None,
    vision_worker_source: Optional[Path] = None,
    runtime_identity_collector: Optional[
        Callable[[], dict[str, str]]
    ] = None,
) -> dict[str, Any]:
    dataset_root = Path(dataset_root).resolve()
    annotation_root = Path(annotation_root).resolve()
    source_annotation_root = Path(source_annotation_root).resolve()
    correctness_audit_root = Path(correctness_audit_root).resolve()
    aggregate_root = Path(aggregate_root).resolve()
    final_audit_root = Path(final_audit_root).resolve()
    final_judgments = Path(final_judgments).resolve()
    result_root = _assert_owner_only_directory(Path(result_root))
    if any(_paths_overlap(result_root, private_input) for private_input in (
        dataset_root,
        annotation_root,
        source_annotation_root,
        correctness_audit_root,
        aggregate_root,
        final_audit_root,
        final_judgments,
    )):
        raise RunnerError("result root must be separate from private inputs")
    manifest_path = adapter_manifest or (
        Path(__file__).parents[1] / "adapters" / "manifest.json"
    )
    protocol_path = protocol_manifest or (
        Path(__file__).parents[3] / "docs" / "evals" /
        "screen-understanding-v1.json"
    )
    runner_source_path = runner_source or Path(__file__)
    vision_worker_source_path = vision_worker_source or Path(__file__).with_name(
        "apple_vision_batch.swift"
    )
    adapter_document, adapter_raw = _load_json(
        manifest_path, "adapter manifest", require_owner_only=False
    )
    selected = select_methods(adapter_document, methods)
    protocol_document, protocol_raw = _load_json(
        protocol_path, "screen-understanding protocol", require_owner_only=False
    )
    artifact_pins, runner_source_bytes, vision_worker_source_bytes = (
        _validate_builtin_artifact_pins(
            selected,
            protocol_document,
            Path(runner_source_path),
            Path(vision_worker_source_path),
        )
    )
    native_runtime_identity = _validated_native_runtime_identity(
        runtime_identity_collector or collect_native_runtime_identity
    )
    seal = validate_seal(
        dataset_root,
        annotation_root,
        source_annotation_root=source_annotation_root,
        correctness_audit_root=correctness_audit_root,
        aggregate_root=aggregate_root,
        final_audit_root=final_audit_root,
        final_judgments=final_judgments,
    )

    try:
        manifest_data = _read_private_regular(dataset_root / "manifest.json")
        manifest = json.loads(manifest_data)
    except RunnerError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RunnerError("corpus manifest is invalid") from error
    if not isinstance(manifest, dict):
        raise RunnerError("corpus manifest is invalid")
    if _sha256(manifest_data) != seal["datasetManifestSHA256"]:
        raise RunnerError("corpus manifest changed after seal validation")
    split_ids = manifest.get("splits", {}).get(LOCKED_SPLIT)
    if not isinstance(split_ids, list) or len(split_ids) != EXPECTED_TEST_CASES \
            or len(set(split_ids)) != EXPECTED_TEST_CASES:
        raise RunnerError("locked test split integrity verification failed")
    cases = manifest.get("cases")
    if not isinstance(cases, list) or any(not isinstance(case, dict) for case in cases):
        raise RunnerError("corpus case inventory is invalid")
    by_id = {case.get("id"): case for case in cases}
    if len(by_id) != len(cases):
        raise RunnerError("corpus case inventory is invalid")

    inputs: list[tuple[str, Path, str, dict[str, Any]]] = []
    for case_id in split_ids:
        case = by_id.get(case_id)
        if not isinstance(case, dict):
            raise RunnerError("locked test split integrity verification failed")
        media_path, expected_media_hash, context = _verified_case_paths(
            dataset_root, case, case_id
        )
        inputs.append((case_id, media_path, expected_media_hash, context))

    selected_ids = [entry["id"] for entry in selected]
    needs_vision = any(
        method in {"apple-vision", "deterministic-hybrid"}
        for method in selected_ids
    )
    vision_by_id: dict[str, Any] = {}
    if needs_vision:
        backend = vision_backend or NativeVisionBackend(
            source_bytes=vision_worker_source_bytes
        )
        with tempfile.TemporaryDirectory(
            prefix=".screen-media-", dir=result_root
        ) as directory:
            media_scratch = Path(directory)
            os.chmod(media_scratch, 0o700)
            jobs = _materialize_verified_media(inputs, media_scratch)
            try:
                vision_by_id = backend.classify(jobs)
            except RunnerError:
                raise
            except Exception as error:
                raise RunnerError("native Vision execution failed") from error
        if set(vision_by_id) != set(split_ids):
            raise RunnerError("native Vision output inventory is invalid")

    records_by_method: dict[str, list[dict[str, Any]]] = {
        method: [] for method in selected_ids
    }
    for case_id, _, _, context in inputs:
        baseline = _baseline_result(context)
        vision = _vision_result(vision_by_id[case_id]) if needs_vision else None
        for method in selected_ids:
            if method == "metadata-ax-ocr":
                result = baseline
            elif method == "apple-vision":
                assert vision is not None
                result = vision
            elif method == "deterministic-hybrid":
                assert vision is not None
                result = _hybrid_result(baseline, vision)
            else:
                raise RunnerError("selected method is not executable by this runner")
            records_by_method[method].append(_record(case_id, result))

    target_names = [METHOD_FILES[method] for method in selected_ids]
    target_names.append("run-inventory.json")
    if any((result_root / name).exists() for name in target_names):
        raise RunnerError("private result target already exists")
    canonical_paths = {
        "canonicalLabelsSHA256": annotation_root / "canonical" / "labels.json",
        "canonicalReliabilitySHA256": (
            annotation_root / "canonical" / "reliability.json"
        ),
        "canonicalCommitSHA256": annotation_root / "canonical" / "commit.json",
    }
    for key, path in canonical_paths.items():
        if _sha256(_read_private_regular(path)) != seal[key]:
            raise RunnerError("canonical seal changed after validation")
    staging = Path(tempfile.mkdtemp(prefix=".screen-run-", dir=result_root))
    os.chmod(staging, 0o700)
    try:
        output_hashes: dict[str, str] = {}
        for method in selected_ids:
            data = _json_bytes(records_by_method[method], lines=True)
            output_hashes[method] = _sha256(data)
            _write_owner_only_atomic(staging / METHOD_FILES[method], data)
        inventory = {
            "schema": RUN_SCHEMA,
            "protocolID": manifest.get("protocolID"),
            "split": LOCKED_SPLIT,
            "caseCount": len(inputs),
            "selectedMethods": selected_ids,
            "mappingPending": True,
            "complete": True,
            "commitFile": "run-inventory.json",
            "partialOutputsValidWithoutInventory": False,
            "datasetManifestSHA256": seal["datasetManifestSHA256"],
            "canonicalLabelsSHA256": seal["canonicalLabelsSHA256"],
            "canonicalReliabilitySHA256": seal["canonicalReliabilitySHA256"],
            "canonicalCommitSHA256": seal["canonicalCommitSHA256"],
            "nativeRuntimeIdentity": native_runtime_identity,
            "nativeRuntimeIdentitySHA256": _sha256(
                _json_bytes(native_runtime_identity)
            ),
            "methodArtifacts": {
                method_id: artifact_pins[method_id]
                for method_id in selected_ids
            },
            "runnerSourceSHA256": {
                "adapterManifest": _sha256(
                    adapter_raw.encode("utf-8")
                ),
                "protocolManifest": _sha256(
                    protocol_raw.encode("utf-8")
                ),
                "orchestrator": _sha256(runner_source_bytes),
                **({
                    "appleVisionWorker": _sha256(vision_worker_source_bytes),
                } if needs_vision else {}),
            },
            "outputSHA256": output_hashes,
        }
        _write_owner_only_atomic(
            staging / "run-inventory.json", _json_bytes(inventory)
        )
        _commit_staged_run(staging, result_root, target_names[:-1])
        return inventory
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset-root", required=True, type=Path)
    parser.add_argument("--annotation-root", required=True, type=Path)
    parser.add_argument("--source-annotation-root", required=True, type=Path)
    parser.add_argument("--correctness-audit-root", required=True, type=Path)
    parser.add_argument("--aggregate-root", required=True, type=Path)
    parser.add_argument("--final-audit-root", required=True, type=Path)
    parser.add_argument("--final-judgments", required=True, type=Path)
    parser.add_argument("--result-root", required=True, type=Path)
    parser.add_argument("--methods", required=True)
    args = parser.parse_args()
    try:
        inventory = run_quality(
            args.dataset_root,
            args.annotation_root,
            args.result_root,
            args.methods,
            source_annotation_root=args.source_annotation_root,
            correctness_audit_root=args.correctness_audit_root,
            aggregate_root=args.aggregate_root,
            final_audit_root=args.final_audit_root,
            final_judgments=args.final_judgments,
        )
    except UnsupportedMethodError as error:
        print(f"security-unsupported: {error}", file=sys.stderr)
        return 3
    except (PreflightError, RunnerError) as error:
        print(f"quality run failed: {error}", file=sys.stderr)
        return 2
    except Exception:
        print("quality run failed: internal runner failure", file=sys.stderr)
        return 2
    print(json.dumps({
        "caseCount": inventory["caseCount"],
        "mappingPending": True,
        "selectedMethods": inventory["selectedMethods"],
    }, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
