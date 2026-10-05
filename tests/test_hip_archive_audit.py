"""Synthetic/adversarial checks for the disabled HIP archive's offline auditor."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import struct
import tempfile
import unittest
from unittest import mock
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fastllm_hip_audit", ROOT / "tools/audit_hip_archive.py")
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


def tiny_pe(direct="foo.dll", delay="bar.dll"):
    data = bytearray(0x600)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", data, 0x86, 1)  # one section
    struct.pack_into("<H", data, 0x94, 0xF0)  # optional header bytes
    opt = 0x98
    struct.pack_into("<H", data, opt, 0x20B)
    struct.pack_into("<Q", data, opt + 24, 0x140000000)
    struct.pack_into("<I", data, opt + 60, 0x200)  # headers
    struct.pack_into("<I", data, opt + 108, 16)  # directories
    struct.pack_into("<II", data, opt + 112 + 8, 0x1000, 40)  # import
    struct.pack_into("<II", data, opt + 112 + 13 * 8, 0x1040, 64)  # delay import
    section = opt + 0xF0
    struct.pack_into("<IIII", data, section + 8, 0x400, 0x1000, 0x400, 0x200)
    struct.pack_into("<I", data, 0x200 + 12, 0x1100)  # direct descriptor name RVA
    struct.pack_into("<II", data, 0x240, 1, 0x1120)  # delay descriptor RVA mode/name
    data[0x300:0x300 + len(direct) + 1] = direct.encode() + b"\0"
    data[0x320:0x320 + len(delay) + 1] = delay.encode() + b"\0"
    return bytes(data)


def synthetic_archive(path, members):
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zipped:
        for name, value in members:
            if isinstance(value, zipfile.ZipInfo):
                zipped.writestr(value, b"")
            else:
                zipped.writestr(name, value)
    rows = [(name, data) for name, data in members if isinstance(data, bytes) and not name.endswith("/")]
    digest = hashlib.sha256()
    for name, data in sorted(rows):
        digest.update(f"{name}\0{len(data)}\0{hashlib.sha256(data).hexdigest()}\n".encode())
    raw = path.read_bytes()
    return {
        "id": "synthetic-disabled", "executionEnabled": False,
        "archive": {"sizeBytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()},
        "extractedFileCount": len(rows),
        "extractedDirectoryCount": sum(name.endswith("/") for name, _ in members),
        "extractedSizeBytes": sum(len(data) for _, data in rows),
        "fileSetDigest": {"sha256": digest.hexdigest()},
    }


class HipArchiveAuditTests(unittest.TestCase):
    def test_direct_delay_graph_and_external_classification(self):
        self.assertEqual(audit.pe_imports(tiny_pe()), {"direct": ["foo.dll"], "delay": ["bar.dll"]})
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "tiny.zip"
            policy = synthetic_archive(path, [("server.exe", tiny_pe()), ("foo.dll", tiny_pe("kernel32.dll", "vcruntime140.dll"))])
            result = audit.audit_archive(path, policy, enforce_identity=False)
            self.assertEqual(result["fileCount"], 2)
            self.assertEqual(len(result["peImports"]), 2)
            edges = {(row["from"], row["kind"], row["dll"]): row["classification"] for row in result["importEdges"]}
            self.assertEqual(edges[("server.exe", "direct", "foo.dll")], "app-local-name-present")
            self.assertEqual(edges[("server.exe", "delay", "bar.dll")], "external-unclassified")
            self.assertEqual(edges[("foo.dll", "direct", "kernel32.dll")], "windows-system-api-prerequisite")
            self.assertEqual(edges[("foo.dll", "delay", "vcruntime140.dll")], "microsoft-vc-ucrt-prerequisite")
            self.assertFalse(result["staticImportNamesClassified"])
            self.assertFalse(result["dynamicLoadClosureVerified"])
            self.assertFalse(result["legalReviewComplete"])

    def test_rejects_unsafe_entry_names_case_collision_and_links(self):
        for members in (
            [("../escape.dll", b"x")],
            [("foo.dll", b"x"), ("FOO.DLL", b"y")],
            [("folder\\evil.dll", b"x")],
            [("folder./x", b"x")],
        ):
            with self.subTest(members=members), tempfile.TemporaryDirectory() as directory:
                path = Path(directory).resolve() / "bad.zip"
                policy = synthetic_archive(path, members)
                with self.assertRaises(ValueError):
                    audit.audit_archive(path, policy, enforce_identity=False)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "link.zip"
            link = zipfile.ZipInfo("link.dll")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            policy = synthetic_archive(path, [("link.dll", link)])
            with self.assertRaises(ValueError):
                audit.audit_archive(path, policy, enforce_identity=False)

    def test_rejects_pin_changes_and_malformed_pe(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "bad.zip"
            policy = synthetic_archive(path, [("server.exe", tiny_pe())])
            wrong = json.loads(json.dumps(policy))
            wrong["archive"]["sha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "SHA-256"):
                audit.audit_archive(path, wrong, enforce_identity=False)
            corrupt = bytearray(tiny_pe())
            corrupt[0x200 + 20:0x200 + 40] = b"X" * 20  # remove direct terminator
            with self.assertRaises(ValueError):
                audit.pe_imports(bytes(corrupt))
            short_section = bytearray(tiny_pe())
            struct.pack_into("<I", short_section, 0x188 + 16, 0x101)
            with self.assertRaisesRegex(ValueError, "RVA"):
                audit.pe_imports(bytes(short_section))  # DLL name spills beyond mapped raw bytes
            overlap = bytearray(tiny_pe())
            struct.pack_into("<H", overlap, 0x86, 2)
            struct.pack_into("<IIII", overlap, 0x188 + 40 + 8, 0x400, 0x1000, 0x400, 0x200)
            with self.assertRaisesRegex(ValueError, "ambiguously"):
                audit.pe_imports(bytes(overlap))
            with self.assertRaises(ValueError):
                audit.audit_archive(path, policy)  # synthetic identity cannot pass production policy

    def test_rejects_file_parent_topology(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "bad.zip"
            policy = synthetic_archive(path, [("foo.dll", tiny_pe()), ("foo.dll/bar.txt", b"x")])
            with self.assertRaisesRegex(ValueError, "directory ancestor"):
                audit.audit_archive(path, policy, enforce_identity=False)

    @unittest.skipIf(os.name == "nt", "Windows may deny replacing an open ZIP; held-descriptor behavior is tested on POSIX")
    def test_path_swap_cannot_change_inspected_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            path, replacement = root / "original.zip", root / "replacement.zip"
            policy = synthetic_archive(path, [("server.exe", tiny_pe())])
            synthetic_archive(replacement, [("other.exe", tiny_pe("other.dll", "bar.dll"))])
            real_zip = zipfile.ZipFile
            def swap_then_open(stream, *args, **kwargs):
                os.replace(replacement, path)
                return real_zip(stream, *args, **kwargs)
            with mock.patch.object(audit.zipfile, "ZipFile", side_effect=swap_then_open):
                report = audit.audit_archive(path, policy, enforce_identity=False)
            self.assertEqual([row["path"] for row in report["files"]], ["server.exe"])
            self.assertEqual(report["archiveSha256"], policy["archive"]["sha256"])
            self.assertNotEqual(hashlib.sha256(path.read_bytes()).hexdigest(), report["archiveSha256"])

    @unittest.skipIf(os.name == "nt", "Windows may deny modifying an open ZIP; held-descriptor behavior is tested on POSIX")
    def test_inplace_archive_change_fails_final_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "original.zip"
            policy = synthetic_archive(path, [("server.exe", tiny_pe())])
            real_zip = zipfile.ZipFile
            def append_then_open(stream, *args, **kwargs):
                with path.open("ab") as writer:
                    writer.write(b"changed-after-first-hash")
                return real_zip(stream, *args, **kwargs)
            with mock.patch.object(audit.zipfile, "ZipFile", side_effect=append_then_open):
                with self.assertRaisesRegex(ValueError, "changed during held-descriptor audit"):
                    audit.audit_archive(path, policy, enforce_identity=False)

    def test_rejects_archive_symlink_ancestor_and_output_alias(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            real = root / "real"
            real.mkdir()
            path = real / "tiny.zip"
            policy = synthetic_archive(path, [("server.exe", tiny_pe())])
            alias = root / "alias"
            alias.symlink_to(real, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symlink"):
                audit.audit_archive(alias / "tiny.zip", policy, enforce_identity=False)
            output_alias = root / "result.json"
            output_alias.symlink_to(root / "missing.json")
            with self.assertRaises(ValueError):
                audit._safe_output(output_alias)

    def test_notice_presence_is_inventory_not_legal_approval(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve() / "notice.zip"
            policy = synthetic_archive(path, [("server.exe", tiny_pe()), ("LICENSE-MIT", b"test license")])
            result = audit.audit_archive(path, policy, enforce_identity=False)
            self.assertEqual(result["noticeCandidates"], ["LICENSE-MIT"])
            self.assertFalse(result["legalReviewComplete"])

    @unittest.skipUnless(os.environ.get("FASTLLM_LEMONADE_B1339_ARCHIVE"), "set exact pinned b1339 ZIP for real archive audit")
    def test_exact_pinned_archive(self):
        policy = json.loads((ROOT / "config/experiments/lemonade-hip-b1339-gfx110x.json").read_text())
        result = audit.audit_archive(Path(os.environ["FASTLLM_LEMONADE_B1339_ARCHIVE"]), policy)
        self.assertEqual(result["fileCount"], 1081)
        self.assertEqual(result["directoryCount"], 8)
        self.assertEqual(len(result["peImports"]), 73)
        self.assertEqual(result["noticeCandidates"], [])
        self.assertFalse(result["dynamicLoadClosureVerified"])


if __name__ == "__main__":
    unittest.main()
