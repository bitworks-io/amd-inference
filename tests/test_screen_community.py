import importlib.util, io, json, tempfile, unittest
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIX = ROOT / "tests" / "fixtures" / "community"
spec = importlib.util.spec_from_file_location("screen_community", ROOT / "tools" / "screen-community.py")
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

RECIPES = sc.load(ROOT / "data" / "verified-recipes.json")
COMPONENTS = sc.load(ROOT / "config" / "components.json")
VARIANTS = sc.load(ROOT / "config" / "gpu-variants.json")


def run(name):
    rows = sc.screen(sc.load(FIX / f"{name}.json"), RECIPES, COMPONENTS, VARIANTS)
    assert len(rows) == 1
    return rows[0]


class ScreenTests(unittest.TestCase):
    def test_each_reason(self):
        cases = {
            "topology": "topology-unavailable", "aggregate": "aggregate-metric",
            "nopin": "model-not-pinned", "enginepin": "engine-not-pinnable",
            "incomplete": "submission-incomplete", "hip": "lane-not-shipped:hip",
            "draft": "lane-not-shipped:draft", "other": "lane-not-shipped:other-engine",
            "slow": "not-compelling", "nometric": "no-metric",
        }
        for name, reason in cases.items():
            with self.subTest(name):
                row = run(name)
                self.assertIn(reason, row["reasons"])
                self.assertFalse(row["candidate"])

    def test_dual_card_not_compared_as_candidate(self):
        row = run("topology")
        self.assertEqual(row["gpuCount"], 2)
        self.assertIsNone(row["compellingOnPaper"]["baseline"])  # no 2-card Bitworks recipe

    def test_candidate(self):
        row = run("cand")
        self.assertTrue(row["candidate"])
        self.assertEqual(row["reasons"], [])
        self.assertTrue(row["compellingOnPaper"]["compelling"])
        self.assertAlmostEqual(row["compellingOnPaper"]["genGainPct"], 20.0, delta=0.1)
        self.assertEqual(row["pin"]["engine"]["build"], "b10829")
        self.assertFalse(row["pin"]["engine"]["inComponentsJson"])
        self.assertEqual(row["pin"]["model"]["sha256"], "a" * 64)

    def test_v1_list_form(self):
        rows = sc.screen(sc.load(FIX / "v1-list.json"), RECIPES, COMPONENTS, VARIANTS)
        self.assertTrue(rows[0]["candidate"])
        self.assertEqual(rows[0]["variant"], "rx-7900-xt")

    def test_best_per_variant(self):
        best = sc.best_by_variant(RECIPES)
        self.assertIn(("rx-7900-xt", 1), best)
        self.assertIn(("rx-7900-xtx", 1), best)


class RealShapeTests(unittest.TestCase):
    """Synthetic records reproducing the shape variants seen in the real website export."""

    def rows(self):
        rows = sc.screen(sc.load(FIX / "real-shapes.json"), RECIPES, COMPONENTS, VARIANTS)
        return {r["id"] or f"#{i}": r for i, r in enumerate(rows)}

    def test_never_crashes_and_every_record_gets_a_row(self):
        rows = sc.screen(sc.load(FIX / "real-shapes.json"), RECIPES, COMPONENTS, VARIANTS)
        self.assertEqual(len(rows), 12)
        for r in rows:
            self.assertTrue(r["reasons"] or r["candidate"])
            self.assertFalse(r["candidate"])

    def test_unparseable(self):
        bad = [r for r in sc.screen(sc.load(FIX / "real-shapes.json"), RECIPES, COMPONENTS, VARIANTS)
               if "unparseable-record" in r["reasons"]]
        self.assertEqual(len(bad), 4)

    def test_freetext_backend_and_speculative(self):
        r = self.rows()["s-freetext-hip-mtp"]
        for reason in ("lane-not-shipped:hip", "lane-not-shipped:draft", "topology-unavailable", "engine-not-pinnable"):
            self.assertIn(reason, r["reasons"])

    def test_two_copies_c16_is_aggregate(self):
        r = self.rows()["s-two-copies-c16"]
        self.assertIn("aggregate-metric", r["reasons"])
        self.assertIsNone(r["generationTokS"])

    def test_build_text_and_wrapper_and_vllm(self):
        rows = self.rows()
        self.assertNotIn("engine-not-pinnable", rows["s-build-text"]["reasons"])  # build 10817 -> b10817
        self.assertIn("no-metric", rows["s-build-text"]["reasons"])
        self.assertIn("lane-not-shipped:other-engine", rows["s-via-wrapper"]["reasons"])
        self.assertIn("engine-not-pinnable", rows["s-via-wrapper"]["reasons"])
        self.assertIn("lane-not-shipped:other-engine", rows["s-vllm"]["reasons"])

    def test_nulls_and_strings_and_odd_metrics(self):
        rows = self.rows()
        self.assertIn("no-metric", rows["s-nulls"]["reasons"])
        self.assertIn("model-not-pinned", rows["s-string-blocks"]["reasons"])
        self.assertEqual(rows["s-odd-metrics"]["generationTokS"], 31.0)

    def test_parse_build(self):
        self.assertEqual(sc.parse_build("b10698 (25ae3a9b3)"), "b10698")
        self.assertEqual(sc.parse_build("0.4.1-dev build 10964; commit b29c606"), "b10964")
        self.assertEqual(sc.parse_build("47c786924"), "")
        self.assertEqual(sc.parse_build(None), "")


class CliTests(unittest.TestCase):
    def cli(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            try:
                code = sc.main(list(args))
            except SystemExit as e:
                code = e.code
        return code, out.getvalue(), err.getvalue()

    def test_summary_and_out_file(self):
        with tempfile.TemporaryDirectory() as d:
            target = Path(d) / "out.json"
            code, out, _ = self.cli(str(FIX / "cand.json"), "--out", str(target))
            self.assertEqual(code, 0)
            self.assertIn("candidates=1 records=1", out)
            self.assertEqual(len(json.loads(target.read_text())), 1)

    def test_zero_candidates(self):
        code, out, _ = self.cli(str(FIX / "slow.json"), "--out", str(Path(tempfile.gettempdir()) / "sc-slow.json"))
        self.assertEqual(code, 0)
        self.assertIn("candidates=0 records=1", out)

    def test_bad_input_exit_1(self):
        with tempfile.TemporaryDirectory() as d:
            bad = Path(d) / "bad.json"
            bad.write_text("{not json")
            self.assertEqual(self.cli(str(bad))[0], 1)
            self.assertEqual(self.cli(str(Path(d) / "missing.json"))[0], 1)

    def test_real_shapes_cli(self):
        with tempfile.TemporaryDirectory() as d:
            code, out, _ = self.cli(str(FIX / "real-shapes.json"), "--out", str(Path(d) / "o.json"))
            self.assertEqual(code, 0)
            self.assertIn("candidates=0 records=12", out)

    def test_usage_exit_2(self):
        self.assertEqual(self.cli()[0], 2)


if __name__ == "__main__":
    unittest.main()
