#!/usr/bin/env python3
"""Install a checksum-pinned, full-commit FastLLM source ZIP locally.

The operator independently obtains its exact byte count and SHA-256. By
default this bootstrap verifies and installs source without executing it;
guided lab continuation requires a separate explicit opt-in.
"""

import argparse
import ctypes
import functools
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
from urllib.parse import urlsplit
import zipfile

MAX_ARCHIVE = 64 * 1024 * 1024
MAX_EXPANDED = 256 * 1024 * 1024
MAX_FILES = 2000
MAX_MANIFEST = 2 * 1024 * 1024
DOWNLOAD_DEADLINE_SECONDS = 120
MAX_REDIRECTS = 3
SOURCE_RE = re.compile(r"/bitworks-io/amd-inference/archive/([0-9a-fA-F]{40})\.zip\Z")


def require_https(url):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password or parsed.port:
        raise ValueError("source URL and every redirect must be HTTPS without URL credentials")
    if parsed.query or parsed.fragment:
        raise ValueError("source URL and redirects must not have query or fragment")
    return parsed


def source_commit(url):
    parsed = require_https(url)
    match = SOURCE_RE.fullmatch(parsed.path)
    if parsed.hostname != "github.com" or not match:
        raise ValueError("source URL must be the canonical bitworks-io/amd-inference full-commit GitHub ZIP")
    return match.group(1).lower()


class HttpsRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, commit):
        self.commit = commit
        self.count = 0

    def redirect_request(self, request, fp, code, msg, headers, newurl):
        parsed = require_https(newurl)
        self.count += 1
        if self.count > MAX_REDIRECTS:
            raise ValueError("source download exceeded redirect ceiling")
        allowed_path = f"/bitworks-io/amd-inference/zip/{self.commit}"
        if parsed.hostname != "codeload.github.com" or parsed.path.lower() != allowed_path:
            raise ValueError("source redirect is not the reviewed GitHub commit asset")
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def fetch(source_url, destination, expected_bytes):
    commit = source_commit(source_url)
    if type(expected_bytes) is not int or not 0 < expected_bytes <= MAX_ARCHIVE:
        raise ValueError("expected source bytes must be an integer within the archive ceiling")
    request = urllib.request.Request(source_url, headers={"User-Agent": "FastLLM-Linux-lab-bootstrap/1"})
    opener = urllib.request.build_opener(HttpsRedirect(commit))
    deadline = time.monotonic() + DOWNLOAD_DEADLINE_SECONDS
    created = False
    try:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ValueError("source download deadline exceeded")
        with opener.open(request, timeout=min(10, remaining)) as response:
            length = response.headers.get("Content-Length") if getattr(response, "headers", None) else None
            if length is not None and (not length.isdecimal() or int(length) != expected_bytes):
                raise ValueError("source Content-Length differs from expected bytes")
            with destination.open("xb") as output:
                created = True
                total = 0
                while True:
                    if time.monotonic() >= deadline:
                        raise ValueError("source download deadline exceeded")
                    block = response.read1(min(64 * 1024, expected_bytes - total + 1))
                    if time.monotonic() >= deadline:
                        raise ValueError("source download deadline exceeded")
                    if not block:
                        break
                    total += len(block)
                    if total > expected_bytes:
                        raise ValueError("source archive exceeds expected bytes")
                    output.write(block)
                if total != expected_bytes:
                    raise ValueError("source archive shorter than expected bytes")
    except BaseException:
        if created:
            destination.unlink(missing_ok=True)
        raise


def verify_archive(path, expected):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != expected.lower():
        raise ValueError("source archive SHA-256 mismatch")


def _source_path(raw):
    if not isinstance(raw, str) or not raw or "\\" in raw or raw.startswith("/"):
        raise ValueError("unsafe source manifest path")
    parts = raw.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError("unsafe source manifest path")
    return Path(*parts)


def verify_source_manifest(destination):
    manifest_path = destination / "PUBLIC-SOURCE-MANIFEST.json"
    if manifest_path.is_symlink() or not manifest_path.is_file() or manifest_path.stat().st_size > MAX_MANIFEST:
        raise ValueError("missing or oversized public source manifest")
    try:
        manifest = json.loads(manifest_path.read_bytes().decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("invalid public source manifest") from exc
    if (not isinstance(manifest, dict) or set(manifest) != {"schemaVersion", "kind", "files"}
            or type(manifest["schemaVersion"]) is not int or manifest["schemaVersion"] != 1
            or manifest["kind"] != "source-only-public-staging"
            or not isinstance(manifest["files"], list)
            or not 0 < len(manifest["files"]) <= MAX_FILES - 1):
        raise ValueError("invalid public source manifest schema")
    declared = set()
    folded = set()
    for entry in manifest["files"]:
        if not isinstance(entry, dict) or set(entry) != {"path", "sizeBytes", "sha256"}:
            raise ValueError("invalid public source manifest entry")
        relative = _source_path(entry["path"])
        name = relative.as_posix()
        if name == "PUBLIC-SOURCE-MANIFEST.json" or name in declared or name.casefold() in folded:
            raise ValueError("duplicate public source manifest path")
        folded.add(name.casefold())
        declared.add(name)
        size = entry["sizeBytes"]
        digest = entry["sha256"]
        if (type(size) is not int or not 0 <= size <= MAX_EXPANDED
                or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            raise ValueError("invalid public source manifest size or SHA-256")
        target = destination / relative
        if target.is_symlink() or not target.is_file() or target.stat().st_size != size:
            raise ValueError("public source manifest file missing or size mismatch")
        actual = hashlib.sha256()
        with target.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                actual.update(block)
        if actual.hexdigest() != digest:
            raise ValueError("public source manifest SHA-256 mismatch")
    actual_files = set()
    for path in destination.rglob("*"):
        if path.is_symlink():
            raise ValueError("public source tree contains a symlink")
        if path.is_file():
            actual_files.add(path.relative_to(destination).as_posix())
        elif not path.is_dir():
            raise ValueError("public source tree contains a non-regular entry")
    if actual_files != declared | {"PUBLIC-SOURCE-MANIFEST.json"}:
        raise ValueError("public source manifest file set mismatch")


def unpack(path, destination):
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        if len(members) > MAX_FILES or sum(m.file_size for m in members) > MAX_EXPANDED:
            raise ValueError("archive exceeds extraction ceiling")
        roots = set()
        checked = []
        seen = set()
        folded = set()
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
            folded_key = tuple(part.casefold() for part in parts)
            if folded_key in folded:
                raise ValueError("case-colliding archive path")
            folded.add(folded_key)
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
                    written = 0
                    while block := source.read(1024 * 1024):
                        written += len(block)
                        if written > member.file_size or written > MAX_EXPANDED:
                            raise ValueError("archive member exceeds extraction ceiling")
                        output.write(block)
                    if written != member.file_size:
                        raise ValueError("archive member size mismatch")
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
        verify_source_manifest(destination)


def require_continuation_host():
    if platform.system() != "Linux" or platform.machine().lower() not in ("x86_64", "amd64"):
        raise ValueError("guided lab continuation requires a Linux x86-64 host")


def _verify_directory_chain(directory):
    uid = os.geteuid()
    for path in (directory, *directory.parents):
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid not in (0, uid):
            raise ValueError("guided lab source has an unsafe directory ancestor")
        if info.st_mode & 0o022 and not (info.st_uid == 0 and info.st_mode & stat.S_ISVTX):
            raise ValueError("guided lab source has an other-user-writable directory ancestor")


def verify_launch_tree(destination):
    """Check exact source and cross-user permissions, not same-user immutability."""
    _verify_directory_chain(destination)
    uid = os.geteuid()
    if destination.lstat().st_uid != uid:
        raise ValueError("guided lab source root is not owned by the current user")
    for path in destination.rglob("*"):
        info = path.lstat()
        if info.st_uid != uid or info.st_mode & 0o022:
            raise ValueError("guided lab source has an unsafe owner or writable member")
        if stat.S_ISREG(info.st_mode):
            if info.st_nlink != 1:
                raise ValueError("guided lab source has a hardlinked member")
        elif not stat.S_ISDIR(info.st_mode):
            raise ValueError("guided lab source contains a non-regular member")
    verify_source_manifest(destination)


def _seal_source_tree(destination):
    # The private scratch directory was just created by this process. Do not
    # depend on a permissive caller umask when subsequently exposing it.
    destination.chmod(0o700)
    for path in destination.rglob("*"):
        if path.is_dir() and not path.is_symlink():
            path.chmod(0o700)
        elif path.is_file() and not path.is_symlink():
            path.chmod(0o600)
        else:
            raise ValueError("guided lab source contains a non-regular member")


class _Terminated(KeyboardInterrupt):
    pass


def _parent_death(expected_parent):
    # The direct foreground lab child must not survive sudden bootstrap death.
    if os.getppid() != expected_parent:
        os._exit(127)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(1, signal.SIGTERM, 0, 0, 0) != 0 or os.getppid() != expected_parent:
        os._exit(127)


def continue_lab(destination, action, *, install_system_packages=False):
    if action not in ("setup", "start"):
        raise ValueError("guided lab continuation action is not allowed")
    verify_launch_tree(destination)
    command = [sys.executable, "-I", "-B", str(destination / "linux" / "lab.py"), action, "--lab"]
    if install_system_packages:
        command.append("--install-system-packages")
    old_term = signal.getsignal(signal.SIGTERM)

    def interrupted(signum, _frame):
        raise _Terminated(signum)

    signal.signal(signal.SIGTERM, interrupted)
    child = None
    try:
        try:
            child = subprocess.Popen(command, cwd=destination, start_new_session=True,
                                     preexec_fn=functools.partial(_parent_death, os.getpid()))
            code = child.wait()
        except KeyboardInterrupt as exc:
            signum = signal.SIGTERM if isinstance(exc, _Terminated) else signal.SIGINT
            if child is not None and child.poll() is None:
                try:
                    os.killpg(child.pid, signum)
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
            return 128 + signum
        except BaseException:
            if child is not None and child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
            raise
    finally:
        signal.signal(signal.SIGTERM, old_term)
    return code if code >= 0 else 128 - code


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-url", required=True, help="reviewed full-commit GitHub source ZIP URL")
    parser.add_argument("--sha256", required=True, help="independently obtained SHA-256")
    parser.add_argument("--source-bytes", required=True, type=int, help="independently obtained exact ZIP byte length")
    parser.add_argument("--dest", required=True, type=Path, help="new installation directory")
    parser.add_argument("--continue-lab", choices=("setup", "start"),
                        help="opt in to fixed guided lab command after complete source verification")
    parser.add_argument("--continue-install-system-packages", action="store_true",
                        help="with --continue-lab, offer existing interactive Ubuntu package review; never auto-approve")
    args = parser.parse_args(argv)
    if args.continue_install_system_packages and not args.continue_lab:
        parser.error("--continue-install-system-packages requires --continue-lab setup or start")
    if getattr(os, "geteuid", lambda: -1)() == 0:
        parser.error("run as a standard user; root execution is refused")
    if len(args.sha256) != 64 or any(c not in "0123456789abcdefABCDEF" for c in args.sha256):
        parser.error("--sha256 must be 64 hexadecimal characters")
    try:
        source_commit(args.source_url)
    except ValueError as exc:
        parser.error(str(exc))
    if not 0 < args.source_bytes <= MAX_ARCHIVE:
        parser.error("--source-bytes must be positive and within the archive ceiling")
    if args.continue_lab:
        try:
            require_continuation_host()
        except ValueError as exc:
            parser.error(str(exc))
    target = args.dest.expanduser().resolve()
    if target.exists():
        parser.error("destination already exists; choose a new directory")
    if not target.parent.is_dir():
        parser.error("destination parent must already exist")
    if args.continue_lab:
        try:
            _verify_directory_chain(target.parent)
        except (OSError, ValueError) as exc:
            parser.error(str(exc))
    with tempfile.TemporaryDirectory(prefix="fastllm-source-", dir=target.parent) as scratch:
        scratch = Path(scratch)
        archive = scratch / "source.zip"
        staged = scratch / "tree"
        staged.mkdir(mode=0o700)
        fetch(args.source_url, archive, args.source_bytes)
        verify_archive(archive, args.sha256)
        unpack(archive, staged)
        if args.continue_lab:
            _seal_source_tree(staged)
        staged.rename(target)
    print(f"Source installed at {target}")
    if args.continue_lab:
        print("Starting explicitly opted-in private guided lab " + args.continue_lab + "; source remains installed on child failure.")
        return continue_lab(target, args.continue_lab,
                            install_system_packages=args.continue_install_system_packages)
    print(f"Next (explicit private lab only): python3 {target / 'linux' / 'lab.py'} start --lab")
    print("No engine, driver, model, or system package was installed.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"Bootstrap stopped: {exc}", file=sys.stderr)
        sys.exit(1)
