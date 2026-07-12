#!/usr/bin/python3
"""Materialize canonical roots into a sandbox profile without shell interpolation."""

import argparse
import json
import os
from pathlib import Path


TOKENS = (
    "RUNTIME_ROOT",
    "MODEL_ROOT",
    "CASE_ROOT",
    "RESULT_ROOT",
    "TMP_ROOT",
)


def canonical_directory(raw_path: str) -> str:
    path = Path(raw_path)
    if not path.is_absolute():
        raise ValueError("sandbox roots must be absolute")
    canonical = path.resolve(strict=True)
    if not canonical.is_dir() or canonical == Path("/"):
        raise ValueError("sandbox roots must be existing non-root directories")
    return str(canonical)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True)
    parser.add_argument("--output", required=True)
    for token in TOKENS:
        parser.add_argument(f"--{token.lower().replace('_', '-')}", required=True)
    args = parser.parse_args()

    template = Path(args.template).read_text(encoding="utf-8")
    for token in TOKENS:
        value = canonical_directory(getattr(args, token.lower()))
        template = template.replace(f'"__{token}__"', json.dumps(value))
    if "__" in template:
        raise ValueError("unresolved sandbox profile token")

    output = Path(args.output)
    descriptor = os.open(
        output,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(template)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
