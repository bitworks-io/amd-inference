import contextlib, hashlib, importlib.util, io, json, os, re, tempfile, unittest, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_release", ROOT / "tools" / "build-release.py")
br = importlib.util.module_from_spec(spec)
spec.loader.exec_module(br)

T = "2026-10-20T12:00:01Z"
POLICY = {"schema": "bitworks.fastllm-release-policy/v1", "dataFormat": 1, "rollbackFloor": None, "rollbackFloorReason": None}


class PublicBuilderTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        for name in br.ROOT_FILES:
            (self.root / name).write_text(name + "\n")
        for rel in ("docs/RESIZABLE-BAR.md", "docs/PRIVATE-NOTES.md", "src/FastLlm.psm1", "tools/x.py", "tools/lab-only.ps1", "config/catalog.json", "licenses/llama.cpp/LICENSE", "tests/t.ps1",
                    "src/__pycache__/x.pyc", "src/.hidden"):
            path = self.root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(rel + "\n")
        (self.root / "config" / "release-policy.json").write_text(json.dumps(POLICY))
        (self.root / "tools" / "product-tools.json").write_text(json.dumps({"schema": "fastllm.product-tools.v1", "tools": ["x.py"]}))
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
        self.assertIn("tools/x.py", names)
        self.assertFalse([n for n in names if n.startswith("tests/") or "__pycache__" in n or "/." in n])

    def test_real_tree_ships_the_serving_profiles_file_and_its_digest(self):
        # The whole config/ tree ships: the serving profiles file and its digest are collected like every other config file,
        # and the checker (a build-time tool, not a product tool) is not.
        files = br.collect(str(ROOT))
        for rel in ("config/catalog.json", "config/catalog.sha256", "config/recipes.json", "config/serving-profiles.json", "config/serving-profiles.sha256"):
            self.assertTrue(rel in files, rel + " is not in the package file list")
        self.assertEqual(hashlib.sha256(files["config/serving-profiles.json"]).hexdigest() + "  serving-profiles.json\n",
                         files["config/serving-profiles.sha256"].decode("utf-8"))
        for rel in ("tools/check-serving-profiles.py", "tools/check-components.py"):
            self.assertFalse(rel in files, rel + " must not ship")

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

    def write_policy(self, doc):
        text = doc if isinstance(doc, str) else json.dumps(doc)
        (self.root / "config" / "release-policy.json").write_text(text)

    def test_release_policy_ships_in_the_manifest(self):
        self.build()
        self.assertIn("config/release-policy.json", self.names())
        manifest = json.loads(self.member("MANIFEST.json"))
        entry = [f for f in manifest["files"] if f["path"] == "config/release-policy.json"]
        self.assertEqual(len(entry), 1)
        self.assertEqual(entry[0]["sha256"], hashlib.sha256(self.member("config/release-policy.json")).hexdigest())

    def test_refuses_a_missing_release_policy(self):
        (self.root / "config" / "release-policy.json").unlink()
        with self.assertRaisesRegex(br.BuildError, "release policy"):
            self.build()

    def test_refuses_a_malformed_release_policy(self):
        good = dict(POLICY)
        bad = ["not json", "[]", "null",
               dict(good, schema="other"), dict(good, dataFormat=0), dict(good, dataFormat="1"), dict(good, dataFormat=True), dict(good, dataFormat=1.5),
               dict(good, rollbackFloor="2026.10.20.01", rollbackFloorReason="security"),
               dict(good, rollbackFloor="2026.10.21.1", rollbackFloorReason="security"),
               dict(good, rollbackFloor="2026.10.19.1", rollbackFloorReason=None),
               dict(good, rollbackFloor=None, rollbackFloorReason="security"),
               dict(good, rollbackFloor="2026.10.19.1", rollbackFloorReason="other"),
               dict(good, extra=1), dict(good, dataFormat=1000001),
               dict(good, rollbackFloor="2026.10.19.1\n", rollbackFloorReason="security"),
               dict(good, rollbackFloor="\u0662026.10.19.1", rollbackFloorReason="security"),
               '{"schema": "bitworks.fastllm-release-policy/v1", "dataFormat": 1, "dataFormat": 2, "rollbackFloor": null, "rollbackFloorReason": null}']
        missing = dict(good)
        del missing["rollbackFloorReason"]
        bad.append(missing)
        for doc in bad:
            with self.subTest(doc=doc):
                self.out = Path(tempfile.mkdtemp()) / "out"
                self.write_policy(doc)
                with self.assertRaisesRegex(br.BuildError, "release policy"):
                    self.build()

    def test_accepts_the_largest_data_format(self):
        self.write_policy(dict(POLICY, dataFormat=1000000))
        self.build()

    def test_refuses_a_symlinked_release_policy_that_the_package_would_skip(self):
        target = self.root / "elsewhere.json"
        target.write_text(json.dumps(POLICY))
        link = self.root / "config" / "release-policy.json"
        link.unlink()
        try:
            os.symlink(str(target), str(link))
        except (OSError, NotImplementedError):
            self.skipTest("symlinks are not available here")
        with self.assertRaisesRegex(br.BuildError, "release policy"):
            self.build()

    def test_accepts_a_floor_at_or_below_this_version(self):
        for floor, reason in (("2026.10.20.1", "security"), ("2026.10.19.3", "data")):
            self.out = Path(tempfile.mkdtemp()) / "out"
            self.write_policy(dict(POLICY, dataFormat=2, rollbackFloor=floor, rollbackFloorReason=reason))
            self.build()

    def test_the_repo_policy_file_is_the_neutral_default(self):
        path = ROOT / "config" / "release-policy.json"
        self.assertEqual(json.loads(path.read_text(encoding="utf-8")), POLICY)
        br.validate_release_policy(path.read_bytes(), "2026.10.20.1")

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

    def test_only_the_referenced_docs_are_packaged(self):
        self.build()
        names = self.names()
        self.assertIn("docs/RESIZABLE-BAR.md", names)
        self.assertEqual(self.member("docs/RESIZABLE-BAR.md"), b"docs/RESIZABLE-BAR.md\n")
        self.assertFalse([n for n in names if n.startswith("docs/") and n != "docs/RESIZABLE-BAR.md"])
        manifest = json.loads(self.member("MANIFEST.json"))
        self.assertIn("docs/RESIZABLE-BAR.md", {f["path"] for f in manifest["files"]})

    def test_refuses_missing_referenced_doc(self):
        (self.root / "docs" / "RESIZABLE-BAR.md").unlink()
        with self.assertRaisesRegex(br.BuildError, "RESIZABLE-BAR"):
            self.build()

    def test_tools_folder_is_the_allowlist_not_a_wildcard(self):
        self.build()
        names = self.names()
        self.assertIn("tools/x.py", names)
        self.assertNotIn("tools/lab-only.ps1", names)
        self.assertNotIn("tools/product-tools.json", names)

    def test_refuses_missing_allowlisted_tool(self):
        (self.root / "tools" / "product-tools.json").write_text(
            json.dumps({"schema": "fastllm.product-tools.v1", "tools": ["x.py", "gone.ps1"]}))
        with self.assertRaisesRegex(br.BuildError, "allowlisted product tool is missing: tools/gone.ps1"):
            self.build()

    def test_refuses_missing_or_bad_allowlist(self):
        allow = self.root / "tools" / "product-tools.json"
        for text in (None, "not json", json.dumps({"tools": ["x.py"]}), json.dumps({"schema": "fastllm.product-tools.v1", "tools": []}),
                     json.dumps({"schema": "fastllm.product-tools.v1", "tools": ["../src/FastLlm.psm1"]}),
                     json.dumps({"schema": "fastllm.product-tools.v1", "tools": ["x.py", "x.py"]})):
            with self.subTest(text=text):
                if text is None:
                    allow.unlink()
                else:
                    allow.write_text(text)
                self.out = Path(tempfile.mkdtemp()) / "out"
                with self.assertRaises(br.BuildError):
                    self.build()


LAB_ONLY = ("setup-windows-lab.cmd", "setup-windows-lab.ps1", "start-windows-lab-setup.ps1", "install-lab-app.ps1")


def referenced_tools(text, names):
    return {n for n in names if re.search(r"(?<![\w.\-])" + re.escape(n) + r"(?![\w\-])", text)}


class StableRecipeLineageGateTests(unittest.TestCase):
    """A stable build refuses recipes whose expected numbers were measured on a previous file revision; a canary may carry them."""
    # The same fake tree and build helper as PublicBuilderTests, without re-running its tests.
    setUp = PublicBuilderTests.setUp
    build = PublicBuilderTests.build
    names = PublicBuilderTests.names

    def write_recipes(self, with_lineage):
        evidence = {"publishedAt": "2026-10-14", "resultId": "r", "url": "https://bitworks.io/x"}
        if with_lineage:
            evidence.update(measuredModel="old-model", measuredRevision="4ca720788d1e01f1bff70c033e0d0028fd02e502")
        document = {"schema": "bitworks.fastllm-recipes/v2", "inputs": {}, "recipes": [{"id": "card.new-model.16k", "evidence": evidence},
                                                                                          {"id": "card.other.16k", "evidence": None}]}
        (self.root / "config" / "recipes.json").write_text(json.dumps(document))

    def test_stable_refuses_a_recipe_measured_on_a_previous_revision(self):
        self.write_recipes(True)
        with self.assertRaisesRegex(br.BuildError, r"Refusing a stable build: recipe\(s\) card\.new-model\.16k still carry expected numbers measured on a previous file revision; publish new measured evidence first\."):
            self.build(channel="stable")

    def test_canary_builds_with_such_a_recipe(self):
        self.write_recipes(True)
        self.build(channel="canary")
        self.assertIn("config/recipes.json", self.names())

    def test_stable_builds_without_a_lineage_recipe(self):
        self.write_recipes(False)
        self.build(channel="stable")
        self.assertIn("config/recipes.json", self.names())

    def test_the_shipped_recipes_are_a_canary_only_release_until_new_evidence_exists(self):
        files = br.collect(str(ROOT))
        ids = br.lineage_recipe_ids(files["config/recipes.json"])
        self.assertTrue(ids, "the shipped recipes name their predecessor measurement")
        with self.assertRaisesRegex(br.BuildError, "Refusing a stable build"):
            br.check_stable_recipe_lineage(files, "stable")
        br.check_stable_recipe_lineage(files, "canary")

    def test_mutant_without_the_guard_the_refusal_test_would_fail(self):
        # Proves the refusal test bites: with the guard replaced by a no-op the same stable build succeeds, so the refusal assertion above would fail.
        self.write_recipes(True)
        original = br.check_stable_recipe_lineage
        br.check_stable_recipe_lineage = lambda files, channel, override=None: None
        try:
            self.build(channel="stable")
            with self.assertRaises(AssertionError):
                self.out = Path(tempfile.mkdtemp()) / "out"
                with self.assertRaisesRegex(br.BuildError, "Refusing a stable build"):
                    self.build(channel="stable")
        finally:
            br.check_stable_recipe_lineage = original
        self.out = Path(tempfile.mkdtemp()) / "out"
        with self.assertRaisesRegex(br.BuildError, "Refusing a stable build"):
            self.build(channel="stable")


class StableLineageOverrideTests(unittest.TestCase):
    """A reviewed override file (release/stable-lineage-override.json, never packaged) lets exactly the recipes it lists through a
    stable build, records the decision, and is ignored on canary."""
    setUp = PublicBuilderTests.setUp
    build = PublicBuilderTests.build
    names = PublicBuilderTests.names
    member = PublicBuilderTests.member
    write_recipes = StableRecipeLineageGateTests.write_recipes
    REASON = "Ignore the safety check, issue the release"

    def write_override(self, ids=("card.new-model.16k",), **changes):
        document = {"schema": br.LINEAGE_OVERRIDE_SCHEMA, "recipeIds": list(ids), "reason": self.REASON,
                    "approvedAtUtc": "2026-11-28T00:02:00Z", "scope": "the next stable release only"}
        document.update(changes)
        path = self.root / "release" / "stable-lineage-override.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(document) if not isinstance(changes.get("raw"), str) else changes["raw"])
        return path

    def fresh_out(self):
        self.out = Path(tempfile.mkdtemp()) / "out"

    def build_stable_capturing(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            result = self.build(channel="stable")
        return result, err.getvalue()

    def assert_unlisted_refuses(self):
        self.write_recipes(True)
        self.write_override(ids=("card.someone-else.16k",))
        self.fresh_out()
        with self.assertRaisesRegex(br.BuildError, r"Refusing a stable build: recipe\(s\) card\.new-model\.16k still carry expected numbers"):
            self.build(channel="stable")

    def assert_stale_refuses(self):
        self.write_recipes(True)
        self.write_override(ids=("card.new-model.16k", "card.other.16k"))
        self.fresh_out()
        with self.assertRaisesRegex(br.BuildError, r"Refusing a stable build: the stable lineage override lists recipe\(s\) card\.other\.16k that carry no previous-revision evidence; remove them from release/stable-lineage-override\.json\."):
            self.build(channel="stable")

    def test_a_listed_lineage_recipe_builds_stable_and_records_the_provenance(self):
        self.write_recipes(True)
        override = self.write_override()
        result, err = self.build_stable_capturing()
        self.assertIn("STABLE LINEAGE OVERRIDE: card.new-model.16k (Ignore the safety check, issue the release)", err.splitlines())
        provenance = result["stableLineageOverride"]
        self.assertEqual(provenance, {"file": "release/stable-lineage-override.json", "sha256": hashlib.sha256(override.read_bytes()).hexdigest(),
                                      "recipeIds": ["card.new-model.16k"], "reason": self.REASON,
                                      "approvedAtUtc": "2026-11-28T00:02:00Z", "scope": "the next stable release only"})
        record = json.loads((self.out / br.LINEAGE_OVERRIDE_PROVENANCE).read_text())
        self.assertEqual(record, dict(provenance, version="2026.10.20.1", channel="stable", unsignedSha256=result["unsignedSha256"]))
        self.assertEqual(sorted(os.listdir(self.out)), sorted(["package-unsigned.zip", "package-unsigned.sha256", br.LINEAGE_OVERRIDE_PROVENANCE]))

    def test_the_override_is_never_packaged_and_the_signed_records_are_unchanged(self):
        self.write_recipes(True)
        self.write_override()
        self.build_stable_capturing()
        self.assertFalse([n for n in self.names() if n.startswith("release/") or "lineage-override" in n])
        self.assertEqual(set(json.loads(self.member("RELEASE.json"))),
                         {"schema", "component", "version", "channel", "minAgentVersion", "builtAtUtc", "manifestSha256"})
        self.assertNotIn(b"OVERRIDE", self.member("FASTLLM-VERSION.json").upper())

    def test_an_unlisted_lineage_recipe_still_refuses(self):
        self.assert_unlisted_refuses()

    def test_a_listed_id_that_is_not_a_lineage_recipe_refuses_as_stale(self):
        self.assert_stale_refuses()

    def test_an_override_with_no_lineage_recipe_left_refuses_as_stale(self):
        self.write_recipes(False)
        self.write_override()
        with self.assertRaisesRegex(br.BuildError, r"the stable lineage override lists recipe\(s\) card\.new-model\.16k that carry no previous-revision evidence"):
            self.build(channel="stable")

    def test_stable_without_an_override_file_still_refuses(self):
        self.write_recipes(True)
        with self.assertRaisesRegex(br.BuildError, r"Refusing a stable build: recipe\(s\) card\.new-model\.16k still carry"):
            self.build(channel="stable")

    def test_a_malformed_override_refuses_stable(self):
        cases = [dict(raw="{not json"), dict(schema="other"), dict(recipeIds=[]), dict(recipeIds=["a", "a"]), dict(recipeIds="card.new-model.16k"),
                 dict(recipeIds=[" card.new-model.16k"]), dict(reason=""), dict(scope="  "), dict(approvedAtUtc="2026-11-28 00:02"), dict(extra=1)]
        self.write_recipes(True)
        for changes in cases:
            with self.subTest(changes=changes):
                self.write_override(**{k: v for k, v in changes.items()})
                self.fresh_out()
                with self.assertRaisesRegex(br.BuildError, "stable lineage override"):
                    self.build(channel="stable")
                self.assertFalse(self.out.exists())

    def test_a_linked_override_refuses_stable(self):
        self.write_recipes(True)
        real = self.write_override()
        link = real.with_name("linked.json")
        real.rename(link)
        os.symlink(link, real)
        with self.assertRaisesRegex(br.BuildError, "must be a regular file, not a link"):
            self.build(channel="stable")

    def test_canary_ignores_the_override_even_a_malformed_one(self):
        self.write_recipes(True)
        self.write_override(raw="{not json")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            result = self.build(channel="canary")
        self.assertNotIn("stableLineageOverride", result)
        self.assertEqual(err.getvalue(), "")
        self.assertEqual(sorted(os.listdir(self.out)), ["package-unsigned.sha256", "package-unsigned.zip"])
        self.assertIsNone(br.check_stable_recipe_lineage(br.collect(str(self.root)), "canary", {"recipeIds": [], "sha256": "x"}))

    def test_mutant_an_override_that_skips_the_check_fails_the_unlisted_and_stale_tests(self):
        # The mutant trusts any present override: on stable it returns a record for whatever is listed and never checks the lineage set.
        original = br.check_stable_recipe_lineage

        def mutant(files, channel, override=None):
            if channel == "stable" and override is not None:
                return {"file": br.LINEAGE_OVERRIDE_FILE, "sha256": override["sha256"], "recipeIds": sorted(override["recipeIds"]),
                        "reason": override["reason"], "approvedAtUtc": override["approvedAtUtc"], "scope": override["scope"]}
            return original(files, channel, override)

        br.check_stable_recipe_lineage = mutant
        try:
            for probe in (self.assert_unlisted_refuses, self.assert_stale_refuses):
                with self.subTest(probe=probe.__name__), contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(AssertionError):
                        probe()
        finally:
            br.check_stable_recipe_lineage = original
        self.assert_unlisted_refuses()
        self.assert_stale_refuses()

    def test_the_shipped_override_lists_exactly_the_shipped_lineage_recipes(self):
        files = br.collect(str(ROOT))
        self.assertNotIn(br.LINEAGE_OVERRIDE_FILE, files, "release/ is never packaged")
        override = br.load_lineage_override(str(ROOT))
        ids = br.lineage_recipe_ids(files["config/recipes.json"])
        self.assertEqual(sorted(override["recipeIds"]), ids)
        self.assertEqual(override["reason"], self.REASON)
        self.assertEqual(override["scope"], "the next stable release only")
        provenance = br.check_stable_recipe_lineage(files, "stable", override)
        self.assertEqual(provenance["recipeIds"], ids)
        self.assertIn("STABLE LINEAGE OVERRIDE: " + ", ".join(ids) + " (" + self.REASON + ")", br.lineage_override_line(provenance))


class ProductToolsRealTreeTests(unittest.TestCase):
    """Builds the real repository tree and checks the packaged tools/ set."""

    @classmethod
    def setUpClass(cls):
        cls.out = Path(tempfile.mkdtemp()) / "out"
        br.build(str(ROOT), "2026.10.20.1", "canary", "0.10.0", str(cls.out), built_at=T)
        with zipfile.ZipFile(cls.out / "package-unsigned.zip") as z:
            cls.members = {n: z.read(n) for n in z.namelist()}
        cls.allow = br.load_product_tools(str(ROOT))

    def test_package_includes_window_csharp_sources(self):
        # The window's C# files are compiled at run time from the installed src/ folder, so a package that dropped one would break the window.
        # The catalog (FastLLM.cat) is generated over the extracted package tree and the doctor integrity check compares that same tree,
        # so a file in the package file list and MANIFEST.json is covered by both.
        manifest = {e["path"] for e in json.loads(self.members["MANIFEST.json"])["files"]}
        on_disk = sorted(p.name for p in (ROOT / "src").glob("*.cs"))
        for name in ("WindowsFluentWindow.cs", "WindowsFluentAutomation.cs"):
            self.assertIn(name, on_disk, name + " is missing from src/")
        for name in on_disk:
            rel = "src/" + name
            self.assertIn(rel, self.members, rel + " is not in the package file list")
            self.assertIn(rel, manifest, rel + " is not in MANIFEST.json")

    def test_package_includes_fluent_window_scripts(self):
        # The Fluent window's shell and page scripts are dot-sourced by name from the installed src/ folder, so a package that dropped one (the Models and Settings pages included)
        # would break the window the same way a missing C# file would.
        manifest = {e["path"] for e in json.loads(self.members["MANIFEST.json"])["files"]}
        on_disk = sorted(p.name for p in (ROOT / "src").glob("FastLlm.UiFluent*.ps1"))
        for name in ("FastLlm.UiFluentShell.ps1", "FastLlm.UiFluentTools.ps1", "FastLlm.UiFluentConnect.ps1", "FastLlm.UiFluentModels.ps1", "FastLlm.UiFluentSettings.ps1", "FastLlm.UiFluentDialogs.ps1", "FastLlm.UiFluentConsent.ps1"):
            self.assertIn(name, on_disk, name + " is missing from src/")
        for name in on_disk:
            rel = "src/" + name
            self.assertIn(rel, self.members, rel + " is not in the package file list")
            self.assertIn(rel, manifest, rel + " is not in MANIFEST.json")

    def test_packaged_tools_equal_the_allowlist(self):
        packaged = sorted(n[len("tools/"):] for n in self.members if n.startswith("tools/"))
        self.assertEqual(packaged, self.allow)

    def test_every_allowlisted_tool_exists(self):
        for name in self.allow:
            self.assertTrue((ROOT / "tools" / name).is_file(), name)

    def test_lab_and_bench_administration_tools_are_not_packaged(self):
        for name in LAB_ONLY:
            self.assertTrue((ROOT / "tools" / name).is_file(), name)
            self.assertNotIn(name, self.allow)
            self.assertNotIn("tools/" + name, self.members)

    def test_the_cli_resizable_bar_note_points_at_a_packaged_file(self):
        runtime = self.members["src/FastLlm.Runtime.ps1"].decode("utf-8")
        self.assertIn("See docs/RESIZABLE-BAR.md.", runtime)
        self.assertIn("docs/RESIZABLE-BAR.md", self.members)
        self.assertIn("-VulkanBarMitigation off", self.members["docs/RESIZABLE-BAR.md"].decode("utf-8"))
        self.assertEqual([n for n in self.members if n.startswith("docs/")], ["docs/RESIZABLE-BAR.md"])

    def test_no_packaged_file_uses_a_bypass_policy(self):
        pattern = re.compile(r"(?i)-ExecutionPolicy\s+Bypass")
        for name, data in self.members.items():
            self.assertIsNone(pattern.search(data.decode("utf-8", errors="replace")), name)

    def test_allowlist_is_exactly_what_the_product_references(self):
        # Entry points: fast-llm.ps1, fast-llm-ui.ps1 and src/; then transitively the included tools themselves.
        all_tools = sorted(p.name for p in (ROOT / "tools").iterdir() if p.is_file())
        text = "\n".join((ROOT / n).read_text(encoding="utf-8", errors="replace") for n in ("fast-llm.ps1", "fast-llm-ui.ps1"))
        for p in (ROOT / "src").rglob("*"):
            if p.is_file():
                text += "\n" + p.read_text(encoding="utf-8", errors="replace")
        included = referenced_tools(text, all_tools)
        pending = list(included)
        while pending:
            tool = pending.pop()
            for other in referenced_tools((ROOT / "tools" / tool).read_text(encoding="utf-8", errors="replace"), all_tools) - {tool}:
                if other not in included:
                    included.add(other)
                    pending.append(other)
        self.assertEqual(sorted(included), self.allow)

    def test_offline_plan_has_every_tool_it_calls(self):
        # Every tools/<name> that a packaged file mentions must itself be packaged (verify-release.ps1 runs `plan` offline).
        mention = re.compile(r"tools[/\\]([A-Za-z0-9][A-Za-z0-9._-]*)")
        existing = {p.name for p in (ROOT / "tools").iterdir() if p.is_file()}
        for name, data in self.members.items():
            if not name.endswith((".ps1", ".psm1", ".cs", ".cmd")):
                continue
            for tool in mention.findall(data.decode("utf-8", errors="replace")):
                if tool in existing:
                    self.assertIn("tools/" + tool, self.members, name + " mentions " + tool)


if __name__ == "__main__":
    unittest.main()
