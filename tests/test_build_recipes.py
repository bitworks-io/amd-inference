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


class RecipeBuilderTests(unittest.TestCase):
    def tree(self, entries=None, records=None):
        root = Path(tempfile.mkdtemp())
        (root / "config").mkdir(); (root / "data").mkdir()
        catalog = {"engine": {"version": "b10698"}, "models": [{"id": "qwen3.8-27b-ud-q4-k-m", "contextSize": 32768},
                                                              {"id": "qwen3.8-27b-ud-iq4-xs", "contextSize": 16384}]}
        (root / "config" / "catalog.json").write_text(json.dumps(catalog))
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
                 (("runtime", "vulkanBarMitigation"), "maybe"), (("runtime", "contextSize"), 65536),
                 (("expected", "generationTokS"), 0), (("evidence", "url"), "http://example.com/x")]
        for key, value in cases:
            with self.subTest(key=key):
                entry = copy.deepcopy(ENTRY)
                if isinstance(key, tuple): entry[key[0]][key[1]] = value
                else: entry[key] = value
                with self.assertRaises(br.RecipeError):
                    br.build(self.tree([entry]))

    def test_two_recommended_for_one_card_is_refused(self):
        other = copy.deepcopy(ENTRY); other["id"] = "rx-7900-xtx.other"
        with self.assertRaises(br.RecipeError):
            br.build(self.tree([ENTRY, other]))

    def test_community_compelling_rule(self):
        def record(gen, prompt, ctx=32768):
            return {"id": "c1", "origin": "community-reproduced", "variant": "rx-7900-xtx", "gpuCount": 1, "model": "qwen3.8-27b-ud-q4-k-m",
                    "runtime": ENTRY["runtime"], "engineBuild": "b10698", "recommended": False,
                    "expected": dict(ENTRY["expected"], generationTokS=gen, promptTokS=prompt, contextTokens=ctx),
                    "evidence": ENTRY["evidence"], "source": {"author": "a", "url": "https://example.com/p", "postedAt": "2026-10-01", "recordId": "r"}}
        for gen, prompt, ctx, want in [(37.7, 654.14, 32768, True), (33.0, 990.0, 32768, True), (36.0, 700.0, 32768, False), (40.0, 654.0, 16384, False)]:
            with self.subTest(gen=gen, prompt=prompt, ctx=ctx):
                document, _ = br.build(self.tree([ENTRY], [record(gen, prompt, ctx)]))
                community = [r for r in document["recipes"] if r["origin"] == "community-reproduced"][0]
                self.assertEqual(community["compelling"]["isCompelling"], want)
                self.assertEqual(community["label"], "Community recipe, reproduced by Bitworks")

    def test_output_is_deterministic_and_check_detects_drift(self):
        root = self.tree([ENTRY])
        self.assertEqual(subprocess.run([sys.executable, str(ROOT / "tools" / "build-recipes.py"), "--root", str(root)]).returncode, 0)
        first = (root / "config" / "recipes.json").read_bytes()
        self.assertEqual(subprocess.run([sys.executable, str(ROOT / "tools" / "build-recipes.py"), "--root", str(root), "--check"]).returncode, 0)
        (root / "config" / "recipes.json").write_bytes(first.replace(b"32.73", b"99.99"))
        self.assertEqual(subprocess.run([sys.executable, str(ROOT / "tools" / "build-recipes.py"), "--root", str(root), "--check"]).returncode, 1)

    def test_repo_recipes_are_current(self):
        result = subprocess.run([sys.executable, str(ROOT / "tools" / "build-recipes.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
