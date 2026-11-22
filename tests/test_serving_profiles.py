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

    def test_add_ons_and_sidecars_must_be_lists(self):
        # CHANGED EXPECTATION: this test used to pin "addOns must be an empty list". Vision add-on rows are accepted now (VisionAddOnRowTests).
        self.assertRefused(top(lambda d: d.update(addOns={})), "addOns must be a list")
        self.assertRefused(top(lambda d: d.update(addOns=None)), "addOns must be a list")
        self.assertRefused(top(lambda d: d.update(sidecars=None)), "sidecars must be a list")
        self.assertRefused(top(lambda d: d.update(sidecars={})), "sidecars must be a list")
        # A sidecar row is checked like a profile row: a row that is only a role is refused for its missing keys.
        self.assertRefused(top(lambda d: d.update(sidecars=[{"role": "embedding"}])), "missing keys")

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


# ---- sidecars[]: the measured row of an embedding sidecar (a second llama-server with its own model, CPU placement) ----
# Test rows and a test component only: config/serving-profiles.json ships no sidecar row and config/components.json no embedding model.
SIDECAR_COMPONENTS = json.loads((ROOT / "tests" / "fixtures" / "embedding-components-test.json").read_text(encoding="utf-8"))
SIDECAR_GOOD = json.loads((ROOT / "tests" / "fixtures" / "embedding-profiles-test.json").read_text(encoding="utf-8"))
SIDECAR_KEYS = ["role", "componentId", "componentSha256", "engineId", "backend", "placement", "contextSize", "pooling", "dimension", "evidence"]


def sidecar(fn):
    doc = copy.deepcopy(SIDECAR_GOOD)
    fn(doc["sidecars"][0])
    return doc


class SidecarRowTests(unittest.TestCase):
    def errors(self, doc, components=None):
        return sp.validate(doc, CATALOG, SIDECAR_COMPONENTS if components is None else components)

    def assertRefused(self, doc, text, components=None):
        errors = self.errors(doc, components)
        self.assertTrue(errors, "expected a refusal")
        self.assertTrue(any(text in e for e in errors), errors)

    def test_shipped_file_has_no_sidecar_row_and_no_embedding_component(self):
        self.assertEqual(SHIPPED["sidecars"], [])
        self.assertEqual([c["id"] for c in COMPONENTS["components"] if c.get("kind") == "embedding-model"], [])

    def test_test_row_passes_and_uses_exactly_the_row_keys(self):
        self.assertEqual(self.errors(SIDECAR_GOOD), [])
        self.assertEqual(len(SIDECAR_GOOD["sidecars"]), 1)
        self.assertEqual(list(SIDECAR_GOOD["sidecars"][0]), SIDECAR_KEYS)
        self.assertEqual(list(SIDECAR_GOOD["sidecars"][0]["evidence"]), ["resultId", "measuredAt", "gpuClasses"])

    def test_test_row_is_refused_against_the_shipped_components(self):
        # The fixture component is not a shipped component: the same row against config/components.json names an unknown component.
        self.assertRefused(SIDECAR_GOOD, "is not a listed embedding-model component", components=COMPONENTS)

    def test_row_keys_are_closed(self):
        self.assertRefused(sidecar(lambda r: r.update(bogus=1)), "unexpected keys")
        self.assertRefused(sidecar(lambda r: r.update(requiredFreeVramMiB=512)), "unexpected keys")
        self.assertRefused(sidecar(lambda r: r.update(modelId="m")), "unexpected keys")
        for key in SIDECAR_KEYS:
            self.assertRefused(sidecar(lambda r, k=key: r.pop(k)), "missing keys")
        self.assertRefused(top_sidecars(lambda rows: rows.append("row")), "must be an object")
        self.assertRefused(sidecar(lambda r: r["evidence"].update(url="https://example.invalid/")), "unexpected keys")

    def test_role(self):
        for bad in ("rerank", "Embedding", "", None, 1):
            self.assertRefused(sidecar(lambda r, b=bad: r.update(role=b)), "role must be 'embedding'")

    def test_component_binding(self):
        self.assertRefused(sidecar(lambda r: r.update(componentId="other-embedding-model")), "is not a listed embedding-model component")
        self.assertRefused(sidecar(lambda r: r.update(componentId=7)), "is not a listed embedding-model component")
        self.assertRefused(sidecar(lambda r: r.update(componentSha256="0" * 64)), "componentSha256 does not equal the sha256 of the model file")
        for bad in ("A" * 64, "0" * 63, 5, None):
            self.assertRefused(sidecar(lambda r, b=bad: r.update(componentSha256=b)), "componentSha256 must be 64 lowercase hex characters")
        # A component of another kind with the same id is not an embedding model.
        other = copy.deepcopy(SIDECAR_COMPONENTS)
        other["components"][0]["kind"] = "model"
        self.assertRefused(SIDECAR_GOOD, "is not a listed embedding-model component", components=other)

    def test_engine_is_the_built_in_engine(self):
        self.assertRefused(sidecar(lambda r: r.update(engineId="llama.cpp-b1-vulkan")), "engineId must be the built-in engine")
        # A listed HIP engine component is a known engine for a profile row, but a sidecar runs on the built-in engine only.
        hip = next(c["id"] for c in COMPONENTS["components"] if c.get("kind") == "engine" and c.get("platform", {}).get("backend") == "hip")
        with_hip = copy.deepcopy(SIDECAR_COMPONENTS)
        with_hip["components"].append(next(c for c in COMPONENTS["components"] if c["id"] == hip))
        self.assertRefused(sidecar(lambda r: r.update(engineId=hip, backend="hip")), "engineId must be the built-in engine", components=with_hip)
        self.assertRefused(sidecar(lambda r: r.update(backend="hip")), "backend must be 'vulkan'")
        self.assertRefused(sidecar(lambda r: r.update(backend="cpu")), "backend must be 'vulkan'")

    def test_built_in_engine_id_follows_the_catalog(self):
        catalog = copy.deepcopy(CATALOG)
        catalog["engine"]["version"] = "b99999"
        self.assertTrue(any("engineId must be the built-in engine" in e for e in sp.validate(SIDECAR_GOOD, catalog, SIDECAR_COMPONENTS)))

    def test_placement_is_cpu_only(self):
        for bad in ("gpu", "auto", "CPU", "", None):
            self.assertRefused(sidecar(lambda r, b=bad: r.update(placement=b)), "placement must be 'cpu'")

    def test_numbers_and_pooling(self):
        for bad in (0, -1, 1.5, "8192", True, None, 1048577):
            self.assertRefused(sidecar(lambda r, b=bad: r.update(contextSize=b)), "contextSize must be a whole number from 1 to 1048576")
        for bad in (0, -4, 2.0, "1024", True, None, 65537):
            self.assertRefused(sidecar(lambda r, b=bad: r.update(dimension=b)), "dimension must be a whole number from 1 to 65536")
        for bad in ("none", "rank", "MEAN", "", None, 3):
            self.assertRefused(sidecar(lambda r, b=bad: r.update(pooling=b)), "pooling must be one of")
        for good in ("mean", "cls", "last"):
            self.assertEqual(self.errors(sidecar(lambda r, g=good: r.update(pooling=g))), [])

    def test_evidence(self):
        self.assertRefused(sidecar(lambda r: r["evidence"].update(resultId="")), "evidence.resultId")
        self.assertRefused(sidecar(lambda r: r["evidence"].update(measuredAt="yesterday")), "evidence.measuredAt")
        self.assertRefused(sidecar(lambda r: r["evidence"].update(gpuClasses=[])), "evidence.gpuClasses")
        self.assertRefused(sidecar(lambda r: r.update(evidence="measured")), "must be an object")

    def test_duplicate_rows(self):
        doc = copy.deepcopy(SIDECAR_GOOD)
        doc["sidecars"].append(copy.deepcopy(doc["sidecars"][0]))
        self.assertRefused(doc, "duplicate sidecar row")

    def test_profiles_and_sidecars_are_checked_together(self):
        doc = copy.deepcopy(GOOD)
        doc["sidecars"] = copy.deepcopy(SIDECAR_GOOD["sidecars"])
        self.assertEqual(self.errors(doc), [])
        doc["sidecars"][0]["placement"] = "gpu"
        doc["profiles"][0]["contextTotal"] = 0
        errors = self.errors(doc)
        self.assertTrue(any("placement must be 'cpu'" in e for e in errors) and any("contextTotal" in e for e in errors), errors)

    def test_cli_counts_sidecar_rows(self):
        root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, str(root), True)
        (root / "config").mkdir()
        shutil.copyfile(str(ROOT / "config" / "catalog.json"), str(root / "config" / "catalog.json"))
        (root / "config" / "components.json").write_text(json.dumps(SIDECAR_COMPONENTS), encoding="utf-8")
        raw = json.dumps(SIDECAR_GOOD, indent=2) + "\n"
        (root / "config" / "serving-profiles.json").write_bytes(raw.encode("utf-8"))
        (root / "config" / "serving-profiles.sha256").write_bytes((hashlib.sha256(raw.encode("utf-8")).hexdigest() + "  serving-profiles.json\n").encode("ascii"))
        self.assertEqual(sp.main(["--root", str(root)]), 0)
        (root / "config" / "serving-profiles.json").write_bytes(raw.replace('"cpu"', '"gpu"').encode("utf-8"))
        self.assertEqual(sp.main(["--root", str(root)]), 1)


# ---- addOns[]: the measured extra memory of the vision option (a projector beside the text model) ----
# Test rows and a test component only: config/serving-profiles.json ships no add-on row and config/components.json no projector.
VISION_COMPONENTS = json.loads((ROOT / "tests" / "fixtures" / "vision-components-test.json").read_text(encoding="utf-8"))
VISION_GOOD = json.loads((ROOT / "tests" / "fixtures" / "vision-profiles-test.json").read_text(encoding="utf-8"))
VISION_PARITY = json.loads((ROOT / "tests" / "fixtures" / "vision-addon-parity-cases.json").read_text(encoding="utf-8"))
VISION_KEYS = ["kind", "modelId", "modelSha256", "engineId", "backend", "componentId", "extraFreeVramMiB", "evidence"]


def vision(fn, index=0):
    doc = copy.deepcopy(VISION_GOOD)
    fn(doc["addOns"][index])
    return doc


class VisionAddOnRowTests(unittest.TestCase):
    def errors(self, doc, components=None):
        return sp.validate(doc, CATALOG, VISION_COMPONENTS if components is None else components)

    def assertRefused(self, doc, text, components=None):
        errors = self.errors(doc, components)
        self.assertTrue(errors, "expected a refusal")
        self.assertTrue(any(text in e for e in errors), errors)

    def test_shipped_file_has_no_add_on_row_and_no_projector_component(self):
        self.assertEqual(SHIPPED["addOns"], [])
        self.assertEqual([c["id"] for c in COMPONENTS["components"] if c.get("kind") == "projector"], [])
        self.assertEqual(self.errors(SHIPPED, COMPONENTS), [])
        # Byte-identical to main (6436d2c): this PR adds no real row.
        self.assertEqual(hashlib.sha256(SHIPPED_PATH.read_bytes()).hexdigest(), "927651eabb7fd2ab3c1ffb99e742cdfa2dcd06b891aa329ed6fc48a8117f2160")

    def test_valid_rows_pass_and_use_exactly_the_row_keys(self):
        self.assertEqual(self.errors(VISION_GOOD), [])
        self.assertEqual(len(VISION_GOOD["addOns"]), 2)
        for row in VISION_GOOD["addOns"]:
            self.assertEqual(list(row), VISION_KEYS)
            self.assertEqual(list(row["evidence"]), ["resultId", "measuredAt", "gpuClasses"])

    def test_test_rows_never_ship(self):
        self.assertNotEqual(SHIPPED_PATH.read_bytes(), (ROOT / "tests" / "fixtures" / "vision-profiles-test.json").read_bytes())

    def test_test_row_is_refused_against_the_shipped_components(self):
        # The fixture projector is not a shipped component: the same row against config/components.json names an unknown component.
        self.assertRefused(VISION_GOOD, "is not a listed projector component", components=COMPONENTS)

    def test_mtp_and_ngram_rows_are_still_refused(self):
        for kind in ("mtp", "ngram", "audio", "", None, 1, "Vision"):
            self.assertRefused(vision(lambda r, k=kind: r.update(kind=k)), "kind must be 'vision'")

    def test_row_keys_are_closed(self):
        self.assertRefused(vision(lambda r: r.update(bogus=1)), "unexpected keys")
        self.assertRefused(vision(lambda r: r.update(requiredFreeVramMiB=512)), "unexpected keys")
        for key in VISION_KEYS:
            self.assertRefused(vision(lambda r, k=key: r.pop(k)), "missing keys")
        self.assertRefused(top(lambda d: d.update(addOns=["row"])), "must be an object")
        self.assertRefused(vision(lambda r: r["evidence"].update(url="https://example.invalid/")), "unexpected keys")

    def test_add_ons_must_be_a_list(self):
        self.assertRefused(top(lambda d: d.update(addOns={})), "addOns must be a list")

    def test_extra_memory_is_a_positive_whole_number_per_known_profile_id(self):
        for bad in (0, -5, 1.5, "900", True, None, [900]):
            self.assertRefused(vision(lambda r, b=bad: r["extraFreeVramMiB"].update(default=b)), "extraFreeVramMiB['default'] must be a positive whole number")
        self.assertRefused(vision(lambda r: r["extraFreeVramMiB"].update(huge=100)), "unknown profile id")
        self.assertRefused(vision(lambda r: r.update(extraFreeVramMiB={})), "extraFreeVramMiB must be a non-empty object")
        self.assertRefused(vision(lambda r: r.update(extraFreeVramMiB=[900])), "extraFreeVramMiB must be a non-empty object")
        self.assertRefused(vision(lambda r: r.update(extraFreeVramMiB=900)), "extraFreeVramMiB must be a non-empty object")
        # A row may cover one profile id only.
        self.assertEqual(self.errors(vision(lambda r: r.update(extraFreeVramMiB={"long": 1}))), [])

    def test_model_and_engine_binding(self):
        for bad in ("0" * 63, "G" * 64, "", None, 5, VISION_GOOD["addOns"][0]["modelSha256"].upper()):
            self.assertRefused(vision(lambda r, b=bad: r.update(modelSha256=b)), "modelSha256 must be 64 lowercase hex characters")
        self.assertRefused(vision(lambda r: r.update(modelSha256="0" * 64)), "does not equal the catalog sha256")
        self.assertRefused(vision(lambda r: r.update(modelId="no-such-model")), "is not a catalog model")
        self.assertRefused(vision(lambda r: r.update(engineId="llama.cpp-b1-vulkan")), "is not the built-in engine or a listed llama.cpp engine component")
        self.assertRefused(vision(lambda r: r.update(backend="hip")), "backend must be 'vulkan'")
        self.assertRefused(vision(lambda r: r.update(backend="cpu")), "backend must be 'vulkan'")

    def test_projector_component_binding(self):
        self.assertRefused(vision(lambda r: r.update(componentId="other-projector")), "is not a listed projector component")
        self.assertRefused(vision(lambda r: r.update(componentId=7)), "is not a listed projector component")
        other = copy.deepcopy(VISION_COMPONENTS)
        other["components"][0]["kind"] = "embedding-model"
        self.assertRefused(VISION_GOOD, "is not a listed projector component", components=other)

    def test_evidence(self):
        self.assertRefused(vision(lambda r: r["evidence"].update(resultId="")), "evidence.resultId")
        self.assertRefused(vision(lambda r: r["evidence"].update(measuredAt="yesterday")), "evidence.measuredAt")
        self.assertRefused(vision(lambda r: r["evidence"].update(gpuClasses=[])), "evidence.gpuClasses")
        self.assertRefused(vision(lambda r: r.update(evidence="measured")), "must be an object")

    def test_duplicate_rows(self):
        doc = copy.deepcopy(VISION_GOOD)
        doc["addOns"].append(copy.deepcopy(doc["addOns"][0]))
        self.assertRefused(doc, "duplicate add-on row")
        # The same key with other values is still a duplicate; the key is kind + model sha256 + engine + backend.
        doc = copy.deepcopy(VISION_GOOD)
        doc["addOns"].append(copy.deepcopy(doc["addOns"][0]))
        doc["addOns"][2]["extraFreeVramMiB"] = {"long": 1}
        self.assertRefused(doc, "duplicate add-on row")

    def test_profiles_sidecars_and_add_ons_are_checked_together(self):
        doc = copy.deepcopy(VISION_GOOD)
        doc["profiles"][0]["contextTotal"] = 0
        doc["addOns"][0]["kind"] = "mtp"
        errors = self.errors(doc)
        self.assertTrue(any("contextTotal" in e for e in errors) and any("kind must be 'vision'" in e for e in errors), errors)

    def test_parity_cases_with_the_powershell_loader(self):
        # tests/optin-arguments-tests.ps1 reads the same table and requires the same verdict from the loader. These are shape checks only: the
        # checks that need the catalog or the component list (model, engine, component) are checker-only, because the loader binds a row to the
        # plan's exact model sha256, engine id and backend.
        self.assertGreaterEqual(len(VISION_PARITY["cases"]), 20)
        for case in VISION_PARITY["cases"]:
            doc = copy.deepcopy(VISION_GOOD)
            doc["addOns"] = copy.deepcopy(case["addOns"])
            self.assertEqual(bool(self.errors(doc)), case["refuse"], case["name"])

    def test_cli_counts_add_on_rows(self):
        root = Path(tempfile.mkdtemp())
        (root / "config").mkdir()
        shutil.copyfile(str(ROOT / "config" / "catalog.json"), str(root / "config" / "catalog.json"))
        (root / "config" / "components.json").write_text(json.dumps(VISION_COMPONENTS), encoding="utf-8")
        raw = json.dumps(VISION_GOOD, indent=2) + "\n"
        (root / "config" / "serving-profiles.json").write_bytes(raw.encode("utf-8"))
        (root / "config" / "serving-profiles.sha256").write_bytes((hashlib.sha256(raw.encode("utf-8")).hexdigest() + "  serving-profiles.json\n").encode("ascii"))
        self.assertEqual(sp.main(["--root", str(root)]), 0)
        (root / "config" / "serving-profiles.json").write_bytes(raw.replace('"vision"', '"mtp"').encode("utf-8"))
        self.assertEqual(sp.main(["--root", str(root)]), 1)


def top_sidecars(fn):
    doc = copy.deepcopy(SIDECAR_GOOD)
    fn(doc["sidecars"])
    return doc


if __name__ == "__main__":
    unittest.main()
