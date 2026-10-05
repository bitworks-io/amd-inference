#!/usr/bin/env python3
"""Verify and stage a pinned Linux llama.cpp archive without executing it.

The b10698 Vulkan archive is a disabled candidate. Preparing it does not
qualify the host runtime, GPU, model fit, placement, or inference performance.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import stat
import sys
import tarfile
import tempfile
import time
from urllib.parse import urlsplit
import urllib.request

MANIFEST = Path(__file__).with_name("engine-candidates.json")
DOWNLOAD_DEADLINE_SECONDS = 300


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_asset():
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1:
        raise ValueError("unsupported Linux engine manifest")
    asset = manifest["assets"]["vulkan"]
    if asset["status"] != "archive-verified-execution-disabled" or asset.get("executionEnabled") is not False:
        raise ValueError("unexpected Vulkan candidate status")
    return asset


def _expected(asset):
    result = {}
    for entry in asset["members"]:
        name = entry["path"]
        if (not isinstance(name, str) or not name or name in (".", "..")
                or "/" in name or "\\" in name or name in result):
            raise ValueError("invalid candidate member manifest")
        result[name] = entry
    if asset["entryPoint"] not in result or result[asset["entryPoint"]]["type"] != "file":
        raise ValueError("candidate entry point is not a pinned file")
    for entry in result.values():
        if entry["type"] != "symlink":
            continue
        target = entry["target"]
        seen = set()
        while target in result and result[target]["type"] == "symlink":
            if target in seen:
                raise ValueError("candidate symlink cycle")
            seen.add(target)
            target = result[target]["target"]
        if target not in result or result[target]["type"] != "file":
            raise ValueError("candidate symlink escapes pinned files")
    return result


def _archive_members(archive, asset):
    expected = _expected(asset)
    actual = {}
    root = asset["archiveRoot"]
    root_seen = False
    for member in archive.getmembers():
        if member.isdir() and member.name.rstrip("/") == root:
            if root_seen:
                raise ValueError("duplicate archive root")
            root_seen = True
            continue
        prefix = root + "/"
        if not member.name.startswith(prefix):
            raise ValueError("archive path escaped expected root")
        name = member.name[len(prefix):]
        if name not in expected or name in actual or "/" in name or "\\" in name:
            raise ValueError("archive has extra, duplicate, or unsafe member")
        entry = expected[name]
        if entry["type"] == "file":
            if not member.isfile() or member.size != entry["sizeBytes"] or bool(member.mode & 0o111) != entry["executable"]:
                raise ValueError("archive file metadata differs")
        elif entry["type"] == "symlink":
            if not member.issym() or member.linkname != entry["target"] or entry["target"] not in expected:
                raise ValueError("archive symlink differs")
        else:
            raise ValueError("unsupported candidate member type")
        actual[name] = member
    if not root_seen or set(actual) != set(expected):
        raise ValueError("archive member set differs")
    return expected, actual


def verify_archive(path, asset):
    if not path.is_file() or path.stat().st_size != asset["sizeBytes"]:
        raise ValueError("archive size differs")
    if digest_file(path) != asset["sha256"]:
        raise ValueError("archive SHA-256 differs")
    with tarfile.open(path, "r:gz") as archive:
        expected, actual = _archive_members(archive, asset)
        for name, entry in expected.items():
            if entry["type"] != "file":
                continue
            digest = hashlib.sha256()
            with archive.extractfile(actual[name]) as source:
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
            if digest.hexdigest() != entry["sha256"]:
                raise ValueError(f"archive member hash differs: {name}")
    return len(expected)


def verify_tree(folder, asset):
    _require_real_directories(folder)
    if folder.is_symlink() or not folder.is_dir():
        raise ValueError("candidate directory is missing or a symlink")
    directory_metadata = folder.lstat()
    if directory_metadata.st_uid != os.geteuid() or stat.S_IMODE(directory_metadata.st_mode) != 0o700:
        raise ValueError("candidate directory owner or permissions differ")
    expected = _expected(asset)
    actual = {entry.name: entry for entry in os.scandir(folder)}
    if set(actual) != set(expected):
        raise ValueError("candidate file set differs")
    for name, item in expected.items():
        path = folder / name
        if item["type"] == "file":
            metadata = path.lstat()
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_size != item["sizeBytes"]
                    or metadata.st_uid != os.geteuid() or metadata.st_nlink != 1
                    or metadata.st_mode & 0o7777 != (0o700 if item["executable"] else 0o600)
                    or digest_file(path) != item["sha256"]):
                raise ValueError(f"candidate file integrity differs: {name}")
        elif (not path.is_symlink() or path.lstat().st_uid != os.geteuid()
              or path.lstat().st_nlink != 1
              or os.readlink(path) != item["target"]):
            raise ValueError(f"candidate symlink differs: {name}")
    return len(expected)


def _require_real_directories(path):
    absolute = path.expanduser().absolute()
    for current in (absolute, *absolute.parents):
        try:
            metadata = current.lstat()
        except FileNotFoundError as exc:
            raise ValueError(f"directory path does not exist: {current}") from exc
        if not stat.S_ISDIR(metadata.st_mode):
            raise ValueError(f"directory path contains a symlink or non-directory: {current}")


def prepare_asset(archive_path, destination, asset):
    verify_archive(archive_path, asset)
    if destination.exists() or destination.is_symlink():
        raise ValueError("destination already exists; choose a new path")
    _require_real_directories(destination.parent)
    destination.mkdir(mode=0o700)
    try:
        with tarfile.open(archive_path, "r:gz") as archive:
            expected, actual = _archive_members(archive, asset)
            for name, entry in expected.items():
                if entry["type"] != "file":
                    continue
                output = destination / name
                digest = hashlib.sha256()
                with archive.extractfile(actual[name]) as source, output.open("xb") as target:
                    for block in iter(lambda: source.read(1024 * 1024), b""):
                        digest.update(block)
                        target.write(block)
                if digest.hexdigest() != entry["sha256"]:
                    raise ValueError(f"archive changed while staging: {name}")
                output.chmod(0o700 if entry["executable"] else 0o600)
            for name, entry in expected.items():
                if entry["type"] == "symlink":
                    (destination / name).symlink_to(entry["target"])
        verify_tree(destination, asset)
    except Exception:
        # Preserve the partial directory for inspection; never run it.
        raise
    return destination


def require_https(url):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError("engine archive URL and redirects must use HTTPS without credentials")


class HttpsRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        require_https(newurl)
        return super().redirect_request(request, fp, code, msg, headers, newurl)


def download_asset(destination, asset):
    require_https(asset["url"])
    opener = urllib.request.build_opener(HttpsRedirect())
    request = urllib.request.Request(asset["url"], headers={"User-Agent": "FastLLM-Linux-lab/1"})
    deadline = time.monotonic() + DOWNLOAD_DEADLINE_SECONDS
    with opener.open(request, timeout=10) as response, destination.open("xb") as output:
        total = 0
        while True:
            if time.monotonic() >= deadline:
                raise ValueError("engine archive download deadline exceeded")
            block = response.read1(64 * 1024)
            if time.monotonic() >= deadline:
                raise ValueError("engine archive download deadline exceeded")
            if not block:
                break
            total += len(block)
            if total > asset["sizeBytes"]:
                raise ValueError("engine archive exceeds pinned size")
            output.write(block)
    verify_archive(destination, asset)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("inspect", "prepare", "verify-tree"))
    parser.add_argument("--archive", type=Path, help="existing exact upstream Vulkan tar.gz")
    parser.add_argument("--dest", type=Path, help="new stage directory, or existing directory for verify-tree")
    args = parser.parse_args(argv)
    if getattr(os, "geteuid", lambda: -1)() == 0:
        parser.error("run as a standard user; root execution is refused")
    if platform.system() != "Linux" and args.command == "prepare":
        parser.error("prepare requires Linux")
    asset = load_asset()
    try:
        if args.command == "verify-tree":
            if not args.dest:
                parser.error("verify-tree requires --dest")
            count = verify_tree(args.dest, asset)
        elif args.command == "inspect":
            if not args.archive:
                parser.error("inspect requires --archive")
            count = verify_archive(args.archive, asset)
        else:
            if not args.dest:
                parser.error("prepare requires --dest")
            target = args.dest.expanduser().absolute()
            if target.exists() or target.is_symlink() or not target.parent.is_dir():
                parser.error("choose a new destination with an existing parent")
            _require_real_directories(target.parent)
            if args.archive:
                prepare_asset(args.archive, target, asset)
            else:
                with tempfile.TemporaryDirectory(prefix="fastllm-engine-", dir=target.parent) as scratch:
                    downloaded = Path(scratch) / "vulkan.tar.gz"
                    download_asset(downloaded, asset)
                    prepare_asset(downloaded, target, asset)
            count = len(asset["members"])
        print(json.dumps({"archiveSha256": asset["sha256"], "membersVerified": count,
                          "executionEnabled": False, "status": asset["status"]}, indent=2))
        return 0
    except (OSError, ValueError, tarfile.TarError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    sys.exit(main())
