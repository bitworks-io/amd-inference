#!/usr/bin/env python3
"""Manifest, RELEASE.json and OFFER.json helpers for the FastLLM signing job. Byte-compatible with fast-llm ops/bench/pack.py."""
import hashlib, json, os, sys

SCHEMA = "bitworks.fastllm-release/v1"
MANIFEST_SCHEMA = "fastllm.private-native-test-package.v1"
UNLISTED = {"MANIFEST.json", "RELEASE.json", "FastLLM.cat"}

def canonical(obj):
    return (json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("utf-8")

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""): h.update(chunk)
    return h.hexdigest()

def list_files(tree):
    out = []
    for dp, dn, fn in os.walk(tree):
        dn.sort()
        for f in fn:
            full = os.path.join(dp, f)
            if os.path.islink(full): raise ValueError("link in tree: " + full)
            rel = os.path.relpath(full, tree).replace(os.sep, "/")
            if rel not in UNLISTED: out.append(rel)
    return sorted(out)

def regen_manifest(tree):
    entries = [{"path": r, "bytes": os.path.getsize(os.path.join(tree, r)), "sha256": sha256_file(os.path.join(tree, r))}
               for r in list_files(tree)]
    data = json.dumps({"schema": MANIFEST_SCHEMA, "fileCount": len(entries), "files": entries}, indent=1, sort_keys=True).encode()
    with open(os.path.join(tree, "MANIFEST.json"), "wb") as h: h.write(data)
    return hashlib.sha256(data).hexdigest()

def _read_release(tree):
    with open(os.path.join(tree, "RELEASE.json"), "rb") as h: r = json.loads(h.read())
    if r.get("schema") != SCHEMA or r.get("component") != "fastllm-lab": raise ValueError("RELEASE.json schema/component")
    return r

def update_release(tree):
    r = _read_release(tree)
    r["manifestSha256"] = sha256_file(os.path.join(tree, "MANIFEST.json"))
    with open(os.path.join(tree, "RELEASE.json"), "wb") as h: h.write(canonical(r))

def write_offer(tree, zip_path, out_path):
    r = _read_release(tree); r["packageSha256"] = sha256_file(zip_path)
    with open(out_path, "wb") as h: h.write(canonical(r))

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "regen-manifest": print(regen_manifest(sys.argv[2]))
    elif cmd == "update-release": update_release(sys.argv[2])
    elif cmd == "write-offer": write_offer(sys.argv[2], sys.argv[3], sys.argv[4])
    else: raise SystemExit("unknown command " + cmd)
