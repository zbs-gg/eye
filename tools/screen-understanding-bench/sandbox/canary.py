#!/usr/bin/python3
"""Prove network denial against endpoints that first passed a reachable control."""

from __future__ import annotations

import argparse
import errno
import json
import os
import socket
import stat
from pathlib import Path
from typing import Callable


CONTROL_SCHEMA = "screen-understanding-sandbox-network-control-v2"
POLICY_DENIAL_ERRNOS = {errno.EACCES, errno.EPERM}
ENDPOINT_KEYS = {
    "dnsHost", "dnsPort", "directHost", "directPort",
    "localhostPort", "proxyPort",
}
NETWORK_KEYS = {"dns", "directIP", "localhost", "proxy"}


def observe(operation: Callable[[], None]) -> dict:
    try:
        operation()
        return {"allowed": True, "errno": None}
    except OSError as error:
        return {"allowed": False, "errno": error.errno}


def tcp_connect(host: str, port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as connection:
        connection.settimeout(1.0)
        connection.connect((host, port))


def udp_send(host: str, port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
        connection.settimeout(1.0)
        connection.connect((host, port))
        connection.send(b"\x00")


def network_observations(endpoints: dict) -> dict:
    return {
        "dns": observe(lambda: udp_send(endpoints["dnsHost"], endpoints["dnsPort"])),
        "directIP": observe(
            lambda: tcp_connect(endpoints["directHost"], endpoints["directPort"])
        ),
        "localhost": observe(
            lambda: tcp_connect("127.0.0.1", endpoints["localhostPort"])
        ),
        "proxy": observe(
            lambda: tcp_connect("127.0.0.1", endpoints["proxyPort"])
        ),
    }


def make_control_receipt(endpoints: dict, observations: dict) -> dict:
    if set(endpoints) != ENDPOINT_KEYS or set(observations) != NETWORK_KEYS:
        raise ValueError("network control fields are invalid")
    if any(value != {"allowed": True, "errno": None} for value in observations.values()):
        raise ValueError("every network control endpoint must be reachable")
    return {
        "schema": CONTROL_SCHEMA,
        "endpoints": endpoints,
        "observations": observations,
    }


def load_control_receipt(path: Path, endpoints: dict) -> dict:
    metadata = path.lstat()
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode) \
            or metadata.st_uid != os.getuid() \
            or stat.S_IMODE(metadata.st_mode) != 0o600:
        raise ValueError("network control receipt must be an owner-only regular file")
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or set(payload) != {
        "schema", "endpoints", "observations",
    } or payload["schema"] != CONTROL_SCHEMA or payload["endpoints"] != endpoints:
        raise ValueError("network control receipt does not match this canary run")
    make_control_receipt(payload["endpoints"], payload["observations"])
    return payload


def denied_by_policy(observation: dict) -> bool:
    return observation.get("allowed") is False \
        and observation.get("errno") in POLICY_DENIAL_ERRNOS


def endpoints_from_args(args: argparse.Namespace) -> dict:
    return {
        "dnsHost": args.dns_host,
        "dnsPort": args.dns_port,
        "directHost": args.direct_host,
        "directPort": args.direct_port,
        "localhostPort": args.localhost_port,
        "proxyPort": args.proxy_port,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("control", "sandboxed"), required=True)
    parser.add_argument("--dns-host", required=True)
    parser.add_argument("--dns-port", required=True, type=int)
    parser.add_argument("--direct-host", required=True)
    parser.add_argument("--direct-port", required=True, type=int)
    parser.add_argument("--localhost-port", required=True, type=int)
    parser.add_argument("--proxy-port", required=True, type=int)
    parser.add_argument("--control-receipt", type=Path)
    parser.add_argument("--case-file", type=Path)
    parser.add_argument("--result-file", type=Path)
    parser.add_argument("--outside-read", type=Path)
    parser.add_argument("--outside-write", type=Path)
    args = parser.parse_args()
    endpoints = endpoints_from_args(args)
    network = network_observations(endpoints)

    if args.mode == "control":
        try:
            receipt = make_control_receipt(endpoints, network)
        except ValueError as error:
            print(json.dumps({"error": str(error), "observations": network}))
            return 2
        print(json.dumps(receipt, separators=(",", ":"), sort_keys=True))
        return 0

    required_paths = {
        "control receipt": args.control_receipt,
        "case file": args.case_file,
        "result file": args.result_file,
        "outside read": args.outside_read,
        "outside write": args.outside_write,
    }
    if any(path is None for path in required_paths.values()):
        parser.error("sandboxed mode requires the control and four filesystem paths")
    try:
        load_control_receipt(args.control_receipt, endpoints)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(json.dumps({"error": str(error)}))
        return 2

    filesystem = {
        "caseReadAllowed": observe(args.case_file.read_bytes)["allowed"],
        "resultWriteAllowed": observe(
            lambda: args.result_file.write_text("allowed", encoding="utf-8")
        )["allowed"],
        "outsideReadAllowed": observe(args.outside_read.read_bytes)["allowed"],
        "outsideWriteAllowed": observe(
            lambda: args.outside_write.write_text("forbidden", encoding="utf-8")
        )["allowed"],
    }
    observations = {"filesystem": filesystem, "network": network}
    print(json.dumps(observations, separators=(",", ":"), sort_keys=True))
    filesystem_ok = filesystem == {
        "caseReadAllowed": True,
        "resultWriteAllowed": True,
        "outsideReadAllowed": False,
        "outsideWriteAllowed": False,
    }
    network_ok = all(denied_by_policy(value) for value in network.values())
    return 0 if filesystem_ok and network_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
