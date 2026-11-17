import copy, hashlib, importlib.util, json, tempfile, unittest
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

    def test_ids_are_folder_names(self):
        for bad in ("con", "nul", "com1", "lpt9", "aux.txt", "abc."):
            errors = self.errors(mutated(lambda c, b=bad: c.update(id=b)))
            self.assertTrue(any("id must not" in e for e in errors), (bad, errors))
        for bad in ("v1.", "nul", "v1 "):
            errors = self.errors(mutated(lambda c, b=bad: c.update(version=b)))
            self.assertTrue(any("version must not" in e for e in errors), (bad, errors))
        for good in ("console", "com10", "abc-1.2"):
            errors = self.errors(mutated(lambda c, g=good: c.update(id=g)))
            self.assertFalse(any("id must not" in e for e in errors), (good, errors))

    def test_ids_duplicate_case_insensitively(self):
        doc = copy.deepcopy(GOOD)
        twin = copy.deepcopy(doc["components"][0])
        twin["id"] = twin["id"].upper()
        doc["components"].append(twin)
        self.assertRefused(doc, "duplicate")

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


# ---- zip-tree, sources[], requires chains, license links, runtimePathDirs ----
ZERO = "0" * 64


def part(paths, fmt="zip-tree", prefix="pre/", host="example.com"):
    # Equal sources must pin equal manifests, so a fixture part's sha256 follows its manifest.
    sha = hashlib.sha256("\n".join(paths).encode()).hexdigest()
    out = {"url": f"https://{host}/x.zip", "allowedRedirectHosts": [host], "sha256": sha, "sizeBytes": 10, "format": fmt,
           "fileManifest": [{"path": p, "sizeBytes": 3, "sha256": ZERO} for p in paths]}
    if prefix is not None:
        out["extractPrefix"] = prefix
    return out


def comp(cid, parts, requires=(), kind="runtime", path_dirs=None, license=None):
    out = {"id": cid, "kind": kind, "displayName": cid, "version": "1.0", "sources": parts,
           "license": license or {"spdx": "proprietary", "url": "https://example.com/l", "consent": "accept"},
           "platform": {"os": "windows", "arch": "x64", "backend": "hip"}, "requires": list(requires), "signer": None}
    if path_dirs is not None:
        out["runtimePathDirs"] = path_dirs
    return out


def with_base(*extra):
    doc = copy.deepcopy(GOOD)
    doc["components"] = [doc["components"][0]] + [copy.deepcopy(c) for c in extra]
    return doc


class TreeTests(unittest.TestCase):
    def errors(self, *components):
        return cc.validate(with_base(*components), CATALOG)

    def assertRefused(self, components, text):
        errors = self.errors(*components)
        self.assertTrue(any(text in e for e in errors), errors)

    def test_shipped_hip_components(self):
        by_id = {c["id"]: c for c in GOOD["components"]}
        engine, runtime = by_id["llama.cpp-hip-b11658"], by_id["amd-rocm-gfx1100-10.0.0"]
        self.assertEqual(len(engine["source"]["fileManifest"]), 55)
        self.assertEqual([len(p["fileManifest"]) for p in runtime["sources"]], [16, 252])
        self.assertEqual(runtime["runtimePathDirs"], ["bin"])
        self.assertEqual(engine["requires"], ["amd-rocm-gfx1100-10.0.0"])
        self.assertEqual(cc.validate(GOOD, CATALOG), [])
        self.assertEqual(cc.main([]), 0)

    def test_shipped_rdna4_hip_components_mirror_gfx1100(self):
        by_id = {c["id"]: c for c in GOOD["components"]}
        base_engine, base_runtime = by_id["llama.cpp-hip-b11658"], by_id["amd-rocm-gfx1100-10.0.0"]
        for target in ("gfx1201", "gfx1200"):
            engine, runtime = by_id[f"llama.cpp-hip-b11658-{target}"], by_id[f"amd-rocm-{target}-10.0.0"]
            self.assertEqual(engine["requires"], [f"amd-rocm-{target}-10.0.0"])
            self.assertEqual(runtime["requires"], [])
            self.assertEqual(engine["source"], base_engine["source"])
            self.assertEqual(runtime["sources"][0], base_runtime["sources"][0])
            device = runtime["sources"][1]
            self.assertEqual(device["url"], f"https://stable.repo.amd.com/rocm/core/whl-next/rocm-sdk-device-{target}/rocm_sdk_device_{target}-10.0.0-py3-none-win_amd64.whl")
            self.assertEqual(device["allowedRedirectHosts"], ["stable.repo.amd.com"])
            self.assertEqual((device["format"], device["extractPrefix"]), ("zip-tree", "_rocm_sdk_libraries/"))
            self.assertTrue(all(target in m["path"] for m in device["fileManifest"]))
            self.assertEqual(runtime["license"], base_runtime["license"])
            self.assertEqual(engine["license"], base_engine["license"])
            self.assertEqual(runtime["platform"], base_runtime["platform"])
            self.assertEqual(runtime["runtimePathDirs"], ["bin"])
        self.assertEqual(by_id["amd-rocm-gfx1201-10.0.0"]["sources"][1]["sizeBytes"], 312303802)
        self.assertEqual(by_id["amd-rocm-gfx1200-10.0.0"]["sources"][1]["sizeBytes"], 377648520)
        self.assertEqual(base_engine["requires"], ["amd-rocm-gfx1100-10.0.0"])
        self.assertEqual(cc.validate(GOOD, CATALOG), [])

    def test_equal_source_must_pin_an_equal_manifest(self):
        def engine_manifest(doc):
            next(c for c in doc["components"] if c["id"] == "llama.cpp-hip-b11658-gfx1201")["source"]["fileManifest"][0]["sha256"] = "1" * 64
        def runtime_manifest(doc):
            next(c for c in doc["components"] if c["id"] == "amd-rocm-gfx1200-10.0.0")["sources"][0]["fileManifest"].pop()
        def runtime_size(doc):
            next(c for c in doc["components"] if c["id"] == "amd-rocm-gfx1201-10.0.0")["sources"][0]["sizeBytes"] += 1
        def engine_prefix(doc):
            next(c for c in doc["components"] if c["id"] == "amd-rocm-gfx1201-10.0.0")["sources"][0]["extractPrefix"] = "other/"
        for mutate, what in ((engine_manifest, "fileManifest"), (runtime_manifest, "fileManifest"), (runtime_size, "sizeBytes"), (engine_prefix, "extractPrefix")):
            doc = copy.deepcopy(GOOD)
            mutate(doc)
            errors = cc.validate(doc, CATALOG)
            self.assertTrue(any("same sha256" in e and what in e for e in errors), (what, errors))

    def test_shipped_adlx_probe_tool(self):
        probe = {c["id"]: c for c in GOOD["components"]}["bitworks-adlx-probe"]
        self.assertEqual(probe["kind"], "tool")
        self.assertEqual(probe["entryPoint"], "adlx-identity-vram.exe")
        self.assertNotIn("adapter", probe)
        self.assertEqual(probe["requires"], [])
        self.assertEqual(probe["signer"], "Bitworks LLC")
        manifest = {m["path"]: m for m in probe["source"]["fileManifest"]}
        self.assertEqual(sorted(manifest), ["EULA.txt", "NOTICE.txt", "adlx-identity-vram.exe"])
        self.assertEqual(manifest["adlx-identity-vram.exe"]["sha256"], "f53e3eebbf97de5bc8de97fbcbb357df83b71c16579be761d7567c0935cc2766")
        self.assertEqual(probe["license"]["consent"], "accept")
        self.assertEqual(len(probe["license"]["links"]), 2)
        self.assertEqual(probe["source"]["allowedRedirectHosts"], ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"])
        self.assertEqual(cc.validate(GOOD, CATALOG), [])

    def test_valid_tree(self):
        ok = comp("rt", [part(["bin/a.dll", ".kpack/x.kpack", "bin/rocblas/library/y.dat"], prefix="_rocm_sdk_libraries/")], path_dirs=["bin"])
        self.assertEqual(self.errors(ok), [])

    def test_nested_paths_are_refused(self):
        for bad in ("bin/../x.dll", "../x.dll", "bin/x:y.dll", "C:/x.dll", "/abs/x.dll", "bin\\x.dll", "bin//x.dll", "bin/./x.dll",
                    "bin/x.", "bin/x ", "bin/con", "NUL/x.dll", "bin/com1.txt", "bin/..",
                    "bin/..a", "bin/._a", "bin/__a", "bin/...", "bin/" + "a" * 201, "bin/x.dll\n", "bin/x.\n", "bin/\u212a.dll", "bin/con\n"):
            self.assertRefused([comp("rt", [part(["bin/ok.dll", bad])])], "unsafe path")
        self.assertEqual(self.errors(comp("rt", [part(["bin/console.dll", "bin/com10.dll", "bin/" + "a" * 200, "_a/.b/c.d"])])), [])

    def test_flat_zip_stays_flat(self):
        self.assertRefused([comp("rt", [part(["sub/x.dll"], fmt="zip", prefix=None)])], "unsafe path")
        for bad in (".hidden", "_x.dll", "a b.dll", "x.dll\n", "\u212a.dll", "con", "x.", "a" * 201):
            self.assertRefused([comp("rt", [part([bad], fmt="zip", prefix=None)])], "unsafe path")

    def test_version_is_a_simple_leaf_name(self):
        for bad in (".x", "_x", "../x", "v1\n", "a b", "\u212a1"):
            errors = self.errors(dict(comp("rt", [part(["bin/a.dll"])]), version=bad))
            self.assertTrue(any("version" in e for e in errors), (bad, errors))

    def test_extract_prefix(self):
        for bad in (None, "pre", "pre//", "../pre/", "/pre/", "c:/pre/", "con/", "pre//"):
            self.assertRefused([comp("rt", [part(["bin/a.dll"], prefix=bad)])], "extractPrefix")
        self.assertRefused([comp("rt", [part(["a.dll"], fmt="zip", prefix="pre/")])], "only for zip-tree")

    def test_source_shape(self):
        both = comp("rt", [part(["bin/a.dll"])]); both["source"] = part(["bin/b.dll"])
        self.assertRefused([both], "exactly one of source or sources")
        neither = comp("rt", [part(["bin/a.dll"])]); del neither["sources"]
        self.assertRefused([neither], "exactly one of source or sources")
        self.assertRefused([comp("rt", [])], "sources must be a non-empty list")

    def test_parts_must_be_disjoint(self):
        self.assertRefused([comp("rt", [part(["bin/a.dll"]), part(["bin/a.dll"])])], "more than once")
        self.assertRefused([comp("rt", [part(["bin/a.dll"]), part(["BIN/A.DLL"])])], "more than once")
        self.assertRefused([comp("rt", [part(["bin/a.dll", "bin/A.dll"])])], "more than once")
        self.assertRefused([comp("rt", [part(["bin/a.dll", "bin/a.dll"])])], "duplicate path")
        self.assertRefused([comp("rt", [part(["bin"]), part(["bin/a.dll"])])], "both a file and a directory")
        self.assertEqual(self.errors(comp("rt", [part(["bin/a.dll"]), part(["bin/b.dll"])])), [])

    def test_requires(self):
        self.assertRefused([comp("aa", [part(["bin/a.dll"])], requires=["nope"])], "unknown component")
        self.assertRefused([comp("aa", [part(["bin/a.dll"])], requires=["AA"])], "requires itself")
        self.assertRefused([comp("aa", [part(["bin/a.dll"])], requires=["bb"]), comp("bb", [part(["bin/b.dll"])], requires=["cc"]),
                            comp("cc", [part(["bin/c.dll"])], requires=["aa"])], "cycle")
        chain4 = [comp(f"d{i}", [part([f"bin/d{i}.dll"])], requires=[f"d{i + 1}"] if i < 4 else []) for i in range(1, 5)]
        self.assertEqual(self.errors(*chain4), [])
        shared = [comp("top", [part(["bin/t.dll"])], requires=["xx", "aa"]), comp("aa", [part(["bin/a.dll"])], requires=["bb"]),
                  comp("bb", [part(["bin/b.dll"])], requires=["xx"]), comp("xx", [part(["bin/x.dll"])], requires=["yy"]),
                  comp("yy", [part(["bin/y.dll"])])]
        self.assertRefused(shared, "deeper than 4")
        diamond = [comp("top", [part(["bin/t.dll"])], requires=["aa", "bb"]), comp("aa", [part(["bin/a.dll"])], requires=["cc"]),
                   comp("bb", [part(["bin/b.dll"])], requires=["cc"]), comp("cc", [part(["bin/c.dll"])])]
        self.assertEqual(self.errors(*diamond), [])
        chain5 = [comp(f"d{i}", [part([f"bin/d{i}.dll"])], requires=[f"d{i + 1}"] if i < 5 else []) for i in range(1, 6)]
        self.assertRefused(chain5, "deeper than 4")

    def test_sha_with_trailing_newline_is_refused(self):
        bad = comp("rt", [part(["bin/a.dll"])]); bad["sources"][0]["sha256"] = ZERO + "\n"
        self.assertRefused([bad], "sha256")
        bad = comp("rt", [part(["bin/a.dll"])]); bad["sources"][0]["fileManifest"][0]["sha256"] = ZERO + "\n"
        self.assertRefused([bad], "sha256")

    def test_license_links(self):
        links = {"spdx": "p", "consent": "accept", "url": "https://example.com/l", "links": [{"title": "EULA", "url": "https://example.com/e"}]}
        self.assertEqual(self.errors(comp("aa", [part(["bin/a.dll"])], license=links)), [])
        only_links = {k: v for k, v in links.items() if k != "url"}
        self.assertEqual(self.errors(comp("aa", [part(["bin/a.dll"])], license=only_links)), [])
        http = copy.deepcopy(links); http["links"][0]["url"] = "http://example.com/e"
        self.assertRefused([comp("aa", [part(["bin/a.dll"])], license=http)], "url must be an https URL")
        notitle = copy.deepcopy(links); notitle["links"][0]["title"] = ""
        self.assertRefused([comp("aa", [part(["bin/a.dll"])], license=notitle)], "title must be a non-empty string")
        empty = copy.deepcopy(links); empty["links"] = []
        self.assertRefused([comp("aa", [part(["bin/a.dll"])], license=empty)], "non-empty list")

    def test_every_consent_needs_url_or_links(self):
        for consent in ("accept", "show"):
            none = {"spdx": "p", "consent": consent}
            self.assertRefused([comp("aa", [part(["bin/a.dll"])], license=none)], "needs license.url or license.links")
            empty_url = {"spdx": "p", "consent": consent, "url": "",
                         "links": [{"title": "EULA", "url": "https://example.com/e"}]}
            self.assertRefused([comp("aa", [part(["bin/a.dll"])], license=empty_url)], "license.url must be an https URL")

    def test_runtime_path_dirs(self):
        self.assertRefused([comp("aa", [part(["bin/a.dll"])], kind="engine", path_dirs=["bin"])], "only for runtime")
        self.assertRefused([comp("aa", [part(["bin/a.dll"])], path_dirs=["lib"])], "no manifest files")
        self.assertRefused([comp("aa", [part(["bin/a.dll"])], path_dirs=["bin/.."])], "unsafe")
        self.assertRefused([comp("aa", [part(["bin/a.dll"])], path_dirs=["/bin"])], "unsafe")
        self.assertRefused([comp("aa", [part(["bin/a.dll"])], path_dirs=[])], "non-empty list")
        self.assertEqual(self.errors(comp("aa", [part(["bin/a.dll"])], path_dirs=["BIN"])), [])



# ---- kind "tool": a standalone verified binary ----
def tool(**over):
    out = comp("probe-tool", [part(["probe.exe", "EULA.txt"], fmt="zip", prefix=None)], kind="tool")
    out["entryPoint"] = "probe.exe"
    out["requires"] = []
    out.update(over)
    return out


class ToolKindTests(unittest.TestCase):
    def errors(self, *components):
        return cc.validate(with_base(*components), CATALOG)

    def test_valid_tool(self):
        self.assertEqual(self.errors(tool()), [])

    def test_tool_needs_an_entry_point_in_the_manifest(self):
        bad = tool(); del bad["entryPoint"]
        self.assertTrue(any("tool needs an entryPoint" in e for e in self.errors(bad)))
        self.assertTrue(any("not in the fileManifest" in e for e in self.errors(tool(entryPoint="other.exe"))))

    def test_tool_has_no_adapter_or_runtime_path_dirs(self):
        self.assertTrue(any("tool has no adapter" in e for e in self.errors(tool(adapter="llama.cpp"))))
        self.assertTrue(any("only for runtime" in e for e in self.errors(tool(runtimePathDirs=["bin"]))))

    def test_unknown_kind_is_still_refused(self):
        self.assertTrue(any("kind must be one of" in e for e in self.errors(tool(kind="plugin"))))


# ---- kind "embedding-model": the model file of the embedding sidecar ----
def embedding_model(**over):
    out = comp("test-embedding-model", [part(["test-embedding.gguf", "LICENSE.txt"], fmt="zip", prefix=None)], kind="embedding-model")
    out["entryPoint"] = "test-embedding.gguf"
    out["requires"] = []
    out.update(over)
    return out


class EmbeddingModelKindTests(unittest.TestCase):
    def errors(self, *components):
        return cc.validate(with_base(*components), CATALOG)

    def test_kind_is_listed(self):
        self.assertIn("embedding-model", cc.KINDS)
        self.assertEqual(cc.KINDS, ("engine", "runtime", "model", "draft", "tool", "embedding-model"))

    def test_valid_embedding_model(self):
        self.assertEqual(self.errors(embedding_model()), [])

    def test_the_shipped_list_has_none(self):
        self.assertEqual([c["id"] for c in GOOD["components"] if c["kind"] == "embedding-model"], [])

    def test_the_fixture_component_passes(self):
        fixture = json.loads((ROOT / "tests" / "fixtures" / "embedding-components-test.json").read_text(encoding="utf-8"))
        self.assertEqual(cc.validate(fixture, None), [])
        self.assertEqual([c["kind"] for c in fixture["components"]], ["embedding-model"])

    def test_needs_an_entry_point_that_is_a_gguf_file_of_the_manifest(self):
        bad = embedding_model(); del bad["entryPoint"]
        self.assertTrue(any("embedding-model needs an entryPoint" in e for e in self.errors(bad)))
        self.assertTrue(any("not in the fileManifest" in e for e in self.errors(embedding_model(entryPoint="other.gguf"))))
        self.assertTrue(any("must be a .gguf file" in e for e in self.errors(embedding_model(entryPoint="LICENSE.txt"))))
        nested = comp("test-embedding-model", [part(["models/test-embedding.gguf"])], kind="embedding-model")
        nested["entryPoint"] = "models/test-embedding.gguf"
        self.assertTrue(any("must be a .gguf file at the top of the component" in e for e in self.errors(nested)))

    def test_has_no_adapter_runtime_path_dirs_or_requires(self):
        self.assertTrue(any("embedding-model has no adapter" in e for e in self.errors(embedding_model(adapter="llama.cpp"))))
        self.assertTrue(any("only for runtime" in e for e in self.errors(embedding_model(runtimePathDirs=["bin"]))))
        runtime = comp("some-runtime", [part(["bin/a.dll"])], path_dirs=["bin"])
        self.assertTrue(any("embedding-model requires no other component" in e for e in self.errors(runtime, embedding_model(requires=["some-runtime"]))))

    def test_consent_and_hash_rules_apply_like_any_component(self):
        self.assertTrue(any("license.consent" in e for e in self.errors(embedding_model(license={"spdx": "Apache-2.0", "url": "https://example.com/l", "consent": "none"}))))
        bad = embedding_model()
        bad["sources"][0]["fileManifest"][0]["sha256"] = "xyz"
        self.assertTrue(any("sha256 must be 64 lowercase hex" in e for e in self.errors(bad)))


if __name__ == "__main__":
    unittest.main()
