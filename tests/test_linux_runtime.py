"""Offline integrity checks for the disabled Linux Vulkan archive candidate."""

import hashlib
import importlib.util
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fastllm_linux_runtime", ROOT / "linux" / "runtime.py")
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)


def make_archive(path, extra=None, link_target="engine"):
    with tarfile.open(path, "w:gz") as archive:
        directory = tarfile.TarInfo("release")
        directory.type = tarfile.DIRTYPE
        archive.addfile(directory)
        data = b"non-executed-test-engine"
        member = tarfile.TarInfo("release/engine")
        member.mode = 0o755
        member.size = len(data)
        archive.addfile(member, io.BytesIO(data))
        link = tarfile.TarInfo("release/libengine.so")
        link.type = tarfile.SYMTYPE
        link.linkname = link_target
        archive.addfile(link)
        if extra:
            unexpected = tarfile.TarInfo(extra)
            unexpected.size = 1
            archive.addfile(unexpected, io.BytesIO(b"x"))
    return {
        "status": "archive-verified-execution-disabled",
        "archiveRoot": "release",
        "entryPoint": "engine",
        "sizeBytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "members": [
            {"path": "engine", "type": "file", "sizeBytes": len(data),
             "sha256": hashlib.sha256(data).hexdigest(), "executable": True},
            {"path": "libengine.so", "type": "symlink", "target": "engine"},
        ],
    }


class LinuxRuntimeTests(unittest.TestCase):
    def test_pinned_release_metadata_and_disabled_status(self):
        asset = runtime.load_asset()
        self.assertEqual(asset["status"], "archive-verified-execution-disabled")
        self.assertEqual(asset["sha256"], "76b77c0a9afa4d6a4424d409cc98c52f3fccb242b7a4dbf4292f0c16f40f4b01")
        self.assertEqual(len(asset["members"]), 61)
        self.assertIn("libgomp.so.1", asset["externalNeeded"])

    def test_pinned_archive_elf_needed_matches_external_manifest_when_available(self):
        archive_path = os.environ.get("FASTLLM_LINUX_PINNED_VULKAN_ARCHIVE")
        if not archive_path:
            self.skipTest("set FASTLLM_LINUX_PINNED_VULKAN_ARCHIVE for offline ELF dependency audit")
        objdump = shutil.which("objdump")
        if not objdump:
            self.skipTest("objdump unavailable for offline ELF dependency audit")
        archive_path = Path(archive_path)
        asset = runtime.load_asset()
        runtime.verify_archive(archive_path, asset)
        known_members = {item["path"] for item in asset["members"]}
        needed = set()
        with tempfile.TemporaryDirectory() as folder, tarfile.open(archive_path, "r:gz") as archive:
            for item in asset["members"]:
                if item["type"] != "file" or item["path"] == "LICENSE":
                    continue
                member = archive.getmember(asset["archiveRoot"] + "/" + item["path"])
                output = Path(folder) / "member"
                with archive.extractfile(member) as source, output.open("wb") as target:
                    shutil.copyfileobj(source, target)
                result = subprocess.run([objdump, "-p", str(output)], capture_output=True, text=True,
                                        timeout=15, check=True)
                needed.update(re.findall(r"^\s*NEEDED\s+(\S+)\s*$", result.stdout, re.MULTILINE))
        # The ELF interpreter is checked by Linux when it starts the binary; it
        # is part of glibc, not a separately provisioned library candidate.
        external = needed - known_members - {"ld-linux-x86-64.so.2"}
        self.assertEqual(external, set(asset["externalNeeded"]))

    def test_verify_stage_and_reverify_exact_tree(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder).resolve()
            archive = folder / "asset.tar.gz"
            asset = make_archive(archive)
            self.assertEqual(runtime.verify_archive(archive, asset), 2)
            staged = folder / "staged"
            runtime.prepare_asset(archive, staged, asset)
            self.assertEqual(runtime.verify_tree(staged, asset), 2)
            self.assertEqual((staged / "libengine.so").readlink(), Path("engine"))
            staged.chmod(0o755)
            with self.assertRaisesRegex(ValueError, "directory owner or permissions"):
                runtime.verify_tree(staged, asset)
            staged.chmod(0o700)
            actual_uid = os.geteuid()
            with patch.object(runtime.os, "geteuid", return_value=actual_uid + 1):
                with self.assertRaisesRegex(ValueError, "directory owner or permissions"):
                    runtime.verify_tree(staged, asset)
            with self.assertRaisesRegex(ValueError, "destination already exists"):
                runtime.prepare_asset(archive, staged, asset)
            (staged / ".hidden-extra").write_text("x")
            with self.assertRaisesRegex(ValueError, "file set differs"):
                runtime.verify_tree(staged, asset)
            (staged / ".hidden-extra").unlink()
            (staged / "engine").chmod(0o600)
            with self.assertRaisesRegex(ValueError, "file integrity differs"):
                runtime.verify_tree(staged, asset)
            (staged / "engine").chmod(0o777)
            with self.assertRaisesRegex(ValueError, "file integrity differs"):
                runtime.verify_tree(staged, asset)
            (staged / "engine").chmod(0o700)
            os.link(staged / "engine", folder / "other-link")
            with self.assertRaisesRegex(ValueError, "file integrity differs"):
                runtime.verify_tree(staged, asset)

    def test_symlink_ancestor_cannot_redirect_staging_or_verification(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder).resolve()
            archive = folder / "asset.tar.gz"
            asset = make_archive(archive)
            actual = folder / "actual"
            actual.mkdir()
            alias = folder / "alias"
            alias.symlink_to(actual, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "contains a symlink"):
                runtime.prepare_asset(archive, alias / "staged", asset)
            self.assertFalse((actual / "staged").exists())
            runtime.prepare_asset(archive, actual / "staged", asset)
            with self.assertRaisesRegex(ValueError, "contains a symlink"):
                runtime.verify_tree(alias / "staged", asset)

    def test_archive_hash_member_and_path_rejections(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive = folder / "asset.tar.gz"
            asset = make_archive(archive)
            wrong = dict(asset, sha256="0" * 64)
            with self.assertRaisesRegex(ValueError, "SHA-256 differs"):
                runtime.verify_archive(archive, wrong)
            changed = dict(asset, members=[dict(asset["members"][0], sha256="f" * 64), asset["members"][1]])
            with self.assertRaisesRegex(ValueError, "member hash differs"):
                runtime.verify_archive(archive, changed)
            asset = make_archive(archive, extra="release/../../escape")
            with self.assertRaisesRegex(ValueError, "extra, duplicate, or unsafe"):
                runtime.verify_archive(archive, asset)

    def test_symlink_cannot_escape_or_change(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            archive = folder / "asset.tar.gz"
            asset = make_archive(archive, link_target="../../outside")
            with self.assertRaisesRegex(ValueError, "symlink differs"):
                runtime.verify_archive(archive, asset)

    def test_cli_refuses_root_and_prepare_on_non_linux(self):
        with patch.object(runtime.os, "geteuid", return_value=0), patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as elevated:
                runtime.main(["prepare", "--dest", "/tmp/never-created"])
            self.assertEqual(elevated.exception.code, 2)
        with patch.object(runtime.os, "geteuid", return_value=1000), patch.object(runtime.platform, "system", return_value="Darwin"), patch("sys.stderr", new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as non_linux:
                runtime.main(["prepare", "--dest", "/tmp/never-created"])
            self.assertEqual(non_linux.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
