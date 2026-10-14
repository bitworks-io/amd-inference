import hashlib, importlib.util, json, os, tempfile, unittest, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_release", ROOT / "tools" / "build-release.py")
br = importlib.util.module_from_spec(spec)
spec.loader.exec_module(br)

T = "2026-10-20T12:00:01Z"


class PublicBuilderTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        for name in br.ROOT_FILES:
            (self.root / name).write_text(name + "\n")
        for rel in ("src/FastLlm.psm1", "tools/x.py", "config/catalog.json", "licenses/llama.cpp/LICENSE", "tests/t.ps1",
                    "src/__pycache__/x.pyc", "src/.hidden"):
            path = self.root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(rel + "\n")
        self.out = Path(tempfile.mkdtemp()) / "out"

    def build(self, **kw):
        args = dict(version="2026.10.20.1", channel="canary", min_agent_version="0.10.0", built_at=T)
        args.update(kw)
        return br.build(str(self.root), out_dir=str(self.out), **args)

    def names(self):
        with zipfile.ZipFile(self.out / "package-unsigned.zip") as z:
            return z.namelist()

    def member(self, name):
        with zipfile.ZipFile(self.out / "package-unsigned.zip") as z:
            return z.read(name)

    def test_contents_and_order(self):
        self.build()
        names = self.names()
        self.assertEqual(names[-2:], ["MANIFEST.json", "RELEASE.json"])
        self.assertIn("FASTLLM-VERSION.json", names)
        self.assertIn("licenses/llama.cpp/LICENSE", names)
        self.assertIn("LICENSE", names)
        self.assertFalse([n for n in names if n.startswith("tests/") or "__pycache__" in n or "/." in n])

    def test_manifest_and_release(self):
        result = self.build()
        manifest_bytes = self.member("MANIFEST.json")
        manifest = json.loads(manifest_bytes)
        self.assertEqual(manifest["schema"], "fastllm.private-native-test-package.v1")
        listed = {f["path"] for f in manifest["files"]}
        self.assertEqual(listed, set(self.names()) - {"MANIFEST.json", "RELEASE.json"})
        for entry in manifest["files"]:
            self.assertEqual(hashlib.sha256(self.member(entry["path"])).hexdigest(), entry["sha256"])
        release = json.loads(self.member("RELEASE.json"))
        self.assertEqual(release, {"schema": "bitworks.fastllm-release/v1", "component": "fastllm-lab", "version": "2026.10.20.1",
                                   "channel": "canary", "minAgentVersion": "0.10.0", "builtAtUtc": T,
                                   "manifestSha256": hashlib.sha256(manifest_bytes).hexdigest()})
        self.assertEqual(result["manifestSha256"], release["manifestSha256"])
        sha = (self.out / "package-unsigned.sha256").read_text().strip()
        self.assertEqual(sha, hashlib.sha256((self.out / "package-unsigned.zip").read_bytes()).hexdigest())

    def test_rollback_recorded(self):
        self.build(rollback_of="2026.10.19.1")
        self.assertEqual(json.loads(self.member("RELEASE.json"))["rollbackOf"], "2026.10.19.1")

    def test_deterministic(self):
        first = self.build()["unsignedSha256"]
        self.out = Path(tempfile.mkdtemp()) / "out"
        self.assertEqual(first, self.build()["unsignedSha256"])

    def test_refuses_private_workspace(self):
        (self.root / "ops").mkdir()
        with self.assertRaisesRegex(br.BuildError, "private workspace"):
            self.build()

    def test_refuses_bad_inputs(self):
        for kw in (dict(version="2026.13.01.1"), dict(version="2026.10.20.01"), dict(version="2026.10.20.0"),
                   dict(channel="beta"), dict(min_agent_version="x"), dict(built_at="2026-10-20 12:00:00"),
                   dict(rollback_of="nope")):
            with self.subTest(kw=kw), self.assertRaises(br.BuildError):
                self.build(**kw)

    def test_refuses_existing_output(self):
        self.out.mkdir(parents=True)
        with self.assertRaisesRegex(br.BuildError, "already exists"):
            self.build()

    def test_refuses_missing_root_file(self):
        (self.root / "LICENSE").unlink()
        with self.assertRaisesRegex(br.BuildError, "LICENSE"):
            self.build()


if __name__ == "__main__":
    unittest.main()
