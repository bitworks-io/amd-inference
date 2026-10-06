"""Source-only public staging boundary tests; no network or publication."""

from __future__ import annotations

import importlib.util
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "tools/stage-public-source.py"
SPEC = importlib.util.spec_from_file_location("fastllm_public_stage", SCRIPT)
STAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAGE)


class PublicSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "internal"
        self.source.mkdir()
        for directory in STAGE.SOURCE_DIRS:
            (self.source / directory).mkdir()
        for relative in STAGE.ROOT_FILES + STAGE.PUBLIC_DOCS:
            self.put(relative, f"reviewed {relative}\n".encode())
        self.put(".gitattributes", b"* -text\n")
        self.put("src/core.psm1", b"function Invoke-Test {}\n")
        self.put("config/catalog.json", b'{\n  "engine": "pinned"\n}\n')
        self.put("linux/serve.py", b"# reviewed source\n")
        self.put("tests/fixtures/llama-list-devices.txt", b"Vulkan0: Test GPU\n")
        self.put("tools/benchmark.ps1", b"# reproducible benchmark\n")
        self.put("tools/stage-public-source.py", b"# staging source\n")

    def put(self, relative, payload):
        target = self.source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)

    def test_source_only_mapping_and_content_manifest(self):
        private_paths = (
            "docs/lab-results/BENCH-1.md",
            "docs/bitworks/outbox/internal.md",
            "docs/DELIVERY-PLAN.md",
            "results/private.json",
            "dist/engine.zip",
            "downloads/model.gguf",
            "tools/test-client.pub",
            "src/native.dll",
            "tests/fixture.exe",
            "tests/test_community_coverage.py",
            "config/private.env",
            "tools/notes.txt",
            "tools/__pycache__/cached.py",
        )
        for relative in private_paths:
            self.put(relative, b"MUST NOT EXPORT\n")
        output = self.base / "public"
        manifest = STAGE.stage(self.source, output)
        paths = {entry["path"] for entry in manifest["files"]}
        self.assertEqual(paths, {
            *STAGE.ROOT_FILES, *STAGE.PUBLIC_DOCS, "README.md",
            "src/core.psm1", "config/catalog.json", "linux/serve.py",
            "tests/fixtures/llama-list-devices.txt", "tools/benchmark.ps1",
            "tools/stage-public-source.py",
        })
        self.assertEqual((output / "README.md").read_bytes(),
                         (self.source / "docs/PUBLIC-README.md").read_bytes())
        self.assertNotEqual((output / "README.md").read_bytes(), b"internal README\n")
        self.assertFalse((output / "docs/lab-results").exists())
        self.assertFalse((output / "docs/bitworks").exists())
        self.assertEqual(manifest["files"], sorted(manifest["files"], key=lambda item: item["path"]))
        self.assertEqual(json.loads((output / STAGE.MANIFEST_NAME).read_text()), manifest)
        self.assertNotIn(str(self.source), (output / STAGE.MANIFEST_NAME).read_text())
        for item in manifest["files"]:
            payload = (output / item["path"]).read_bytes()
            self.assertEqual(item["sizeBytes"], len(payload))
            self.assertEqual(item["sha256"], hashlib.sha256(payload).hexdigest())
        second = STAGE.stage(self.source, self.base / "public-again")
        self.assertEqual(second, manifest)

    def test_existing_output_is_never_modified(self):
        output = self.base / "public"
        output.mkdir()
        sentinel = output / "retain.txt"
        sentinel.write_text("owner data")
        with self.assertRaisesRegex(ValueError, "nonexistent"):
            STAGE.stage(self.source, output)
        self.assertEqual(sentinel.read_text(), "owner data")

    def test_symlink_anywhere_under_source_directory_rejected(self):
        outside = self.base / "outside.txt"
        outside.write_text("private data")
        link = self.source / "src" / "innocent.ps1"
        try:
            link.symlink_to(outside)
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"symlinks unavailable: {exc}")
        output = self.base / "public"
        with self.assertRaisesRegex(ValueError, "symlink"):
            STAGE.stage(self.source, output)
        self.assertFalse(output.exists())

    def test_required_public_document_is_not_optional(self):
        (self.source / "docs/PUBLIC-LAB-GUIDE.md").unlink()
        with self.assertRaisesRegex(ValueError, "required source"):
            STAGE.stage(self.source, self.base / "public")

    def test_symlinked_source_directory_rejected(self):
        outside = self.base / "outside-dir"
        outside.mkdir()
        link = self.source / "tools" / "linked-dir"
        try:
            link.symlink_to(outside, target_is_directory=True)
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"symlinks unavailable: {exc}")
        with self.assertRaisesRegex(ValueError, "symlink"):
            STAGE.stage(self.source, self.base / "public")

    def test_output_inside_source_rejected(self):
        with self.assertRaisesRegex(ValueError, "outside"):
            STAGE.stage(self.source, self.source / "public")

    def test_dotdot_output_inside_source_rejected(self):
        (self.source / "nested").mkdir()
        with self.assertRaisesRegex(ValueError, "outside"):
            STAGE.stage(self.source, self.source / "nested" / ".." / "public")
        self.assertFalse((self.source / "public").exists())

    def test_symlinked_output_parent_into_source_rejected(self):
        link = self.base / "alias"
        try:
            link.symlink_to(self.source, target_is_directory=True)
        except (NotImplementedError, OSError) as exc:
            self.skipTest(f"symlinks unavailable: {exc}")
        with self.assertRaisesRegex(ValueError, "outside"):
            STAGE.stage(self.source, link / "public")
        self.assertFalse((self.source / "public").exists())

    def test_autocrlf_checkout_preserves_exact_catalog_and_manifest_bytes(self):
        if shutil.which("git") is None:
            self.skipTest("git is unavailable")
        staged = self.base / "staged"
        STAGE.stage(self.source, staged)
        expected_catalog = (staged / "config/catalog.json").read_bytes()
        expected_manifest = (staged / STAGE.MANIFEST_NAME).read_bytes()
        subprocess.run(["git", "init", "-q", str(staged)], check=True)
        subprocess.run(["git", "-C", str(staged), "-c", "core.autocrlf=false", "add", "."], check=True)
        subprocess.run(["git", "-C", str(staged), "-c", "user.name=FastLLM test",
                        "-c", "user.email=test@example.invalid", "commit", "-qm", "source fixture"], check=True)
        checked_out = self.base / "autocrlf-true-checkout"
        subprocess.run(["git", "-c", "core.autocrlf=true", "clone", "-q",
                        str(staged), str(checked_out)], check=True)
        self.assertEqual((checked_out / "config/catalog.json").read_bytes(), expected_catalog)
        self.assertEqual((checked_out / STAGE.MANIFEST_NAME).read_bytes(), expected_manifest)

    def test_real_catalog_pin_survives_autocrlf_checkout(self):
        if shutil.which("git") is None:
            self.skipTest("git is unavailable")
        staged = self.base / "real-staged"
        manifest = STAGE.stage(SCRIPT.parents[1], staged)
        catalog_digest = "65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6"
        self.assertEqual(hashlib.sha256((staged / "config/catalog.json").read_bytes()).hexdigest(), catalog_digest)
        subprocess.run(["git", "init", "-q", str(staged)], check=True)
        subprocess.run(["git", "-C", str(staged), "-c", "core.autocrlf=false", "add", "."], check=True)
        subprocess.run(["git", "-C", str(staged), "-c", "user.name=FastLLM test",
                        "-c", "user.email=test@example.invalid", "commit", "-qm", "source fixture"], check=True)
        checked_out = self.base / "real-autocrlf-true-checkout"
        subprocess.run(["git", "-c", "core.autocrlf=true", "clone", "-q",
                        str(staged), str(checked_out)], check=True)
        self.assertEqual(hashlib.sha256((checked_out / "config/catalog.json").read_bytes()).hexdigest(), catalog_digest)
        self.assertEqual((checked_out / STAGE.MANIFEST_NAME).read_bytes(),
                         (staged / STAGE.MANIFEST_NAME).read_bytes())
        for item in manifest["files"]:
            payload = (checked_out / item["path"]).read_bytes()
            self.assertEqual(len(payload), item["sizeBytes"], item["path"])
            self.assertEqual(hashlib.sha256(payload).hexdigest(), item["sha256"], item["path"])


if __name__ == "__main__":
    unittest.main()
