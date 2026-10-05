import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

MODULE_PATH = Path(__file__).resolve().parents[1] / "linux" / "models.py"
spec = importlib.util.spec_from_file_location("fastllm_linux_models", MODULE_PATH)
models = importlib.util.module_from_spec(spec)
spec.loader.exec_module(models)

DATA = b"pinned GGUF example"
LICENSE = b"Apache-2.0 test license text"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def catalog(data=DATA, license_data=LICENSE):
    return {"models": [{"id": "qwen-test", "url": "https://models.example/file.gguf",
                        "sizeBytes": len(data), "sha256": digest(data),
                        "upstreamModel": "Qwen/Qwen-test", "upstreamRevision": "a" * 40,
                        "upstreamLicense": "Apache-2.0",
                        "upstreamLicenseUrl": "https://models.example/LICENSE",
                        "upstreamLicenseSha256": digest(license_data),
                        "repository": "unsloth/Qwen-test-GGUF", "revision": "c" * 40,
                        "artifactLicense": "Apache-2.0",
                        "artifactLicenseMetadataUrl": "https://models.example/conversion-license"}]}


class Response(io.BytesIO):
    def __init__(self, data, status=200, headers=None):
        super().__init__(data)
        self.status = status
        self.headers = headers or {}


class FakeTransport:
    def __init__(self, data=DATA, license_data=LICENSE, interrupt=False, bad_range=False):
        self.data = data
        self.license_data = license_data
        self.interrupt = interrupt
        self.bad_range = bad_range
        self.calls = []

    def open(self, url, offset):
        self.calls.append((url, offset))
        if url.endswith("LICENSE"):
            return Response(self.license_data)
        if self.interrupt:
            self.interrupt = False
            return Response(self.data[:6], headers={"Content-Length": str(len(self.data))})
        if offset:
            content_range = f"bytes {offset}-{len(self.data)-1}/{len(self.data)}"
            if self.bad_range:
                content_range = "bytes 0-0/1"
            return Response(self.data[offset:], 206,
                            {"Content-Range": content_range, "Content-Length": str(len(self.data)-offset)})
        return Response(self.data, headers={"Content-Length": str(len(self.data))})


class LinuxModelTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1])
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "private"
        self.root.mkdir(mode=0o700)
        self.patches = [mock.patch.object(models.os, "geteuid", return_value=self.root.stat().st_uid),
                        mock.patch.object(models.platform, "system", return_value="Linux")]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def acquire(self, transport=None, accept=None, cat=None):
        cat = cat or catalog()
        item = cat["models"][0]
        reviewed = ({"reviewed_license_sha256": item["upstreamLicenseSha256"],
                     "reviewed_upstream_revision": item["upstreamRevision"],
                     "reviewed_artifact_sha256": item["sha256"],
                     "reviewed_provenance_sha256": models._provenance_sha256(item)} if accept else {})
        return models.acquire_model(cat, "qwen-test", self.root,
                                    accept_license_for=accept, transport=transport or FakeTransport(),
                                    **reviewed)

    def test_exact_consent_then_verified_reuse_without_network(self):
        transport = FakeTransport()
        with self.assertRaisesRegex(ValueError, "consent required"):
            self.acquire(transport)
        self.assertEqual(transport.calls, [])
        result = self.acquire(transport, accept="qwen-test")
        self.assertFalse(result["reused"])
        self.assertEqual(Path(result["path"]).read_bytes(), DATA)
        self.assertEqual(len(transport.calls), 2)
        second = self.acquire(transport)
        self.assertTrue(second["reused"])
        self.assertEqual(len(transport.calls), 2)

    def test_resume_exact_content_range(self):
        transport = FakeTransport(interrupt=True)
        with self.assertRaisesRegex(ValueError, "size or SHA-256"):
            self.acquire(transport, accept="qwen-test")
        result = self.acquire(transport)
        self.assertEqual(Path(result["path"]).read_bytes(), DATA)
        self.assertEqual(transport.calls[-1][1], 6)

    def test_zero_byte_partial_resumes_as_new_transfer(self):
        item = catalog()["models"][0]
        partial = self.root / f"{item['id']}-{item['sha256']}.gguf.part"
        partial.touch(mode=0o600)
        result = self.acquire(accept="qwen-test")
        self.assertEqual(Path(result["path"]).read_bytes(), DATA)

    def test_reconsent_on_changed_license_revision_same_artifact(self):
        first = self.acquire(accept="qwen-test")
        changed = catalog()
        changed["models"][0]["upstreamRevision"] = "b" * 40
        with self.assertRaisesRegex(ValueError, "renewed"):
            self.acquire(cat=changed)
        transport = FakeTransport()
        second = self.acquire(transport=transport, accept="qwen-test", cat=changed)
        self.assertTrue(second["reused"])
        self.assertEqual(transport.calls, [("https://models.example/LICENSE", 0)])
        self.assertEqual(len(list(self.root.glob("*.superseded-*"))), 1)
        self.assertEqual(Path(first["path"]).read_bytes(), DATA)

    def test_conversion_revision_or_terms_change_requires_new_consent(self):
        self.acquire(accept="qwen-test")
        for field, value in (("revision", "d" * 40), ("artifactLicense", "New-License"),
                             ("url", "https://models.example/new-location.gguf"),
                             ("repository", "other/Qwen-test-GGUF")):
            with self.subTest(field=field):
                changed = catalog()
                changed["models"][0][field] = value
                with self.assertRaisesRegex(ValueError, "renewed"):
                    self.acquire(cat=changed)
        changed = catalog()
        changed["models"][0]["revision"] = "d" * 40
        with self.assertRaisesRegex(ValueError, "reviewed exact"):
            models.acquire_model(changed, "qwen-test", self.root, accept_license_for="qwen-test",
                                 reviewed_license_sha256=digest(LICENSE),
                                 reviewed_upstream_revision="a" * 40,
                                 reviewed_artifact_sha256=digest(DATA),
                                 reviewed_provenance_sha256=models._provenance_sha256(catalog()["models"][0]),
                                 transport=FakeTransport())
        self.assertTrue(self.acquire(cat=changed, accept="qwen-test")["reused"])

    def test_held_lock_obeys_deadline(self):
        deadline = models.time.monotonic() + 1
        with models._lock(self.root, deadline):
            with self.assertRaisesRegex(TimeoutError, "lock deadline"):
                models.acquire_model(catalog(), "qwen-test", self.root, deadline_seconds=0.02,
                                     transport=FakeTransport())

    def test_bool_size_rejected(self):
        changed = catalog()
        changed["models"][0]["sizeBytes"] = True
        with self.assertRaisesRegex(ValueError, "model size"):
            self.acquire(cat=changed)

    def test_preview_verifies_license_and_displays_exact_provenance(self):
        result = models.preview_license(catalog(), "qwen-test", transport=FakeTransport())
        self.assertEqual(result["licenseText"], LICENSE.decode())
        self.assertEqual(result["artifactSha256"], digest(DATA))
        self.assertEqual(result["conversionRepository"], "unsloth/Qwen-test-GGUF")
        self.assertEqual(result["conversionRevision"], "c" * 40)
        self.assertEqual(result["consentProvenanceSha256"], models._provenance_sha256(catalog()["models"][0]))
        with self.assertRaisesRegex(ValueError, "license digest differs"):
            models.preview_license(catalog(), "qwen-test", transport=FakeTransport(license_data=b"bad"))
        self.assertEqual(list(self.root.iterdir()), [])

    def test_acceptance_requires_reviewed_exact_provenance(self):
        with self.assertRaisesRegex(ValueError, "reviewed exact"):
            models.acquire_model(catalog(), "qwen-test", self.root,
                                 accept_license_for="qwen-test", transport=FakeTransport())

    def test_resume_rejects_wrong_range(self):
        transport = FakeTransport(interrupt=True, bad_range=True)
        with self.assertRaises(ValueError):
            self.acquire(transport, accept="qwen-test")
        with self.assertRaisesRegex(ValueError, "Content-Range"):
            self.acquire(transport)

    def test_changed_digest_needs_new_consent(self):
        self.acquire(accept="qwen-test")
        altered = catalog(data=b"new exact artifact")
        with self.assertRaisesRegex(ValueError, "consent required"):
            self.acquire(cat=altered)

    def test_corrupt_final_is_quarantined_and_repaired(self):
        original = self.acquire(accept="qwen-test")
        Path(original["path"]).write_bytes(b"corrupt")
        repaired = self.acquire()
        self.assertFalse(repaired["reused"])
        self.assertEqual(Path(repaired["path"]).read_bytes(), DATA)
        self.assertEqual(len(list(self.root.glob("*.corrupt-*"))), 1)

    def test_symlink_cache_file_rejected_without_overwrite(self):
        outside = Path(self.tmp.name) / "outside"
        outside.write_text("keep")
        item = catalog()["models"][0]
        (self.root / f"{item['id']}-{item['sha256']}.consent.json").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "unsafe cache file"):
            self.acquire(accept="qwen-test")
        self.assertEqual(outside.read_text(), "keep")

    def test_symlink_ancestor_rejected(self):
        actual = Path(self.tmp.name) / "actual"
        actual.mkdir(mode=0o700)
        alias = Path(self.tmp.name) / "alias"
        alias.symlink_to(actual)
        with self.assertRaisesRegex(ValueError, "symlink"):
            models.acquire_model(catalog(), "qwen-test", alias / "private",
                                 transport=FakeTransport())

    def test_oversize_transfer_rejected(self):
        transport = FakeTransport(data=DATA + b"too much")
        with self.assertRaisesRegex(ValueError, "Content-Length"):
            self.acquire(transport, accept="qwen-test")

    def test_license_digest_mismatch_leaves_no_receipt_or_model(self):
        transport = FakeTransport(license_data=b"changed")
        with self.assertRaisesRegex(ValueError, "license digest differs"):
            self.acquire(transport, accept="qwen-test")
        self.assertEqual(list(self.root.glob("*.consent.json")), [])
        self.assertEqual(list(self.root.glob("*.gguf")), [])

    def test_partial_symlink_rejected(self):
        outside = Path(self.tmp.name) / "outside-part"
        outside.write_bytes(b"keep")
        item = catalog()["models"][0]
        (self.root / f"{item['id']}-{item['sha256']}.gguf.part").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "unsafe cache file"):
            self.acquire(accept="qwen-test")
        self.assertEqual(outside.read_bytes(), b"keep")

    def test_forged_receipt_rejected(self):
        self.acquire(accept="qwen-test")
        receipt_path = next(self.root.glob("*.consent.json"))
        receipt = json.loads(receipt_path.read_text())
        receipt["upstreamRevision"] = "b" * 40
        receipt_path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, "consent receipt differs"):
            self.acquire()

    def test_root_execution_rejected(self):
        with mock.patch.object(models.os, "geteuid", return_value=0):
            with self.assertRaisesRegex(ValueError, "standard user"):
                self.acquire(accept="qwen-test")


if __name__ == "__main__":
    unittest.main()
