"""Linux source bootstrap and recipe checks using disposable local fixtures."""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
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
COMMIT = "a" * 40
SOURCE_URL = f"https://github.com/bitworks-io/amd-inference/archive/{COMMIT}.zip"


def source_fixture(archive, overrides=None, extra=None, manifest_mutator=None):
    files = {
        "config/catalog.json": b"{}",
        "config/catalog.sha256": b"0" * 64 + b"  catalog.json\n",
        "linux/fast-llm-linux.py": b"# source",
        "linux/models.py": b"# source",
        "linux/prereqs.py": b"# source",
        "linux/probe.py": b"# source",
        "linux/serve.py": b"# source",
        "linux/lab.py": b"# source",
        "linux/ubuntu_packages.py": b"# source",
        "linux/runtime.py": b"# source",
        "linux/engine-candidates.json": b"{}",
    }
    files.update(overrides or {})
    manifest = {"schemaVersion": 1, "kind": "source-only-public-staging", "files": [
        {"path": path, "sizeBytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}
        for path, payload in files.items()]}
    if manifest_mutator is not None:
        manifest_mutator(manifest)
    with zipfile.ZipFile(archive, "w") as package:
        for path, payload in files.items():
            package.writestr("repo/" + path, payload)
        package.writestr("repo/PUBLIC-SOURCE-MANIFEST.json", json.dumps(manifest))
        for path, payload in (extra or {}).items():
            package.writestr("repo/" + path, payload)


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
                bootstrap.main(["--source-url", SOURCE_URL, "--sha256", "0" * 64,
                                "--source-bytes", "100", "--dest", "/tmp/example"])
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
            source_fixture(archive_path)
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

    def test_manifest_rejects_extra_missing_and_altered_files(self):
        cases = (
            ("extra", {}, {"linux/unlisted.py": b"extra"}, None, "file set"),
            ("altered", {"linux/models.py": b"altered"}, {},
             lambda manifest: manifest["files"][3].update(sha256="0" * 64), "SHA-256"),
            ("missing-entry", {}, {},
             lambda manifest: manifest["files"].pop(), "file set"),
            ("duplicate-entry", {}, {},
             lambda manifest: manifest["files"].append(dict(manifest["files"][0])), "duplicate"),
        )
        for label, overrides, extra, mutate, error in cases:
            with self.subTest(case=label), tempfile.TemporaryDirectory() as folder:
                folder = Path(folder)
                source_fixture(folder / "source.zip", overrides, extra, mutate)
                with self.assertRaisesRegex(ValueError, error):
                    bootstrap.unpack(folder / "source.zip", folder / "tree")

    def test_manifest_itself_is_required_before_source_promotion(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            package = folder / "source.zip"
            source_fixture(package)
            with zipfile.ZipFile(package) as original, zipfile.ZipFile(folder / "missing.zip", "w") as missing:
                for member in original.infolist():
                    if not member.filename.endswith("PUBLIC-SOURCE-MANIFEST.json"):
                        missing.writestr(member, original.read(member))
            with self.assertRaisesRegex(ValueError, "public source manifest"):
                bootstrap.unpack(folder / "missing.zip", folder / "tree")

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
            bootstrap.HttpsRedirect(COMMIT).redirect_request(None, None, 302, "", {}, "http://example.invalid/source.zip")
        self.assertEqual(bootstrap.source_commit(SOURCE_URL), COMMIT)
        for invalid in ("https://github.com/bitworks-io/amd-inference/archive/main.zip",
                        SOURCE_URL + "?token=x", SOURCE_URL.replace("github.com", "evil.example"),
                        SOURCE_URL.replace("github.com", "github.com:443")):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                bootstrap.source_commit(invalid)
        handler = bootstrap.HttpsRedirect(COMMIT)
        with self.assertRaisesRegex(ValueError, "reviewed GitHub"):
            handler.redirect_request(None, None, 302, "", {}, "https://evil.example/file.zip")
        with self.assertRaisesRegex(ValueError, "reviewed GitHub"):
            bootstrap.HttpsRedirect(COMMIT).redirect_request(None, None, 302, "", {},
                                                             "https://codeload.github.com/bitworks-io/amd-inference/zip/" + "b" * 40)
        handler = bootstrap.HttpsRedirect(COMMIT)
        for _ in range(3):
            with patch.object(bootstrap.urllib.request.HTTPRedirectHandler, "redirect_request", return_value=None):
                handler.redirect_request(None, None, 302, "", {},
                                         f"https://codeload.github.com/bitworks-io/amd-inference/zip/{COMMIT}")
        with self.assertRaisesRegex(ValueError, "redirect ceiling"):
            handler.redirect_request(None, None, 302, "", {},
                                     f"https://codeload.github.com/bitworks-io/amd-inference/zip/{COMMIT}")

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
            with patch.object(bootstrap.urllib.request, "build_opener", return_value=FakeOpener()), patch.object(bootstrap.time, "monotonic", side_effect=[0, 0, 121]):
                with self.assertRaisesRegex(ValueError, "deadline"):
                    bootstrap.fetch(SOURCE_URL, Path(folder) / "source.zip", 2)
            self.assertFalse((Path(folder) / "source.zip").exists())

    def test_download_exact_length_and_partial_cleanup(self):
        class Response:
            headers = {}

            def __init__(self, blocks):
                self.blocks = iter(blocks)

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def read1(self, _):
                return next(self.blocks, b"")

        class Opener:
            def __init__(self, blocks):
                self.blocks = blocks

            def open(self, *_args, **_kwargs):
                return Response(self.blocks)

        for label, blocks, expected, error in (
                ("short", [b"ab"], 3, "shorter"),
                ("long", [b"abcd"], 3, "exceeds")):
            with self.subTest(case=label), tempfile.TemporaryDirectory() as folder:
                target = Path(folder) / "source.zip"
                with patch.object(bootstrap.urllib.request, "build_opener", return_value=Opener(blocks)):
                    with self.assertRaisesRegex(ValueError, error):
                        bootstrap.fetch(SOURCE_URL, target, expected)
                self.assertFalse(target.exists())
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder) / "source.zip"
            target.write_bytes(b"preexisting")
            with patch.object(bootstrap.urllib.request, "build_opener", return_value=Opener([b"abc"])):
                with self.assertRaises(FileExistsError):
                    bootstrap.fetch(SOURCE_URL, target, 3)
            self.assertEqual(target.read_bytes(), b"preexisting")

    def test_continuation_refuses_unsupported_host_before_fetch(self):
        with tempfile.TemporaryDirectory() as folder:
            archive = Path(folder) / "source.zip"
            source_fixture(archive)
            args = ["--source-url", SOURCE_URL, "--sha256", hashlib.sha256(archive.read_bytes()).hexdigest(),
                    "--source-bytes", str(archive.stat().st_size), "--dest", str(Path(folder) / "installed"),
                    "--continue-lab", "start"]
            with patch.object(bootstrap.os, "geteuid", return_value=1000), \
                    patch.object(bootstrap.platform, "system", return_value="Darwin"), \
                    patch.object(bootstrap, "fetch") as fetch, patch("sys.stderr", new_callable=io.StringIO):
                with self.assertRaises(SystemExit) as stopped:
                    bootstrap.main(args)
                self.assertEqual(stopped.exception.code, 2)
                fetch.assert_not_called()
            with patch.object(bootstrap.os, "geteuid", return_value=0), \
                    patch.object(bootstrap.platform, "system", return_value="Linux"), \
                    patch.object(bootstrap.platform, "machine", return_value="x86_64"), \
                    patch.object(bootstrap, "fetch") as fetch, patch("sys.stderr", new_callable=io.StringIO):
                with self.assertRaises(SystemExit) as stopped:
                    bootstrap.main(args)
                self.assertEqual(stopped.exception.code, 2)
                fetch.assert_not_called()

    def test_other_user_writable_install_parent_stops_before_fetch(self):
        if os.geteuid() == 0:
            self.skipTest("directory ownership test requires a standard user")
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive = folder / "source.zip"
            source_fixture(archive)
            args = ["--source-url", SOURCE_URL, "--sha256", hashlib.sha256(archive.read_bytes()).hexdigest(),
                    "--source-bytes", str(archive.stat().st_size), "--dest", str(folder / "installed"),
                    "--continue-lab", "start"]
            folder.chmod(0o777)
            try:
                with patch.object(bootstrap.platform, "system", return_value="Linux"), \
                        patch.object(bootstrap.platform, "machine", return_value="x86_64"), \
                        patch.object(bootstrap, "fetch") as fetch, patch("sys.stderr", new_callable=io.StringIO):
                    with self.assertRaises(SystemExit) as stopped:
                        bootstrap.main(args)
                    self.assertEqual(stopped.exception.code, 2)
                    fetch.assert_not_called()
            finally:
                folder.chmod(0o700)

    def test_continuation_executes_only_fixed_mock_lab_after_verification(self):
        if os.geteuid() == 0:
            self.skipTest("real-child source ownership test requires a standard user")
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            capture = folder / "child-result.json"
            mock_lab = ("import json, signal, sys\nfrom pathlib import Path\nsignal.alarm(5)\n"
                        "Path(%r).write_text(json.dumps({'argv': sys.argv[1:], "
                        "'isolated': sys.flags.isolated, 'noBytecode': sys.dont_write_bytecode}))\n"
                        "raise SystemExit(7)\n") % str(capture)
            archive = folder / "source.zip"
            source_fixture(archive, {"linux/lab.py": mock_lab.encode()})
            target = folder / "installed"
            args = ["--source-url", SOURCE_URL, "--sha256", hashlib.sha256(archive.read_bytes()).hexdigest(),
                    "--source-bytes", str(archive.stat().st_size), "--dest", str(target),
                    "--continue-lab", "setup"]

            def fixture_fetch(_url, destination, _size):
                shutil.copyfile(archive, destination)

            with patch.object(bootstrap.platform, "system", return_value="Linux"), \
                    patch.object(bootstrap.platform, "machine", return_value="x86_64"), \
                    patch.object(bootstrap, "fetch", side_effect=fixture_fetch), \
                    patch.object(bootstrap, "_parent_death", return_value=None), \
                    patch("sys.stdout", new_callable=io.StringIO) as output:
                self.assertEqual(bootstrap.main(args), 7)
            self.assertEqual(json.loads(capture.read_text()),
                             {"argv": ["setup", "--lab"], "isolated": 1, "noBytecode": True})
            bootstrap.verify_launch_tree(target.resolve())
            self.assertTrue(target.is_dir())
            self.assertNotIn("No engine, driver, model", output.getvalue())

    def test_default_source_install_does_not_launch_lab(self):
        if os.geteuid() == 0:
            self.skipTest("source install test requires a standard user")
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive = folder / "source.zip"
            source_fixture(archive)
            target = folder / "installed"
            args = ["--source-url", SOURCE_URL, "--sha256", hashlib.sha256(archive.read_bytes()).hexdigest(),
                    "--source-bytes", str(archive.stat().st_size), "--dest", str(target)]
            with patch.object(bootstrap, "fetch", side_effect=lambda _u, d, _n: shutil.copyfile(archive, d)), \
                    patch.object(bootstrap.subprocess, "Popen") as child, \
                    patch("sys.stdout", new_callable=io.StringIO) as output:
                self.assertEqual(bootstrap.main(args), 0)
            child.assert_not_called()
            self.assertTrue(target.is_dir())
            self.assertIn("No engine, driver, model", output.getvalue())

    def test_tampered_source_and_unsafe_permissions_block_continuation(self):
        if os.geteuid() == 0:
            self.skipTest("source ownership test requires a standard user")
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive = folder / "source.zip"
            source_fixture(archive)
            target = folder / "installed"
            target.mkdir(mode=0o700)
            target = target.resolve()
            bootstrap.unpack(archive, target)
            (target / "linux" / "lab.py").write_bytes(b"tampered")
            with patch.object(bootstrap.subprocess, "Popen") as child:
                with self.assertRaisesRegex(ValueError, "SHA-256"):
                    bootstrap.continue_lab(target, "start")
                child.assert_not_called()
            (target / "linux" / "lab.py").chmod(0o666)
            with patch.object(bootstrap.subprocess, "Popen") as child:
                with self.assertRaisesRegex(ValueError, "unsafe owner or writable member"):
                    bootstrap.continue_lab(target, "start")
                child.assert_not_called()

    def test_hash_and_manifest_failures_never_continue(self):
        if os.geteuid() == 0:
            self.skipTest("source install test requires a standard user")
        for label, extra, expected_hash, error in (
                ("hash", {}, "0" * 64, "SHA-256 mismatch"),
                ("manifest", {"unlisted.py": b"extra"}, None, "file set mismatch")):
            with self.subTest(case=label), tempfile.TemporaryDirectory() as folder:
                folder = Path(folder)
                archive = folder / "source.zip"
                source_fixture(archive, extra=extra)
                target = folder / "installed"
                args = ["--source-url", SOURCE_URL,
                        "--sha256", expected_hash or hashlib.sha256(archive.read_bytes()).hexdigest(),
                        "--source-bytes", str(archive.stat().st_size), "--dest", str(target),
                        "--continue-lab", "start"]
                with patch.object(bootstrap.platform, "system", return_value="Linux"), \
                        patch.object(bootstrap.platform, "machine", return_value="x86_64"), \
                        patch.object(bootstrap, "fetch", side_effect=lambda _u, d, _n: shutil.copyfile(archive, d)), \
                        patch.object(bootstrap.subprocess, "Popen") as child:
                    with self.assertRaisesRegex(ValueError, error):
                        bootstrap.main(args)
                    child.assert_not_called()
                self.assertFalse(target.exists())

    def test_postpromotion_change_blocks_continuation(self):
        if os.geteuid() == 0:
            self.skipTest("source install test requires a standard user")
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive = folder / "source.zip"
            source_fixture(archive)
            target = folder / "installed"
            args = ["--source-url", SOURCE_URL, "--sha256", hashlib.sha256(archive.read_bytes()).hexdigest(),
                    "--source-bytes", str(archive.stat().st_size), "--dest", str(target),
                    "--continue-lab", "start"]
            seal = bootstrap._seal_source_tree

            def tamper_after_verification(stage):
                seal(stage)
                (stage / "linux" / "lab.py").write_bytes(b"tampered")

            with patch.object(bootstrap.platform, "system", return_value="Linux"), \
                    patch.object(bootstrap.platform, "machine", return_value="x86_64"), \
                    patch.object(bootstrap, "fetch", side_effect=lambda _u, d, _n: shutil.copyfile(archive, d)), \
                    patch.object(bootstrap, "_seal_source_tree", side_effect=tamper_after_verification), \
                    patch.object(bootstrap.subprocess, "Popen") as child, \
                    patch("sys.stdout", new_callable=io.StringIO):
                with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                    bootstrap.main(args)
                child.assert_not_called()
            self.assertTrue(target.exists())  # retained for exact inspection/retry elsewhere

    def test_internal_continuation_rejects_arbitrary_action(self):
        with patch.object(bootstrap.subprocess, "Popen") as child:
            with self.assertRaisesRegex(ValueError, "not allowed"):
                bootstrap.continue_lab(Path("/unused"), "custom")
            child.assert_not_called()

    def test_continuation_binds_original_parent_before_spawn(self):
        child = unittest.mock.Mock(pid=8126)
        child.wait.return_value = 0
        with patch.object(bootstrap, "verify_launch_tree"), \
                patch.object(bootstrap.subprocess, "Popen", return_value=child) as launched:
            self.assertEqual(bootstrap.continue_lab(Path("/fixed"), "setup"), 0)
        options = launched.call_args.kwargs
        self.assertIs(options["preexec_fn"].func, bootstrap._parent_death)
        self.assertEqual(options["preexec_fn"].args, (os.getpid(),))
        self.assertEqual(launched.call_args.args[0][1:3], ["-I", "-B"])

    @unittest.skipUnless(sys.platform.startswith("linux") and Path("/proc").is_dir(),
                         "requires Linux parent-death signaling and procfs")
    def test_bootstrap_death_stops_live_disposable_lab_child(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive = folder / "fixture.zip"
            mock_lab = ("import os, time\nprint('READY', os.getpid(), flush=True)\n"
                        "time.sleep(30)\n")
            source_fixture(archive, {"linux/lab.py": mock_lab.encode()})
            target = folder / "installed"
            target.mkdir(mode=0o700)
            target = target.resolve()
            bootstrap.unpack(archive, target)
            bootstrap._seal_source_tree(target)
            source = str(ROOT / "linux" / "bootstrap.py")
            parent_script = (
                "import importlib.util, pathlib\n"
                f"s=importlib.util.spec_from_file_location('bootstrap_parent_test',{source!r})\n"
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m)\n"
                f"raise SystemExit(m.continue_lab(pathlib.Path({str(target)!r}),'setup'))\n"
            )
            parent = subprocess.Popen([sys.executable, "-I", "-B", "-c", parent_script],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      text=True, start_new_session=True)
            child_pid = None
            try:
                ready, _, _ = select.select([parent.stdout], [], [], 5)
                self.assertTrue(ready, "fixture lab child did not report readiness")
                reported = parent.stdout.readline().strip().split()
                self.assertEqual(reported[0], "READY")
                child_pid = int(reported[1])
                self.assertIsNone(parent.poll(), "bootstrap exited before the deliberate kill")
                self.assertNotEqual(Path(f"/proc/{child_pid}/stat").read_text().split()[2], "Z")
                parent.kill()  # no graceful forwarding: only PDEATHSIG can stop the child
                parent.wait(timeout=5)
                stopped = False
                for _ in range(100):
                    status = Path(f"/proc/{child_pid}/stat")
                    if not status.exists() or status.read_text().split()[2] == "Z":
                        stopped = True
                        break
                    time.sleep(0.05)
                self.assertTrue(stopped, "lab child survived bootstrap SIGKILL")
            finally:
                if parent.poll() is None:
                    parent.kill()
                    parent.wait(timeout=5)
                parent.stdout.close()
                parent.stderr.close()
                if child_pid is not None:
                    try:
                        os.killpg(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux prctl")
    def test_bootstrap_parent_death_setup_fails_closed_on_wrong_pid(self):
        child = subprocess.run([sys.executable, "-c", "raise SystemExit(0)"], timeout=5,
                               preexec_fn=lambda: bootstrap._parent_death(os.getpid() + 1))
        self.assertEqual(child.returncode, 127)


if __name__ == "__main__":
    unittest.main()
