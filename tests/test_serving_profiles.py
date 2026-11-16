import copy, hashlib, importlib.util, json, shutil, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("check_serving_profiles", ROOT / "tools" / "check-serving-profiles.py")
sp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sp)

CATALOG = json.loads((ROOT / "config" / "catalog.json").read_text(encoding="utf-8"))
COMPONENTS = json.loads((ROOT / "config" / "components.json").read_text(encoding="utf-8"))
SHIPPED_PATH = ROOT / "config" / "serving-profiles.json"
DIGEST_PATH = ROOT / "config" / "serving-profiles.sha256"
SHIPPED = json.loads(SHIPPED_PATH.read_text(encoding="utf-8"))
# Test rows only: the opt-in argument golden is planned from these. They pass the same checker as the shipped file.
GOOD = json.loads((ROOT / "tests" / "fixtures" / "serving-profiles-test.json").read_text(encoding="utf-8"))
ROW_KEYS = ["modelId", "modelSha256", "engineId", "backend", "id", "contextTotal", "cacheTypeK", "cacheTypeV", "slotsAllowed",
            "requiredFreeVramMiB", "fitTargetMiB", "evidence"]


def mutated(fn, index=0):
    doc = copy.deepcopy(GOOD)
    fn(doc["profiles"][index])
    return doc


def top(fn):
    doc = copy.deepcopy(GOOD)
    fn(doc)
    return doc


class ServingProfilesTests(unittest.TestCase):
    def errors(self, doc):
        return sp.validate(doc, CATALOG, COMPONENTS)

    def assertRefused(self, doc, text):
        errors = self.errors(doc)
        self.assertTrue(errors, "expected a refusal")
        self.assertTrue(any(text in e for e in errors), errors)

    # ---- the shipped file ----
    def test_shipped_file_has_the_schema_and_no_rows(self):
        self.assertEqual(SHIPPED, {"schema": "bitworks.fastllm-serving-profiles/v1", "profiles": [], "addOns": [], "sidecars": []})
        self.assertEqual(list(SHIPPED), ["schema", "profiles", "addOns", "sidecars"])

    def test_shipped_file_passes(self):
        self.assertEqual(self.errors(SHIPPED), [])

    def test_cli_passes_on_repo(self):
        self.assertEqual(sp.main([]), 0)

    def test_shipped_digest_matches(self):
        digest = hashlib.sha256(SHIPPED_PATH.read_bytes()).hexdigest()
        self.assertEqual(DIGEST_PATH.read_text(encoding="utf-8"), digest + "  serving-profiles.json\n")
        self.assertEqual(sp.check_digest(str(ROOT)), [])

    def test_workflow_runs_the_checker_beside_the_components_checker(self):
        lines = (ROOT / ".github" / "workflows" / "test.yml").read_text(encoding="utf-8").splitlines()
        self.assertIn("      - run: python3 tools/check-components.py", lines)
        self.assertEqual(lines[lines.index("      - run: python3 tools/check-components.py") + 1], "      - run: python3 tools/check-serving-profiles.py")

    # ---- the test rows ----
    def test_test_rows_pass_and_use_exactly_the_row_keys(self):
        self.assertEqual(self.errors(GOOD), [])
        self.assertGreaterEqual(len(GOOD["profiles"]), 4)
        for row in GOOD["profiles"]:
            self.assertEqual(list(row), ROW_KEYS)
            self.assertEqual(list(row["evidence"]), ["resultId", "measuredAt", "gpuClasses"])
        self.assertEqual(GOOD["addOns"], [])
        self.assertEqual(GOOD["sidecars"], [])

    def test_test_rows_never_ship(self):
        self.assertNotEqual(SHIPPED_PATH.read_bytes(), (ROOT / "tests" / "fixtures" / "serving-profiles-test.json").read_bytes())
        self.assertEqual(SHIPPED["profiles"], [])

    # ---- closed keys ----
    def test_top_level_shape(self):
        self.assertRefused(top(lambda d: d.update(schema="bitworks.fastllm-serving-profiles/v2")), "schema")
        self.assertRefused(top(lambda d: d.update(extra=1)), "unexpected keys")
        for key in ("schema", "profiles", "addOns", "sidecars"):
            self.assertRefused(top(lambda d, k=key: d.pop(k)), "missing keys")
        self.assertRefused(top(lambda d: d.update(profiles={})), "profiles must be a list")
        self.assertRefused([], "must be an object")
        self.assertRefused("x", "must be an object")

    def test_add_ons_and_sidecars_must_stay_empty(self):
        add_on = {"kind": "vision", "modelId": "m", "modelSha256": "0" * 64, "engineId": "llama.cpp-b10698-vulkan", "backend": "vulkan",
                  "extraFreeVramMiB": {"default": 1}, "evidence": {}}
        self.assertRefused(top(lambda d: d.update(addOns=[add_on])), "addOns must be an empty list")
        self.assertRefused(top(lambda d: d.update(sidecars=[{"role": "embedding"}])), "sidecars must be an empty list")
        self.assertRefused(top(lambda d: d.update(addOns={})), "addOns must be an empty list")
        self.assertRefused(top(lambda d: d.update(sidecars=None)), "sidecars must be an empty list")

    def test_row_keys_are_closed(self):
        self.assertRefused(mutated(lambda r: r.update(bogus=1)), "unexpected keys")
        self.assertRefused(mutated(lambda r: r.update(contextSize=8192)), "unexpected keys")
        for key in ROW_KEYS:
            self.assertRefused(mutated(lambda r, k=key: r.pop(k)), "missing keys")
        self.assertRefused(top(lambda d: d["profiles"].append("row")), "must be an object")
        self.assertRefused(mutated(lambda r: r["evidence"].update(url="https://example.invalid/")), "unexpected keys")
        for key in ("resultId", "measuredAt", "gpuClasses"):
            self.assertRefused(mutated(lambda r, k=key: r["evidence"].pop(k)), "missing keys")
        self.assertRefused(mutated(lambda r: r.update(evidence="measured")), "must be an object")

    # ---- model and engine binding ----
    def test_model_sha256(self):
        for bad in ("0" * 63, "0" * 65, "G" * 64, "", None, 5, GOOD["profiles"][0]["modelSha256"].upper()):
            self.assertRefused(mutated(lambda r, b=bad: r.update(modelSha256=b)), "modelSha256 must be 64 lowercase hex characters")
        self.assertRefused(mutated(lambda r: r.update(modelSha256="0" * 64)), "does not equal the catalog sha256")
        other = GOOD["profiles"][2]["modelSha256"]
        self.assertNotEqual(other, GOOD["profiles"][0]["modelSha256"])
        self.assertRefused(mutated(lambda r: r.update(modelSha256=other)), "does not equal the catalog sha256")

    def test_model_id(self):
        self.assertRefused(mutated(lambda r: r.update(modelId="no-such-model")), "is not a catalog model")
        self.assertRefused(mutated(lambda r: r.update(modelId="")), "is not a catalog model")
        self.assertRefused(mutated(lambda r: r.update(modelId=7)), "is not a catalog model")
        # The id of another catalog model with this row's sha256 is a mismatch, not a second key.
        self.assertRefused(mutated(lambda r: r.update(modelId=GOOD["profiles"][2]["modelId"])), "does not equal the catalog sha256")

    def test_engine_id(self):
        for bad in ("llama.cpp-b99999-vulkan", "llama.cpp", "", None, 3, "LLAMA.CPP-B10698-VULKAN"):
            self.assertRefused(mutated(lambda r, b=bad: r.update(engineId=b)), "is not the built-in engine or a listed llama.cpp engine component")
        runtime_ids = [c["id"] for c in COMPONENTS["components"] if c["kind"] != "engine"]
        self.assertTrue(runtime_ids)
        for bad in runtime_ids:
            self.assertRefused(mutated(lambda r, b=bad: r.update(engineId=b)), "is not the built-in engine or a listed llama.cpp engine component")

    def test_backend_must_be_the_engine_backend(self):
        self.assertRefused(mutated(lambda r: r.update(backend="hip")), "backend must be 'vulkan' for engine")
        self.assertRefused(mutated(lambda r: r.update(backend="Vulkan")), "backend must be 'vulkan' for engine")
        self.assertRefused(mutated(lambda r: r.update(backend="cpu")), "backend must be 'vulkan' for engine")
        hip = [c["id"] for c in COMPONENTS["components"] if c["kind"] == "engine" and c["platform"]["backend"] == "hip"]
        self.assertTrue(hip)
        self.assertRefused(mutated(lambda r: r.update(engineId=hip[0])), "backend must be 'hip' for engine")
        self.assertEqual(self.errors(mutated(lambda r: r.update(engineId=hip[0], backend="hip"))), [])

    def test_built_in_engine_id_follows_the_catalog(self):
        catalog = copy.deepcopy(CATALOG)
        catalog["engine"]["version"] = "b20000"
        components = {"schema": COMPONENTS["schema"], "components": [c for c in COMPONENTS["components"] if c["kind"] != "engine"]}
        # With the engine refreshed, every row for the previous build is refused until it is measured again.
        errors = sp.validate(GOOD, catalog, components)
        self.assertEqual(len([e for e in errors if "is not the built-in engine or a listed llama.cpp engine component" in e]), len(GOOD["profiles"]))
        doc = copy.deepcopy(GOOD)
        for row in doc["profiles"]:
            row["engineId"] = "llama.cpp-b20000-vulkan"
        self.assertEqual(sp.validate(doc, catalog, components), [])

    # ---- values ----
    def test_profile_id(self):
        for bad in ("short", "Long", "LONG", "", None, 1):
            self.assertRefused(mutated(lambda r, b=bad: r.update(id=b)), "id must be 'default' or 'long'")

    def test_context_total(self):
        for bad in (0, -1, 1.5, "65536", None, True):
            self.assertRefused(mutated(lambda r, b=bad: r.update(contextTotal=b)), "contextTotal must be a positive integer")
        # long means more context than the catalog default; default means exactly the catalog context and KV types.
        self.assertRefused(mutated(lambda r: r.update(contextTotal=32768)), "a long profile must have more context than the catalog")
        self.assertRefused(mutated(lambda r: r.update(contextTotal=16384)), "a long profile must have more context than the catalog")
        self.assertEqual(GOOD["profiles"][1]["id"], "default")
        self.assertRefused(mutated(lambda r: r.update(contextTotal=16384), index=1), "a default profile must use the catalog context")
        self.assertRefused(mutated(lambda r: r.update(contextTotal=65536), index=1), "a default profile must use the catalog context")
        self.assertRefused(mutated(lambda r: r.update(cacheTypeK="q8_0"), index=1), "a default profile must use the catalog KV types")
        self.assertRefused(mutated(lambda r: r.update(cacheTypeV="q8_0"), index=1), "a default profile must use the catalog KV types")

    def test_cache_types(self):
        for key in ("cacheTypeK", "cacheTypeV"):
            for bad in ("q4_0", "F16", "", None, 8, "q8_0 --host 0.0.0.0"):
                self.assertRefused(mutated(lambda r, k=key, b=bad: r.update({k: b})), key + " must be one of")
        self.assertEqual(self.errors(mutated(lambda r: r.update(cacheTypeK="f16", cacheTypeV="f16"))), [])

    def test_slots_allowed(self):
        for bad in ([], [3], [0], [1, 2, 4], [2, 1], [1, 1], ["1"], [True], [1.0], None, 1, "1,2"):
            self.assertRefused(mutated(lambda r, b=bad: r.update(slotsAllowed=b)), "slotsAllowed must be [1], [2] or [1, 2]")
        self.assertEqual(self.errors(mutated(lambda r: r.update(slotsAllowed=[2]))), [])
        self.assertRefused(mutated(lambda r: r.update(contextTotal=65537)), "contextTotal must divide evenly by every allowed slot count")
        self.assertEqual(self.errors(mutated(lambda r: r.update(contextTotal=65537, slotsAllowed=[1]))), [])

    def test_memory_numbers(self):
        for bad in (0, -5, 1.5, "21500", None, True):
            self.assertRefused(mutated(lambda r, b=bad: r.update(requiredFreeVramMiB=b)), "requiredFreeVramMiB must be a positive integer")
        for bad in (-1, 1.5, "896", None, False):
            self.assertRefused(mutated(lambda r, b=bad: r.update(fitTargetMiB=b)), "fitTargetMiB must be a non-negative integer")
        self.assertEqual(self.errors(mutated(lambda r: r.update(fitTargetMiB=0))), [])

    def test_evidence(self):
        for bad in ("", None, 5, "has space", "x" * 121, "../x"):
            self.assertRefused(mutated(lambda r, b=bad: r["evidence"].update(resultId=b)), "evidence.resultId must be")
        for bad in ("2026-01-01", "2026-01-01T00:00:00", "2026-13-01T00:00:00Z", "yesterday", "", None, 20260101):
            self.assertRefused(mutated(lambda r, b=bad: r["evidence"].update(measuredAt=b)), "evidence.measuredAt must be")
        for bad in ([], [""], ["ok", 5], None, "24gb", [" "], ["x" * 81]):
            self.assertRefused(mutated(lambda r, b=bad: r["evidence"].update(gpuClasses=b)), "evidence.gpuClasses must be")

    def test_duplicate_rows(self):
        doc = copy.deepcopy(GOOD)
        doc["profiles"].append(copy.deepcopy(doc["profiles"][0]))
        self.assertRefused(doc, "duplicate row")
        # The same model and engine may have one row per profile id.
        ids = {(r["modelSha256"], r["engineId"], r["backend"]) for r in GOOD["profiles"]}
        self.assertLess(len(ids), len(GOOD["profiles"]))

    def test_every_problem_is_reported(self):
        doc = mutated(lambda r: r.update(contextTotal=0, cacheTypeK="x", requiredFreeVramMiB=0))
        self.assertGreaterEqual(len(self.errors(doc)), 3)

    # ---- the command line and the digest file ----
    def make_root(self, document=None, digest=None, text=None):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, str(root), True)
        (root / "config").mkdir()
        for name in ("catalog.json", "components.json"):
            shutil.copyfile(str(ROOT / "config" / name), str(root / "config" / name))
        raw = text if text is not None else json.dumps(document, indent=2) + "\n"
        (root / "config" / "serving-profiles.json").write_bytes(raw.encode("utf-8"))
        if digest is None:
            digest = hashlib.sha256(raw.encode("utf-8")).hexdigest() + "  serving-profiles.json\n"
        if digest is not False:
            (root / "config" / "serving-profiles.sha256").write_bytes(digest.encode("utf-8"))
        return root

    def test_cli_on_a_valid_tree(self):
        self.assertEqual(sp.main(["--root", str(self.make_root(GOOD))]), 0)
        self.assertEqual(sp.main(["--root", str(self.make_root(SHIPPED))]), 0)

    def test_cli_refuses_an_invalid_file(self):
        self.assertEqual(sp.main(["--root", str(self.make_root(mutated(lambda r: r.update(bogus=1))))]), 1)
        self.assertEqual(sp.main(["--root", str(self.make_root(top(lambda d: d.update(addOns=[{}]))))]), 1)
        self.assertEqual(sp.main(["--root", str(self.make_root(text="{ not json"))]), 1)
        self.assertEqual(sp.main(["--root", str(Path(tempfile.mkdtemp()))]), 1)

    def test_cli_refuses_a_digest_that_does_not_match(self):
        self.assertEqual(sp.main(["--root", str(self.make_root(GOOD, digest="0" * 64 + "  serving-profiles.json\n"))]), 1)
        self.assertEqual(sp.main(["--root", str(self.make_root(GOOD, digest=False))]), 1)
        good_hex = hashlib.sha256((json.dumps(GOOD, indent=2) + "\n").encode("utf-8")).hexdigest()
        for bad in (good_hex + "  other.json\n", good_hex + "\n", good_hex.upper() + "  serving-profiles.json\n", ""):
            self.assertEqual(sp.main(["--root", str(self.make_root(GOOD, digest=bad))]), 1, bad)

    def test_digest_problem_text(self):
        root = self.make_root(GOOD, digest="0" * 64 + "  serving-profiles.json\n")
        self.assertTrue(any("serving-profiles.sha256 does not match" in e for e in sp.check_digest(str(root))))


if __name__ == "__main__":
    unittest.main()
