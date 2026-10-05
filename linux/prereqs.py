#!/usr/bin/env python3
"""Read-only Linux Vulkan prerequisite inventory for a verified, disabled engine.

This does not resolve ELF dependencies, load a library, start llama.cpp, query
the Vulkan driver, or establish compatibility. Fixture paths are test-only.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import stat
import sys

RUNTIME_PATH = Path(__file__).with_name("runtime.py")
SPEC = importlib.util.spec_from_file_location("fastllm_linux_runtime_prereqs", RUNTIME_PATH)
runtime = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runtime)

OS_RELEASE = Path("/etc/os-release")
FALLBACK_OS_RELEASE = Path("/usr/lib/os-release")
LIBRARY_DIRS = (Path("/usr/lib/x86_64-linux-gnu"), Path("/usr/lib64"), Path("/usr/lib"),
                Path("/lib/x86_64-linux-gnu"), Path("/lib64"), Path("/lib"))
ICD_DIRS = (Path("/usr/share/vulkan/icd.d"), Path("/etc/vulkan/icd.d"))
MAX_OS_RELEASE_BYTES = 16 * 1024
MAX_ICD_BYTES = 64 * 1024
MAX_ICD_FILES = 64
MAX_ICD_DIR_ENTRIES = 256
MAX_JSON_DEPTH = 16
MAX_PATH_CHARS = 4096
KEY_VALUE = re.compile(r"^([A-Z][A-Z0-9_]*)=(.*)$")


def _path_status(path, *, allow_leaf_symlink=False):
    path = Path(path).expanduser().absolute()
    if len(str(path)) > MAX_PATH_CHARS or ".." in path.parts:
        return "unsafe-path"
    for parent in path.parents:
        try:
            mode = parent.lstat().st_mode
        except OSError:
            return "missing-parent"
        if not stat.S_ISDIR(mode):
            return "symlink-or-nondirectory-parent"
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return "missing"
    except OSError:
        return "unreadable"
    if stat.S_ISLNK(mode):
        return "symlink-unverified" if allow_leaf_symlink else "unsafe-symlink"
    if stat.S_ISREG(mode):
        return "regular"
    if stat.S_ISDIR(mode):
        return "directory"
    return "unsupported-file-type"


def _open_dir_no_follow(path):
    """Walk from / using directory FDs, never resolving a swapped symlink."""
    path = Path(path).expanduser().absolute()
    if len(str(path)) > MAX_PATH_CHARS or ".." in path.parts:
        raise ValueError("unsafe metadata directory path")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open("/", flags)
    try:
        for component in path.parts[1:]:
            child = os.open(component, flags, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except Exception:
        os.close(fd)
        raise


def _status_at(parent_fd, name, *, allow_symlink=False):
    try:
        mode = os.stat(name, dir_fd=parent_fd, follow_symlinks=False).st_mode
    except FileNotFoundError:
        return "missing"
    except OSError:
        return "unreadable"
    if stat.S_ISLNK(mode):
        return "symlink-unverified" if allow_symlink else "unsafe-symlink"
    if stat.S_ISREG(mode):
        return "regular"
    if stat.S_ISDIR(mode):
        return "directory"
    return "unsupported-file-type"


def _bounded_read(path, limit, *, parent_fd=None):
    path = Path(path)
    own_parent = parent_fd is None
    if own_parent:
        parent_fd = _open_dir_no_follow(path.parent)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        try:
            metadata = os.fstat(fd)
            if (not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1
                    or metadata.st_size > limit):
                raise ValueError("non-regular, hardlinked, or oversized metadata")
            with os.fdopen(fd, "rb", closefd=False) as stream:
                raw = stream.read(limit + 1)
            if len(raw) > limit:
                raise ValueError("oversized metadata")
            return raw
        finally:
            os.close(fd)
    finally:
        if own_parent:
            os.close(parent_fd)


def _read_os_release(path, fixture):
    status = _path_status(path)
    source = Path(path)
    # /etc/os-release commonly points at this fixed, system-owned fallback.
    fallback = False
    if status == "unsafe-symlink" and not fixture and source == OS_RELEASE:
        try:
            if os.readlink(source) in ("../usr/lib/os-release", str(FALLBACK_OS_RELEASE)):
                source = FALLBACK_OS_RELEASE
                status = _path_status(source)
                fallback = status == "regular"
        except OSError:
            pass
    result = {"path": str(path), "resolvedSourcePath": str(source),
              "allowlistedSymlinkFallback": fallback,
              "status": "allowlisted-symlink-fallback" if fallback else status,
              "id": None, "versionId": None,
              "prettyName": None, "candidateDistroStatus": "unknown"}
    if status != "regular":
        return result
    try:
        raw = _bounded_read(source, MAX_OS_RELEASE_BYTES).decode("utf-8")
        if len(raw.splitlines()) > 128:
            raise ValueError("too many os-release lines")
        values = {}
        for line in raw.splitlines():
            if not line or line.startswith("#"):
                continue
            match = KEY_VALUE.fullmatch(line)
            if not match or len(match.group(2)) > 1024 or match.group(1) in values:
                raise ValueError("malformed os-release field")
            value = match.group(2)
            if value.startswith(('"', "'")):
                quote = value[0]
                if len(value) < 2 or value[-1] != quote:
                    raise ValueError("malformed os-release quote")
                value = value[1:-1]
            values[match.group(1)] = value
        distro = values.get("ID")
        if distro and not re.fullmatch(r"[a-z0-9._-]{1,64}", distro):
            raise ValueError("invalid distro ID")
        result.update({"id": distro, "versionId": values.get("VERSION_ID"),
                       "prettyName": values.get("PRETTY_NAME"),
                       "candidateDistroStatus": ("ubuntu-unqualified" if distro == "ubuntu" else
                                                  "unsupported-for-ubuntu-candidate" if distro else "unknown")})
    except (OSError, UnicodeError, ValueError):
        result["status"] = "malformed-or-oversized"
    return result


def _json_depth(value, depth=0):
    if depth > MAX_JSON_DEPTH:
        raise ValueError("ICD JSON exceeds nesting limit")
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str) or len(key) > 256:
                raise ValueError("ICD JSON key invalid")
            _json_depth(child, depth + 1)
    elif isinstance(value, list):
        for child in value:
            _json_depth(child, depth + 1)


def _icd_file(path, parent_fd):
    status = _status_at(parent_fd, path.name)
    result = {"path": str(path), "status": status, "libraryPathText": None,
              "driverIdentity": "unknown"}
    if status != "regular":
        return result
    try:
        def unique_keys(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("duplicate ICD JSON key")
                result[key] = value
            return result

        data = json.loads(_bounded_read(path, MAX_ICD_BYTES, parent_fd=parent_fd).decode("utf-8"),
                          object_pairs_hook=unique_keys)
        _json_depth(data)
        if not isinstance(data, dict) or not isinstance(data.get("ICD"), dict):
            raise ValueError("missing ICD object")
        library = data["ICD"].get("library_path")
        if not isinstance(library, str) or not library or len(library) > 512:
            raise ValueError("invalid ICD library_path")
        result["libraryPathText"] = library
        result["status"] = ("unsafe-library-path-text" if ".." in Path(library).parts or "\\" in library
                            else "parsed-unverified")
    except (OSError, UnicodeError, ValueError, TypeError, RecursionError):
        result["status"] = "malformed-or-oversized"
    return result


def assess(stage, *, asset=None, os_release=OS_RELEASE, library_dirs=LIBRARY_DIRS,
           icd_dirs=ICD_DIRS, fixture=False):
    """Verify staged files first, then inventory inert host metadata only."""
    defaults = (Path(os_release) == OS_RELEASE and tuple(map(Path, library_dirs)) == LIBRARY_DIRS
                and tuple(map(Path, icd_dirs)) == ICD_DIRS)
    if (asset is not None or not defaults) and not fixture:
        raise ValueError("alternate manifest or system paths require fixture=True")
    if not fixture and (platform.system() != "Linux" or os.geteuid() == 0):
        raise ValueError("native prerequisite inventory requires a standard-user Linux host")
    asset = asset or runtime.load_asset()
    runtime.verify_tree(Path(stage), asset)
    if len(library_dirs) > 16 or len(icd_dirs) > 8:
        raise ValueError("too many system inventory directories")
    loaders = []
    for directory in library_dirs:
        directory = Path(directory)
        status = _path_status(directory)
        candidate = directory / "libvulkan.so.1"
        candidate_status = "not-inspected"
        if status == "directory":
            try:
                directory_fd = _open_dir_no_follow(directory)
                try:
                    candidate_status = _status_at(directory_fd, candidate.name, allow_symlink=True)
                finally:
                    os.close(directory_fd)
            except (OSError, ValueError):
                candidate_status = "unsafe-or-unreadable-directory"
        loaders.append({"directory": str(directory), "directoryStatus": status,
                        "candidate": str(candidate),
                        "candidateStatus": candidate_status})
    icds = []
    truncated = False
    icd_count = 0
    for directory in icd_dirs:
        directory = Path(directory)
        status = _path_status(directory)
        if status != "directory":
            icds.append({"directory": str(directory), "directoryStatus": status, "files": []})
            continue
        files = []
        try:
            scanned = 0
            directory_fd = _open_dir_no_follow(directory)
            try:
                with os.scandir(directory_fd) as entries:
                    for entry in entries:
                        scanned += 1
                        if scanned > MAX_ICD_DIR_ENTRIES:
                            truncated = True
                            break
                        if not entry.name.endswith(".json"):
                            continue
                        if icd_count >= MAX_ICD_FILES:
                            truncated = True
                            break
                        files.append(_icd_file(directory / entry.name, directory_fd))
                        icd_count += 1
            finally:
                os.close(directory_fd)
        except (OSError, ValueError):
            status = "unreadable"
        icds.append({"directory": str(directory), "directoryStatus": status,
                     "files": sorted(files, key=lambda item: item["path"])})
    return {"schemaVersion": 1, "fixture": fixture,
            "executionEnabled": False, "compatibilityVerified": False,
            "driverIdentityVerified": False, "engineStatus": asset["status"],
            "engineArchiveSha256": asset["sha256"], "verifiedStage": str(Path(stage).absolute()),
            "hostArchitecture": platform.machine(),
            "manifestExternalNeeded": asset.get("externalNeeded", []),
            "manifestMinimumObservedSymbolVersions": asset.get("minimumObservedSymbolVersions", {}),
            "osRelease": _read_os_release(os_release, fixture),
            "vulkanLoaderCandidates": loaders, "icdManifests": icds,
            "icdFileLimitReached": truncated,
            "note": "Static candidate paths only; no ELF resolver, Vulkan loader/ICD execution, AMD identity, or compatibility proof."}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", type=Path, required=True, help="existing verified engine staging directory")
    args = parser.parse_args(argv)
    try:
        result = assess(args.stage)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
