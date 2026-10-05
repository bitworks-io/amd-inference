"""No-network orchestration checks for the explicit Linux lab entrypoint."""

import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fastllm_linux_lab_test", ROOT / "linux" / "lab.py")
lab = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lab)


class LabTests(unittest.TestCase):
    def test_setup_requires_explicit_lab_before_any_mutation(self):
        with mock.patch.object(lab, "_root") as root, mock.patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as stopped:
                lab.main(["start", "--root", "/unused"])
            self.assertEqual(stopped.exception.code, 2)
            root.assert_not_called()

    def test_missing_packages_stop_before_native_probe_or_model(self):
        with mock.patch.object(lab, "_root", return_value=Path("/private")), \
             mock.patch.object(lab.models, "load_catalog", return_value={}), \
             mock.patch.object(lab, "_stage", return_value=Path("/private/engine")), \
             mock.patch.object(lab.ubuntu_packages, "check", return_value={"missing": ["libgomp1"]}), \
             mock.patch.object(lab, "_host_plan") as plan, \
             mock.patch.object(lab, "_model_ready") as model:
            with self.assertRaisesRegex(lab.LabError, "--install-system-packages"):
                lab.setup("/private")
            plan.assert_not_called()
            model.assert_not_called()

    def test_interrupted_stage_is_private_temporary_and_retryable(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            asset = lab.runtime.load_asset()
            attempts = []
            def prepare(archive, destination, chosen):
                attempts.append(destination)
                destination.mkdir()
                if len(attempts) == 1:
                    raise ValueError("interrupted archive")
            with mock.patch.object(lab.runtime, "load_asset", return_value=asset), \
                 mock.patch.object(lab.runtime, "prepare_asset", side_effect=prepare), \
                 mock.patch.object(lab.runtime, "verify_tree"):
                with self.assertRaisesRegex(ValueError, "interrupted archive"):
                    lab._stage(root, Path("/reviewed.tar.gz"))
                self.assertFalse((root / "engine").exists())
                self.assertEqual(list(root.iterdir()), [])
                self.assertEqual(lab._stage(root, Path("/reviewed.tar.gz")), root / "engine")
                self.assertTrue((root / "engine").is_dir())

    def test_tampered_candidate_manifest_rejects_before_download_or_stage(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            changed = root / "changed.json"
            changed.write_bytes(b'{"unreviewedUrl":"https://example.invalid/engine"}')
            with mock.patch.object(lab.runtime, "MANIFEST", changed), \
                 mock.patch.object(lab.runtime, "download_asset") as download, \
                 mock.patch.object(lab.runtime, "prepare_asset") as prepare:
                with self.assertRaisesRegex(lab.LabError, "reviewed bytes"):
                    lab._stage(root)
                download.assert_not_called()
                prepare.assert_not_called()

    def test_opted_in_package_flow_precedes_native_probe_and_model(self):
        calls = []
        item = {"id": "qwen", "contextSize": 8192, "sizeBytes": 100}
        def package_install(*args, **kwargs):
            calls.append("packages")
        def host_plan(*args, **kwargs):
            calls.append("probe-plan")
            return item, {"modelId": "qwen"}
        def model_ready(*args, **kwargs):
            calls.append("model")
            return {"sha256": "a" * 64}
        with mock.patch.object(lab, "_root", return_value=Path("/private")), \
             mock.patch.object(lab.models, "load_catalog", return_value={}), \
             mock.patch.object(lab, "_stage", return_value=Path("/private/engine")), \
             mock.patch.object(lab.ubuntu_packages, "check", return_value={"missing": ["libgomp1"]}), \
             mock.patch.object(lab.ubuntu_packages, "install", side_effect=package_install), \
             mock.patch.object(lab, "_host_plan", side_effect=host_plan), \
             mock.patch.object(lab.models, "_private_root", return_value=Path("/private/models")), \
             mock.patch.object(lab, "_model_ready", side_effect=model_ready), \
             mock.patch("sys.stdout", new_callable=io.StringIO):
            result = lab.setup("/private", install_system_packages=True)
        self.assertEqual(calls, ["packages", "probe-plan", "model"])
        self.assertEqual(result["modelId"], "qwen")

    def test_live_plan_requires_single_discrete_card_vulkan0_and_min_free(self):
        card = {"card": "card0", "recipeEligible": True, "vramFreeMiB": 22000}
        device = {"device": "Vulkan0", "name": "AMD Radeon RX 7900 XTX", "reportedFreeMiB": 19000}
        catalog = {"models": [{"id": "a", "autoEligible": True, "requiredFreeVramMiB": 18000,
                               "scores": {"balanced": 1}, "contextSize": 8192, "sizeBytes": 100,
                               "family": "qwen", "quantization": "q4", "artifactProvider": "test",
                               "upstreamModel": "test", "upstreamLicense": "test",
                               "upstreamLicenseUrl": "https://example.invalid/license",
                               "sha256": "a" * 64, "url": "https://example.invalid/model"}]}
        with mock.patch.object(lab.preview, "inventory", return_value=[card]), \
             mock.patch.object(lab.probe, "run", return_value={"fixture": False, "devices": [device]}), \
             mock.patch.object(lab.models, "_model", return_value=catalog["models"][0]):
            item, plan = lab._host_plan(Path("/stage"), catalog, "balanced", None)
            self.assertEqual(item["id"], "a")
            self.assertEqual(plan["conservativeFreeVramMiB"], 19000)
            self.assertFalse(plan["hardwareBindingVerified"])
        with mock.patch.object(lab.preview, "inventory", return_value=[card]), \
             mock.patch.object(lab.probe, "run", return_value={"fixture": True, "devices": [device]}):
            with self.assertRaises(lab.LabError):
                lab._host_plan(Path("/stage"), catalog, "balanced", None)
        with mock.patch.object(lab.preview, "inventory", return_value=[card]), \
             mock.patch.object(lab.probe, "run", return_value={"fixture": False, "devices": [dict(device, reportedFreeMiB=17000)]}), \
             mock.patch.object(lab.models, "_model", return_value=catalog["models"][0]):
            with self.assertRaises(lab.LabError):
                lab._host_plan(Path("/stage"), catalog, "balanced", "a")

    def test_live_lab_refuses_each_two_card_headline_pair(self):
        for label, name, free in (
            ("two 7900 XT", "AMD Radeon RX 7900 XT", 19900),
            ("two 7900 XTX", "AMD Radeon RX 7900 XTX", 23800),
            ("two R9700", "AMD Radeon AI PRO R9700", 32000),
        ):
            cards = [{"card": f"card{index}", "recipeEligible": True, "vramFreeMiB": free - 100 * index}
                     for index in range(2)]
            devices = [{"device": f"Vulkan{index}", "name": name, "reportedFreeMiB": free - 100 * index}
                       for index in range(2)]
            with self.subTest(pair=label), \
                 mock.patch.object(lab.preview, "inventory", return_value=cards), \
                 mock.patch.object(lab.probe, "run", return_value={"fixture": False, "devices": devices}):
                with self.assertRaisesRegex(lab.LabError, "exactly one"):
                    lab._host_plan(Path("/stage"), {"models": []}, "balanced", None)

    def test_new_license_requires_full_exact_typed_artifact_approval(self):
        item = {"id": "qwen"}
        review = {"licenseText": "Apache test text", "modelId": "qwen", "upstreamLicenseSha256": "a" * 64,
                  "upstreamRevision": "b" * 40, "conversionRepository": "repo", "conversionRevision": "c" * 40,
                  "artifactLicense": "Apache-2.0", "artifactSha256": "d" * 64,
                  "consentProvenanceSha256": "e" * 64}
        with mock.patch.object(lab.models, "preview_license", return_value=review), \
             mock.patch.object(lab.models, "acquire_model") as acquire, \
             mock.patch("sys.stdout", new_callable=io.StringIO) as output:
            with self.assertRaises(lab.LabError):
                lab._display_and_accept_for_root({}, item, Path("/cache"), confirm=lambda prompt: "ACCEPT qwen")
            acquire.assert_not_called()
            self.assertIn("Apache test text", output.getvalue())
            expected = "ACCEPT qwen " + "a" * 64 + " " + "e" * 64
            lab._display_and_accept_for_root({}, item, Path("/cache"), confirm=lambda prompt: expected)
            self.assertEqual(acquire.call_args.kwargs["reviewed_artifact_sha256"], "d" * 64)
            self.assertEqual(acquire.call_args.kwargs["reviewed_upstream_revision"], "b" * 40)

    def test_verified_cached_model_reused_without_license_fetch(self):
        item = {"id": "qwen", "sha256": "f" * 64}
        with mock.patch.object(lab.models, "_private_root", return_value=Path("/cache")), \
             mock.patch.object(lab.models, "_lock") as lock, \
             mock.patch.object(lab.serve, "verify_cached_model", return_value=(Path("/cache/qwen.gguf"), item)), \
             mock.patch.object(lab.models, "preview_license") as preview_license, \
             mock.patch.object(lab.models, "acquire_model") as acquire:
            result = lab._model_ready({}, item, Path("/cache"))
            self.assertTrue(result["reused"])
            preview_license.assert_not_called()
            acquire.assert_not_called()
            self.assertTrue(lock.called)

    def test_corrupt_cached_bytes_repair_under_exact_receipt_without_new_consent(self):
        item = {"id": "qwen", "sha256": "f" * 64}
        with mock.patch.object(lab.models, "_private_root", return_value=Path("/cache")), \
             mock.patch.object(lab.models, "_lock"), \
             mock.patch.object(lab.serve, "verify_cached_model", side_effect=lab.serve.ServeError("cached model SHA-256 differs")), \
             mock.patch.object(lab.models, "acquire_model", return_value={"reused": False}) as acquire, \
             mock.patch.object(lab.models, "preview_license") as preview_license:
            self.assertFalse(lab._model_ready({}, item, Path("/cache"))["reused"])
            self.assertIsNone(acquire.call_args.kwargs.get("accept_license_for"))
            preview_license.assert_not_called()

    def test_changed_receipt_requires_fresh_exact_review(self):
        item = {"id": "qwen", "sha256": "f" * 64}
        with mock.patch.object(lab.models, "_private_root", return_value=Path("/cache")), \
             mock.patch.object(lab.models, "_lock"), \
             mock.patch.object(lab.serve, "verify_cached_model", side_effect=lab.serve.ServeError("exact consent receipt or conversion provenance differs")), \
             mock.patch.object(lab.models, "acquire_model", side_effect=ValueError("consent receipt differs; renewed exact-provenance acceptance required")) as acquire, \
             mock.patch.object(lab, "_display_and_accept_for_root", return_value={"reviewed": True}) as review:
            self.assertTrue(lab._model_ready({}, item, Path("/cache"))["reviewed"])
            self.assertEqual(acquire.call_count, 1)
            review.assert_called_once()


if __name__ == "__main__":
    unittest.main()
