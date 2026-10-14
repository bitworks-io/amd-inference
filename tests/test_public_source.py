"""Source-only public staging boundary tests; no network or publication."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
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
        self.put("tests/fixtures/catalog-shape.json", b'{"reviewed":true}\n')
        self.put("tests/helpers/mock-api.ps1", b"# reviewed test helper\n")
        self.put("tools/benchmark.ps1", b"# reproducible benchmark\n")
        self.put("tools/stage-public-source.py", b"# staging source\n")
        # PRIVATE_TEST_FILES entries must exist in their exact case outside a public re-staging (stale-constant check).
        self.put("tests/test_community_coverage.py", b"# private editorial test\n")
        # The internal-only list is required (fail closed): a non-empty list whose listed file exists.
        self.put("src/Internal.Example.ps1", b"# listed\n")
        self.write_exclusions({"files": ["src/Internal.Example.ps1"], "directoryPrefixes": []})

    def put(self, relative, payload):
        target = self.source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(payload)

    def test_source_only_mapping_and_content_manifest(self):
        private_paths = (
            ".github/workflows/replica-private.yml",
            "docs/private-notes/EXAMPLE.md",
            "docs/private-notes/outbox/internal.md",
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
            "tests/fixtures/llama-list-devices.txt", "tests/fixtures/catalog-shape.json",
            "tests/helpers/mock-api.ps1", "tools/benchmark.ps1",
            "tools/stage-public-source.py",
        })
        self.assertEqual((output / "README.md").read_bytes(),
                         (self.source / "docs/PUBLIC-README.md").read_bytes())
        self.assertNotEqual((output / "README.md").read_bytes(), b"internal README\n")
        self.assertFalse((output / "docs/private-notes").exists())
        self.assertEqual(manifest["files"], sorted(manifest["files"], key=lambda item: item["path"]))
        self.assertEqual(json.loads((output / STAGE.MANIFEST_NAME).read_text()), manifest)
        self.assertNotIn(str(self.source), (output / STAGE.MANIFEST_NAME).read_text())
        for item in manifest["files"]:
            payload = (output / item["path"]).read_bytes()
            self.assertEqual(item["sizeBytes"], len(payload))
            self.assertEqual(item["sha256"], hashlib.sha256(payload).hexdigest())
        second = STAGE.stage(self.source, self.base / "public-again")
        self.assertEqual(second, manifest)

    def test_generated_test_trees_and_top_level_reports_stay_private(self):
        private = (
            "tests/gateway-task-tests-a0b83df2f7094103af56cdef07551433/complete.json",
            "tests/gateway-task-tests-a0b83df2f7094103af56cdef07551433/nested/trace.md",
            "tests/other-scratch/fixture-looking.json",
            "tests/fixtures/generated/run.json",
            "tests/helpers/temp/response.ps1",
            "tests/complete.json",
        )
        for relative in private:
            self.put(relative, b'{"privateLocalPath":"C:\\Users\\bench\\model.gguf"}\n')
        self.put("tests/gateway-task-quality-tests.ps1", b"# real top-level source test\n")
        output = self.base / "public"
        manifest = STAGE.stage(self.source, output)
        paths = {entry["path"] for entry in manifest["files"]}
        for relative in private:
            self.assertNotIn(relative, paths)
            self.assertFalse((output / relative).exists())
        self.assertIn("tests/gateway-task-quality-tests.ps1", paths)
        self.assertIn("tests/fixtures/catalog-shape.json", paths)
        self.assertIn("tests/helpers/mock-api.ps1", paths)
        self.assertNotIn("C:\\Users\\bench", (output / STAGE.MANIFEST_NAME).read_text())

    def write_exclusions(self, document):
        self.put("ops/public-export/internal-only.json", json.dumps(document).encode())

    def test_listed_files_and_prefixes_are_never_staged(self):
        listed = ("src/Internal.Example.ps1", "tools/internal-example.ps1", "tests/internal-example-tests.ps1")
        self.write_exclusions({"files": list(listed), "directoryPrefixes": ["src/example-vector/"]})
        for relative in listed:
            self.put(relative, b"# listed\n")
        self.put("src/example-vector/data.json", b'{"listed":true}\n')
        self.put("src/example-vector/nested/deep.json", b'{"listed":true}\n')
        self.put("ops/notes.txt", b"never a source directory\n")
        output = self.base / "public"
        manifest = STAGE.stage(self.source, output)
        paths = {entry["path"] for entry in manifest["files"]}
        for relative in listed + ("src/example-vector/data.json", "src/example-vector/nested/deep.json", "ops/public-export/internal-only.json", "ops/notes.txt"):
            self.assertNotIn(relative, paths)
            self.assertFalse((output / relative).exists())
        self.assertIn("tools/benchmark.ps1", paths)
        self.assertIn("tests/fixtures/catalog-shape.json", paths)

    def test_ops_without_the_list_refuses(self):
        (self.source / "ops/public-export/internal-only.json").unlink()
        self.put("ops/notes.txt", b"private\n")
        output = self.base / "public"
        with self.assertRaisesRegex(ValueError, "missing or malformed"):
            STAGE.stage(self.source, output)
        self.assertFalse(output.exists())

    def test_malformed_list_refuses(self):
        for payload in (b"not json", b"[]", b'{"files": []}', b'{"files": "x", "directoryPrefixes": []}',
                        b'{"files": ["/abs.ps1"], "directoryPrefixes": []}',
                        b'{"files": ["../up.ps1"], "directoryPrefixes": []}',
                        b'{"files": [], "directoryPrefixes": ["no-trailing-slash"]}',
                        b'{"files": ["ends/with/slash/"], "directoryPrefixes": []}',
                        b'{"files": [], "directoryPrefixes": [], "extra": 1}'):
            with self.subTest(payload=payload):
                self.put("ops/public-export/internal-only.json", payload)
                output = self.base / ("public-" + hashlib.sha256(payload).hexdigest()[:8])
                with self.assertRaisesRegex(ValueError, "missing or malformed"):
                    STAGE.stage(self.source, output)
                self.assertFalse(output.exists())

    def remove_ops(self):
        shutil.rmtree(self.source / "ops")
        self.assertFalse((self.source / "ops").exists())

    def test_tree_without_ops_is_refused_unless_public_tree_is_given(self):
        self.remove_ops()
        output = self.base / "public"
        with self.assertRaisesRegex(ValueError, "no ops directory"):
            STAGE.stage(self.source, output)
        self.assertFalse(output.exists())
        with self.assertRaisesRegex(ValueError, "no ops directory"):
            STAGE.load_exclusions(self.source.resolve())
        self.assertEqual(STAGE.load_exclusions(self.source.resolve(), public_tree=True), (frozenset(), ()))
        manifest = STAGE.stage(self.source, output, public_tree=True)
        self.assertIn("tools/benchmark.ps1", {entry["path"] for entry in manifest["files"]})

    def test_public_tree_flag_on_a_tree_with_ops_still_enforces_the_private_test_check(self):
        # N-c: the private-test check is skipped only on a real public tree (no ops/), never merely because --public-tree was passed.
        self.assertTrue((self.source / "ops").exists())
        (self.source / "tests" / "test_community_coverage.py").unlink()
        output = self.base / "public-missing"
        with self.assertRaisesRegex(ValueError, "PRIVATE_TEST_FILES is stale"):
            STAGE.stage(self.source, output, public_tree=True)
        with self.assertRaisesRegex(ValueError, "PRIVATE_TEST_FILES is stale"):
            STAGE.source_map(self.source.resolve(), public_tree=True)
        self.assertFalse(output.exists())
        self.put("tests/Test_Community_Coverage.py", b"only the wrong case exists\n")
        with self.assertRaisesRegex(ValueError, "PRIVATE_TEST_FILES is stale"):
            STAGE.source_map(self.source.resolve(), public_tree=True)

    def test_a_real_public_tree_skips_the_private_test_check_with_public_tree(self):
        self.remove_ops()
        (self.source / "tests" / "test_community_coverage.py").unlink()
        self.assertIn("src/core.psm1", STAGE.source_map(self.source.resolve(), public_tree=True))
        manifest = STAGE.stage(self.source, self.base / "public-real", public_tree=True)
        self.assertNotIn("tests/test_community_coverage.py", {entry["path"].casefold() for entry in manifest["files"]})
        # Without --public-tree the missing ops/ is still refused.
        with self.assertRaisesRegex(ValueError, "no ops directory"):
            STAGE.source_map(self.source.resolve())

    def test_command_line_requires_public_tree_for_a_tree_without_ops(self):
        self.remove_ops()
        refused = subprocess.run([sys.executable, str(SCRIPT), "--source-root", str(self.source),
                                  "--output", str(self.base / "cli-refused")], capture_output=True, text=True)
        self.assertEqual(refused.returncode, 1)
        self.assertIn("--public-tree", refused.stderr)
        self.assertFalse((self.base / "cli-refused").exists())
        allowed = subprocess.run([sys.executable, str(SCRIPT), "--source-root", str(self.source),
                                  "--output", str(self.base / "cli-allowed"), "--public-tree"], capture_output=True, text=True)
        self.assertEqual(allowed.returncode, 0, allowed.stderr)
        self.assertTrue((self.base / "cli-allowed" / STAGE.MANIFEST_NAME).is_file())

    def test_empty_list_refuses(self):
        self.write_exclusions({"files": [], "directoryPrefixes": []})
        output = self.base / "public"
        with self.assertRaisesRegex(ValueError, "is empty"):
            STAGE.stage(self.source, output)
        self.assertFalse(output.exists())

    def test_stale_list_refuses_when_a_listed_file_is_missing(self):
        self.write_exclusions({"files": ["src/Internal.Example.ps1", "tools/renamed-away.ps1"], "directoryPrefixes": []})
        output = self.base / "public"
        with self.assertRaisesRegex(ValueError, "stale.*tools/renamed-away.ps1"):
            STAGE.stage(self.source, output)
        self.assertFalse(output.exists())
        self.put("tools/renamed-away.ps1", b"# present again\n")
        manifest = STAGE.stage(self.source, output)
        self.assertNotIn("tools/renamed-away.ps1", {entry["path"] for entry in manifest["files"]})

    def test_stale_list_refuses_when_a_listed_directory_prefix_is_missing(self):
        self.write_exclusions({"files": ["src/Internal.Example.ps1"],
                               "directoryPrefixes": ["src/renamed-away/"]})
        output = self.base / "public"
        with self.assertRaisesRegex(ValueError, "stale.*src/renamed-away/"):
            STAGE.stage(self.source, output)
        self.assertFalse(output.exists())
        self.put("src/renamed-away/data.json", b'{"listed":true}\n')
        manifest = STAGE.stage(self.source, output)
        self.assertNotIn("src/renamed-away/data.json", {entry["path"] for entry in manifest["files"]})

    def test_prefix_only_list_is_not_empty(self):
        # The prefix is under src/, which the walker reaches, so "excluded when present" is a real check: the same
        # file is staged when its directory is not listed.
        self.put("src/example-vector/data.json", b'{"listed":true}\n')
        self.put("tools/other-vector/data.json", b'{"other":true}\n')
        self.write_exclusions({"files": [], "directoryPrefixes": ["tools/other-vector/"]})
        control = STAGE.stage(self.source, self.base / "public-control")
        self.assertIn("src/example-vector/data.json", {entry["path"] for entry in control["files"]})
        self.assertNotIn("tools/other-vector/data.json", {entry["path"] for entry in control["files"]})
        self.write_exclusions({"files": [], "directoryPrefixes": ["src/example-vector/"]})
        manifest = STAGE.stage(self.source, self.base / "public")
        paths = {entry["path"] for entry in manifest["files"]}
        self.assertNotIn("src/example-vector/data.json", paths)
        self.assertIn("tools/other-vector/data.json", paths)

    def test_exclusions_match_case_folded(self):
        self.put("src/Internal.Example.ps1", b"# listed\n")
        self.put("src/Example-Vector/Data.json", b'{"listed":true}\n')
        self.write_exclusions({"files": ["src/Internal.Example.ps1"], "directoryPrefixes": ["src/Example-Vector/"]})
        # Source paths whose case differs from the listed spelling are still excluded.
        self.put("src/INTERNAL.EXAMPLE.PS1", b"# mixed-case copy of a listed file\n")
        self.put("src/example-vector/other.json", b'{"listed":true}\n')
        self.put("src/EXAMPLE-VECTOR/NESTED/deep.json", b'{"listed":true}\n')
        manifest = STAGE.stage(self.source, self.base / "public")
        paths = {entry["path"] for entry in manifest["files"]}
        folded = {path.casefold() for path in paths}
        for excluded in ("src/internal.example.ps1", "src/example-vector/data.json",
                         "src/example-vector/other.json", "src/example-vector/nested/deep.json"):
            self.assertNotIn(excluded, folded)
        self.assertIn("src/core.psm1", paths)

    def test_private_test_files_match_case_folded_and_must_exist_in_exact_case(self):
        # A differently-cased copy of the private test must never be staged (a case-insensitive disk may hand back any spelling).
        self.put("tests/Test_Community_Coverage.py", b"MUST NOT EXPORT\n")
        self.put("tests/TEST_COMMUNITY_COVERAGE.PY", b"MUST NOT EXPORT\n")
        manifest = STAGE.stage(self.source, self.base / "public")
        folded = {entry["path"].casefold() for entry in manifest["files"]}
        self.assertNotIn("tests/test_community_coverage.py", folded)
        self.assertIn("src/core.psm1", {entry["path"] for entry in manifest["files"]})
        # A stale constant (the listed private file is absent in its exact case) refuses, exactly like the exclusion list.
        output = self.base / "public-stale"
        for name in os.listdir(self.source / "tests"):
            if name.casefold() == "test_community_coverage.py":
                (self.source / "tests" / name).unlink()
        self.put("tests/Test_Community_Coverage.py", b"only the wrong case exists\n")
        with self.assertRaisesRegex(ValueError, "PRIVATE_TEST_FILES is stale"):
            STAGE.stage(self.source, output)
        self.assertFalse(output.exists())
        # A public re-staging (a real public tree: no ops/, no private tests by design) does not require the file and still never stages another spelling.
        # N-c: --public-tree alone no longer skips the check; it is skipped only when ops/ is absent.
        self.remove_ops()
        manifest = STAGE.stage(self.source, self.base / "public-ok", public_tree=True)
        self.assertNotIn("tests/test_community_coverage.py", {entry["path"].casefold() for entry in manifest["files"]})

    def test_stale_list_refuses_when_the_case_of_a_listed_name_differs(self):
        # Directory listings, not is_file()/is_dir(): those answer yes for any case on a case-insensitive disk.
        self.put("src/Mixed-Case.ps1", b"# present\n")
        self.put("src/Mixed-Dir/data.json", b'{"listed":true}\n')
        output = self.base / "public"
        for document in (
                {"files": ["src/Internal.Example.ps1", "src/mixed-case.ps1"], "directoryPrefixes": []},
                {"files": ["src/Internal.Example.ps1", "SRC/Mixed-Case.ps1"], "directoryPrefixes": []},
                {"files": ["src/Internal.Example.ps1"], "directoryPrefixes": ["src/mixed-dir/"]},
                {"files": ["src/Internal.Example.ps1"], "directoryPrefixes": ["Src/Mixed-Dir/"]}):
            with self.subTest(document=document):
                self.write_exclusions(document)
                with self.assertRaisesRegex(ValueError, "stale"):
                    STAGE.stage(self.source, output)
                self.assertFalse(output.exists())
        self.write_exclusions({"files": ["src/Internal.Example.ps1", "src/Mixed-Case.ps1"],
                               "directoryPrefixes": ["src/Mixed-Dir/"]})
        manifest = STAGE.stage(self.source, output)
        paths = {entry["path"] for entry in manifest["files"]}
        self.assertNotIn("src/Mixed-Case.ps1", paths)
        self.assertNotIn("src/Mixed-Dir/data.json", paths)

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
        manifest = STAGE.stage(SCRIPT.parents[1], staged,
                               public_tree=not (SCRIPT.parents[1] / "ops").exists())
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
