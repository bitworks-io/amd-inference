"""SBOM and notice-inventory generator tests; offline and deterministic."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/build-sbom.py"
CATALOG = ROOT / "config/catalog.json"
# A staged public tree has no ops/, so the generator needs --public-tree there; the private tree must not pass it.
PUBLIC_TREE = not (ROOT / "ops").exists()
# The windows-lab-runtime profile needs the private gateway NuGet lock. Its path is private (ops/lab-paths.json), so this
# public test never names it; a staged public tree has no ops/ and skips the profile.
LAB_LOCK = None if PUBLIC_TREE else ROOT / json.loads((ROOT / "ops" / "lab-paths.json").read_text())["nugetLock"]
PROFILES = ("public-source",) + (() if PUBLIC_TREE else ("windows-lab-runtime",))


def run(*args):
    args = list(args)
    if PUBLIC_TREE and args and args[0] == "sbom" and "--public-tree" not in args:
        args.append("--public-tree")
    if args and args[0] == "sbom" and "windows-lab-runtime" in args and "--nuget-lock" not in args:
        args += ["--nuget-lock", str(LAB_LOCK)]
    return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)],
                          capture_output=True, text=True, cwd=ROOT)


def prop(component, name):
    for item in component.get("properties", []):
        if item["name"] == name:
            return item["value"]
    return None


class SbomTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.base = Path(cls.temp.name)
        cls.catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
        cls.boms = {}
        for profile in PROFILES:
            out = cls.base / f"{profile}.json"
            result = run("sbom", "--profile", profile, "--out", out)
            assert result.returncode == 0, result.stderr
            cls.boms[profile] = json.loads(out.read_text(encoding="utf-8"))

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def components(self, profile="public-source"):
        return self.boms[profile]["components"]

    def app(self, profile="public-source"):
        found = [c for c in self.components(profile) if c["type"] == "application"]
        self.assertEqual(len(found), 1)
        return found[0]

    def test_cyclonedx_shape_and_no_timestamp_by_default(self):
        for profile in PROFILES:
            bom = self.boms[profile]
            self.assertEqual(bom["bomFormat"], "CycloneDX")
            self.assertEqual(bom["specVersion"], "1.5")
            self.assertRegex(bom["serialNumber"], r"^urn:uuid:[0-9a-f-]{36}$")
            self.assertNotIn("timestamp", bom["metadata"])

    def test_serial_number_is_rfc4122_urn_uuid(self):
        # CycloneDX 1.5 JSON schema pattern for metadata serialNumber.
        import re
        pattern = re.compile(r"^urn:uuid:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
        for profile, bom in self.boms.items():
            self.assertRegex(bom["serialNumber"], pattern, profile)

    def test_byte_deterministic_across_runs(self):
        for profile in PROFILES:
            outs = []
            for index in range(2):
                out = self.base / f"det-{profile}-{index}.json"
                self.assertEqual(run("sbom", "--profile", profile, "--out", out).returncode, 0)
                outs.append(out.read_bytes())
            self.assertEqual(outs[0], outs[1])
            self.assertEqual(outs[0], (self.base / f"{profile}.json").read_bytes())
        out = self.base / "notices-a.json"
        out2 = self.base / "notices-b.json"
        self.assertEqual(run("notices", "--out", out).returncode, 0)
        self.assertEqual(run("notices", "--out", out2).returncode, 0)
        self.assertEqual(out.read_bytes(), out2.read_bytes())

    def test_timestamp_only_when_requested(self):
        out = self.base / "ts.json"
        self.assertEqual(run("sbom", "--profile", "public-source", "--out", out,
                             "--timestamp", "2026-10-06T00:00:00Z").returncode, 0)
        self.assertEqual(json.loads(out.read_text())["metadata"]["timestamp"], "2026-10-06T00:00:00Z")

    def test_fastllm_is_apache_2_0(self):
        for profile in PROFILES:
            app = self.app(profile)
            self.assertEqual(app["licenses"], [{"license": {"id": "Apache-2.0"}}])
            self.assertEqual(prop(app, "bitworks:licenseDecision"), "owner-decision-5-2026-10-14")

    def test_fastllm_claims_only_apache(self):
        for profile in PROFILES:
            text = json.dumps(self.app(profile))
            self.assertNotIn('"MIT"', text)
            self.assertNotIn("NOASSERTION", text)

    def test_notices_nuget_lock_relative_resolves_against_root(self):
        if PUBLIC_TREE:
            self.skipTest("no private lock in a public tree")
        relative = json.loads((ROOT / "ops" / "lab-paths.json").read_text())["nugetLock"]
        with tempfile.TemporaryDirectory() as other:
            out = Path(other) / "n.json"
            result = subprocess.run([sys.executable, str(SCRIPT), "notices", "--root", str(ROOT), "--out", str(out),
                                     "--nuget-lock", relative], capture_output=True, text=True, cwd=other)
            self.assertEqual(result.returncode, 0, result.stderr)
            comps = [c for c in json.loads(out.read_text())["components"] if c["kind"] == "nuget-package"]
            self.assertTrue(comps)
            for comp in comps:
                self.assertEqual(comp["declarationSource"]["file"], relative)

    def test_runtime_profile_requires_nuget_lock(self):
        if PUBLIC_TREE:
            self.skipTest("no private lock in a public tree")
        out = self.base / "x.json"
        result = subprocess.run([sys.executable, str(SCRIPT), "sbom", "--profile", "windows-lab-runtime", "--out", str(out)],
                                capture_output=True, text=True, cwd=ROOT)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--nuget-lock", result.stderr)

    def test_every_enabled_asset_present_with_matching_sha256(self):
        assets = self.catalog["engine"]["assets"]
        for profile in PROFILES:
            by_ref = {c["bom-ref"]: c for c in self.components(profile)}
            for name, asset in assets.items():
                if not asset.get("enabled"):
                    continue
                matches = [c for c in by_ref.values()
                           if c.get("name") == asset["file"]]
                self.assertEqual(len(matches), 1, name)
                comp = matches[0]
                self.assertEqual(comp["hashes"], [{"alg": "SHA-256", "content": asset["sha256"]}])
                self.assertEqual(prop(comp, "bitworks:sizeBytes"), str(asset["sizeBytes"]))
                self.assertNotEqual(comp.get("scope"), "excluded")
                urls = [r["url"] for r in comp["externalReferences"]]
                self.assertIn(asset["url"], urls)
                self.assertEqual(comp["licenses"], [{"license": {"id": "MIT"}}])
                self.assertEqual(prop(comp, "bitworks:licenseTextBundledInArchive"), "false")

    def test_disabled_lanes_are_excluded_with_reason(self):
        for name, asset in self.catalog["engine"]["assets"].items():
            if asset.get("enabled"):
                continue
            comp = [c for c in self.components() if c.get("name") == asset["file"]][0]
            self.assertEqual(comp["scope"], "excluded")
            self.assertEqual(prop(comp, "bitworks:disabledReason"), asset["disabledReason"])
            self.assertEqual(prop(comp, "bitworks:licenseTextBundledInArchive"), "unknown")

    def test_models_are_references_not_redistributed(self):
        models = [c for c in self.components() if c["type"] == "machine-learning-model"
                  and prop(c, "bitworks:catalogId") in {m["id"] for m in self.catalog["models"]}]
        self.assertEqual(len(models), len(self.catalog["models"]))
        by_id = {prop(c, "bitworks:catalogId"): c for c in models}
        for model in self.catalog["models"]:
            comp = by_id[model["id"]]
            self.assertEqual(prop(comp, "bitworks:redistributed"), "false")
            self.assertEqual(comp["hashes"], [{"alg": "SHA-256", "content": model["sha256"]}])
            self.assertEqual(prop(comp, "bitworks:repository"), model["repository"])
            self.assertEqual(prop(comp, "bitworks:revision"), model["revision"])
            self.assertEqual(prop(comp, "bitworks:file"), model["file"])
        for comp in self.components():
            if comp["type"] == "machine-learning-model":
                self.assertNotEqual(prop(comp, "bitworks:redistributed"), "true")

    @unittest.skipIf(PUBLIC_TREE, "windows-lab-runtime profile needs the private gateway NuGet lock (not in a staged public tree)")
    def test_nuget_only_in_runtime_profile(self):
        def nuget(profile):
            return [c for c in self.components(profile) if c.get("purl", "").startswith("pkg:nuget/")]
        self.assertEqual(nuget("public-source"), [])
        names = {c["name"]: c for c in nuget("windows-lab-runtime")}
        self.assertEqual(names["Yarp.ReverseProxy"]["version"], "2.3.0")
        self.assertIn("System.IO.Hashing", names)
        self.assertTrue(prop(names["Yarp.ReverseProxy"], "bitworks:nuget.contentHash"))
        self.assertEqual(names["Yarp.ReverseProxy"]["licenses"], [{"expression": "NOASSERTION"}])

    def test_components_sorted_and_unique(self):
        for profile in PROFILES:
            refs = [c["bom-ref"] for c in self.components(profile)]
            self.assertEqual(refs, sorted(refs))
            self.assertEqual(len(refs), len(set(refs)))

    def test_notices_flags_gaps(self):
        out = self.base / "notices.json"
        self.assertEqual(run("notices", "--out", out).returncode, 0)
        data = json.loads(out.read_text())
        self.assertTrue(data["project"]["licenseFilePresent"])
        self.assertEqual(data["project"]["licenseDecision"], "Apache-2.0")
        gap_ids = {g["id"] for g in data["gaps"]}
        self.assertNotIn("fastllm-license-file-missing", gap_ids)
        self.assertNotIn("engine-license-text-missing", gap_ids)
        for comp in data["components"]:
            self.assertIn("declarationSource", comp)
            self.assertIn("licenseTextPresentInRepo", comp)
            if not comp["licenseTextPresentInRepo"]:
                self.assertTrue(comp.get("gap"), comp["id"])
        engine = [c for c in data["components"] if c["id"] == "llama.cpp"][0]
        self.assertEqual(engine["declaredLicense"], "MIT")
        self.assertEqual(engine["declarationSource"]["file"], "config/catalog.json")
        self.assertEqual(engine["declarationSource"]["jsonPath"], "$.engine.license")

    def test_check_mode_detects_one_byte_change(self):
        cases = (("sbom", ["--profile", "public-source"]), ("notices", []))
        for command, extra in cases:
            out = self.base / f"check-{command}.json"
            self.assertEqual(run(command, *extra, "--out", out).returncode, 0)
            self.assertEqual(run(command, *extra, "--out", out, "--check").returncode, 0)
            payload = bytearray(out.read_bytes())
            payload[len(payload) // 2] ^= 0x01
            out.write_bytes(bytes(payload))
            self.assertNotEqual(run(command, *extra, "--out", out, "--check").returncode, 0)
            missing = self.base / f"missing-{command}.json"
            self.assertNotEqual(run(command, *extra, "--out", missing, "--check").returncode, 0)
            self.assertFalse(missing.exists())

    def test_refuses_catalog_asset_without_sha256(self):
        for target in ("enabled", "disabled", "model"):
            catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
            if target == "model":
                del catalog["models"][0]["sha256"]
            else:
                want = target == "enabled"
                for asset in catalog["engine"]["assets"].values():
                    if bool(asset.get("enabled")) == want:
                        del asset["sha256"]
                        break
            bad = self.base / f"bad-{target}.json"
            bad.write_text(json.dumps(catalog), encoding="utf-8")
            out = self.base / f"bad-{target}-out.json"
            for command in (["sbom", "--profile", "public-source"], ["notices"]):
                result = run(*command, "--catalog", bad, "--out", out)
                self.assertNotEqual(result.returncode, 0, (target, command))
                self.assertIn("sha256", result.stderr.lower())
                self.assertFalse(out.exists())



class SourceManifestPublicTreeTest(unittest.TestCase):
    """The SBOM source manifest follows the export's fail-closed rule: a public checkout (no ops/) needs --public-tree."""

    def test_public_checkout_requires_public_tree(self):
        import importlib.util as _ilu
        import tempfile as _tempfile
        repo = Path(__file__).resolve().parents[1]
        def load(name, rel):
            spec = _ilu.spec_from_file_location(name, repo / rel)
            module = _ilu.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
        stage = load("fastllm_stage_pt", "tools/stage-public-source.py")
        sbom = load("fastllm_build_sbom_pt", "tools/build-sbom.py")
        with _tempfile.TemporaryDirectory() as tmp:
            public = Path(tmp) / "public"
            stage.stage(repo, public, public_tree=PUBLIC_TREE)
            self.assertFalse((public / "ops").exists())
            with self.assertRaises(ValueError):
                sbom.source_manifest(public)
            entries = dict(sbom.source_manifest(public, public_tree=True))
            self.assertIn("tools/build-sbom.py", entries)


if __name__ == "__main__":
    unittest.main()
