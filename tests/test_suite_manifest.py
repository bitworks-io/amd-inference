import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TESTS = ROOT / "tests"
MANIFEST = TESTS / "suite-manifest.json"
WORKFLOW = ROOT / ".github" / "workflows" / "test.yml"
CLASSES = {"ci", "bench-native", "bench-physical"}


def suite_files():
    return sorted(p.name[: -len(".ps1")] for p in TESTS.glob("*-tests.ps1"))


def workflow_references():
    text = WORKFLOW.read_text(encoding="utf-8")
    return set(re.findall(r"\.[\\/]tests[\\/]([A-Za-z0-9_-]+)\.ps1", text))


class SuiteManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        cls.entries = cls.manifest["suites"]

    def test_schema(self):
        self.assertEqual(self.manifest["schema"], "bitworks.fastllm-suite-manifest/v1")

    def test_entries_are_well_formed(self):
        for entry in self.entries:
            self.assertEqual(set(entry), {"suite", "class", "reason"}, entry)
            self.assertIn(entry["class"], CLASSES, entry["suite"])
            self.assertTrue(entry["reason"].strip(), entry["suite"])

    def test_no_duplicates(self):
        names = [e["suite"] for e in self.entries]
        duplicates = sorted({n for n in names if names.count(n) > 1})
        self.assertEqual(duplicates, [], "duplicate manifest entries")

    def test_every_suite_file_is_classified(self):
        missing = sorted(set(suite_files()) - {e["suite"] for e in self.entries})
        self.assertEqual(missing, [], "suite files missing from tests/suite-manifest.json")

    def test_every_entry_has_a_file(self):
        orphans = sorted({e["suite"] for e in self.entries} - set(suite_files()))
        self.assertEqual(orphans, [], "manifest entries without a suite file")

    def test_ci_suites_are_wired(self):
        refs = workflow_references()
        unwired = sorted(e["suite"] for e in self.entries if e["class"] == "ci" and e["suite"] not in refs)
        self.assertEqual(unwired, [], "ci suites not referenced in test.yml")

    def test_non_ci_suites_are_not_wired(self):
        refs = workflow_references()
        wired = sorted(e["suite"] for e in self.entries if e["class"] != "ci" and e["suite"] in refs)
        self.assertEqual(wired, [], "non-ci suites referenced in test.yml")

    def test_workflow_references_only_known_suites(self):
        known = {e["suite"] for e in self.entries}
        stray = sorted(n for n in workflow_references() if n.endswith("-tests") and n not in known)
        self.assertEqual(stray, [], "test.yml references suites absent from the manifest")


if __name__ == "__main__":
    unittest.main()
