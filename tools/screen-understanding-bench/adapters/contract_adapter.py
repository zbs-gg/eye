#!/usr/bin/python3
"""Synthetic JSONL adapter used to verify the benchmark process contract."""

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


def respond(payload: dict[str, object]) -> None:
    print(json.dumps(payload, separators=(",", ":")), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=(
            "synthetic", "unsupported", "malformed", "crash", "hang", "hang-child",
            "flood",
        ),
        default="synthetic",
    )
    parser.add_argument("--child-pid-file", type=Path)
    args = parser.parse_args()

    if args.mode == "crash":
        return 23
    if args.mode == "hang":
        time.sleep(3600)
        return 0
    if args.mode == "hang-child":
        if args.child_pid_file is None:
            return 24
        child = subprocess.Popen([
            sys.executable,
            "-c",
            "import time; time.sleep(3600)",
        ])
        args.child_pid_file.write_text(str(child.pid), encoding="utf-8")
        time.sleep(3600)
        return 0
    if args.mode == "flood":
        sys.stdout.buffer.write(b"x" * (5 * 1024 * 1024))
        sys.stdout.buffer.flush()
        sys.stderr.buffer.write(b"y" * (5 * 1024 * 1024))
        sys.stderr.buffer.flush()
        return 0

    for raw_line in sys.stdin:
        message = json.loads(raw_line)
        if args.mode == "malformed":
            print("not-json", flush=True)
            return 0
        if args.mode == "unsupported":
            respond(
                {
                    "id": message["id"],
                    "status": "unsupported",
                    "error": "runtime not provisioned",
                }
            )
            return 0

        message_type = message["type"]
        if message_type == "hello":
            respond({"id": message["id"], "status": "ready"})
        elif message_type == "case":
            respond(
                {
                    "id": message["id"],
                    "status": "ok",
                    "normalized": {
                        "summary": "Synthetic visible activity",
                        "atomicFacts": ["A synthetic window is visible"],
                        "visibleText": [],
                        "labels": ["synthetic"],
                    },
                }
            )
        elif message_type == "shutdown":
            respond({"id": message["id"], "status": "bye"})
        else:
            respond({"id": message["id"], "status": "error", "error": "unknown message"})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
