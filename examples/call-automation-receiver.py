#!/usr/bin/env python3
"""Minimal loopback receiver for ZBS Eye call automation events.

It verifies signed requests, deduplicates event IDs in SQLite, and emits one
compact JSON line to stdout for a supervising local harness. It never launches
commands or contacts another service.
"""

from __future__ import annotations

import argparse
import getpass
import hashlib
import hmac
import json
import os
import sqlite3
import stat
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Mapping


MAX_BODY_BYTES = 64 * 1024
MAX_CLOCK_SKEW_SECONDS = 5 * 60
SUPPORTED_TYPES = {
    "call.ended",
    "call.transcript.ready",
    "call.transcript.failed",
    "call.automation.test",
}
DATA_SCHEMA = "zbseye://schemas/call-automation/v1"


class VerificationError(ValueError):
    pass


def _header(headers: Mapping[str, str], name: str) -> str:
    lowered = {key.lower(): value for key, value in headers.items()}
    value = lowered.get(name.lower(), "").strip()
    if not value:
        raise VerificationError(f"missing_{name.lower()}")
    return value


def verify_event(
    *,
    secret: str,
    headers: Mapping[str, str],
    body: bytes,
    now_seconds: int | None = None,
) -> dict:
    if not secret:
        raise VerificationError("missing_secret")
    if not body or len(body) > MAX_BODY_BYTES:
        raise VerificationError("invalid_body_size")

    event_id = _header(headers, "X-ZBS-Eye-Event-ID")
    timestamp_text = _header(headers, "X-ZBS-Eye-Delivery-Timestamp")
    signature = _header(headers, "X-ZBS-Eye-Signature")
    try:
        timestamp = int(timestamp_text)
    except ValueError as error:
        raise VerificationError("invalid_timestamp") from error
    now = int(time.time()) if now_seconds is None else int(now_seconds)
    if abs(now - timestamp) > MAX_CLOCK_SKEW_SECONDS:
        raise VerificationError("stale_timestamp")

    if not signature.startswith("sha256="):
        raise VerificationError("invalid_signature_format")
    supplied = signature.removeprefix("sha256=")
    if len(supplied) != 64:
        raise VerificationError("invalid_signature_format")
    expected = hmac.new(
        secret.encode("utf-8"),
        timestamp_text.encode("ascii") + b"." + body,
        hashlib.sha256,
    ).hexdigest()
    if not hmac.compare_digest(supplied, expected):
        raise VerificationError("invalid_signature")

    try:
        event = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError("invalid_json") from error
    if not isinstance(event, dict):
        raise VerificationError("invalid_event")
    if event.get("specversion") != "1.0":
        raise VerificationError("unsupported_specversion")
    if event.get("dataschema") != DATA_SCHEMA:
        raise VerificationError("unsupported_dataschema")
    if event.get("id") != event_id:
        raise VerificationError("event_id_mismatch")
    event_type = event.get("type")
    if event_type not in SUPPORTED_TYPES:
        raise VerificationError("unsupported_event_type")
    if event_type == "call.automation.test":
        if "subject" in event:
            raise VerificationError("test_event_has_subject")
    else:
        subject = event.get("subject")
        if not isinstance(subject, str) or not subject.startswith("call:"):
            raise VerificationError("invalid_call_subject")
        try:
            if int(subject.removeprefix("call:")) <= 0:
                raise ValueError
        except ValueError as error:
            raise VerificationError("invalid_call_subject") from error
    return event


class EventDeduplicator:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._database = sqlite3.connect(path)
        self._database.execute("PRAGMA journal_mode=WAL")
        self._database.execute("PRAGMA synchronous=FULL")
        self._database.execute(
            """
            CREATE TABLE IF NOT EXISTS accepted_events (
                event_id TEXT PRIMARY KEY,
                accepted_at INTEGER NOT NULL,
                body BLOB NOT NULL,
                emitted_at INTEGER
            )
            """
        )
        self._database.commit()

    def accept_event(self, event_id: str, body: bytes) -> bool:
        cursor = self._database.execute(
            """
            INSERT OR IGNORE INTO accepted_events(event_id, accepted_at, body, emitted_at)
            VALUES (?, ?, ?, NULL)
            """,
            (event_id, int(time.time()), body),
        )
        self._database.commit()
        return cursor.rowcount == 1

    def pending_events(self, limit: int = 100) -> list[tuple[str, bytes]]:
        rows = self._database.execute(
            """
            SELECT event_id, body
            FROM accepted_events
            WHERE emitted_at IS NULL
            ORDER BY accepted_at, event_id
            LIMIT ?
            """,
            (limit,),
        ).fetchall()
        return [(str(row[0]), bytes(row[1])) for row in rows]

    def mark_emitted(self, event_id: str) -> None:
        self._database.execute(
            "UPDATE accepted_events SET emitted_at = ?, body = X'' WHERE event_id = ?",
            (int(time.time()), event_id),
        )
        self._database.commit()

    def purge(self) -> None:
        self._database.execute("DELETE FROM accepted_events")
        self._database.commit()

    def close(self) -> None:
        self._database.close()


def emit_event(body: bytes) -> None:
    event = json.loads(body)
    print(json.dumps(event, separators=(",", ":"), sort_keys=True), flush=True)


class ReceiverServer(HTTPServer):
    def __init__(self, address, secret: str, deduplicator: EventDeduplicator):
        super().__init__(address, ReceiverHandler)
        self.secret = secret
        self.deduplicator = deduplicator


class ReceiverHandler(BaseHTTPRequestHandler):
    server: ReceiverServer

    def do_POST(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_error(400)
            return
        if length <= 0 or length > MAX_BODY_BYTES:
            self.send_error(413)
            return
        body = self.rfile.read(length)
        try:
            event = verify_event(
                secret=self.server.secret,
                headers=self.headers,
                body=body,
            )
        except VerificationError:
            self.send_error(401)
            return

        event_id = event["id"]
        if self.server.deduplicator.accept_event(event_id, body):
            emit_event(body)
            self.server.deduplicator.mark_emitted(event_id)
        self.send_response(204)
        self.end_headers()

    def log_message(self, format: str, *args) -> None:
        print(f"[receiver] {format % args}", file=sys.stderr)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", choices=["127.0.0.1"])
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument(
        "--state",
        type=Path,
        default=Path.home() / ".local" / "share" / "zbs-eye-call-receiver.sqlite3",
    )
    parser.add_argument("--purge-deduplication", action="store_true")
    secret_source = parser.add_mutually_exclusive_group()
    secret_source.add_argument("--prompt-secret", action="store_true")
    secret_source.add_argument("--secret-file", type=Path)
    return parser.parse_args()


def load_secret(args: argparse.Namespace) -> str:
    if args.prompt_secret:
        secret = getpass.getpass("ZBS Eye signing secret: ").strip()
    elif args.secret_file is not None:
        mode = stat.S_IMODE(args.secret_file.stat().st_mode)
        if mode & 0o077:
            raise ValueError("secret file must be readable only by its owner (mode 0600)")
        secret = args.secret_file.read_text(encoding="utf-8").strip()
    else:
        secret = os.environ.get("ZBS_EYE_WEBHOOK_SECRET", "").strip()
    if not secret:
        raise ValueError("a signing secret is required")
    return secret


def main() -> int:
    args = parse_args()
    if not 1024 <= args.port <= 65535:
        print("port must be between 1024 and 65535", file=sys.stderr)
        return 2
    try:
        secret = load_secret(args)
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2
    deduplicator = EventDeduplicator(args.state)
    if args.purge_deduplication:
        deduplicator.purge()
    while pending := deduplicator.pending_events():
        for event_id, body in pending:
            emit_event(body)
            deduplicator.mark_emitted(event_id)
    server = ReceiverServer((args.host, args.port), secret, deduplicator)
    print(f"[receiver] listening on http://{args.host}:{args.port}/", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    finally:
        server.server_close()
        deduplicator.close()


if __name__ == "__main__":
    raise SystemExit(main())
