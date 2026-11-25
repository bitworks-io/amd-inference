#!/usr/bin/env python3
"""Build the unsigned FastLLM release package. Signing happens in .github/workflows/release.yml.

Writes <out>/package-unsigned.zip and <out>/package-unsigned.sha256. The zip holds the app files (plus the individual docs the product references), FASTLLM-VERSION.json,
MANIFEST.json (every file with bytes and sha256, except itself and RELEASE.json) and RELEASE.json (last). Offline: no
network, no keys. Refuses to run inside the private workspace (a tree with ops/).

Usage: build-release.py --version 2026.10.20.1 --channel canary --min-agent-version 0.10.0 --out out [--built-at T]
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import sys
import zipfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPONENT = "fastllm-lab"                                   # wire name the bench agent expects
RELEASE_SCHEMA = "bitworks.fastllm-release/v1"
MANIFEST_SCHEMA = "fastllm.private-native-test-package.v1"   # wire name the bench agent expects
CHANNELS = ("stable", "canary")
VERSION_RE = re.compile(r"^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[1-9][0-9]{0,3}$")
MIN_AGENT_RE = re.compile(r"^[0-9]{1,4}(\.[0-9]{1,6}){1,3}$")
BUILT_AT_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
ROOT_FILES = ("fast-llm.ps1", "fast-llm-ui.ps1", "FastLLM.cmd", "LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "README.md", "SECURITY.md")
# Individual docs the product points users at (the CLI Resizable BAR note says "See docs/RESIZABLE-BAR.md."). Not the whole docs/ tree.
DOC_FILES = ("docs/RESIZABLE-BAR.md",)
TREES = ("src", "tools", "config", "licenses")
PRODUCT_TOOLS_FILE = "tools/product-tools.json"             # the explicit allowlist of tools/ files that ship
PRODUCT_TOOLS_SCHEMA = "fastllm.product-tools.v1"
SKIP = re.compile(r"(^|/)(__pycache__|bin|obj|\.[^/]*)(/|$)")
POLICY_FILE = "config/release-policy.json"                   # signed with the tree; the installed copy names the oldest release a reinstall may go back to
POLICY_SCHEMA = "bitworks.fastllm-release-policy/v1"
POLICY_KEYS = frozenset({"schema", "dataFormat", "rollbackFloor", "rollbackFloorReason"})
POLICY_REASONS = ("security", "data")
POLICY_MAX_FORMAT = 1000000
VERSION_FILE = "FASTLLM-VERSION.json"
RESERVED = frozenset({VERSION_FILE, "MANIFEST.json", "RELEASE.json", "FastLLM.cat"})


class BuildError(Exception):
    """A refused build. The message is safe to print."""


def is_canonical_version(value):
    if not isinstance(value, str) or not VERSION_RE.match(value):
        return False
    try:
        datetime.datetime.strptime(value.rsplit(".", 1)[0], "%Y.%m.%d")
    except ValueError:
        return False
    return True


def validate_inputs(version, channel, min_agent_version, built_at, rollback_of):
    if not is_canonical_version(version):
        raise BuildError("version must be canonical YYYY.MM.DD.N: a real date and N in 1..9999 without leading zeros")
    if channel not in CHANNELS:
        raise BuildError("channel must be stable or canary")
    if not MIN_AGENT_RE.match(min_agent_version or ""):
        raise BuildError("minAgentVersion must be a dotted numeric version")
    if not BUILT_AT_RE.match(built_at or ""):
        raise BuildError("builtAtUtc must look like YYYY-MM-DDTHH:MM:SSZ")
    if rollback_of is not None and not is_canonical_version(rollback_of):
        raise BuildError("rollbackOf must be a canonical YYYY.MM.DD.N version")


def canonical_json(obj):
    return (json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("utf-8")


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def collect(root):
    """{relative POSIX path: bytes} for the package source files."""
    files = {}
    for name in ROOT_FILES + DOC_FILES:
        path = os.path.join(root, *name.split("/"))
        if not os.path.isfile(path) or os.path.islink(path):
            raise BuildError("required root file is missing: " + name)
        with open(path, "rb") as handle:
            files[name] = handle.read()
    product_tools = set(load_product_tools(root))
    for tree in TREES:
        base = os.path.join(root, tree)
        if not os.path.isdir(base):
            raise BuildError("required folder is missing: " + tree)
        if tree == "tools":
            # Product allowlist, not the whole folder: lab and bench administration tools never ship.
            for name in sorted(product_tools):
                full = os.path.join(base, *name.split("/"))
                if not os.path.isfile(full) or os.path.islink(full):
                    raise BuildError("allowlisted product tool is missing: tools/" + name)
                with open(full, "rb") as handle:
                    files["tools/" + name] = handle.read()
            continue
        for current, dirs, names in os.walk(base):
            dirs.sort()
            for name in sorted(names):
                full = os.path.join(current, name)
                rel = os.path.relpath(full, root).replace(os.sep, "/")
                if SKIP.search(rel) or os.path.islink(full):
                    continue
                with open(full, "rb") as handle:
                    files[rel] = handle.read()
    clash = RESERVED.intersection(files)
    if clash:
        raise BuildError("the source tree must not contain " + ", ".join(sorted(clash)))
    return files


def load_product_tools(root):
    """The allowlist of tools/ files that ship, as a sorted list of paths relative to tools/."""
    path = os.path.join(root, *PRODUCT_TOOLS_FILE.split("/"))
    try:
        with open(path, "rb") as handle:
            doc = json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError):
        raise BuildError("the product tools allowlist is missing or unreadable: " + PRODUCT_TOOLS_FILE)
    names = doc.get("tools") if isinstance(doc, dict) and doc.get("schema") == PRODUCT_TOOLS_SCHEMA else None
    if not isinstance(names, list) or not names or not all(isinstance(n, str) for n in names):
        raise BuildError("the product tools allowlist must carry schema %s and a non-empty tools list" % PRODUCT_TOOLS_SCHEMA)
    for name in names:
        if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$", name):
            raise BuildError("the product tools allowlist has an unsafe path: " + name)
    if len(set(names)) != len(names):
        raise BuildError("the product tools allowlist has a duplicate entry")
    return sorted(names)


def _no_duplicate_keys(pairs):
    keys = [k for k, _ in pairs]
    if len(set(keys)) != len(keys):
        raise ValueError("duplicate key")
    return dict(pairs)


def validate_release_policy(data, version):
    """The release policy must be in the collected tree and well formed. `data` is the collected file's bytes (None when collect() did not take it)."""
    if data is None:
        raise BuildError("the release policy file is missing from the package: " + POLICY_FILE)
    try:
        doc = json.loads(data.decode("utf-8"), object_pairs_hook=_no_duplicate_keys)
    except (ValueError, UnicodeDecodeError):
        raise BuildError("the release policy file is unreadable or has a duplicate key: " + POLICY_FILE)
    if not isinstance(doc, dict) or set(doc) != POLICY_KEYS or doc["schema"] != POLICY_SCHEMA:
        raise BuildError("the release policy file must carry exactly schema %s, dataFormat, rollbackFloor and rollbackFloorReason" % POLICY_SCHEMA)
    data_format = doc["dataFormat"]
    if isinstance(data_format, bool) or not isinstance(data_format, int) or not 1 <= data_format <= POLICY_MAX_FORMAT:
        raise BuildError("the release policy dataFormat must be a whole number from 1 to %d" % POLICY_MAX_FORMAT)
    floor, reason = doc["rollbackFloor"], doc["rollbackFloorReason"]
    if (floor is None) != (reason is None):
        raise BuildError("the release policy rollbackFloor and rollbackFloorReason must be set together or both null")
    if floor is not None:
        if not isinstance(floor, str) or not re.fullmatch(VERSION_RE.pattern, floor) or not is_canonical_version(floor):
            raise BuildError("the release policy rollbackFloor must be a canonical YYYY.MM.DD.N version or null")
        if reason not in POLICY_REASONS:
            raise BuildError("the release policy rollbackFloorReason must be security, data or null")
        if tuple(int(n) for n in floor.split(".")) > tuple(int(n) for n in version.split(".")):
            raise BuildError("the release policy rollbackFloor must not be newer than the release being built")


RECIPES_FILE = "config/recipes.json"


def lineage_recipe_ids(recipes_bytes):
    """Ids of the recipes whose expected numbers were measured on a previous file revision (evidence.measuredModel)."""
    if recipes_bytes is None:
        return []
    try:
        document = json.loads(recipes_bytes.decode("utf-8"))
        recipes = document["recipes"]
    except (ValueError, KeyError, TypeError):
        raise BuildError("the recipes file is unreadable: " + RECIPES_FILE)
    return sorted(str(r.get("id")) for r in recipes if isinstance(r, dict) and isinstance(r.get("evidence"), dict) and r["evidence"].get("measuredModel"))


def check_stable_recipe_lineage(files, channel):
    """A stable package never carries a recipe whose expected numbers were measured on a previous file revision. A canary may."""
    if channel != "stable":
        return
    ids = lineage_recipe_ids(files.get(RECIPES_FILE))
    if ids:
        raise BuildError("Refusing a stable build: recipe(s) " + ", ".join(ids)
                         + " still carry expected numbers measured on a previous file revision; publish new measured evidence first.")


def manifest_bytes(entries):
    return json.dumps({"schema": MANIFEST_SCHEMA, "fileCount": len(entries), "files": entries}, indent=1, sort_keys=True).encode()


def build(root, version, channel, min_agent_version, out_dir, built_at=None, rollback_of=None):
    root = os.path.abspath(root)
    built_at = built_at or datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    validate_inputs(version, channel, min_agent_version, built_at, rollback_of)
    if os.path.isdir(os.path.join(root, "ops")):
        raise BuildError("refusing to build a public package inside the private workspace (ops/ exists)")
    if os.path.exists(out_dir):
        raise BuildError("the output folder already exists")
    files = collect(root)
    validate_release_policy(files.get(POLICY_FILE), version)
    check_stable_recipe_lineage(files, channel)
    entries = [{"path": p, "bytes": len(b), "sha256": sha256_hex(b)} for p, b in sorted(files.items())]
    version_doc = canonical_json({"version": version, "builtAtUtc": built_at, "channel": channel,
                                  "sourceManifestSha256": sha256_hex(manifest_bytes(entries))})
    files[VERSION_FILE] = version_doc
    entries = sorted(entries + [{"path": VERSION_FILE, "bytes": len(version_doc), "sha256": sha256_hex(version_doc)}],
                     key=lambda e: e["path"])
    mbytes = manifest_bytes(entries)
    release = {"schema": RELEASE_SCHEMA, "component": COMPONENT, "version": version, "channel": channel,
               "minAgentVersion": min_agent_version, "builtAtUtc": built_at, "manifestSha256": sha256_hex(mbytes)}
    if rollback_of is not None:
        release["rollbackOf"] = rollback_of
    stamp = datetime.datetime.strptime(built_at, "%Y-%m-%dT%H:%M:%SZ")
    fixed = (max(stamp.year, 1980), stamp.month, stamp.day, stamp.hour, stamp.minute, stamp.second - stamp.second % 2)

    def add(archive, name, data):
        info = zipfile.ZipInfo(name, date_time=fixed)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        archive.writestr(info, data)

    os.makedirs(out_dir)
    package = os.path.join(out_dir, "package-unsigned.zip")
    try:
        with zipfile.ZipFile(package, "w", zipfile.ZIP_DEFLATED) as archive:
            for entry in entries:
                add(archive, entry["path"], files[entry["path"]])
            add(archive, "MANIFEST.json", mbytes)
            add(archive, "RELEASE.json", canonical_json(release))
        with open(package, "rb") as handle:
            unsigned_sha256 = sha256_hex(handle.read())
        with open(os.path.join(out_dir, "package-unsigned.sha256"), "w") as handle:
            handle.write(unsigned_sha256 + "\n")
    except BaseException:
        for name in os.listdir(out_dir):
            os.remove(os.path.join(out_dir, name))
        os.rmdir(out_dir)
        raise
    return {"outDir": out_dir, "version": version, "unsignedSha256": unsigned_sha256,
            "manifestSha256": release["manifestSha256"], "fileCount": len(entries)}


def main(argv=None):
    parser = argparse.ArgumentParser(description="Build the unsigned FastLLM release package (offline).")
    parser.add_argument("--version", required=True)
    parser.add_argument("--channel", required=True, choices=CHANNELS)
    parser.add_argument("--min-agent-version", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--built-at")
    parser.add_argument("--rollback-of")
    args = parser.parse_args(argv)
    try:
        result = build(REPO_ROOT, args.version, args.channel, args.min_agent_version, os.path.abspath(args.out),
                       built_at=args.built_at, rollback_of=args.rollback_of)
    except BuildError as error:
        print("build-release: " + str(error), file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
