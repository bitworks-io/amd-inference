import hashlib
import json
import re
import unittest
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "config" / "catalog.json"
CATALOG_DIGEST_PATH = ROOT / "config" / "catalog.sha256"


class CatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = CATALOG_PATH.read_bytes()
        cls.catalog = json.loads(cls.raw)

    def test_schema_and_alpha_status_are_explicit(self):
        self.assertEqual(1, self.catalog["schemaVersion"])
        self.assertEqual("alpha-unvalidated", self.catalog["status"])

    def test_model_ids_and_files_are_unique(self):
        models = self.catalog["models"]
        self.assertEqual(len(models), len({m["id"] for m in models}))
        self.assertEqual(len(models), len({m["file"] for m in models}))

    def test_every_artifact_is_immutable_and_hash_pinned(self):
        sha256 = re.compile(r"^[0-9a-f]{64}$")
        revision = re.compile(r"^[0-9a-f]{40}$")
        for model in self.catalog["models"]:
            with self.subTest(model=model["id"]):
                self.assertRegex(model["sha256"], sha256)
                self.assertRegex(model["revision"], revision)
                self.assertIn(model["revision"], model["url"])
                self.assertEqual("https", urlparse(model["url"]).scheme)
                self.assertGreater(model["sizeBytes"], 1_000_000)
        for asset in self.catalog["engine"]["assets"].values():
            self.assertRegex(asset["sha256"], sha256)
            self.assertEqual("https", urlparse(asset["url"]).scheme)

    def test_enabled_engine_has_an_exact_extracted_manifest(self):
        assets = self.catalog["engine"]["assets"]
        self.assertFalse(assets["rocm"]["enabled"])
        self.assertIn("hipblas.dll", assets["rocm"]["disabledReason"])
        vulkan = assets["vulkan"]
        self.assertTrue(vulkan["enabled"])
        self.assertEqual("llama-server.exe", vulkan["entryPoint"])
        paths = [entry["path"] for entry in vulkan["manifest"]]
        self.assertEqual(len(paths), len(set(path.lower() for path in paths)))
        self.assertIn(vulkan["entryPoint"], paths)
        self.assertEqual(
            vulkan["expandedSizeBytes"],
            sum(entry["sizeBytes"] for entry in vulkan["manifest"]),
        )

    def test_models_record_both_upstream_and_conversion_provenance(self):
        sha256 = re.compile(r"^[0-9a-f]{64}$")
        revision = re.compile(r"^[0-9a-f]{40}$")
        for model in self.catalog["models"]:
            with self.subTest(model=model["id"]):
                self.assertRegex(model["upstreamRevision"], revision)
                self.assertRegex(model["revision"], revision)
                self.assertEqual("Apache-2.0", model["upstreamLicense"])
                self.assertEqual("Apache-2.0", model["artifactLicense"])
                self.assertRegex(model["upstreamLicenseSha256"], sha256)
                self.assertIn(model["upstreamRevision"], model["upstreamLicenseUrl"])
                self.assertIn("text-only", model["servingMode"])

    def test_security_and_hardware_policy_are_explicit(self):
        policy = self.catalog["hardwarePolicy"]
        self.assertEqual("127.0.0.1", policy["serverHost"])
        self.assertEqual(2, policy["maximumCombinedGpus"])
        self.assertGreater(policy["deviceProbeTimeoutSeconds"], 0)
        self.assertLess(self.catalog["hardwarePolicy"]["minimumDedicatedVramMiB"], 4096)

    def test_qwen38_is_a_generation_not_qwen3_8b(self):
        qwen38 = [m for m in self.catalog["models"] if m["family"] == "Qwen3.8"]
        self.assertTrue(qwen38)
        self.assertTrue(all(m["parameters"] == "27B" for m in qwen38))
        self.assertFalse(any("qwen3-8b" in m["id"] for m in self.catalog["models"]))

    def test_flash_next_is_not_an_automatic_candidate(self):
        model_ids = {m["id"] for m in self.catalog["models"]}
        self.assertNotIn("qwen3.8-flash-next", model_ids)
        excluded = {m["id"] for m in self.catalog["excludedModels"]}
        self.assertIn("qwen3.8-flash-next", excluded)

    def test_aggressive_16gb_qwen38_quant_is_not_auto_selected(self):
        iq3 = next(m for m in self.catalog["models"] if m["id"] == "qwen3.8-27b-ud-iq3-xxs")
        self.assertFalse(iq3["autoEligible"])

    def test_catalog_digest_is_stable_for_release_tooling(self):
        digest = hashlib.sha256(self.raw).hexdigest()
        expected, filename = CATALOG_DIGEST_PATH.read_text(encoding="utf-8").strip().split()
        self.assertEqual("catalog.json", filename)
        self.assertEqual(expected, digest)


if __name__ == "__main__":
    unittest.main()
