import importlib.util
import json
import stat
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("prepare_batches.py")


def load_module():
    spec = importlib.util.spec_from_file_location("prepare_batches", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PrepareAnnotationBatchesTests(unittest.TestCase):
    def test_batches_cover_corpus_once_and_hide_candidate_outputs(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            corpus = self.make_corpus(base)
            output = base / "annotations"
            result = module.prepare_batches(
                corpus_root=corpus,
                annotation_root=output,
                batch_count=4,
                duplicate_fraction=0.15,
                seed="locked-seed",
                render=False,
            )

            pass_one = []
            for batch_path in sorted((output / "batches").glob("pass1-*.json")):
                batch = json.loads(batch_path.read_text())
                pass_one.extend(batch["items"])
                self.assertNotIn(str(corpus), batch_path.read_text())
                self.assertNotIn('"candidateOutput"', batch_path.read_text())
            self.assertEqual(len(pass_one), 12)
            self.assertEqual(len({item["id"] for item in pass_one}), 12)

            audit = []
            for batch_path in sorted((output / "batches").glob("pass2-*.json")):
                audit.extend(json.loads(batch_path.read_text())["items"])
            self.assertEqual(len(audit), 2)
            self.assertEqual(result["pass1Count"], 12)
            self.assertEqual(result["pass2Count"], 2)
            self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
            self.assertTrue(all(
                stat.S_IMODE(path.stat().st_mode) == 0o600
                for path in output.rglob("*.json")
            ))

    def test_existing_annotation_root_is_rejected(self):
        module = load_module()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            corpus = self.make_corpus(base)
            output = base / "annotations"
            output.mkdir()
            with self.assertRaises(ValueError):
                module.prepare_batches(
                    corpus_root=corpus,
                    annotation_root=output,
                    batch_count=2,
                    duplicate_fraction=0.15,
                    seed="locked-seed",
                    render=False,
                )

    def make_corpus(self, base: Path) -> Path:
        corpus = base / "corpus"
        cases = corpus / "cases"
        cases.mkdir(parents=True)
        singles = [f"{index:024x}" for index in range(1, 9)]
        for identifier in singles:
            case = cases / identifier
            case.mkdir()
            (case / "image.heic").write_bytes(b"fixture")
        pairs = []
        for index in range(4):
            before = singles[index * 2]
            after = singles[index * 2 + 1]
            pairs.append({
                "id": f"{100 + index:024x}",
                "beforeCaseID": before,
                "afterCaseID": after,
                "deltaMs": 1000,
                "strata": ["temporal-change"],
            })
        manifest = {
            "singleFrameCaseIDs": singles,
            "temporalPairs": pairs,
            "splitSHA256": "a" * 64,
        }
        (corpus / "manifest.json").write_text(json.dumps(manifest))
        return corpus


if __name__ == "__main__":
    unittest.main()
