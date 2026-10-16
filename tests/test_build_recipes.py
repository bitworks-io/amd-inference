import copy, importlib.util, json, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_recipes", ROOT / "tools" / "build-recipes.py")
br = importlib.util.module_from_spec(spec)
spec.loader.exec_module(br)

ENTRY = {
    "id": "rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k", "variant": "rx-7900-xtx", "gpuCount": 1, "model": "qwen3.8-27b-ud-q4-k-m",
    "runtime": {"contextSize": 32768, "parallel": 1, "cacheTypeK": "f16", "cacheTypeV": "f16", "fitTargetMiB": 512, "vulkanBarMitigation": "auto"},
    "engineBuild": "b10698", "recommended": True,
    "expected": {"generationTokS": 32.73, "promptTokS": 654.14, "firstTextS": 0.82, "promptTokens": 512, "contextTokens": 32768,
                 "engineBuild": "b10698", "mitigation": "on", "measuredAt": "2026-10-07", "producer": "fastllm-benchmark-vnext vnext.1"},
    "evidence": {"url": "https://bitworks.io/amd/results/x", "resultId": "r1", "publishedAt": "2026-10-20"},
}


def community(origin="community-reproduced", rid="c1", **expected):
    exp = dict(ENTRY["expected"], **expected)
    record = {"id": rid, "origin": origin, "variant": "rx-7900-xtx", "gpuCount": 1, "model": "qwen3.8-27b-ud-q4-k-m",
            "runtime": ENTRY["runtime"], "engineBuild": "b10698", "recommended": False,
            "expected": exp, "evidence": copy.deepcopy(ENTRY["evidence"]),
            "source": {"author": "a", "url": "https://example.com/p", "postedAt": "2026-10-01", "recordId": "r"}}
    if origin == "community-reproduced":
        record["reproduction"] = repro(exp["generationTokS"], exp["promptTokS"])
    return record


def repro(gen, prompt):
    return {"resultId": "res-1", "batchManifestSha256": "ab" * 32, "measuredAt": "2026-10-14", "generationTokS": gen, "promptTokS": prompt}


HIP_COMPONENTS = {"components": [
    {"id": "llama.cpp-b10698-vulkan", "kind": "engine", "version": "b10698", "platform": {"backend": "vulkan"}},
    {"id": "llama.cpp-hip-b11658", "kind": "engine", "version": "b11658", "platform": {"backend": "hip"}, "requires": ["amd-rt"]},
    {"id": "amd-rt", "kind": "runtime", "version": "10.0.0"}]}
HIP_ENTRY = {"id": "rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip", "origin": "bitworks-experimental", "variant": "rx-7900-xtx", "gpuCount": 1,
             "model": "qwen3.8-27b-ud-q4-k-m", "components": {"engine": "llama.cpp-hip-b11658"}, "engineBuild": "b11658",
             "runtime": {"contextSize": 32768, "cacheTypeK": "f16", "cacheTypeV": "f16"}}


HIP_VERIFIED = {"id": "rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip", "variant": "rx-7900-xtx", "gpuCount": 1, "model": "qwen3.8-27b-ud-q4-k-m",
                "components": {"engine": "llama.cpp-hip-b11658"}, "engineBuild": "b11658",
                "runtime": {"contextSize": 32768, "cacheTypeK": "f16", "cacheTypeV": "f16"},
                "expected": {"generationTokS": 33.72, "promptTokS": 876.3, "firstTextS": 0.59, "promptTokens": 512, "contextTokens": 32768,
                             "engineBuild": "b11658", "mitigation": "not-applicable", "measuredAt": "2026-10-15", "producer": "fastllm-benchmark-vnext vnext.3"},
                "evidence": {"url": "https://bitworks.io/amd-inference/recipes/x-hip/#lab-observation", "resultId": "r2", "publishedAt": "2026-10-16"}}


class RecipeBuilderTests(unittest.TestCase):
    def tree(self, entries=None, records=None):
        root = Path(tempfile.mkdtemp())
        (root / "config").mkdir(); (root / "data").mkdir()
        catalog = {"engine": {"version": "b10698"}, "models": [{"id": "qwen3.8-27b-ud-q4-k-m", "contextSize": 32768},
                                                              {"id": "qwen3.8-27b-ud-iq4-xs", "contextSize": 16384}]}
        (root / "config" / "catalog.json").write_text(json.dumps(catalog))
        (root / "config" / "components.json").write_text(json.dumps({"components": [{"id": "llama.cpp-b10698-vulkan", "kind": "engine", "version": "b10698"}]}))
        (root / "config" / "gpu-variants.json").write_text((ROOT / "config" / "gpu-variants.json").read_text())
        (root / "data" / "verified-recipes.json").write_text(json.dumps({"schema": "bitworks.fastllm-verified-recipes/v1", "entries": entries or []}))
        (root / "data" / "community-records.json").write_text(json.dumps({"schema": "bitworks.fastllm-community-recipes/v1", "records": records or []}))
        return root

    def test_published_entry_becomes_a_bitworks_recipe(self):
        document, skipped = br.build(self.tree([ENTRY]))
        self.assertEqual(skipped, [])
        recipe = document["recipes"][0]
        self.assertEqual(recipe["origin"], "bitworks")
        self.assertEqual(recipe["label"], "Measured by Bitworks on this card")
        self.assertEqual(recipe["components"], {"engine": "llama.cpp-b10698-vulkan", "model": "qwen3.8-27b-ud-q4-k-m"})
        self.assertEqual(recipe["gpu"], {"variant": "rx-7900-xtx", "count": 1})
        self.assertIsNone(recipe["compelling"])

    def test_unpublished_entry_is_skipped_not_shipped(self):
        entry = copy.deepcopy(ENTRY); entry["evidence"]["publishedAt"] = None
        document, skipped = br.build(self.tree([entry]))
        self.assertEqual(document["recipes"], [])
        self.assertIn("no live evidence page", skipped[0])

    def test_refusals(self):
        cases = [("variant", "rx-9999"), ("model", "missing-model"), ("engineBuild", "b1"),
                 (("runtime", "vulkanBarMitigation"), "maybe"), (("runtime", "vulkanBarMitigation"), "on"), (("runtime", "vulkanBarMitigation"), "off"),
                 (("runtime", "parallel"), 2), (("runtime", "parallel"), 0), (("runtime", "cacheTypeK"), "q2_k"), (("runtime", "cacheTypeV"), "--evil"),
                 (("runtime", "fitTargetMiB"), 0), (("runtime", "contextSize"), 65536),
                 (("expected", "generationTokS"), 0), (("expected", "engineBuild"), None), (("expected", "engineBuild"), "b1"),
                 (("evidence", "url"), "http://example.com/x")]
        for key, value in cases:
            with self.subTest(key=key):
                entry = copy.deepcopy(ENTRY)
                if isinstance(key, tuple): entry[key[0]][key[1]] = value
                else: entry[key] = value
                with self.assertRaises(br.RecipeError):
                    br.build(self.tree([entry]))

    def test_components_json_constrains_the_engine_reference(self):
        good = {"components": [{"id": "llama.cpp-b10698-vulkan", "kind": "engine", "version": "b10698"}]}
        for comps, ok in ((good, True),
                          ({"components": [dict(good["components"][0], version="b1")]}, False),
                          ({"components": [dict(good["components"][0], kind="runtime")]}, False),
                          ({"components": [dict(good["components"][0], id="other")]}, False)):
            root = self.tree([ENTRY])
            (root / "config" / "components.json").write_text(json.dumps(comps))
            if ok:
                document, _ = br.build(root)
                self.assertIn("config/components.json", document["inputs"])
            else:
                with self.assertRaises(br.RecipeError):
                    br.build(root)

    def test_two_recommended_for_one_card_is_refused(self):
        other = copy.deepcopy(ENTRY); other["id"] = "rx-7900-xtx.other"
        with self.assertRaises(br.RecipeError):
            br.build(self.tree([ENTRY, other]))

    def test_community_compelling_rule(self):
        def record(gen, prompt, ctx=32768):
            return {"id": "c1", "origin": "community-reproduced", "variant": "rx-7900-xtx", "gpuCount": 1, "model": "qwen3.8-27b-ud-q4-k-m",
                    "runtime": ENTRY["runtime"], "engineBuild": "b10698", "recommended": False,
                    "expected": dict(ENTRY["expected"], generationTokS=gen, promptTokS=prompt, contextTokens=ctx),
                    "reproduction": repro(gen, prompt), "evidence": ENTRY["evidence"], "source": {"author": "a", "url": "https://example.com/p", "postedAt": "2026-10-01", "recordId": "r"}}
        for gen, prompt, ctx, want in [(37.7, 654.14, 32768, True), (33.0, 990.0, 32768, True), (36.0, 700.0, 32768, False), (40.0, 654.0, 16384, False)]:
            with self.subTest(gen=gen, prompt=prompt, ctx=ctx):
                document, skipped = br.build(self.tree([ENTRY], [record(gen, prompt, ctx)]))
                shipped = [r for r in document["recipes"] if r["origin"] == "community-reproduced"]
                self.assertEqual(bool(shipped), want)
                if want:
                    self.assertEqual(shipped[0]["label"], "Community recipe, reproduced by Bitworks")
                else:
                    self.assertEqual(skipped, ["c1: not-compelling"])

    def test_reproduced_community_entry_needs_a_live_bitworks_page(self):
        # "Reproduced by Bitworks" with no result page behind it is the overclaim the live-page rule exists to stop.
        for label, evidence in [("no evidence", None), ("empty evidence", {}), ("url without date", {"url": "https://bitworks.io/amd/results/c"}),
                                ("date without url", {"publishedAt": "2026-10-20"}), ("null date", {"url": "https://bitworks.io/amd/results/c", "publishedAt": None})]:
            with self.subTest(label):
                record = community(generationTokS=40.0)
                record["evidence"] = evidence
                document, skipped = br.build(self.tree([ENTRY], [record]))
                self.assertEqual([r["id"] for r in document["recipes"]], [ENTRY["id"]])
                self.assertIn("c1: no live evidence page", skipped[0])

    def test_reproduced_community_entry_with_a_live_page_ships(self):
        document, skipped = br.build(self.tree([ENTRY], [community(generationTokS=40.0)]))
        self.assertEqual(skipped, [])
        self.assertEqual(sorted(r["origin"] for r in document["recipes"]), ["bitworks", "community-reproduced"])

    def test_reproduced_community_entry_off_the_bitworks_site_is_refused(self):
        record = community(generationTokS=40.0)
        record["evidence"]["url"] = "https://evil.example/bitworks.io/"
        with self.assertRaises(br.RecipeError):
            br.build(self.tree([ENTRY], [record]))

    def test_experimental_community_entry_needs_no_bitworks_page(self):
        record = community("community-experimental", generationTokS=40.0)
        record["evidence"] = None
        document, skipped = br.build(self.tree([ENTRY], [record]))
        self.assertEqual(skipped, [])
        self.assertEqual(sorted(r["origin"] for r in document["recipes"]), ["bitworks", "community-experimental"])

    def test_recommended_is_for_verified_bitworks_recipes_only(self):
        # No Bitworks recipe for this card, so the "more than one recommended" rule cannot be what rejects the record.
        for origin in ("community-reproduced", "community-experimental"):
            with self.subTest(origin=origin):
                record = community(origin, generationTokS=40.0)
                record["recommended"] = True
                with self.assertRaisesRegex(br.RecipeError, "recommended is for verified Bitworks recipes only"):
                    br.build(self.tree([], [record]))

    def test_without_a_bitworks_peer_only_the_fastest_record_is_compelling(self):
        slow, fast, tie = community(rid="c-slow", generationTokS=20.0), community(rid="c-fast", generationTokS=30.0), community(rid="b-tie", generationTokS=30.0)
        document, skipped = br.build(self.tree([], [slow, fast, tie]))
        flags = {r["id"]: r["compelling"]["isCompelling"] for r in document["recipes"]}
        self.assertEqual(flags, {"b-tie": True})
        self.assertEqual(sorted(skipped), ["c-fast: not-compelling", "c-slow: not-compelling"])

    def test_without_a_bitworks_peer_a_slower_experimental_record_is_skipped(self):
        fast = community(rid="c-fast", generationTokS=30.0)
        slow = community("community-experimental", rid="e-slow", generationTokS=10.0)
        document, skipped = br.build(self.tree([], [fast, slow]))
        self.assertEqual([r["id"] for r in document["recipes"]], ["c-fast"])
        self.assertTrue(document["recipes"][0]["compelling"]["isCompelling"])
        self.assertEqual(skipped, ["e-slow: experimental entries must be compelling"])

    def test_the_peerless_rule_is_per_card_and_gpu_count(self):
        xt = community(rid="x1", generationTokS=15.0)
        xt["variant"] = "rx-7900-xt"; xt["model"] = "qwen3.8-27b-ud-iq4-xs"
        xt["runtime"] = dict(ENTRY["runtime"], contextSize=16384)
        document, _ = br.build(self.tree([], [community(rid="c-xtx", generationTokS=30.0), xt]))
        self.assertTrue(all(r["compelling"]["isCompelling"] for r in document["recipes"]))

    def test_runtime_fields_the_planner_applies_verbatim_are_valid(self):
        entry = copy.deepcopy(ENTRY); entry["runtime"].update(parallel=1, cacheTypeK="q8_0", cacheTypeV="q8_0", fitTargetMiB=768)
        document, _ = br.build(self.tree([entry]))
        self.assertEqual(document["recipes"][0]["runtime"]["cacheTypeK"], "q8_0")

    def test_a_model_that_is_not_auto_eligible_is_refused_except_for_experimental(self):
        def tree_with_experimental_model(entries, records):
            root = self.tree(entries, records)
            catalog = json.loads((root / "config" / "catalog.json").read_text())
            catalog["models"].append({"id": "qwen3.8-27b-ud-iq3-xxs", "contextSize": 16384, "autoEligible": False})
            (root / "config" / "catalog.json").write_text(json.dumps(catalog))
            return root
        runtime = dict(ENTRY["runtime"], contextSize=16384)
        for origin in ("bitworks", "community-reproduced"):
            with self.subTest(origin=origin):
                if origin == "bitworks":
                    entry = copy.deepcopy(ENTRY); entry["id"] = "rx-7900-xtx.exp"; entry["model"] = "qwen3.8-27b-ud-iq3-xxs"; entry["runtime"] = runtime; entry["recommended"] = False
                    args = ([entry], [])
                else:
                    record = community(generationTokS=40.0); record["model"] = "qwen3.8-27b-ud-iq3-xxs"; record["runtime"] = runtime
                    args = ([ENTRY], [record])
                with self.assertRaises(br.RecipeError):
                    br.build(tree_with_experimental_model(*args))
        record = community("community-experimental", generationTokS=40.0); record["model"] = "qwen3.8-27b-ud-iq3-xxs"; record["runtime"] = runtime
        document, _ = br.build(tree_with_experimental_model([ENTRY], [record]))
        self.assertIn("community-experimental", [r["origin"] for r in document["recipes"]])

    def test_reproduced_entry_needs_a_valid_reproduction_block(self):
        cases = [("missing", None), ("no resultId", {"resultId": ""}), ("short sha", {"batchManifestSha256": "ab" * 31}),
                 ("non-hex sha", {"batchManifestSha256": "zz" * 32}), ("bad date", {"measuredAt": "yesterday"}),
                 ("zero gen", {"generationTokS": 0}), ("zero prompt", {"promptTokS": 0}), ("string gen", {"generationTokS": "40"})]
        for label, change in cases:
            with self.subTest(label):
                record = community(generationTokS=40.0)
                if change is None: del record["reproduction"]
                else: record["reproduction"].update(change)
                with self.assertRaises(br.RecipeError):
                    br.build(self.tree([ENTRY], [record]))

    def test_compelling_is_computed_from_the_reproduction_not_the_claim(self):
        record = community(generationTokS=60.0, promptTokS=2000.0)
        record["reproduction"] = repro(33.0, 660.0)
        document, skipped = br.build(self.tree([ENTRY], [record]))
        self.assertEqual([r["id"] for r in document["recipes"]], [ENTRY["id"]])
        self.assertEqual(skipped, ["c1: not-compelling"])
        record = community(generationTokS=33.0, promptTokS=660.0)
        record["reproduction"] = repro(40.0, 660.0)
        document, _ = br.build(self.tree([ENTRY], [record]))
        shipped = [r for r in document["recipes"] if r["origin"] == "community-reproduced"][0]
        self.assertEqual(shipped["compelling"]["baselineRecipe"], ENTRY["id"])
        self.assertEqual(shipped["compelling"]["generationGainPct"], 22.2)
        self.assertEqual(shipped["compelling"]["promptGainPct"], 0.9)
        self.assertEqual(shipped["reproduction"], record["reproduction"])

    def test_bitworks_recipes_carry_no_reproduction_key(self):
        document, _ = br.build(self.tree([ENTRY]))
        self.assertNotIn("reproduction", document["recipes"][0])

    def test_experimental_entry_components_must_exist_with_matching_kinds(self):
        comps = {"components": [{"id": "llama.cpp-b10698-vulkan", "kind": "engine", "version": "b10698"},
                                {"id": "rt-1", "kind": "runtime", "version": "1"}, {"id": "dr-1", "kind": "draft", "version": "1"}]}
        cases = [({}, True), ({"runtime": "rt-1", "draft": "dr-1"}, True), ({"runtime": "missing"}, False), ({"draft": "rt-1"}, False),
                 ({"runtime": "dr-1"}, False), ({"engine": "other-engine"}, False)]
        for refs, ok in cases:
            with self.subTest(refs=refs):
                record = community("community-experimental", generationTokS=40.0)
                if refs: record["components"] = refs
                root = self.tree([ENTRY], [record])
                (root / "config" / "components.json").write_text(json.dumps(comps))
                if ok:
                    document, _ = br.build(root)
                    exp = [r for r in document["recipes"] if r["origin"] == "community-experimental"][0]
                    self.assertFalse(exp["recommended"])
                    self.assertEqual(exp["label"], "Experimental community recipe, not reproduced by Bitworks")
                    self.assertEqual(exp["source"], record["source"])
                    self.assertNotIn("reproduction", exp)
                else:
                    with self.assertRaises(br.RecipeError):
                        br.build(root)

    def test_experimental_entry_needs_a_source_block(self):
        for key in ("author", "url", "postedAt", "recordId"):
            with self.subTest(key=key):
                record = community("community-experimental", generationTokS=40.0)
                del record["source"][key]
                with self.assertRaises(br.RecipeError):
                    br.build(self.tree([ENTRY], [record]))

    def test_experimental_entry_without_components_json_is_refused(self):
        root = self.tree([ENTRY], [community("community-experimental", generationTokS=40.0)])
        (root / "config" / "components.json").unlink()
        with self.assertRaises(br.RecipeError):
            br.build(root)

    def test_demoted_entry_is_skipped_with_its_reason_and_never_ships(self):
        for origin in ("community-reproduced", "community-experimental"):
            with self.subTest(origin=origin):
                record = community(origin, generationTokS=40.0)
                record.update(demotedAt="2026-10-20", demotionReason="regressed on b10750")
                document, skipped = br.build(self.tree([ENTRY], [record]))
                self.assertEqual([r["id"] for r in document["recipes"]], [ENTRY["id"]])
                self.assertEqual(skipped, ["c1: demoted: regressed on b10750"])

    def test_a_half_specified_demotion_is_refused(self):
        for change in ({"demotedAt": "2026-10-20"}, {"demotionReason": "x"}, {"demotedAt": "soon", "demotionReason": "x"}, {"demotedAt": "2026-10-20", "demotionReason": " "}):
            with self.subTest(change=change):
                record = community(generationTokS=40.0); record.update(change)
                with self.assertRaises(br.RecipeError):
                    br.build(self.tree([ENTRY], [record]))

    def test_output_is_deterministic_and_check_detects_drift(self):
        root = self.tree([ENTRY])
        self.assertEqual(subprocess.run([sys.executable, str(ROOT / "tools" / "build-recipes.py"), "--root", str(root)]).returncode, 0)
        first = (root / "config" / "recipes.json").read_bytes()
        self.assertEqual(subprocess.run([sys.executable, str(ROOT / "tools" / "build-recipes.py"), "--root", str(root), "--check"]).returncode, 0)
        (root / "config" / "recipes.json").write_bytes(first.replace(b"32.73", b"99.99"))
        self.assertEqual(subprocess.run([sys.executable, str(ROOT / "tools" / "build-recipes.py"), "--root", str(root), "--check"]).returncode, 1)

    def hip_verified_tree(self, entry=None, comps=None, vulkan_recommended=True):
        vulkan = copy.deepcopy(ENTRY); vulkan["recommended"] = vulkan_recommended
        root = self.tree([vulkan, entry or copy.deepcopy(HIP_VERIFIED)])
        (root / "config" / "components.json").write_text(json.dumps(comps or HIP_COMPONENTS))
        return root

    def test_a_measured_hip_entry_becomes_a_bitworks_recipe_that_is_not_recommended_unless_it_says_so(self):
        # A recommended Vulkan twin that the HIP entry measurably beats is itself refused by the evidence rule.
        with self.assertRaisesRegex(br.RecipeError, "recommended but not measured at least as good as"):
            br.build(self.hip_verified_tree())
        document, skipped = br.build(self.hip_verified_tree(vulkan_recommended=False))
        self.assertEqual(skipped, [])
        by_id = {r["id"]: r for r in document["recipes"]}
        recipe = by_id[HIP_VERIFIED["id"]]
        self.assertEqual(recipe["origin"], "bitworks")
        self.assertEqual(recipe["label"], "Measured by Bitworks on this card")
        self.assertEqual(recipe["components"], {"engine": "llama.cpp-hip-b11658", "model": "qwen3.8-27b-ud-q4-k-m"})
        self.assertEqual(recipe["engineBuild"], "b11658")
        self.assertIs(recipe["recommended"], False)
        self.assertNotIn("vulkanBarMitigation", recipe["runtime"])
        self.assertEqual(recipe["expected"]["mitigation"], "not-applicable")
        self.assertEqual(recipe["evidence"]["publishedAt"], "2026-10-16")
        vulkan = by_id[ENTRY["id"]]
        self.assertIs(vulkan["recommended"], False)
        self.assertEqual(vulkan["components"]["engine"], "llama.cpp-b10698-vulkan")
        self.assertEqual(vulkan["expected"]["mitigation"], "on")

    def pair(self, hip_gen=33.72, hip_prompt=876.3, vulkan_gen=32.75, vulkan_prompt=507.02, hip_recommended=True, mutate_hip=None):
        vulkan = copy.deepcopy(ENTRY); vulkan["recommended"] = False
        vulkan["expected"].update(generationTokS=vulkan_gen, promptTokS=vulkan_prompt)
        hip = copy.deepcopy(HIP_VERIFIED); hip["recommended"] = hip_recommended
        hip["expected"].update(generationTokS=hip_gen, promptTokS=hip_prompt)
        if mutate_hip:
            mutate_hip(hip)
        root = self.tree([vulkan, hip])
        (root / "config" / "components.json").write_text(json.dumps(HIP_COMPONENTS))
        return root

    def test_bitworks_hip_entry_may_be_recommended(self):
        root = self.pair()
        document, skipped = br.build(root)
        by_id = {r["id"]: r for r in document["recipes"]}
        self.assertIs(by_id[HIP_VERIFIED["id"]]["recommended"], True)
        self.assertIs(by_id[ENTRY["id"]]["recommended"], False)
        self.assertEqual(subprocess.run([sys.executable, str(ROOT / "tools" / "build-recipes.py"), "--root", str(root)], capture_output=True).returncode, 0)

    def test_recommended_must_not_be_slower_in_prompt(self):
        with self.assertRaises(br.RecipeError) as caught:
            br.build(self.pair(hip_prompt=500))
        self.assertIn(HIP_VERIFIED["id"], str(caught.exception))
        self.assertIn(ENTRY["id"], str(caught.exception))
        self.assertIn("recommended but not measured at least as good as", str(caught.exception))

    def test_recommended_generation_floor_is_97_percent(self):
        with self.assertRaises(br.RecipeError):
            br.build(self.pair(hip_gen=31.7))
        br.build(self.pair(hip_gen=31.8))
        # The boundary compares unrounded values: exactly 97.0% passes, just under fails.
        br.build(self.pair(hip_gen=97.0, vulkan_gen=100.0))
        with self.assertRaises(br.RecipeError):
            br.build(self.pair(hip_gen=96.99, vulkan_gen=100.0))

    def test_evidence_check_is_keyed_on_variant_count_and_model(self):
        # A faster Vulkan sibling on another model or another GPU count is not compared with the recommended entry.
        def other_model(hip):
            hip["model"] = "qwen3.8-27b-ud-iq4-xs"; hip["runtime"]["contextSize"] = 16384; hip["expected"]["contextTokens"] = 16384
        br.build(self.pair(hip_prompt=500, mutate_hip=other_model))
        br.build(self.pair(hip_prompt=500, mutate_hip=lambda hip: hip.update(gpuCount=2)))

    def test_one_recommended_per_variant_and_count_still_enforced(self):
        vulkan = copy.deepcopy(ENTRY)
        hip = copy.deepcopy(HIP_VERIFIED); hip["recommended"] = True
        root = self.tree([vulkan, hip])
        (root / "config" / "components.json").write_text(json.dumps(HIP_COMPONENTS))
        with self.assertRaisesRegex(br.RecipeError, "more than one recommended recipe"):
            br.build(root)

    def test_shipped_data_xt_and_xtx_recommend_hip(self):
        document, _ = br.build(ROOT)
        by_id = {r["id"]: r for r in document["recipes"]}
        for hip_id in ("rx-7900-xt.qwen3.8-27b-ud-iq4-xs.16k.hip", "rx-7900-xtx.qwen3.8-27b-ud-q4-k-m.32k.hip"):
            self.assertIs(by_id[hip_id]["recommended"], True, hip_id)
            self.assertIs(by_id[hip_id[:-len(".hip")]]["recommended"], False, hip_id)

    def test_experimental_and_community_entries_still_cannot_be_recommended(self):
        for value in (True, 1):
            with self.subTest(origin="bitworks-experimental", value=value):
                entry = copy.deepcopy(HIP_ENTRY); entry["recommended"] = value
                with self.assertRaisesRegex(br.RecipeError, "recommended is for verified Bitworks recipes only"):
                    br.build(self.hip_tree(entry))
        for origin in ("community-reproduced", "community-experimental"):
            with self.subTest(origin=origin):
                record = community(origin, generationTokS=40.0); record["recommended"] = True
                with self.assertRaisesRegex(br.RecipeError, "recommended is for verified Bitworks recipes only"):
                    br.build(self.tree([ENTRY], [record]))

    def test_a_hip_entry_without_a_live_evidence_page_is_skipped(self):
        entry = copy.deepcopy(HIP_VERIFIED); del entry["evidence"]
        document, skipped = br.build(self.hip_verified_tree(entry))
        self.assertEqual([r["id"] for r in document["recipes"]], [ENTRY["id"]])
        self.assertEqual(len(skipped), 1)

    def test_not_applicable_mitigation_is_for_non_vulkan_engines_only(self):
        for mitigation in ("on", "off", "auto", None):
            with self.subTest(mitigation=mitigation):
                entry = copy.deepcopy(HIP_VERIFIED); entry["expected"]["mitigation"] = mitigation
                with self.assertRaisesRegex(br.RecipeError, "expected.mitigation must be not-applicable"):
                    br.build(self.hip_verified_tree(entry))
        vulkan = copy.deepcopy(ENTRY); vulkan["expected"]["mitigation"] = "not-applicable"
        with self.assertRaisesRegex(br.RecipeError, "expected.mitigation must be on or off"):
            br.build(self.tree([vulkan]))

    def test_a_measured_hip_entry_is_checked_like_the_other_entries(self):
        def mutate(key, value, section=None):
            entry = copy.deepcopy(HIP_VERIFIED)
            (entry[section] if section else entry)[key] = value
            return entry
        cases = {
            "runtime.vulkanBarMitigation": (mutate("vulkanBarMitigation", "auto", "runtime"), "runtime.vulkanBarMitigation is for Vulkan engines only"),
            "engineBuild differs from the component": (dict(mutate("engineBuild", "b1"), expected=dict(HIP_VERIFIED["expected"], engineBuild="b1")), "is not the engine component's version"),
            "expected.engineBuild differs": (mutate("engineBuild", "b1", "expected"), "expected.engineBuild must equal"),
            "unknown engine": (mutate("engine", "missing", "components"), "is not an engine in config/components.json"),
            "unknown runtime": (dict(HIP_VERIFIED, components={"engine": "llama.cpp-hip-b11658", "runtime": "missing"}), "is not a runtime in config/components.json"),
            "context too large": (mutate("contextSize", 65536, "runtime"), "runtime.contextSize must be"),
            "evidence off bitworks.io": (mutate("url", "https://example.com/x", "evidence"), "evidence.url must be on https://bitworks.io/"),
        }
        for label, (entry, message) in cases.items():
            with self.subTest(label):
                # The Vulkan twin is NOT recommended, so a missing guard cannot hide behind the one-recommended-per-card check.
                with self.assertRaisesRegex(br.RecipeError, message):
                    br.build(self.hip_verified_tree(entry, vulkan_recommended=False))
        root = self.hip_verified_tree()
        (root / "config" / "components.json").unlink()
        with self.assertRaisesRegex(br.RecipeError, "needs config/components.json"):
            br.build(root)

    def test_compelling_compares_each_metric_with_the_best_bitworks_value_for_that_metric(self):
        # The Vulkan entry is the best generation (32.73); a HIP entry is slower to generate (32.0) but much faster on prompt (1000.0).
        prompt_fast = copy.deepcopy(HIP_VERIFIED); prompt_fast["expected"].update(generationTokS=32.0, promptTokS=1000.0)

        def compelling_of(record):
            document = br.build(self.tree_with_hip_and_record(prompt_fast, record))[0]
            found = [r for r in document["recipes"] if r["origin"] == "community-reproduced"]
            return found[0]["compelling"] if found else None

        # +20% on prompt over the best prompt (HIP 1000.0) is not enough, though it is +83% over the Vulkan entry (it was compelling before).
        self.assertIsNone(compelling_of(community("community-reproduced", generationTokS=30.0, promptTokS=1200.0)))
        # +50% over the best prompt rate is compelling, and the block names each metric's baseline.
        block = compelling_of(community("community-reproduced", generationTokS=30.0, promptTokS=1500.0))
        self.assertTrue(block["isCompelling"])
        self.assertEqual((block["baselineGeneration"], block["baselinePrompt"]), (ENTRY["id"], HIP_VERIFIED["id"]))
        self.assertEqual(block["baselineRecipe"], block["baselineGeneration"])
        # A record that beats both bests is compelling; one that beats the generation best by 15% is too.
        block = compelling_of(community("community-reproduced", generationTokS=40.0, promptTokS=1600.0))
        self.assertTrue(block["isCompelling"])
        self.assertEqual((block["generationGainPct"], block["promptGainPct"]), (22.2, 60.0))
        self.assertIsNone(compelling_of(community("community-reproduced", generationTokS=37.0, promptTokS=1100.0)))
        self.assertTrue(compelling_of(community("community-reproduced", generationTokS=37.7, promptTokS=1100.0))["isCompelling"])

    def tree_with_hip_and_record(self, hip, record):
        vulkan = copy.deepcopy(ENTRY); vulkan["recommended"] = False
        root = self.tree([vulkan, hip], [record])
        (root / "config" / "components.json").write_text(json.dumps(HIP_COMPONENTS))
        return root

    def test_repo_recipes_are_current(self):
        result = subprocess.run([sys.executable, str(ROOT / "tools" / "build-recipes.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def hip_tree(self, entry=None, comps=None, entries=None):
        root = self.tree(entries if entries is not None else [ENTRY])
        (root / "config" / "components.json").write_text(json.dumps(comps or HIP_COMPONENTS))
        (root / "data" / "bitworks-experimental-recipes.json").write_text(json.dumps(
            {"schema": "bitworks.fastllm-bitworks-experimental-recipes/v1", "entries": [entry or copy.deepcopy(HIP_ENTRY)]}))
        return root

    def test_bitworks_experimental_is_accepted_without_evidence(self):
        document, skipped = br.build(self.hip_tree())
        self.assertEqual(skipped, [])
        recipe = [r for r in document["recipes"] if r["origin"] == "bitworks-experimental"][0]
        self.assertEqual(recipe["label"], "Experimental Bitworks setup, not yet measured by Bitworks on this card")
        self.assertEqual(recipe["components"], {"engine": "llama.cpp-hip-b11658", "model": "qwen3.8-27b-ud-q4-k-m"})
        self.assertEqual(recipe["engineBuild"], "b11658")
        self.assertIs(recipe["recommended"], False)
        self.assertEqual((recipe["expected"], recipe["evidence"], recipe["source"], recipe["compelling"]), (None, None, None, None))
        self.assertNotIn("vulkanBarMitigation", recipe["runtime"])
        self.assertIn("data/bitworks-experimental-recipes.json", document["inputs"])
        # The existing Bitworks recipe is unchanged, and the experimental one is not a baseline for the compelling rule.
        self.assertEqual([r["origin"] for r in document["recipes"]], ["bitworks", "bitworks-experimental"])

    def test_bitworks_experimental_refuses_recommended(self):
        for value in (True, 1, "yes"):
            with self.subTest(value=value):
                entry = copy.deepcopy(HIP_ENTRY); entry["recommended"] = value
                with self.assertRaisesRegex(br.RecipeError, "recommended is for verified Bitworks recipes only"):
                    br.build(self.hip_tree(entry))
        entry = copy.deepcopy(HIP_ENTRY); entry["recommended"] = False
        br.build(self.hip_tree(entry))

    def test_bitworks_experimental_components_must_all_be_listed(self):
        no_hip = {"components": [HIP_COMPONENTS["components"][0]]}
        no_runtime = {"components": HIP_COMPONENTS["components"][:2]}
        wrong_kind = {"components": [HIP_COMPONENTS["components"][0], dict(HIP_COMPONENTS["components"][1], kind="runtime"), HIP_COMPONENTS["components"][2]]}
        wrong_version = {"components": [HIP_COMPONENTS["components"][0], dict(HIP_COMPONENTS["components"][1], version="b1"), HIP_COMPONENTS["components"][2]]}
        for label, comps in (("engine unlisted", no_hip), ("required runtime unlisted", no_runtime), ("engine of the wrong kind", wrong_kind), ("engine version differs", wrong_version)):
            with self.subTest(label):
                with self.assertRaises(br.RecipeError):
                    br.build(self.hip_tree(comps=comps))
        entry = copy.deepcopy(HIP_ENTRY); entry["components"]["runtime"] = "missing"
        with self.assertRaises(br.RecipeError):
            br.build(self.hip_tree(entry))
        entry = copy.deepcopy(HIP_ENTRY); entry["components"]["runtime"] = "amd-rt"
        shipped = [r for r in br.build(self.hip_tree(entry))[0]["recipes"] if r["origin"] == "bitworks-experimental"][0]
        self.assertEqual(shipped["components"]["runtime"], "amd-rt")

    def test_bitworks_experimental_needs_components_json_and_a_clean_entry(self):
        root = self.hip_tree()
        (root / "config" / "components.json").unlink()
        with self.assertRaises(br.RecipeError):
            br.build(root)
        for key, value in (("variant", "rx-9999"), ("model", "missing-model"), ("gpuCount", 3), ("origin", "bitworks"), ("id", "Bad Id"),
                           ("expected", {"generationTokS": 30}), ("evidence", {"url": "https://bitworks.io/x"}), ("source", {"author": "a"})):
            with self.subTest(key=key):
                entry = copy.deepcopy(HIP_ENTRY); entry[key] = value
                with self.assertRaises(br.RecipeError):
                    br.build(self.hip_tree(entry))
        for field, value in (("contextSize", 65536), ("parallel", 2), ("cacheTypeK", "--evil"), ("fitTargetMiB", 0), ("vulkanBarMitigation", "auto")):
            with self.subTest(field=field):
                entry = copy.deepcopy(HIP_ENTRY); entry["runtime"][field] = value
                with self.assertRaises(br.RecipeError):
                    br.build(self.hip_tree(entry))

    def test_the_existing_origins_are_unchanged_by_bitworks_experimental(self):
        # Without the experimental file the output is exactly what it was, and the community file still refuses the new origin.
        document, _ = br.build(self.tree([ENTRY]))
        self.assertNotIn("data/bitworks-experimental-recipes.json", document["inputs"])
        self.assertEqual([r["origin"] for r in document["recipes"]], ["bitworks"])
        record = community("bitworks-experimental", generationTokS=40.0)
        with self.assertRaises(br.RecipeError):
            br.build(self.tree([ENTRY], [record]))


if __name__ == "__main__":
    unittest.main()
