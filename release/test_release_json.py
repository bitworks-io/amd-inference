import hashlib, json, os, tempfile, unittest, zipfile
import release_json as rj

def write(p, b):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as h: h.write(b)

class ReleaseJsonTests(unittest.TestCase):
    def tree(self):
        d = tempfile.mkdtemp()
        write(os.path.join(d, "src", "a.ps1"), b"a")
        write(os.path.join(d, "FASTLLM-VERSION.json"), b"{}")
        write(os.path.join(d, "RELEASE.json"), rj.canonical({"schema": rj.SCHEMA, "component": "fastllm-lab", "version": "2026.10.13.90",
            "channel": "canary", "minAgentVersion": "0.10.0", "builtAtUtc": "2026-10-13T12:00:00Z", "manifestSha256": "0" * 64}))
        write(os.path.join(d, "FastLLM.cat"), b"cat")
        return d

    def test_manifest_matches_pack_format_and_excludes_release_and_catalog(self):
        d = self.tree(); sha = rj.regen_manifest(d)
        data = open(os.path.join(d, "MANIFEST.json"), "rb").read()
        self.assertEqual(sha, hashlib.sha256(data).hexdigest())
        entries = [{"bytes": 2, "path": "FASTLLM-VERSION.json", "sha256": hashlib.sha256(b"{}").hexdigest()},
                   {"bytes": 1, "path": "src/a.ps1", "sha256": hashlib.sha256(b"a").hexdigest()}]
        self.assertEqual(data, json.dumps({"schema": "fastllm.private-native-test-package.v1", "fileCount": 2, "files": entries},
                                          indent=1, sort_keys=True).encode())

    def test_update_release_sets_manifest_sha(self):
        d = self.tree(); sha = rj.regen_manifest(d); rj.update_release(d)
        self.assertEqual(json.load(open(os.path.join(d, "RELEASE.json")))["manifestSha256"], sha)

    def test_offer_adds_package_sha(self):
        d = self.tree(); rj.regen_manifest(d); rj.update_release(d)
        z = os.path.join(d, "..", "p.zip")
        with zipfile.ZipFile(z, "w") as zz: zz.writestr("x", b"x")
        out = os.path.join(d, "..", "OFFER.json"); rj.write_offer(d, z, out)
        offer = json.load(open(out))
        self.assertEqual(offer["packageSha256"], hashlib.sha256(open(z, "rb").read()).hexdigest())
        self.assertEqual({k: v for k, v in offer.items() if k != "packageSha256"}, json.load(open(os.path.join(d, "RELEASE.json"))))

    def test_rejects_wrong_component(self):
        d = self.tree(); p = os.path.join(d, "RELEASE.json"); r = json.load(open(p)); r["component"] = "fan-control"
        write(p, rj.canonical(r))
        with self.assertRaises(ValueError): rj.update_release(d)

if __name__ == "__main__":
    unittest.main()
