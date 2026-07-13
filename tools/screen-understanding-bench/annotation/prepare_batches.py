#!/usr/bin/python3
"""Prepare private, candidate-blind frontier annotation work batches."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import uuid
from pathlib import Path


CASE_ID = re.compile(r"^[0-9a-f]{24}$")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def locked_order(items: list[dict], seed: str) -> list[dict]:
    return sorted(items, key=lambda item: digest(f"{seed}:{item['id']}".encode()))


def write_private_json(path: Path, value: object) -> None:
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")


def make_directory(path: Path) -> None:
    path.mkdir(mode=0o700)
    path.chmod(0o700)


def render_case(corpus: Path, staging: Path, case_id: str) -> None:
    source = corpus / "cases" / case_id / "image.heic"
    if not source.is_file() or source.is_symlink():
        raise ValueError("annotation source must be a regular sealed image")
    destination = staging / "renders" / f"{case_id}.jpg"
    subprocess.run(
        ["/usr/bin/sips", "-s", "format", "jpeg", str(source), "--out", str(destination)],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    destination.chmod(0o600)


def prepare_batches(
    corpus_root: Path,
    annotation_root: Path,
    batch_count: int,
    duplicate_fraction: float,
    seed: str,
    render: bool,
    rubric_version: str = "screen-understanding-canonical-v1",
) -> dict:
    corpus = corpus_root.resolve(strict=True)
    output = annotation_root.resolve(strict=False)
    if output.exists():
        raise ValueError("annotation root already exists")
    if batch_count < 2:
        raise ValueError("at least two annotator batches are required")
    if not 0 < duplicate_fraction <= 0.5:
        raise ValueError("duplicate fraction must be within (0, 0.5]")
    if corpus == output or corpus in output.parents or output in corpus.parents:
        raise ValueError("corpus and annotation roots must be disjoint")
    lowered = str(output).lower()
    if "/library/mobile documents/" in lowered or "/cloudstorage/" in lowered:
        raise ValueError("annotation root cannot use cloud-synchronized storage")

    manifest_path = corpus / "manifest.json"
    manifest_data = manifest_path.read_bytes()
    manifest = json.loads(manifest_data)
    singles = manifest.get("singleFrameCaseIDs", [])
    pairs = manifest.get("temporalPairs", [])
    if len(singles) != 200 or len(pairs) != 100:
        if not (len(singles) == 8 and len(pairs) == 4):
            raise ValueError("corpus does not match the locked 200/100 protocol")
    if any(not CASE_ID.fullmatch(identifier) for identifier in singles):
        raise ValueError("invalid single-frame case identifier")

    single_items = [
        {
            "id": identifier,
            "targetType": "single-frame",
            "image": f"renders/{identifier}.jpg",
        }
        for identifier in singles
    ]
    pair_items = []
    render_ids = set(singles)
    for pair in pairs:
        identifier = pair.get("id", "")
        before = pair.get("beforeCaseID", "")
        after = pair.get("afterCaseID", "")
        if not all(CASE_ID.fullmatch(value) for value in [identifier, before, after]):
            raise ValueError("invalid temporal-pair identifier")
        render_ids.update([before, after])
        pair_items.append({
            "id": identifier,
            "targetType": "temporal-pair",
            "beforeImage": f"renders/{before}.jpg",
            "afterImage": f"renders/{after}.jpg",
            "deltaMs": pair["deltaMs"],
        })

    ordered = locked_order(single_items + pair_items, seed)
    pass_one_batches = [[] for _ in range(batch_count)]
    pass_one_assignment = {}
    for index, item in enumerate(ordered):
        batch_index = index % batch_count
        pass_one_batches[batch_index].append(item)
        pass_one_assignment[item["id"]] = batch_index

    duplicate_singles = locked_order(single_items, f"{seed}:audit-single")[
        :max(1, round(len(single_items) * duplicate_fraction))
    ]
    duplicate_pairs = locked_order(pair_items, f"{seed}:audit-pair")[
        :max(1, round(len(pair_items) * duplicate_fraction))
    ]
    pass_two_batches = [[] for _ in range(batch_count)]
    for item in duplicate_singles + duplicate_pairs:
        different_batch = (pass_one_assignment[item["id"]] + 1) % batch_count
        pass_two_batches[different_batch].append(item)

    staging = output.parent / f".{output.name}.staging-{uuid.uuid4()}"
    make_directory(staging)
    try:
        for name in ["renders", "batches", "labels", "adjudication"]:
            make_directory(staging / name)
        make_directory(staging / "labels" / "pass1")
        make_directory(staging / "labels" / "pass2")
        if render:
            for case_id in sorted(render_ids):
                render_case(corpus, staging, case_id)

        for index, items in enumerate(pass_one_batches, start=1):
            write_private_json(staging / "batches" / f"pass1-{index:02d}.json", {
                "schema": "screen-understanding-annotation-batch-v1",
                "pass": 1,
                "annotatorSlot": f"frontier-{index:02d}",
                "rubricVersion": rubric_version,
                "candidateOutputsAvailable": False,
                "items": items,
            })
        for index, items in enumerate(pass_two_batches, start=1):
            write_private_json(staging / "batches" / f"pass2-{index:02d}.json", {
                "schema": "screen-understanding-annotation-batch-v1",
                "pass": 2,
                "annotatorSlot": f"frontier-audit-{index:02d}",
                "rubricVersion": rubric_version,
                "candidateOutputsAvailable": False,
                "items": items,
            })

        result = {
            "schema": "screen-understanding-annotation-work-v1",
            "protocolID": "screen-understanding-v1",
            "corpusManifestSHA256": digest(manifest_data),
            "splitSHA256": manifest.get("splitSHA256"),
            "rubricVersion": rubric_version,
            "producer": "frontier-vlm",
            "candidateOutputsAvailable": False,
            "pass1Count": len(ordered),
            "pass2Count": len(duplicate_singles) + len(duplicate_pairs),
            "batchCount": batch_count,
            "renderCount": len(render_ids) if render else 0,
        }
        write_private_json(staging / "annotation-manifest.json", result)
        staging.rename(output)
        return result
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus-root", required=True, type=Path)
    parser.add_argument("--annotation-root", required=True, type=Path)
    parser.add_argument("--batches", type=int, default=4)
    parser.add_argument("--duplicate-fraction", type=float, default=0.15)
    parser.add_argument("--seed", default="screen-understanding-canonical-v1")
    parser.add_argument(
        "--rubric-version",
        choices=("screen-understanding-canonical-v1", "screen-understanding-canonical-v2"),
        default="screen-understanding-canonical-v2",
    )
    parser.add_argument("--skip-render", action="store_true")
    args = parser.parse_args()
    result = prepare_batches(
        corpus_root=args.corpus_root,
        annotation_root=args.annotation_root,
        batch_count=args.batches,
        duplicate_fraction=args.duplicate_fraction,
        seed=args.seed,
        render=not args.skip_render,
        rubric_version=args.rubric_version,
    )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
