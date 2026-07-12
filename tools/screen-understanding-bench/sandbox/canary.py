#!/usr/bin/python3
"""Fail closed unless the benchmark sandbox exposes only its declared roots."""

import argparse
import json
import socket
from pathlib import Path


def attempt(operation) -> bool:
    try:
        operation()
        return True
    except OSError:
        return False


def connect(host: str, port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as connection:
        connection.settimeout(0.2)
        connection.connect((host, port))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--case-file", required=True)
    parser.add_argument("--result-file", required=True)
    parser.add_argument("--outside-read", required=True)
    parser.add_argument("--outside-write", required=True)
    args = parser.parse_args()

    case_file = Path(args.case_file)
    result_file = Path(args.result_file)
    outside_read = Path(args.outside_read)
    outside_write = Path(args.outside_write)

    observations = {
        "caseReadAllowed": attempt(case_file.read_bytes),
        "resultWriteAllowed": attempt(lambda: result_file.write_text("allowed")),
        "outsideReadAllowed": attempt(outside_read.read_bytes),
        "outsideWriteAllowed": attempt(lambda: outside_write.write_text("forbidden")),
        "dnsAllowed": attempt(lambda: socket.getaddrinfo("example.com", 443)),
        "directIPAllowed": attempt(lambda: connect("1.1.1.1", 443)),
        "localhostAllowed": attempt(lambda: connect("127.0.0.1", 9)),
    }
    print(json.dumps(observations, separators=(",", ":")))
    return 0 if observations == {
        "caseReadAllowed": True,
        "resultWriteAllowed": True,
        "outsideReadAllowed": False,
        "outsideWriteAllowed": False,
        "dnsAllowed": False,
        "directIPAllowed": False,
        "localhostAllowed": False,
    } else 1


if __name__ == "__main__":
    raise SystemExit(main())
