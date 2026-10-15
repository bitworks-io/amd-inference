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

    def test_usage_exit_2(self):
        self.assertEqual(self.cli()[0], 2)


if __name__ == "__main__":
    unittest.main()
