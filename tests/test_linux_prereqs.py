"""No native execution or system-library loading in Linux prerequisite fixtures."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fastllm_linux_prereqs", ROOT / "linux" / "prereqs.py")
prereqs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prereqs)


class PrerequisiteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.stage = self.base / "stage"
        self.stage.mkdir(mode=0o700)
        payload = b"verified fixture, never executed"
        (self.stage / "engine").write_bytes(payload)
        (self.stage / "engine").chmod(0o700)
        self.asset = {"status": "archive-verified-execution-disabled", "sha256": "a" * 64,
                      "entryPoint": "engine", "members": [{"path": "engine", "type": "file",
                      "sizeBytes": len(payload), "sha256": hashlib.sha256(payload).hexdigest(),
                      "executable": True}],
                      "externalNeeded": ["libvulkan.so.1"],
                      "minimumObservedSymbolVersions": {"glibc": "2.34"}}
        self.os_release = self.base / "os-release"
        self.os_release.write_text('ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu fixture"\n')
        self.libdir = self.base / "lib"
        self.libdir.mkdir()
        (self.libdir / "libvulkan.so.1").write_bytes(b"inert placeholder")
        self.icddir = self.base / "icd.d"
        self.icddir.mkdir()
        (self.icddir / "amd_icd.json").write_text(json.dumps({"ICD": {"library_path": "libvulkan_radeon.so"}}))

    def assess(self, **overrides):
        options = {"asset": self.asset, "os_release": self.os_release,
                   "library_dirs": (self.libdir,), "icd_dirs": (self.icddir,), "fixture": True}
        options.update(overrides)
        return prereqs.assess(self.stage, **options)

    def test_fixture_report_never_claims_execution_or_compatibility(self):
        report = self.assess()
        self.assertTrue(report["fixture"])
        self.assertFalse(report["executionEnabled"])
        self.assertFalse(report["compatibilityVerified"])
        self.assertFalse(report["driverIdentityVerified"])
        self.assertEqual(report["osRelease"]["candidateDistroStatus"], "ubuntu-unqualified")
        self.assertEqual(report["vulkanLoaderCandidates"][0]["candidateStatus"], "regular")
        self.assertEqual(report["icdManifests"][0]["files"][0]["driverIdentity"], "unknown")
        self.assertEqual(report["manifestExternalNeeded"], ["libvulkan.so.1"])

    def test_stage_verification_precedes_metadata_read(self):
        self.os_release.write_text("ID=ubuntu\n")
        (self.stage / "engine").write_bytes(b"changed")
        with mock.patch.object(prereqs, "_read_os_release", side_effect=AssertionError("metadata read")):
            with self.assertRaisesRegex(ValueError, "integrity differs"):
                self.assess()

    def test_malformed_oversized_and_missing_os_release(self):
        self.os_release.write_text("ID=ubuntu\nID=fedora\n")
        self.assertEqual(self.assess()["osRelease"]["status"], "malformed-or-oversized")
        self.os_release.write_bytes(b"X" * (prereqs.MAX_OS_RELEASE_BYTES + 1))
        self.assertEqual(self.assess()["osRelease"]["status"], "malformed-or-oversized")
        self.os_release.unlink()
        self.assertEqual(self.assess()["osRelease"]["status"], "missing")

    def test_unsupported_distro_not_qualified(self):
        self.os_release.write_text('ID=fedora\nVERSION_ID="42"\n')
        self.assertEqual(self.assess()["osRelease"]["candidateDistroStatus"],
                         "unsupported-for-ubuntu-candidate")

    def test_symlink_and_traversal_paths_not_read(self):
        outside = self.base / "outside"
        outside.write_text("ID=ubuntu\n")
        self.os_release.unlink()
        self.os_release.symlink_to(outside)
        self.assertEqual(self.assess()["osRelease"]["status"], "unsafe-symlink")
        self.assertEqual(self.assess(os_release=self.base / ".." / "outside")["osRelease"]["status"],
                         "unsafe-path")
        (self.libdir / "libvulkan.so.1").unlink()
        (self.libdir / "libvulkan.so.1").symlink_to(outside)
        self.assertEqual(self.assess()["vulkanLoaderCandidates"][0]["candidateStatus"], "symlink-unverified")
        (self.icddir / "amd_icd.json").unlink()
        (self.icddir / "amd_icd.json").symlink_to(outside)
        self.assertEqual(self.assess()["icdManifests"][0]["files"][0]["status"], "unsafe-symlink")

    def test_oversized_malformed_nested_and_traversing_icd_json(self):
        icd = self.icddir / "amd_icd.json"
        icd.write_bytes(b"{" * (prereqs.MAX_ICD_BYTES + 1))
        self.assertEqual(self.assess()["icdManifests"][0]["files"][0]["status"], "malformed-or-oversized")
        icd.write_text("{broken")
        self.assertEqual(self.assess()["icdManifests"][0]["files"][0]["status"], "malformed-or-oversized")
        icd.write_text('{"ICD":{"library_path":"first.so","library_path":"second.so"}}')
        self.assertEqual(self.assess()["icdManifests"][0]["files"][0]["status"], "malformed-or-oversized")
        nested = {"ICD": {"library_path": "library.so"}}
        for _ in range(prereqs.MAX_JSON_DEPTH + 2):
            nested = {"wrap": nested}
        icd.write_text(json.dumps(nested))
        self.assertEqual(self.assess()["icdManifests"][0]["files"][0]["status"], "malformed-or-oversized")
        icd.write_text(json.dumps({"ICD": {"library_path": "../../tmp/escape.so"}}))
        self.assertEqual(self.assess()["icdManifests"][0]["files"][0]["status"],
                         "unsafe-library-path-text")

    def test_icd_count_and_directory_bounds(self):
        for index in range(prereqs.MAX_ICD_FILES + 2):
            (self.icddir / f"fixture-{index}.json").write_text("{}")
        report = self.assess()
        self.assertTrue(report["icdFileLimitReached"])
        self.assertEqual(len(report["icdManifests"][0]["files"]), prereqs.MAX_ICD_FILES)
        with self.assertRaisesRegex(ValueError, "too many"):
            self.assess(library_dirs=(self.libdir,) * 17)
        second = self.base / "second-icd.d"
        second.mkdir()
        (second / "extra.json").write_text("{}")
        report = self.assess(icd_dirs=(self.icddir, second))
        self.assertTrue(report["icdFileLimitReached"])
        self.assertEqual(sum(len(item["files"]) for item in report["icdManifests"]), prereqs.MAX_ICD_FILES)

    def test_absent_system_metadata_remains_unknown(self):
        report = self.assess(os_release=self.base / "absent-release",
                             library_dirs=(self.base / "absent-lib",),
                             icd_dirs=(self.base / "absent-icd",))
        self.assertEqual(report["osRelease"]["candidateDistroStatus"], "unknown")
        self.assertEqual(report["vulkanLoaderCandidates"][0]["candidateStatus"], "not-inspected")
        self.assertEqual(report["icdManifests"][0]["files"], [])
        self.assertFalse(report["compatibilityVerified"])

    def test_non_json_directory_flood_is_bounded(self):
        for index in range(prereqs.MAX_ICD_DIR_ENTRIES + 2):
            (self.icddir / f"other-{index}.txt").write_text("")
        report = self.assess()
        self.assertTrue(report["icdFileLimitReached"])
        self.assertFalse(report["compatibilityVerified"])

    def test_icd_directory_symlink_swap_does_not_scan_outside(self):
        outside = self.base / "outside-icd"
        outside.mkdir()
        (outside / "secret.json").write_text(json.dumps({"ICD": {"library_path": "secret.so"}}))
        original = prereqs._open_dir_no_follow
        swapped = False

        def swap_before_open(path):
            nonlocal swapped
            if Path(path) == self.icddir and not swapped:
                swapped = True
                self.icddir.rename(self.base / "moved-icd")
                self.icddir.symlink_to(outside)
            return original(path)

        with mock.patch.object(prereqs, "_open_dir_no_follow", side_effect=swap_before_open):
            report = self.assess()
        self.assertTrue(swapped)
        self.assertEqual(report["icdManifests"][0]["files"], [])
        self.assertEqual(report["icdManifests"][0]["directoryStatus"], "unreadable")

    def test_os_release_parent_symlink_swap_and_hardlink_rejected(self):
        metadata_dir = self.base / "metadata"
        metadata_dir.mkdir()
        release = metadata_dir / "os-release"
        release.write_text("ID=ubuntu\n")
        outside = self.base / "outside-metadata"
        outside.mkdir()
        (outside / "os-release").write_text("ID=fedora\nPRETTY_NAME=secret\n")
        original = prereqs._open_dir_no_follow
        swapped = False

        def swap_before_open(path):
            nonlocal swapped
            if Path(path) == metadata_dir and not swapped:
                swapped = True
                metadata_dir.rename(self.base / "moved-metadata")
                metadata_dir.symlink_to(outside)
            return original(path)

        with mock.patch.object(prereqs, "_open_dir_no_follow", side_effect=swap_before_open):
            report = self.assess(os_release=release)
        self.assertTrue(swapped)
        self.assertEqual(report["osRelease"]["status"], "malformed-or-oversized")
        self.assertIsNone(report["osRelease"]["prettyName"])
        linked_dir = self.base / "linked-metadata"
        linked_dir.mkdir()
        os.link(outside / "os-release", linked_dir / "os-release")
        report = self.assess(os_release=linked_dir / "os-release")
        self.assertEqual(report["osRelease"]["status"], "malformed-or-oversized")
        self.assertIsNone(report["osRelease"]["id"])

    def test_allowlisted_os_release_fallback_discloses_resolved_source(self):
        fallback = self.base / "usr-lib-os-release"
        fallback.write_text('ID=ubuntu\nVERSION_ID="24.04"\n')
        primary = self.base / "etc-os-release"
        primary.symlink_to(fallback)
        with mock.patch.object(prereqs, "OS_RELEASE", primary), mock.patch.object(prereqs, "FALLBACK_OS_RELEASE", fallback):
            result = prereqs._read_os_release(primary, fixture=False)
        self.assertEqual(result["status"], "allowlisted-symlink-fallback")
        self.assertTrue(result["allowlistedSymlinkFallback"])
        self.assertEqual(result["resolvedSourcePath"], str(fallback))
        self.assertEqual(result["id"], "ubuntu")

    def test_alternate_paths_require_fixture_and_native_guard(self):
        with self.assertRaisesRegex(ValueError, "fixture=True"):
            self.assess(fixture=False)
        with mock.patch.object(prereqs.platform, "system", return_value="Darwin"):
            with self.assertRaisesRegex(ValueError, "standard-user Linux"):
                prereqs.assess(self.stage)


if __name__ == "__main__":
    unittest.main()
