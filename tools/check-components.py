#!/usr/bin/env python3
"""Validate config/components.json (bitworks.fastllm-components/v1). Exit 0 ok, 1 invalid.

Shape (spec 2.1):
  { "schema": "bitworks.fastllm-components/v1", "components": [ Component, ... ] }
  Component = {
    "id": str                       # ^[a-z0-9][a-z0-9.\\-]{1,120}$, unique
    "kind": "engine"|"runtime"|"model"|"draft",
    "displayName": str, "version": str,
    "source": { "url": https url, "allowedRedirectHosts": [host, ...], "sha256": 64 hex, "sizeBytes": int > 0,
                "format": "zip"|"zip-tree"|"gguf"|"vendor-installer",
                "extractPrefix": "dir/",                                         # zip-tree only, required there
                "fileManifest": [ { "path", "sizeBytes", "sha256" }, ... ] },   # required for zip and zip-tree
    "sources": [ source, ... ]      # instead of "source" (exactly one of the two); a non-empty list of parts
    "runtimePathDirs": [dir, ...]   # runtime only: directories inside the component root that hold DLLs
    "license": { "spdx": str, "url": https url (optional with links), "consent": "show"|"accept",
                 "links": [ { "title", "url": https url }, ... ] },     # every consent needs url or links
    "platform": { "os": "windows", "arch": "x64", "backend": str },
    "adapter": str,                 # engine only
    "entryPoint": str,              # engine only; must be a fileManifest path
    "requires": [component id, ...],
    "signer": str|null              # expected Authenticode publisher
  }
The base engine entry must mirror config/catalog.json engine.assets.vulkan (url, sha256, size, manifest).
Usage: check-components.py [--root R]
"""
import argparse
import json
import os
import re
import sys
from urllib.parse import urlparse

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = "bitworks.fastllm-components/v1"
ID_RE = re.compile(r"[a-z0-9][a-z0-9.\-]{1,120}")
RESERVED_RE = re.compile(r"(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?", re.IGNORECASE)
SHA_RE = re.compile(r"[0-9a-f]{64}")
KINDS = ("engine", "runtime", "model", "draft")
FORMATS = ("zip", "zip-tree", "gguf", "vendor-installer")
MAX_CHAIN_DEPTH = 4
CONSENTS = ("show", "accept")
BASE_ENGINE_ID = "llama.cpp-b10698-vulkan"
COMPONENT_KEYS = {"id", "kind", "displayName", "version", "source", "sources", "runtimePathDirs", "license", "platform", "adapter", "entryPoint", "requires", "signer"}
SOURCE_KEYS = {"url", "allowedRedirectHosts", "sha256", "sizeBytes", "format", "fileManifest", "extractPrefix"}
LICENSE_KEYS = {"spdx", "url", "consent", "links"}
LINK_KEYS = {"title", "url"}
# A zip-tree path segment: the component leaf character set, optionally with ONE leading dot or underscore (".kpack", "_rocm_sdk_libraries").
# This is the only extension of the leaf rule; "." and ".." never match.
SEGMENT_RE = re.compile(r"[._]?[A-Za-z0-9][A-Za-z0-9._+-]{0,199}")
# Flat zip names, versions: the simple leaf rule (no leading dot or underscore). Matched with fullmatch: no trailing line feed.
LEAF_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,199}")
PLATFORM_KEYS = {"os", "arch", "backend"}
MANIFEST_KEYS = {"path", "sizeBytes", "sha256"}


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def is_str(value):
    return isinstance(value, str) and value != ""


def check_keys(label, obj, expected, errors, optional=()):
    if not isinstance(obj, dict):
        errors.append(f"{label}: must be an object")
        return False
    keys = set(obj)
    missing = expected - set(optional) - keys
    extra = keys - expected
    if missing:
        errors.append(f"{label}: missing keys {sorted(missing)}")
    if extra:
        errors.append(f"{label}: unexpected keys {sorted(extra)}")
    return not missing and not extra


def leaf_problem(value):
    """Ids and versions are folder names: no trailing dot or space, no Windows reserved device name (mirrors FastLlm.psm1)."""
    if value.endswith((".", " ")):
        return "must not end with a dot or a space"
    if RESERVED_RE.fullmatch(value):
        return "must not be a reserved Windows device name"
    return None


def tree_path_problem(path):
    """A nested, forward-slash, relative path: every segment passes the leaf rules (mirrors Assert-FastLlmComponentTreePath)."""
    if not is_str(path):
        return "must be a non-empty string"
    for segment in path.split("/"):
        if not SEGMENT_RE.fullmatch(segment):
            return f"segment {segment!r} is not a simple name (no empty, '..', ':', backslash or other special characters)"
        problem = leaf_problem(segment)
        if problem:
            return f"segment {segment!r} {problem}"
    return None


def check_manifest(label, manifest, errors, tree=False):
    if not isinstance(manifest, list) or not manifest:
        errors.append(f"{label}: fileManifest must be a non-empty list")
        return set()
    paths = set()
    for i, item in enumerate(manifest):
        where = f"{label}: fileManifest[{i}]"
        if not check_keys(where, item, MANIFEST_KEYS, errors):
            continue
        if tree:
            problem = tree_path_problem(item["path"])
            if problem:
                errors.append(f"{where}: unsafe path {item['path']!r}: {problem}")
                continue
        elif not is_str(item["path"]) or not LEAF_RE.fullmatch(item["path"]) or leaf_problem(item["path"]):
            errors.append(f"{where}: unsafe path {item['path']!r} (a flat zip name is a simple leaf name)")
            continue
        if item["path"] in paths:
            errors.append(f"{where}: duplicate path {item['path']!r}")
        else:
            paths.add(item["path"])
        if not is_int(item["sizeBytes"]) or item["sizeBytes"] < 0:
            errors.append(f"{where}: sizeBytes must be a non-negative integer")
        if not isinstance(item["sha256"], str) or not SHA_RE.fullmatch(item["sha256"]):
            errors.append(f"{where}: sha256 must be 64 lowercase hex characters")
    return paths


def check_source(label, source, errors):
    """Validates one source entry; returns its manifest paths (as a list, in order)."""
    paths = []
    if not check_keys(f"{label}: source", source, SOURCE_KEYS, errors, optional=("fileManifest", "extractPrefix")):
        return paths
    parsed = urlparse(source["url"]) if isinstance(source["url"], str) else None
    hosts = source["allowedRedirectHosts"]
    if not isinstance(hosts, list) or not all(is_str(h) for h in hosts):
        errors.append(f"{label}: source.allowedRedirectHosts must be a list of hosts")
        hosts = []
    if parsed is None or parsed.scheme != "https" or not parsed.hostname:
        errors.append(f"{label}: source.url must be an https URL")
    else:
        github_release = parsed.hostname == "github.com" and "/releases/" in parsed.path
        if parsed.hostname not in hosts and not github_release:
            errors.append(f"{label}: source.url host {parsed.hostname!r} is not in allowedRedirectHosts or a GitHub release")
    if not isinstance(source["sha256"], str) or not SHA_RE.fullmatch(source["sha256"]):
        errors.append(f"{label}: source.sha256 must be 64 lowercase hex characters")
    if not is_int(source["sizeBytes"]) or source["sizeBytes"] <= 0:
        errors.append(f"{label}: source.sizeBytes must be a positive integer")
    fmt = source["format"]
    if fmt not in FORMATS:
        errors.append(f"{label}: source.format must be one of {FORMATS}")
    if fmt == "zip-tree":
        prefix = source.get("extractPrefix")
        if not (is_str(prefix) and prefix.endswith("/")) or tree_path_problem(prefix[:-1]):
            errors.append(f"{label}: a zip-tree source needs a safe relative extractPrefix ending in '/'")
    elif "extractPrefix" in source:
        errors.append(f"{label}: extractPrefix is only for zip-tree sources")
    if "fileManifest" in source:
        paths = check_manifest(label, source["fileManifest"], errors, tree=(fmt == "zip-tree"))
    elif fmt in ("zip", "zip-tree"):
        errors.append(f"{label}: a {fmt} source needs a fileManifest")
    return paths


def check_sources(label, comp, errors):
    """Exactly one of source / sources. Returns the set of installed file paths across all parts; parts must be disjoint."""
    if ("source" in comp) == ("sources" in comp):
        errors.append(f"{label}: needs exactly one of source or sources")
        return set()
    parts = [comp["source"]] if "source" in comp else comp["sources"]
    if not isinstance(parts, list) or not parts:
        errors.append(f"{label}: sources must be a non-empty list")
        return set()
    seen = {}
    originals = set()
    for part in parts:
        for path in check_source(label, part, errors):
            originals.add(path)
            key = path.lower()
            if key in seen:
                errors.append(f"{label}: path {path!r} appears more than once (case-insensitively, across all source parts)")
            seen[key] = part
    # A file and a directory of the same name (a, a/b) cannot both be installed.
    for key in seen:
        parent = key.rsplit("/", 1)[0] if "/" in key else None
        while parent:
            if parent in seen:
                errors.append(f"{label}: path {parent!r} is both a file and a directory")
            parent = parent.rsplit("/", 1)[0] if "/" in parent else None
    return originals


def check_runtime_path_dirs(label, comp, installed, errors):
    installed = {path.lower() for path in installed}
    dirs = comp["runtimePathDirs"]
    if comp["kind"] != "runtime":
        errors.append(f"{label}: runtimePathDirs is only for runtime components")
        return
    if not isinstance(dirs, list) or not dirs:
        errors.append(f"{label}: runtimePathDirs must be a non-empty list")
        return
    for entry in dirs:
        problem = tree_path_problem(entry) if isinstance(entry, str) else "must be a string"
        if problem:
            errors.append(f"{label}: runtimePathDirs entry {entry!r} is unsafe: {problem}")
        elif not any(path.startswith(entry.lower() + "/") for path in installed):
            errors.append(f"{label}: runtimePathDirs entry {entry!r} has no manifest files under it")


def check_component(comp, errors):
    cid = comp.get("id") if isinstance(comp, dict) else None
    label = f"component {cid!r}"
    if not check_keys(label, comp, COMPONENT_KEYS, errors, optional=("adapter", "entryPoint", "source", "sources", "runtimePathDirs")):
        return
    if not isinstance(cid, str) or not ID_RE.fullmatch(cid):
        errors.append(f"{label}: id must match {ID_RE.pattern}")
    if isinstance(cid, str) and leaf_problem(cid):
        errors.append(f"{label}: id {leaf_problem(cid)}")
    if isinstance(comp["version"], str) and not LEAF_RE.fullmatch(comp["version"]):
        errors.append(f"{label}: version must be a simple leaf name")
    if isinstance(comp["version"], str) and leaf_problem(comp["version"]):
        errors.append(f"{label}: version {leaf_problem(comp['version'])}")
    if comp["kind"] not in KINDS:
        errors.append(f"{label}: kind must be one of {KINDS}")
    for key in ("displayName", "version"):
        if not is_str(comp[key]):
            errors.append(f"{label}: {key} must be a non-empty string")
    manifest_paths = check_sources(label, comp, errors)
    lic = comp["license"]
    if check_keys(f"{label}: license", lic, LICENSE_KEYS, errors, optional=("url", "links")):
        if not is_str(lic["spdx"]):
            errors.append(f"{label}: license.spdx must be a non-empty string")
        if "url" in lic and not (isinstance(lic["url"], str) and lic["url"].startswith("https://")):
            errors.append(f"{label}: license.url must be an https URL")
        if lic["consent"] not in CONSENTS:
            errors.append(f"{label}: license.consent must be one of {CONSENTS}")
        links = lic.get("links")
        if "links" in lic:
            if not isinstance(links, list) or not links:
                errors.append(f"{label}: license.links must be a non-empty list")
            else:
                for i, link in enumerate(links):
                    where = f"{label}: license.links[{i}]"
                    if check_keys(where, link, LINK_KEYS, errors):
                        if not is_str(link["title"]):
                            errors.append(f"{where}: title must be a non-empty string")
                        if not (isinstance(link["url"], str) and link["url"].startswith("https://")):
                            errors.append(f"{where}: url must be an https URL")
        if not (is_str(lic.get("url")) or (isinstance(links, list) and links)):
            errors.append(f"{label}: a license needs license.url or license.links")
    if check_keys(f"{label}: platform", comp["platform"], PLATFORM_KEYS, errors):
        for key in PLATFORM_KEYS:
            if not is_str(comp["platform"][key]):
                errors.append(f"{label}: platform.{key} must be a non-empty string")
    if not isinstance(comp["requires"], list) or not all(isinstance(r, str) for r in comp["requires"]):
        errors.append(f"{label}: requires must be a list of component ids")
    elif isinstance(cid, str) and any(r.lower() == cid.lower() for r in comp["requires"]):
        errors.append(f"{label}: requires itself")
    if "runtimePathDirs" in comp:
        check_runtime_path_dirs(label, comp, manifest_paths, errors)
    if comp["signer"] is not None and not is_str(comp["signer"]):
        errors.append(f"{label}: signer must be null or a publisher name")
    if comp["kind"] == "engine":
        if not is_str(comp.get("adapter")):
            errors.append(f"{label}: an engine needs an adapter")
        entry = comp.get("entryPoint")
        if not is_str(entry):
            errors.append(f"{label}: an engine needs an entryPoint")
        elif entry not in manifest_paths:
            errors.append(f"{label}: entryPoint {entry!r} is not in the fileManifest")


def check_base_engine(components, catalog, errors):
    comp = next((c for c in components if isinstance(c, dict) and c.get("id") == BASE_ENGINE_ID), None)
    if comp is None:
        errors.append(f"base engine {BASE_ENGINE_ID!r} is missing")
        return
    asset = catalog["engine"]["assets"]["vulkan"]
    source = comp.get("source") or {}
    for mine, theirs in (("url", "url"), ("sha256", "sha256"), ("sizeBytes", "sizeBytes"), ("fileManifest", "manifest")):
        if source.get(mine) != asset.get(theirs):
            errors.append(f"base engine {BASE_ENGINE_ID!r}: source.{mine} differs from config/catalog.json engine.assets.vulkan.{theirs}")
    if comp.get("version") != catalog["engine"]["version"]:
        errors.append(f"base engine {BASE_ENGINE_ID!r}: version differs from the catalog engine version")
    if comp.get("entryPoint") != asset.get("entryPoint"):
        errors.append(f"base engine {BASE_ENGINE_ID!r}: entryPoint differs from the catalog")


def chain_problem(by_id, cid, stack):
    """Walks requires depth-first. Returns a problem string for a cycle or a chain deeper than MAX_CHAIN_DEPTH, else None."""
    if cid in stack:
        return "requires form a cycle: " + " -> ".join(stack + [cid])
    if len(stack) + 1 > MAX_CHAIN_DEPTH:
        return f"requires chain is deeper than {MAX_CHAIN_DEPTH}"
    comp = by_id.get(cid)
    if comp is None or not isinstance(comp.get("requires"), list):
        return None
    for req in comp["requires"]:
        if isinstance(req, str) and req.lower() in by_id:
            problem = chain_problem(by_id, req.lower(), stack + [cid])
            if problem:
                return problem
    return None


def validate(document, catalog):
    errors = []
    if not isinstance(document, dict) or document.get("schema") != SCHEMA:
        return [f"schema must be {SCHEMA!r}"]
    if set(document) != {"schema", "components"}:
        errors.append("top level must have exactly the keys schema and components")
    components = document.get("components")
    if not isinstance(components, list) or not components:
        return errors + ["components must be a non-empty list"]
    ids = set()
    for comp in components:
        check_component(comp, errors)
        cid = comp.get("id") if isinstance(comp, dict) else None
        key = cid.lower() if isinstance(cid, str) else cid
        if key in ids:
            errors.append(f"duplicate component id {cid!r} (ids are compared case-insensitively)")
        ids.add(key)
    for comp in components:
        if isinstance(comp, dict) and isinstance(comp.get("requires"), list):
            for req in comp["requires"]:
                if req not in ids:
                    errors.append(f"component {comp.get('id')!r}: requires unknown component {req!r}")
    by_id = {c["id"].lower(): c for c in components if isinstance(c, dict) and isinstance(c.get("id"), str)}
    for comp in components:
        if isinstance(comp, dict) and isinstance(comp.get("id"), str) and isinstance(comp.get("requires"), list):
            problem = chain_problem(by_id, comp["id"].lower(), [])
            if problem:
                errors.append(f"component {comp['id']!r}: {problem}")
    if catalog is not None:
        check_base_engine(components, catalog, errors)
    return errors


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=REPO_ROOT)
    args = parser.parse_args(argv)
    try:
        with open(os.path.join(args.root, "config", "components.json"), encoding="utf-8") as handle:
            document = json.load(handle)
        with open(os.path.join(args.root, "config", "catalog.json"), encoding="utf-8") as handle:
            catalog = json.load(handle)
        errors = validate(document, catalog)
    except (OSError, ValueError, KeyError, TypeError) as error:
        errors = [str(error)]
    for line in errors:
        print(f"check-components: {line}", file=sys.stderr)
    if errors:
        return 1
    print(f"components ok ({len(document['components'])})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
