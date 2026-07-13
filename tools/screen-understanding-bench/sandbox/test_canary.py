#!/usr/bin/python3

import errno
import json
import os
import tempfile
import unittest
from pathlib import Path

import canary


class SandboxCanaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.endpoints = {
            "dnsHost": "192.0.2.10",
            "dnsPort": 5353,
            "directHost": "192.0.2.11",
            "directPort": 443,
            "localhostPort": 41001,
            "proxyPort": 41002,
        }
        self.allowed = {
            name: {"allowed": True, "errno": None}
            for name in canary.NETWORK_KEYS
        }

    def test_control_requires_every_exact_endpoint_to_be_reachable(self) -> None:
        receipt = canary.make_control_receipt(self.endpoints, self.allowed)
        self.assertEqual(receipt["endpoints"], self.endpoints)

        refused = dict(self.allowed)
        refused["localhost"] = {"allowed": False, "errno": errno.ECONNREFUSED}
        with self.assertRaisesRegex(ValueError, "must be reachable"):
            canary.make_control_receipt(self.endpoints, refused)

    def test_only_policy_denial_counts_as_sandbox_evidence(self) -> None:
        self.assertTrue(canary.denied_by_policy({"allowed": False, "errno": errno.EPERM}))
        self.assertTrue(canary.denied_by_policy({"allowed": False, "errno": errno.EACCES}))
        self.assertFalse(canary.denied_by_policy({
            "allowed": False,
            "errno": errno.ECONNREFUSED,
        }))
        self.assertFalse(canary.denied_by_policy({"allowed": False, "errno": None}))

    def test_control_receipt_is_owner_only_and_endpoint_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "control.json"
            path.write_text(
                json.dumps(canary.make_control_receipt(self.endpoints, self.allowed)),
                encoding="utf-8",
            )
            os.chmod(path, 0o600)
            self.assertEqual(
                canary.load_control_receipt(path, self.endpoints)["schema"],
                canary.CONTROL_SCHEMA,
            )
            changed = {**self.endpoints, "proxyPort": 9999}
            with self.assertRaisesRegex(ValueError, "does not match"):
                canary.load_control_receipt(path, changed)


if __name__ == "__main__":
    unittest.main()
