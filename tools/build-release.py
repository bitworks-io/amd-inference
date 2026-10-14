#!/usr/bin/env python3
"""Build the unsigned FastLLM release package. Signing happens in .github/workflows/release.yml.

Writes <out>/package-unsigned.zip and <out>/package-unsigned.sha256. The zip holds the app files, FASTLLM-VERSION.json,
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
TREES = ("src", "tools", "config", "licenses")
SKIP = re.compile(r"(^|/)(__pycache__|bin|obj|\.[^/]*)(/|$)")
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
    for name in ROOT_FILES:
        path = os.path.join(root, name)
        if not os.path.isfile(path) or os.path.islink(path):
            raise BuildError("required root file is missing: " + name)
        with open(path, "rb") as handle:
            files[name] = handle.read()
    for tree in TREES:
        base = os.path.join(root, tree)
        if not os.path.isdir(base):
            raise BuildError("required folder is missing: " + tree)
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
