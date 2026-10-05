#!/usr/bin/env python3
"""Private, opt-in Linux b10698 Vulkan --list-devices lab probe.

This executes no model and starts no service. A successful probe is neither a
dependency-closure, AMD-identity, model-fit, placement nor performance approval.
"""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time


def _load(name):
    source = Path(__file__).with_name(name + ".py")
    spec = importlib.util.spec_from_file_location("fastllm_linux_probe_" + name, source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runtime = _load("runtime")
prereqs = _load("prereqs")
MAX_OUTPUT = 32768
MAX_DEVICES = 8
SYSTEM_LIB_DIRS = prereqs.LIBRARY_DIRS
PINNED_ARCHIVE_SHA256 = "76b77c0a9afa4d6a4424d409cc98c52f3fccb242b7a4dbf4292f0c16f40f4b01"
PINNED_ARCHIVE_URL = "https://github.com/ggml-org/llama.cpp/releases/download/b10698/llama-b10698-bin-ubuntu-vulkan-x64.tar.gz"
PINNED_MANIFEST_SHA256 = "2e0d88d1fc3ff8677fff93659cbd2442698117e405220bba0835dd244894e2ef"
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
DEVICE = re.compile(r"^\s*(Vulkan([0-9]+)):\s+([A-Za-z0-9][A-Za-z0-9 ._+()/-]{0,127}?)\s+"
                    r"\(([0-9]{1,9}) MiB, ([0-9]{1,9}) MiB free\)\s*$")
DEVICE_LIKE = re.compile(r"^\s*Vulkan[0-9]+:")


class ProbeError(ValueError):
    pass


def _trusted_system_file(path):
    """Advisory system-file gate, not an ELF dependency or signature resolver."""
    try:
        path = Path(path)
        if not path.is_absolute() or path.is_symlink() and path.lstat().st_uid != 0:
            return False
        resolved = path.resolve(strict=True)
        roots = [Path(root).resolve(strict=True) for root in SYSTEM_LIB_DIRS if Path(root).is_dir()]
        if not any(resolved == root or root in resolved.parents for root in roots):
            return False
        if not stat.S_ISREG(resolved.stat().st_mode) or resolved.stat().st_size > 64 * 1024 * 1024:
            return False
        for part in (resolved, *resolved.parents):
            metadata = part.stat()
            if metadata.st_uid != 0 or metadata.st_mode & 0o022:
                return False
        return True
    except (OSError, RuntimeError):
        return False


def _trusted_manifest(path):
    try:
        path = Path(path)
        if path.is_symlink() or path.parent not in prereqs.ICD_DIRS:
            return False
        for item in (path, path.parent, *path.parent.parents):
            metadata = item.lstat()
            if metadata.st_uid != 0 or metadata.st_mode & 0o022 or stat.S_ISLNK(metadata.st_mode):
                return False
        return stat.S_ISREG(path.stat().st_mode) and path.stat().st_size <= prereqs.MAX_ICD_BYTES
    except OSError:
        return False


def _glibc_version():
    try:
        found = re.fullmatch(r"glibc ([0-9]+)\.([0-9]+)", os.confstr("CS_GNU_LIBC_VERSION"))
        if found:
            return int(found.group(1)), int(found.group(2))
    except (OSError, ValueError, TypeError):
        pass
    return None


def _trusted_icd_library(library, manifest):
    if not library or "\0" in library or ".." in Path(library).parts or "\\" in library:
        return False
    candidate = Path(library)
    if candidate.is_absolute():
        return _trusted_system_file(candidate)
    if "/" in library:
        return _trusted_system_file(Path(manifest).parent / candidate)
    return any(_trusted_system_file(directory / library) for directory in SYSTEM_LIB_DIRS)


def _has_symbol_versions(path, symbols):
    # A bounded presence check, not a dynamic-linker resolution or ABI test.
    remaining = set(symbols)
    with Path(path).open("rb") as source:
        prior = b""
        while True:
            block = source.read(1024 * 1024)
            if not block:
                break
            window = prior + block
            remaining = {symbol for symbol in remaining if symbol not in window}
            if not remaining:
                return True
            prior = window[-64:]
    return False


def preflight(stage, asset):
    if platform.system() != "Linux" or os.geteuid() == 0 or platform.machine().lower() not in ("x86_64", "amd64"):
        raise ProbeError("probe requires a standard-user Linux x86_64 host")
    with runtime.MANIFEST.open("rb") as manifest_file:
        manifest_bytes = manifest_file.read(MAX_MANIFEST_BYTES + 1)
    if (len(manifest_bytes) > MAX_MANIFEST_BYTES or
            hashlib.sha256(manifest_bytes).hexdigest() != PINNED_MANIFEST_SHA256):
        raise ProbeError("Linux engine candidate manifest differs from the reviewed b10698 manifest")
    canonical = json.loads(manifest_bytes.decode("utf-8"))["assets"]["vulkan"]
    if asset != canonical:
        raise ProbeError("supplied engine candidate differs from the reviewed manifest")
    if (asset.get("status") != "archive-verified-execution-disabled" or asset.get("executionEnabled") is not False
            or asset.get("sha256") != PINNED_ARCHIVE_SHA256 or asset.get("url") != PINNED_ARCHIVE_URL
            or asset.get("entryPoint") != "llama-server"
            or asset.get("platform") != "ubuntu-x86_64"):
        raise ProbeError("unexpected engine candidate policy")
    runtime.verify_tree(stage, asset)
    report = prereqs.assess(stage)
    if report["fixture"] or report["osRelease"]["id"] != "ubuntu" or report["icdFileLimitReached"]:
        raise ProbeError("Ubuntu system metadata or bounded ICD inventory is unavailable")
    glibc = _glibc_version()
    if glibc is None or glibc < (2, 34):
        raise ProbeError("observed glibc is below the pinned archive's symbol floor or unknown")
    libraries = {}
    for name in asset["externalNeeded"]:
        matching = [directory / name for directory in SYSTEM_LIB_DIRS
                    if _trusted_system_file(directory / name)]
        if not matching:
            raise ProbeError("required system library candidate is absent or unsafe: " + name)
        libraries[name] = str(matching[0])
    if not any(item["candidate"] == libraries["libvulkan.so.1"]
               and item["candidateStatus"] in ("regular", "symlink-unverified")
               for item in report["vulkanLoaderCandidates"]):
        raise ProbeError("system Vulkan loader inventory and selected library differ")
    if not _has_symbol_versions(libraries["libstdc++.so.6"], (b"GLIBCXX_3.4.30", b"CXXABI_1.3.13")):
        raise ProbeError("system C++ library lacks the observed pinned-archive symbol versions")
    manifests = []
    for directory in report["icdManifests"]:
        for item in directory["files"]:
            if (item["status"] == "parsed-unverified" and _trusted_manifest(item["path"])
                    and _trusted_icd_library(item["libraryPathText"], item["path"])):
                manifests.append(item["path"])
    if not manifests or len(manifests) > prereqs.MAX_ICD_FILES:
        raise ProbeError("no bounded trusted system Vulkan ICD manifest was found")
    return {"osRelease": report["osRelease"], "glibcObserved": ".".join(map(str, glibc)),
            "systemLibraryCandidates": libraries, "icdManifests": sorted(manifests)}


def parse_devices(output):
    if len(output) > MAX_OUTPUT:
        raise ProbeError("device probe output exceeded its limit")
    devices = []
    try:
        lines = output.decode("utf-8").splitlines()
    except UnicodeError as exc:
        raise ProbeError("device probe output is not UTF-8") from exc
    headers = 0
    for line in lines:
        if line.strip() == "Available devices:":
            headers += 1
            if headers > 1:
                raise ProbeError("ambiguous Vulkan device-list header")
            continue
        if not DEVICE_LIKE.match(line):
            continue
        if headers != 1:
            raise ProbeError("Vulkan device line appeared outside the device list")
        match = DEVICE.fullmatch(line)
        if match is None:
            raise ProbeError("malformed Vulkan device line")
        index = int(match.group(2))
        total, free = int(match.group(4)), int(match.group(5))
        if index != len(devices) or len(devices) >= MAX_DEVICES or total == 0 or free > total:
            raise ProbeError("ambiguous or impossible Vulkan device report")
        devices.append({"device": match.group(1), "name": match.group(3).strip(),
                        "reportedTotalMiB": total, "reportedFreeMiB": free,
                        "amdIdentityVerified": False})
    if headers != 1 or not devices:
        raise ProbeError("pinned engine reported no Vulkan device")
    return devices


def _stop_group(child):
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        raise ProbeError("probe process group did not terminate")


def _capture(child, deadline):
    output = bytearray()
    with selectors.DefaultSelector() as watcher:
        os.set_blocking(child.stdout.fileno(), False)
        watcher.register(child.stdout, selectors.EVENT_READ)
        while watcher.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProbeError("device probe deadline exceeded")
            for key, _ in watcher.select(min(remaining, 0.2)):
                block = os.read(key.fileobj.fileno(), 65536)
                if not block:
                    watcher.unregister(key.fileobj)
                    continue
                if len(output) + len(block) > MAX_OUTPUT:
                    raise ProbeError("device probe output exceeded its limit")
                output.extend(block)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ProbeError("device probe deadline exceeded")
        try:
            code = child.wait(timeout=remaining)
        except subprocess.TimeoutExpired as exc:
            raise ProbeError("device probe deadline exceeded") from exc
    if code != 0:
        raise ProbeError("pinned engine device probe exited nonzero")
    return bytes(output)


def run(stage, *, timeout=20):
    if not 1 <= timeout <= 30:
        raise ProbeError("probe timeout outside lab bounds")
    stage = Path(stage).expanduser().absolute()
    asset = runtime.load_asset()
    host = preflight(stage, asset)
    runtime.verify_tree(stage, asset)
    engine = stage / asset["entryPoint"]
    deadline = time.monotonic() + timeout
    with tempfile.TemporaryDirectory(prefix="fastllm-probe-", dir=stage.parent) as private:
        private = Path(private)
        environment = {"PATH": "/usr/bin:/bin", "HOME": str(private), "TMPDIR": str(private),
                       "XDG_CONFIG_HOME": str(private), "XDG_DATA_HOME": str(private),
                       "LC_ALL": "C", "LANG": "C",
                       "VK_DRIVER_FILES": ":".join(host["icdManifests"]),
                       "VK_LOADER_LAYERS_DISABLE": "~implicit~"}
        child = subprocess.Popen([str(engine), "--list-devices"], cwd=private, env=environment,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, start_new_session=True, close_fds=True)
        try:
            devices = parse_devices(_capture(child, deadline))
        finally:
            try:
                _stop_group(child)
            finally:
                child.stdout.close()
    runtime.verify_tree(stage, asset)
    engine_digest = runtime.digest_file(engine)
    pinned_engine = next(item["sha256"] for item in asset["members"] if item["path"] == asset["entryPoint"])
    if engine_digest != pinned_engine:
        raise ProbeError("engine entry point changed after probe")
    return {"schemaVersion": 1, "labOnly": True, "fixture": False,
            "engineArchiveSha256": asset["sha256"], "engineFileSha256": engine_digest,
            "host": host, "devices": devices, "dynamicLoaderAndProbeCompleted": True,
            "executionArtifactIdentity": "staged manifest verified before and after; process mapping not attested",
            "executionEnabledForServing": False, "dependencyClosureVerified": False,
            "driverIdentityVerified": False, "modelFitVerified": False,
            "physicalResidencyVerified": False, "performanceQualified": False,
            "note": "Only pinned --list-devices completed. External libraries and ICDs are system-supplied; no model or server ran."}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--lab-probe", action="store_true", help="explicitly execute pinned --list-devices only")
    parser.add_argument("--timeout", type=int, default=20)
    args = parser.parse_args(argv)
    if not args.lab_probe:
        parser.error("private native diagnostic requires --lab-probe; serving stays disabled")
    try:
        print(json.dumps(run(args.stage, timeout=args.timeout), indent=2))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    sys.exit(main())
