"""Linux source bootstrap and recipe checks using disposable local fixtures."""

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


linux = load(ROOT / "linux" / "fast-llm-linux.py", "fastllm_linux")
bootstrap = load(ROOT / "linux" / "bootstrap.py", "fastllm_bootstrap")


class LinuxDeliveryTests(unittest.TestCase):
    def test_inventory_and_balanced_recipe_use_shared_catalog(self):
        with tempfile.TemporaryDirectory() as folder:
            card = Path(folder) / "card0" / "device"
            card.mkdir(parents=True)
            (card / "vendor").write_text("0x1002")
            (card / "device").write_text("0x744c")
            (card / "mem_info_vram_total").write_text(str(24 * 1024**3))
            (card / "mem_info_vram_used").write_text(str(1024**3))
            (card / "driver").symlink_to(Path(folder) / "amdgpu")
            (Path(folder) / "amdgpu").mkdir()
            gpus = linux.inventory(Path(folder))
            catalog = json.loads((ROOT / "config" / "catalog.json").read_text())
            selected = linux.choose_recipe(catalog, gpus, "balanced")
            self.assertEqual(selected["modelId"], "qwen3.8-27b-ud-q4-k-m")
            self.assertEqual(selected["observedFreeVramMiB"], 23 * 1024)

    def test_no_recipe_without_reliable_free_vram(self):
        catalog = json.loads((ROOT / "config" / "catalog.json").read_text())
        self.assertIsNone(linux.choose_recipe(catalog, [{"card": "card0", "recipeEligible": False}], "balanced"))

    def test_two_headline_cards_preview_only_individual_gpu_capacity(self):
        catalog = json.loads((ROOT / "config" / "catalog.json").read_text())
        cases = (
            ("two 7900 XT", (19900, 19800), "qwen3.8-27b-ud-iq4-xs", "qwen3.8-27b-ud-iq4-xs"),
            ("two 7900 XTX", (23800, 23600), "qwen3.8-27b-ud-q4-k-m", "qwen3.8-27b-ud-q5-k-m"),
            ("two R9700", (32000, 31800), "qwen3.8-27b-ud-q6-k-m", "qwen3.8-27b-q8-0"),
        )
        for label, free_mib, balanced, quality in cases:
            cards = [{"card": f"card{index}", "recipeEligible": True, "vramFreeMiB": free}
                     for index, free in enumerate(free_mib)]
            for profile, expected in (("balanced", balanced), ("quality", quality)):
                with self.subTest(pair=label, profile=profile):
                    recipe = linux.choose_recipe(catalog, cards, profile)
                    self.assertEqual(recipe["modelId"], expected)
                    self.assertEqual(recipe["gpu"], "card0")
                    self.assertEqual(recipe["observedFreeVramMiB"], free_mib[0])
                    self.assertIn("unverified", recipe["qualification"])

    def test_unknown_pci_identity_never_gets_recipe_even_with_large_vram(self):
        with tempfile.TemporaryDirectory() as folder:
            card = Path(folder) / "card0" / "device"
            card.mkdir(parents=True)
            (card / "vendor").write_text("0x1002")
            (card / "device").write_text("0x13c0")
            (card / "mem_info_vram_total").write_text(str(32 * 1024**3))
            (card / "mem_info_vram_used").write_text("0")
            (card / "driver").symlink_to(Path(folder) / "amdgpu")
            (Path(folder) / "amdgpu").mkdir()
            gpus = linux.inventory(Path(folder))
            self.assertEqual(gpus[0]["discreteClassification"], "unknown")
            self.assertFalse(gpus[0]["recipeEligible"])
            self.assertIsNone(linux.choose_recipe(linux.load_catalog(ROOT / "config" / "catalog.json"), gpus, "balanced"))

    def test_r9700_pci_family_is_recognized_but_driver_is_required(self):
        with tempfile.TemporaryDirectory() as folder:
            card = Path(folder) / "card0" / "device"
            card.mkdir(parents=True)
            (card / "vendor").write_text("0x1002")
            (card / "device").write_text("0x7551")
            (card / "mem_info_vram_total").write_text(str(32 * 1024**3))
            (card / "mem_info_vram_used").write_text("0")
            gpu = linux.inventory(Path(folder))[0]
            self.assertEqual(gpu["discreteClassification"], "known-discrete-pci-family")
            self.assertFalse(gpu["recipeEligible"])
            (card / "driver").symlink_to(Path(folder) / "amdgpu")
            (Path(folder) / "amdgpu").mkdir()
            self.assertTrue(linux.inventory(Path(folder))[0]["recipeEligible"])

    def test_catalog_digest_mismatch_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            (folder / "catalog.json").write_text('{"models": []}')
            (folder / "catalog.sha256").write_text("0" * 64 + "  catalog.json\n")
            with self.assertRaisesRegex(ValueError, "mismatch"):
                linux.load_catalog(folder / "catalog.json")

    def test_cli_rejects_root_and_unmarked_fixture(self):
        with patch.object(linux.os, "geteuid", return_value=0), patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as root:
                linux.main(["doctor", "--fixture", "--sysfs-root", "/missing"])
            self.assertEqual(root.exception.code, 2)
        with patch.object(linux.os, "geteuid", return_value=1000), patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as alternate:
                linux.main(["recipes", "--sysfs-root", "/missing"])
            self.assertEqual(alternate.exception.code, 2)
        with patch.object(bootstrap.os, "geteuid", return_value=0), patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as root_bootstrap:
                bootstrap.main(["--source-url", "https://example.invalid/source.zip", "--sha256", "0" * 64, "--dest", "/tmp/example"])
            self.assertEqual(root_bootstrap.exception.code, 2)

    def test_fixture_output_is_marked_and_no_native_execution_command_exists(self):
        with patch.object(linux.os, "geteuid", return_value=1000), patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertEqual(linux.main(["recipes", "--fixture", "--sysfs-root", "/missing"]), 0)
            self.assertTrue(json.loads(output.getvalue())["fixture"])
        with patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as unavailable:
                linux.main(["probe-engine", "--fixture", "--sysfs-root", "/missing"])
            self.assertEqual(unavailable.exception.code, 2)

    def test_archive_rejects_traversal_and_symlink(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            with zipfile.ZipFile(folder / "bad.zip", "w") as archive:
                archive.writestr("repo/../escape", "bad")
            with self.assertRaisesRegex(ValueError, "unsafe"):
                bootstrap.unpack(folder / "bad.zip", folder / "dest")
            with zipfile.ZipFile(folder / "link.zip", "w") as archive:
                info = zipfile.ZipInfo("repo/link")
                info.create_system = 3
                info.external_attr = (0o120777 << 16)
                archive.writestr(info, "target")
            with self.assertRaisesRegex(ValueError, "non-regular"):
                bootstrap.unpack(folder / "link.zip", folder / "dest")

    def test_archive_hash_gate_and_expected_files(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive_path = folder / "source.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("repo/config/catalog.json", "{}")
                archive.writestr("repo/config/catalog.sha256", "0" * 64 + "  catalog.json\n")
                archive.writestr("repo/linux/fast-llm-linux.py", "# source")
                archive.writestr("repo/linux/models.py", "# model acquisition source")
                archive.writestr("repo/linux/prereqs.py", "# prerequisite report source")
                archive.writestr("repo/linux/probe.py", "# private probe source")
                archive.writestr("repo/linux/serve.py", "# private serving source")
                archive.writestr("repo/linux/lab.py", "# guided lab source")
                archive.writestr("repo/linux/ubuntu_packages.py", "# lab package source")
                archive.writestr("repo/linux/runtime.py", "# source")
                archive.writestr("repo/linux/engine-candidates.json", "{}")
            good = hashlib.sha256(archive_path.read_bytes()).hexdigest()
            with self.assertRaisesRegex(ValueError, "mismatch"):
                bootstrap.verify_archive(archive_path, "0" * 64)
            bootstrap.verify_archive(archive_path, good)
            bootstrap.unpack(archive_path, folder / "dest")
            self.assertTrue((folder / "dest" / "config" / "catalog.json").is_file())
            self.assertTrue((folder / "dest" / "linux" / "models.py").is_file())
            self.assertTrue((folder / "dest" / "linux" / "prereqs.py").is_file())
            self.assertTrue((folder / "dest" / "linux" / "probe.py").is_file())
            self.assertTrue((folder / "dest" / "linux" / "serve.py").is_file())
            self.assertTrue((folder / "dest" / "linux" / "lab.py").is_file())

    def test_archive_requires_model_acquisition_module(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive_path = folder / "source.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                for relative in ("config/catalog.json", "config/catalog.sha256",
                                 "linux/fast-llm-linux.py", "linux/prereqs.py", "linux/probe.py", "linux/runtime.py",
                                 "linux/serve.py", "linux/lab.py", "linux/ubuntu_packages.py", "linux/engine-candidates.json"):
                    archive.writestr("repo/" + relative, "fixture")
            with self.assertRaisesRegex(ValueError, "missing the expected"):
                bootstrap.unpack(archive_path, folder / "dest")

    def test_archive_requires_prerequisite_report_module(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive_path = folder / "source.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                for relative in ("config/catalog.json", "config/catalog.sha256",
                                 "linux/fast-llm-linux.py", "linux/models.py", "linux/probe.py", "linux/runtime.py",
                                 "linux/serve.py", "linux/lab.py", "linux/ubuntu_packages.py", "linux/engine-candidates.json"):
                    archive.writestr("repo/" + relative, "fixture")
            with self.assertRaisesRegex(ValueError, "missing the expected"):
                bootstrap.unpack(archive_path, folder / "dest")

    def test_archive_requires_private_probe_module(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive_path = folder / "source.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                for relative in ("config/catalog.json", "config/catalog.sha256",
                                 "linux/fast-llm-linux.py", "linux/models.py", "linux/prereqs.py",
                                 "linux/runtime.py", "linux/serve.py", "linux/lab.py", "linux/ubuntu_packages.py", "linux/engine-candidates.json"):
                    archive.writestr("repo/" + relative, "fixture")
            with self.assertRaisesRegex(ValueError, "missing the expected"):
                bootstrap.unpack(archive_path, folder / "dest")

    def test_archive_requires_private_serving_module_without_executing_it(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive_path = folder / "source.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                for relative in ("config/catalog.json", "config/catalog.sha256",
                                 "linux/fast-llm-linux.py", "linux/models.py", "linux/prereqs.py",
                                 "linux/probe.py", "linux/runtime.py", "linux/lab.py", "linux/ubuntu_packages.py", "linux/engine-candidates.json"):
                    archive.writestr("repo/" + relative, "fixture")
            with self.assertRaisesRegex(ValueError, "missing the expected"):
                bootstrap.unpack(archive_path, folder / "dest")

    def test_archive_requires_guided_lab_and_package_modules(self):
        for omitted in ("linux/lab.py", "linux/ubuntu_packages.py"):
            with self.subTest(omitted=omitted), tempfile.TemporaryDirectory() as folder:
                folder = Path(folder)
                archive_path = folder / "source.zip"
                with zipfile.ZipFile(archive_path, "w") as archive:
                    for relative in ("config/catalog.json", "config/catalog.sha256", "linux/fast-llm-linux.py",
                                     "linux/models.py", "linux/prereqs.py", "linux/probe.py", "linux/runtime.py",
                                     "linux/serve.py", "linux/lab.py", "linux/ubuntu_packages.py", "linux/engine-candidates.json"):
                        if relative != omitted:
                            archive.writestr("repo/" + relative, "fixture")
                with self.assertRaisesRegex(ValueError, "missing the expected"):
                    bootstrap.unpack(archive_path, folder / "dest")

    def test_source_url_and_redirect_require_https(self):
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            bootstrap.require_https("http://example.invalid/source.zip")
        with self.assertRaisesRegex(ValueError, "HTTPS"):
            bootstrap.HttpsRedirect().redirect_request(None, None, 302, "", {}, "http://example.invalid/source.zip")

    def test_archive_rejects_noncanonical_and_duplicate_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            for invalid in ("repo/./bad", "repo//bad"):
                with zipfile.ZipFile(folder / "bad.zip", "w") as archive:
                    archive.writestr(invalid, "x")
                with self.assertRaisesRegex(ValueError, "unsafe"):
                    bootstrap.unpack(folder / "bad.zip", folder / "tree")
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(folder / "dupe.zip", "w") as archive:
                    archive.writestr("repo/config/catalog.json", "a")
                    archive.writestr("repo/config/catalog.json", "b")
            with self.assertRaisesRegex(ValueError, "duplicate"):
                bootstrap.unpack(folder / "dupe.zip", folder / "tree")

    def test_download_wall_clock_deadline(self):
        class SlowResponse:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def read1(self, _):
                return b"x"

        class FakeOpener:
            def open(self, *_args, **_kwargs):
                return SlowResponse()

        with tempfile.TemporaryDirectory() as folder:
            with patch.object(bootstrap.urllib.request, "build_opener", return_value=FakeOpener()), patch.object(bootstrap.time, "monotonic", side_effect=[0, 121]):
                with self.assertRaisesRegex(ValueError, "deadline"):
                    bootstrap.fetch("https://example.invalid/source.zip", Path(folder) / "source.zip")


if __name__ == "__main__":
    unittest.main()
