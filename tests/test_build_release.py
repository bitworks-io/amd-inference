import hashlib, importlib.util, json, os, re, tempfile, unittest, zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_release", ROOT / "tools" / "build-release.py")
br = importlib.util.module_from_spec(spec)
spec.loader.exec_module(br)

T = "2026-10-20T12:00:01Z"


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


class ProductToolsRealTreeTests(unittest.TestCase):
    """Builds the real repository tree and checks the packaged tools/ set."""

    @classmethod
    def setUpClass(cls):
        cls.out = Path(tempfile.mkdtemp()) / "out"
        br.build(str(ROOT), "2026.10.20.1", "canary", "0.10.0", str(cls.out), built_at=T)
        with zipfile.ZipFile(cls.out / "package-unsigned.zip") as z:
            cls.members = {n: z.read(n) for n in z.namelist()}
        cls.allow = br.load_product_tools(str(ROOT))

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
