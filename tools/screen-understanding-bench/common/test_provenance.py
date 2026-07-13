import tempfile
import unittest
from pathlib import Path

from provenance import file_evidence, final_audit_evidence, tree_evidence


class ProvenanceTests(unittest.TestCase):
    def test_tree_digest_is_order_independent_and_content_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            first = base / "first"
            second = base / "second"
            (first / "nested").mkdir(parents=True)
            (second / "nested").mkdir(parents=True)
            (first / "z.txt").write_text("z", encoding="utf-8")
            (first / "nested" / "a.txt").write_text("a", encoding="utf-8")
            (second / "nested" / "a.txt").write_text("a", encoding="utf-8")
            (second / "z.txt").write_text("z", encoding="utf-8")

            expected = tree_evidence(first)
            self.assertEqual(expected, tree_evidence(second))

            (second / "z.txt").write_text("changed", encoding="utf-8")
            self.assertNotEqual(expected["sha256"], tree_evidence(second)["sha256"])

    def test_final_audit_digest_excludes_only_publish_ephemera(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "packet").mkdir()
            (root / "packet" / "packet.json").write_text("{}", encoding="utf-8")
            expected = final_audit_evidence(root)
            (root / "canonical").mkdir()
            (root / "canonical" / "labels.json").write_text("private", encoding="utf-8")
            (root / ".canonical.staging-123").mkdir()
            (root / ".canonical.staging-123" / "partial").write_text(
                "private", encoding="utf-8"
            )
            (root / ".canonical-seal.lock").write_text("", encoding="utf-8")

            self.assertEqual(expected, final_audit_evidence(root))
            (root / "packet" / "packet.json").write_text(
                '{"tampered":true}', encoding="utf-8"
            )
            self.assertNotEqual(expected, final_audit_evidence(root))

    def test_file_evidence_reports_only_digest_and_byte_count(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "judgments.json"
            path.write_bytes(b"judgments")

            evidence = file_evidence(path)

            self.assertEqual(set(evidence), {"sha256", "byteCount"})
            self.assertEqual(evidence["byteCount"], 9)


if __name__ == "__main__":
    unittest.main()
