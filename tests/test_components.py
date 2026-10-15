import copy, importlib.util, json, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("check_components", ROOT / "tools" / "check-components.py")
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)

CATALOG = json.loads((ROOT / "config" / "catalog.json").read_text())
GOOD = json.loads((ROOT / "config" / "components.json").read_text())


def mutated(fn):
    doc = copy.deepcopy(GOOD)
    fn(doc["components"][0])
    return doc


def second(**over):
    doc = copy.deepcopy(GOOD)
    comp = copy.deepcopy(doc["components"][0])
    comp.update(id="amd-hip-runtime-6.4", kind="runtime", requires=[], **over)
    comp.pop("adapter", None); comp.pop("entryPoint", None)
    doc["components"].append(comp)
    return doc


class ComponentsTests(unittest.TestCase):
    def errors(self, doc, catalog=CATALOG):
        return cc.validate(doc, catalog)

    def assertRefused(self, doc, text=None):
        errors = self.errors(doc)
        self.assertTrue(errors, "expected a refusal")
        if text:
            self.assertTrue(any(text in e for e in errors), errors)

    def test_repo_file_passes(self):
        self.assertEqual(self.errors(GOOD), [])

    def test_cli_passes_on_repo(self):
        self.assertEqual(cc.main([]), 0)

    def test_valid_second_component_with_requires(self):
        doc = second()
        doc["components"][0]["requires"] = ["amd-hip-runtime-6.4"]
        self.assertEqual(self.errors(doc), [])

    def test_schema_and_keys(self):
        self.assertRefused(dict(copy.deepcopy(GOOD), schema="other/v1"), "schema")
        self.assertRefused(dict(copy.deepcopy(GOOD), extra=1), "top level")
        self.assertRefused(mutated(lambda c: c.update(bogus=1)), "unexpected keys")
        self.assertRefused(mutated(lambda c: c.pop("license")), "missing keys")
        self.assertRefused(mutated(lambda c: c["source"].update(bogus=1)), "unexpected keys")

    def test_ids(self):
        doc = copy.deepcopy(GOOD); doc["components"].append(copy.deepcopy(doc["components"][0]))
        self.assertRefused(doc, "duplicate")
        for bad in ("Bad_Id", "-x", "a", "x" * 130):
            self.assertRefused(mutated(lambda c, b=bad: c.update(id=b)), "id must match")

    def test_enums(self):
        self.assertRefused(mutated(lambda c: c.update(kind="plugin")), "kind")
        self.assertRefused(mutated(lambda c: c["license"].update(consent="maybe")), "consent")
        self.assertRefused(mutated(lambda c: c["source"].update(format="rar")), "format")

    def test_url_rules(self):
        self.assertRefused(mutated(lambda c: c["source"].update(url="http://github.com/x/releases/y.zip")), "https")
        self.assertRefused(mutated(lambda c: c["source"].update(url="https://evil.example/y.zip")), "host")
        ok = mutated(lambda c: c["source"].update(url="https://objects.githubusercontent.com/y.zip"))
        self.assertEqual([e for e in self.errors(ok) if "host" in e], [])

    def test_hash_and_size(self):
        self.assertRefused(mutated(lambda c: c["source"].update(sha256="abc")), "sha256")
        self.assertRefused(mutated(lambda c: c["source"].update(sha256="A" * 64)), "sha256")
        self.assertRefused(mutated(lambda c: c["source"].update(sizeBytes=0)), "sizeBytes")
        self.assertRefused(mutated(lambda c: c["source"].update(sizeBytes=True)), "sizeBytes")

    def test_manifest_rules(self):
        self.assertRefused(mutated(lambda c: c["source"].update(fileManifest=[])), "fileManifest")
        for bad in ("../x.dll", "/abs.dll", "C:\\x.dll", "a/../b.dll"):
            self.assertRefused(mutated(lambda c, b=bad: c["source"]["fileManifest"].append({"path": b, "sizeBytes": 1, "sha256": "0" * 64})), "unsafe path")
        self.assertRefused(mutated(lambda c: c["source"]["fileManifest"][0].pop("sha256")), "missing keys")
        self.assertRefused(mutated(lambda c: c["source"]["fileManifest"][0].update(sha256="zz")), "sha256")

    def test_requires_must_exist(self):
        self.assertRefused(mutated(lambda c: c.update(requires=["nope"])), "unknown component")

    def test_engine_needs_adapter_and_entrypoint_in_manifest(self):
        self.assertRefused(mutated(lambda c: c.pop("adapter")), "adapter")
        self.assertRefused(mutated(lambda c: c.pop("entryPoint")), "entryPoint")
        self.assertRefused(mutated(lambda c: c.update(entryPoint="missing.exe")), "not in the fileManifest")

    def test_base_engine_mirrors_catalog(self):
        self.assertRefused(mutated(lambda c: c["source"].update(sizeBytes=c["source"]["sizeBytes"] + 1)), "differs from config/catalog.json")
        self.assertRefused(mutated(lambda c: c["source"].update(sha256="1" * 64)), "differs from config/catalog.json")
        self.assertRefused(mutated(lambda c: c["source"]["fileManifest"][0].update(sizeBytes=1)), "differs from config/catalog.json")
        doc = copy.deepcopy(GOOD); doc["components"][0]["id"] = "llama.cpp-b1-vulkan"
        self.assertRefused(doc, "missing")

    def test_cli_exit_1_on_bad_file(self):
        root = Path(tempfile.mkdtemp()); (root / "config").mkdir()
        (root / "config" / "catalog.json").write_text(json.dumps(CATALOG))
        (root / "config" / "components.json").write_text(json.dumps(mutated(lambda c: c.update(kind="x"))))
        self.assertEqual(cc.main(["--root", str(root)]), 1)


if __name__ == "__main__":
    unittest.main()
