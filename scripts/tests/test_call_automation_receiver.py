#!/usr/bin/env python3

import hashlib
import hmac
import http.client
import importlib.util
import io
import json
import queue
import sqlite3
import tempfile
import threading
import time
import types
import unittest
from contextlib import closing, redirect_stdout
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RECEIVER_PATH = ROOT / "examples" / "call-automation-receiver.py"


def load_receiver():
    if not RECEIVER_PATH.exists():
        raise AssertionError(f"reference receiver is missing: {RECEIVER_PATH}")
    spec = importlib.util.spec_from_file_location("call_automation_receiver", RECEIVER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class CallAutomationReceiverTests(unittest.TestCase):
    def setUp(self):
        self.receiver = load_receiver()
        self.secret = "test-secret"
        self.now = int(time.time())
        self.event = {
            "specversion": "1.0",
            "dataschema": "zbseye://schemas/call-automation/v1",
            "id": "event-123",
            "source": "zbseye://calls",
            "type": "call.transcript.ready",
            "subject": "call:42",
            "time": "2026-07-17T12:00:00Z",
            "data": {"status": "ready"},
        }
        self.body = json.dumps(
            self.event, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")

    def headers(self, timestamp=None, event_id=None, signature=None):
        timestamp = str(self.now if timestamp is None else timestamp)
        event_id = event_id or self.event["id"]
        if signature is None:
            digest = hmac.new(
                self.secret.encode("utf-8"),
                timestamp.encode("ascii") + b"." + self.body,
                hashlib.sha256,
            ).hexdigest()
            signature = f"sha256={digest}"
        return {
            "X-ZBS-Eye-Event-ID": event_id,
            "X-ZBS-Eye-Delivery-Timestamp": timestamp,
            "X-ZBS-Eye-Signature": signature,
        }

    def test_valid_request_is_verified_and_decoded(self):
        decoded = self.receiver.verify_event(
            secret=self.secret,
            headers=self.headers(),
            body=self.body,
            now_seconds=self.now,
        )

        self.assertEqual(decoded["id"], "event-123")
        self.assertEqual(decoded["subject"], "call:42")

    def test_signature_event_id_and_timestamp_are_fail_closed(self):
        cases = [
            self.headers(signature="sha256=" + "0" * 64),
            self.headers(event_id="different-event"),
            self.headers(timestamp=self.now - 301),
        ]

        for headers in cases:
            with self.subTest(headers=headers):
                with self.assertRaises(self.receiver.VerificationError):
                    self.receiver.verify_event(
                        secret=self.secret,
                        headers=headers,
                        body=self.body,
                        now_seconds=self.now,
                    )

    def test_deduplication_survives_reopen_until_explicit_purge(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.sqlite3"
            first = self.receiver.EventDeduplicator(path)
            self.assertTrue(first.accept_event("event-123", b"{}"))
            self.assertFalse(first.accept_event("event-123", b"{}"))
            first.close()

            reopened = self.receiver.EventDeduplicator(path)
            self.assertFalse(reopened.accept_event("event-123", b"{}"))
            reopened.purge()
            self.assertTrue(reopened.accept_event("event-123", b"{}"))
            reopened.close()

            with closing(sqlite3.connect(path)) as database:
                count = database.execute("SELECT COUNT(*) FROM accepted_events").fetchone()[0]
            self.assertEqual(count, 1)

    def test_test_event_needs_no_call_subject(self):
        event = dict(self.event)
        event["id"] = "test-event"
        event["type"] = "call.automation.test"
        event.pop("subject")
        event["data"] = {}
        body = json.dumps(event, separators=(",", ":"), sort_keys=True).encode("utf-8")
        timestamp = str(self.now)
        digest = hmac.new(
            self.secret.encode("utf-8"),
            timestamp.encode("ascii") + b"." + body,
            hashlib.sha256,
        ).hexdigest()

        decoded = self.receiver.verify_event(
            secret=self.secret,
            headers={
                "X-ZBS-Eye-Event-ID": event["id"],
                "X-ZBS-Eye-Delivery-Timestamp": timestamp,
                "X-ZBS-Eye-Signature": f"sha256={digest}",
            },
            body=body,
            now_seconds=self.now,
        )

        self.assertNotIn("subject", decoded)

    def test_secret_file_requires_owner_only_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secret"
            path.write_text("stable-secret\n", encoding="utf-8")
            path.chmod(0o600)
            args = types.SimpleNamespace(prompt_secret=False, secret_file=path)
            self.assertEqual(self.receiver.load_secret(args), "stable-secret")

            path.chmod(0o644)
            with self.assertRaisesRegex(ValueError, "mode 0600"):
                self.receiver.load_secret(args)

    def test_live_loopback_post_is_persisted_emitted_and_acknowledged(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "events.sqlite3"
            port_ready = queue.Queue()
            finished = queue.Queue()

            def serve_once():
                deduplicator = self.receiver.EventDeduplicator(state)
                server = self.receiver.ReceiverServer(
                    ("127.0.0.1", 0), self.secret, deduplicator
                )
                server.timeout = 2
                port_ready.put(server.server_port)
                output = io.StringIO()
                with redirect_stdout(output):
                    server.handle_request()
                server.server_close()
                deduplicator.close()
                finished.put(output.getvalue())

            thread = threading.Thread(target=serve_once)
            thread.start()
            port = port_ready.get(timeout=2)
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            headers = self.headers()
            headers["Content-Type"] = "application/cloudevents+json"
            connection.request("POST", "/", body=self.body, headers=headers)
            response = connection.getresponse()
            response.read()
            connection.close()
            thread.join(timeout=2)

            self.assertFalse(thread.is_alive())
            self.assertEqual(response.status, 204)
            self.assertIn('\"id\":\"event-123\"', finished.get(timeout=1))
            with closing(sqlite3.connect(state)) as database:
                row = database.execute(
                    "SELECT emitted_at, length(body) FROM accepted_events WHERE event_id = ?",
                    ("event-123",),
                ).fetchone()
            self.assertIsNotNone(row[0])
            self.assertEqual(row[1], 0)


if __name__ == "__main__":
    unittest.main()
