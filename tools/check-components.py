#!/usr/bin/env python3
"""Validate config/components.json (bitworks.fastllm-components/v1). Exit 0 ok, 1 invalid.

Shape (spec 2.1):
  { "schema": "bitworks.fastllm-components/v1", "components": [ Component, ... ] }
  Component = {
    "id": str                       # ^[a-z0-9][a-z0-9.\\-]{1,120}$, unique
    "kind": "engine"|"runtime"|"model"|"draft",
    "displayName": str, "version": str,
    "source": { "url": https url, "allowedRedirectHosts": [host, ...], "sha256": 64 hex, "sizeBytes": int > 0,
                "format": "zip"|"gguf"|"vendor-installer",
                "fileManifest": [ { "path", "sizeBytes", "sha256" }, ... ] },   # required for zip
    "license": { "spdx": str, "url": https url, "consent": "show"|"accept" },
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
ID_RE = re.compile(r"^[a-z0-9][a-z0-9.\-]{1,120}$")
RESERVED_RE = re.compile(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$", re.IGNORECASE)
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
KINDS = ("engine", "runtime", "model", "draft")
FORMATS = ("zip", "gguf", "vendor-installer")
CONSENTS = ("show", "accept")
BASE_ENGINE_ID = "llama.cpp-b10698-vulkan"
COMPONENT_KEYS = {"id", "kind", "displayName", "version", "source", "license", "platform", "adapter", "entryPoint", "requires", "signer"}
SOURCE_KEYS = {"url", "allowedRedirectHosts", "sha256", "sizeBytes", "format", "fileManifest"}
LICENSE_KEYS = {"spdx", "url", "consent"}
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


def safe_path(path):
    if not is_str(path) or path.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", path):
        return False
    return ".." not in re.split(r"[\\/]", path)


def leaf_problem(value):
    """Ids and versions are folder names: no trailing dot or space, no Windows reserved device name (mirrors FastLlm.psm1)."""
    if value.endswith((".", " ")):
        return "must not end with a dot or a space"
    if RESERVED_RE.match(value):
        return "must not be a reserved Windows device name"
    return None


def check_manifest(label, manifest, errors):
    if not isinstance(manifest, list) or not manifest:
        errors.append(f"{label}: fileManifest must be a non-empty list")
        return set()
    paths = set()
    for i, item in enumerate(manifest):
        where = f"{label}: fileManifest[{i}]"
        if not check_keys(where, item, MANIFEST_KEYS, errors):
            continue
        if not safe_path(item["path"]):
            errors.append(f"{where}: unsafe path {item['path']!r}")
        elif item["path"] in paths:
            errors.append(f"{where}: duplicate path {item['path']!r}")
        else:
            paths.add(item["path"])
        if not is_int(item["sizeBytes"]) or item["sizeBytes"] < 0:
            errors.append(f"{where}: sizeBytes must be a non-negative integer")
        if not isinstance(item["sha256"], str) or not SHA_RE.match(item["sha256"]):
            errors.append(f"{where}: sha256 must be 64 lowercase hex characters")
    return paths


def check_component(comp, errors):
    cid = comp.get("id") if isinstance(comp, dict) else None
    label = f"component {cid!r}"
    if not check_keys(label, comp, COMPONENT_KEYS, errors, optional=("adapter", "entryPoint")):
        return
    if not isinstance(cid, str) or not ID_RE.match(cid):
        errors.append(f"{label}: id must match {ID_RE.pattern}")
    if isinstance(cid, str) and leaf_problem(cid):
        errors.append(f"{label}: id {leaf_problem(cid)}")
    if isinstance(comp["version"], str) and leaf_problem(comp["version"]):
        errors.append(f"{label}: version {leaf_problem(comp['version'])}")
    if comp["kind"] not in KINDS:
        errors.append(f"{label}: kind must be one of {KINDS}")
    for key in ("displayName", "version"):
        if not is_str(comp[key]):
            errors.append(f"{label}: {key} must be a non-empty string")
    source = comp["source"]
    manifest_paths = set()
    if check_keys(f"{label}: source", source, SOURCE_KEYS, errors, optional=("fileManifest",)):
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
        if not isinstance(source["sha256"], str) or not SHA_RE.match(source["sha256"]):
            errors.append(f"{label}: source.sha256 must be 64 lowercase hex characters")
        if not is_int(source["sizeBytes"]) or source["sizeBytes"] <= 0:
            errors.append(f"{label}: source.sizeBytes must be a positive integer")
        if source["format"] not in FORMATS:
            errors.append(f"{label}: source.format must be one of {FORMATS}")
        if "fileManifest" in source:
            manifest_paths = check_manifest(label, source["fileManifest"], errors)
        elif source["format"] == "zip":
            errors.append(f"{label}: a zip source needs a fileManifest")
    lic = comp["license"]
    if check_keys(f"{label}: license", lic, LICENSE_KEYS, errors):
        if not is_str(lic["spdx"]):
            errors.append(f"{label}: license.spdx must be a non-empty string")
        if not (isinstance(lic["url"], str) and lic["url"].startswith("https://")):
            errors.append(f"{label}: license.url must be an https URL")
        if lic["consent"] not in CONSENTS:
            errors.append(f"{label}: license.consent must be one of {CONSENTS}")
    if check_keys(f"{label}: platform", comp["platform"], PLATFORM_KEYS, errors):
        for key in PLATFORM_KEYS:
            if not is_str(comp["platform"][key]):
                errors.append(f"{label}: platform.{key} must be a non-empty string")
    if not isinstance(comp["requires"], list) or not all(isinstance(r, str) for r in comp["requires"]):
        errors.append(f"{label}: requires must be a list of component ids")
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
