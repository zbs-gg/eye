#!/usr/bin/python3
"""Synthetic JSONL adapter used to verify the benchmark process contract."""

import argparse
import json
import sys
import time


def respond(payload: dict[str, object]) -> None:
    print(json.dumps(payload, separators=(",", ":")), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=("synthetic", "unsupported", "malformed", "crash", "hang"),
        default="synthetic",
    )
    args = parser.parse_args()

    if args.mode == "crash":
        return 23
    if args.mode == "hang":
        time.sleep(3600)
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
