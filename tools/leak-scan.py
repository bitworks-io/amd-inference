#!/usr/bin/env python3
"""Public leak scan for FastLLM.

Fails when a tree contains private network addresses, personal paths, email addresses, secrets, key files or
host-specific hardware identifiers. Prints path:line: rule-id (line 0 = a file-name hit) and never the matched text.
Exit 0 clean, 1 findings, 2 refused.

Usage: leak-scan.py <tree> [--git-tracked] [--allow tools/leak-scan-allow.json]
"""
import argparse
import json
import os
import re
import subprocess
import sys

RULES = (
    ("private-ipv4", re.compile(r"(?<![\d.])(?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}"
                                r"|192\.168\.\d{1,3}\.\d{1,3}|169\.254\.\d{1,3}\.\d{1,3})(?![\d.])")),
    ("windows-user-path", re.compile(r"[A-Za-z]:(?:\\\\|\\|/)Users(?:\\\\|\\|/)"
                                     r"(?!(?:Public|Default|test|user|username|runneradmin|example)\b)[A-Za-z0-9._-]{2,}", re.I)),
    ("mac-user-path", re.compile(r"/Users/(?!(?:Shared|runner|username|example)\b)[A-Za-z0-9._-]{2,}")),
    ("linux-home-path", re.compile(r"/home/(?!(?:runner|user|username|example)\b)[A-Za-z0-9._-]{2,}")),
    ("email", re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")),
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("github-token", re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})")),
    ("aws-access-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("azure-storage-key", re.compile(r"AccountKey=[A-Za-z0-9+/=]{40,}")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    ("pnp-instance-suffix", re.compile(r"VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}[^\s\"']*?\\{1,2}[0-9A-F]&[0-9A-F]{6,8}&[0-9A-F]&[0-9A-F]{8}", re.I)),
    ("machine-name", re.compile(r"\bDESKTOP-[A-Z0-9]{7}\b")),
    ("windows-sid", re.compile(r"\bS-1-5-21-\d{6,10}-\d{6,10}-\d{6,10}\b")),
    ("mac-address", re.compile(r"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b")),
)
ALLOWED_EMAIL = re.compile(r"^(?:security@bitworks\.io|noreply@github\.com|git@github\.com"
                           r"|[0-9]+\+[A-Za-z0-9-]+@users\.noreply\.github\.com|[^@]+@example\.(?:com|org|net))$", re.I)
KEY_FILE_EXTENSIONS = frozenset({".pem", ".pfx", ".p12", ".key", ".ppk", ".snk"})
SKIP_DIRS = frozenset({".git", "__pycache__", "node_modules"})
MAX_BYTES = 8 * 1024 * 1024


class Refused(Exception):
    pass


def load_allow(path, tree):
    if path is None or not os.path.exists(path):
        return set()
    with open(path, encoding="utf-8") as handle:
        document = json.load(handle)
    if set(document) != {"entries"} or not isinstance(document["entries"], list):
        raise Refused("allowlist must be {\"entries\": [...]}")
    allowed = set()
    for entry in document["entries"]:
        if not isinstance(entry, dict) or set(entry) != {"path", "rule", "reason"} or not str(entry["reason"]).strip():
            raise Refused("each allowlist entry needs path, rule and a reason")
        if entry["rule"] not in {name for name, _ in RULES} | {"key-file"}:
            raise Refused(f"allowlist names an unknown rule: {entry['rule']}")
        if not os.path.isfile(os.path.join(tree, entry["path"])):
            raise Refused(f"allowlist entry is stale (file missing): {entry['path']}")
        allowed.add((entry["path"], entry["rule"]))
    return allowed


def list_files(tree, git_tracked):
    if git_tracked:
        proc = subprocess.run(["git", "-C", tree, "ls-files", "-z"], stdout=subprocess.PIPE, check=True)
        return sorted(item for item in proc.stdout.decode("utf-8").split("\0") if item)
    files = []
    for current, dirs, names in os.walk(tree):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in names:
            files.append(os.path.relpath(os.path.join(current, name), tree).replace(os.sep, "/"))
    return sorted(files)


def line_rules(line):
    for rule, pattern in RULES:
        if rule == "email":
            if any(not ALLOWED_EMAIL.match(match.group(0)) for match in pattern.finditer(line)):
                yield rule
        elif pattern.search(line):
            yield rule


def scan(tree, allow, git_tracked=False):
    findings = []
    for rel in list_files(tree, git_tracked):
        if os.path.splitext(rel)[1].lower() in KEY_FILE_EXTENSIONS and (rel, "key-file") not in allow:
            findings.append((rel, 0, "key-file"))
        path = os.path.join(tree, rel)
        if os.path.islink(path) or not os.path.isfile(path):
            continue
        if os.path.getsize(path) > MAX_BYTES:
            findings.append((rel, 0, "file-too-large-to-scan"))
            continue
        with open(path, "rb") as handle:
            text = handle.read().decode("utf-8", errors="replace")
        for number, line in enumerate(text.splitlines(), 1):
            for rule in line_rules(line):
                if (rel, rule) not in allow:
                    findings.append((rel, number, rule))
    return findings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tree")
    parser.add_argument("--git-tracked", action="store_true")
    parser.add_argument("--allow", default=None, help="defaults to tools/leak-scan-allow.json inside the tree")
    args = parser.parse_args(argv)
    allow_path = args.allow or os.path.join(args.tree, "tools", "leak-scan-allow.json")
    try:
        allow = load_allow(allow_path, args.tree)
    except (OSError, ValueError, Refused) as error:
        print(f"leak-scan: refusing: {error}", file=sys.stderr)
        return 2
    findings = scan(args.tree, allow, args.git_tracked)
    for rel, number, rule in findings:
        print(f"{rel}:{number}: {rule}")
    print(f"leak-scan: {len(findings)} finding(s)", file=sys.stderr)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
