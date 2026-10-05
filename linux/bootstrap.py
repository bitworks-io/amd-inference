#!/usr/bin/env python3
"""Install a checksum-pinned FastLLM source ZIP into a new local directory.

The operator supplies a reviewed immutable release URL and its independently
published SHA-256. This bootstrap does not execute downloaded code.
"""

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import time
import urllib.request
from urllib.parse import urlsplit
import zipfile

MAX_ARCHIVE = 64 * 1024 * 1024
MAX_EXPANDED = 256 * 1024 * 1024
MAX_FILES = 2000
DOWNLOAD_DEADLINE_SECONDS = 120


def require_https(url):
    parsed = urlsplit(url)
    if parsed.scheme.lower() != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError("source URL and every redirect must be HTTPS without URL credentials")


class HttpsRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        require_https(newurl)
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def fetch(source_url, destination):
    require_https(source_url)
    request = urllib.request.Request(source_url, headers={"User-Agent": "FastLLM-Linux-lab-bootstrap/1"})
    opener = urllib.request.build_opener(HttpsRedirect())
    deadline = time.monotonic() + DOWNLOAD_DEADLINE_SECONDS
    with opener.open(request, timeout=10) as response, destination.open("wb") as output:
        total = 0
        while True:
            if time.monotonic() >= deadline:
                raise ValueError("source download deadline exceeded")
            block = response.read1(64 * 1024)
            if time.monotonic() >= deadline:
                raise ValueError("source download deadline exceeded")
            if not block:
                break
            total += len(block)
            if total > MAX_ARCHIVE:
                raise ValueError("source archive exceeds size ceiling")
            output.write(block)


def verify_archive(path, expected):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != expected.lower():
        raise ValueError("source archive SHA-256 mismatch")


def unpack(path, destination):
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        if len(members) > MAX_FILES or sum(m.file_size for m in members) > MAX_EXPANDED:
            raise ValueError("archive exceeds extraction ceiling")
        roots = set()
        checked = []
        seen = set()
        for member in members:
            raw = member.filename
            if not raw or raw.startswith("/") or "\\" in raw:
                raise ValueError("unsafe archive path")
            parts = raw[:-1].split("/") if raw.endswith("/") else raw.split("/")
            if not parts or any(p in ("", ".", "..") for p in parts):
                raise ValueError("unsafe archive path")
            key = tuple(parts)
            if key in seen:
                raise ValueError("duplicate archive path")
            seen.add(key)
            mode = (member.external_attr >> 16) & 0xffff
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError("archive contains a non-regular entry")
            roots.add(parts[0])
            checked.append((member, parts))
        if len(roots) != 1:
            raise ValueError("archive must have one root directory")
        for member, parts in checked:
            relative = Path(*parts[1:])
            if not parts[1:]:
                continue
            target = destination / relative
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
        if (not (destination / "config" / "catalog.json").is_file()
                or not (destination / "config" / "catalog.sha256").is_file()
                or not (destination / "linux" / "fast-llm-linux.py").is_file()
                or not (destination / "linux" / "models.py").is_file()
                or not (destination / "linux" / "prereqs.py").is_file()
                or not (destination / "linux" / "probe.py").is_file()
                or not (destination / "linux" / "serve.py").is_file()
                or not (destination / "linux" / "lab.py").is_file()
                or not (destination / "linux" / "ubuntu_packages.py").is_file()
                or not (destination / "linux" / "runtime.py").is_file()
                or not (destination / "linux" / "engine-candidates.json").is_file()):
            raise ValueError("archive is missing the expected FastLLM source files")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-url", required=True, help="immutable reviewed release ZIP URL")
    parser.add_argument("--sha256", required=True, help="independently obtained SHA-256")
    parser.add_argument("--dest", required=True, type=Path, help="new installation directory")
    args = parser.parse_args(argv)
    if getattr(os, "geteuid", lambda: -1)() == 0:
        parser.error("run as a standard user; root execution is refused")
    if len(args.sha256) != 64 or any(c not in "0123456789abcdefABCDEF" for c in args.sha256):
        parser.error("--sha256 must be 64 hexadecimal characters")
    target = args.dest.expanduser().resolve()
    if target.exists():
        parser.error("destination already exists; choose a new directory")
    if not target.parent.is_dir():
        parser.error("destination parent must already exist")
    with tempfile.TemporaryDirectory(prefix="fastllm-source-", dir=target.parent) as scratch:
        scratch = Path(scratch)
        archive = scratch / "source.zip"
        staged = scratch / "tree"
        staged.mkdir()
        fetch(args.source_url, archive)
        verify_archive(archive, args.sha256)
        unpack(archive, staged)
        staged.rename(target)
    print(f"Source installed at {target}")
    print(f"Next (explicit private lab only): python3 {target / 'linux' / 'lab.py'} start --lab")
    print("No engine, driver, model, or system package was installed.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"Bootstrap stopped: {exc}", file=sys.stderr)
        sys.exit(1)
