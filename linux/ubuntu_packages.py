#!/usr/bin/env python3
"""Explicit Ubuntu 24.04 AMD64 lab prerequisite transaction.

The caller stays unprivileged. Normal root-owned Ubuntu APT hooks and signed
package maintainer scripts execute as root after two explicit approvals.
This does not install a driver or enable serving.
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
import time


def _load(name):
    path = Path(__file__).with_name(name + ".py")
    spec = importlib.util.spec_from_file_location("fastllm_ubuntu_packages_" + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runtime = _load("runtime")
prereqs = _load("prereqs")
probe = _load("probe")

SOURCES = Path("/etc/apt/sources.list.d/ubuntu.sources")
KEYRING = Path("/usr/share/keyrings/ubuntu-archive-keyring.gpg")
APT_CONF = Path("/etc/apt/apt.conf")
APT_CONF_D = Path("/etc/apt/apt.conf.d")
PACKAGE_BY_LIBRARY = {
    "libvulkan.so.1": "libvulkan1",
    "libgomp.so.1": "libgomp1",
    "libssl.so.3": "libssl3t64",
    "libcrypto.so.3": "libssl3t64",
    "libstdc++.so.6": "libstdc++6",
    "libgcc_s.so.1": "libgcc-s1",
    "libc.so.6": "libc6",
    "libm.so.6": "libc6",
}
EXPECTED_LIBRARIES = frozenset(PACKAGE_BY_LIBRARY)
PACKAGES = tuple(sorted(set(PACKAGE_BY_LIBRARY.values())))
NEVER_INSTALL = frozenset({"libc6"})
MAX_CAPTURE = 65536
MAX_SOURCE = 16384
MAX_APT_CONFIG_FILES = 64
MAX_APT_CONFIG_BYTES = 1024 * 1024
VERSION = re.compile(r"^[0-9][A-Za-z0-9.+:~_-]{0,127}$")
SOURCE_URIS = frozenset({"http://archive.ubuntu.com/ubuntu", "http://security.ubuntu.com/ubuntu"})
SOURCE_SUITES = frozenset({"noble", "noble-updates", "noble-security", "noble-backports"})
SOURCE_COMPONENTS = frozenset({"main", "restricted", "universe", "multiverse"})
APT_OPTIONS = (
    "-o", "Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources",
    "-o", "Dir::Etc::sourceparts=-",
    "-o", "Dir::Etc::preferences=/dev/null",
    "-o", "Dir::Etc::preferencesparts=-",
    "-o", "APT::Get::AllowUnauthenticated=false",
    "-o", "Acquire::AllowInsecureRepositories=false",
    "-o", "Acquire::AllowDowngradeToInsecureRepositories=false",
    "-o", "DPkg::Lock::Timeout=60",
    "-o", "Acquire::Retries=0",
    "-o", "Acquire::http::Timeout=20",
    "-o", "Acquire::https::Timeout=20",
)
SAFE_ENV = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C", "LANG": "C"}
INSTALL_ENABLED = True  # Lab-only, interactive; normal root-owned APT hooks are disclosed.


class PackageError(ValueError):
    pass


def _bounded_command(argv, timeout=30):
    """Capture a small diagnostic; only read-only dpkg/APT commands use this."""
    child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, env=SAFE_ENV, start_new_session=True,
                             close_fds=True)
    result = bytearray()
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as watcher:
            os.set_blocking(child.stdout.fileno(), False)
            watcher.register(child.stdout, selectors.EVENT_READ)
            while watcher.get_map():
                left = deadline - time.monotonic()
                if left <= 0:
                    raise PackageError("package diagnostic deadline exceeded")
                for key, _ in watcher.select(min(left, 0.2)):
                    chunk = os.read(key.fileobj.fileno(), 8192)
                    if not chunk:
                        watcher.unregister(key.fileobj)
                    else:
                        if len(result) + len(chunk) > MAX_CAPTURE:
                            raise PackageError("package diagnostic output limit exceeded")
                        result.extend(chunk)
        left = deadline - time.monotonic()
        if left <= 0:
            raise PackageError("package diagnostic deadline exceeded")
        child.wait(timeout=left)
        return child.returncode, result.decode("utf-8", errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        raise PackageError("package diagnostic failed or exceeded its deadline")
    finally:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
        child.stdout.close()


def _trusted_root_file(path, limit):
    path = Path(path)
    if not path.is_absolute():
        raise PackageError("system package path is not absolute")
    for component in (path, *path.parents):
        info = component.lstat()
        if info.st_uid != 0 or info.st_mode & 0o022 or stat.S_ISLNK(info.st_mode):
            raise PackageError("system package source/key path is not root-owned and immutable to users")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022
                or info.st_nlink != 1 or info.st_size > limit):
            raise PackageError("system package source/key file metadata is unsafe")
        raw = os.read(fd, limit + 1)
        if len(raw) > limit:
            raise PackageError("system package source/key file is too large")
        return raw
    finally:
        os.close(fd)


def _source_stanzas(raw):
    try:
        source = raw.decode("ascii")
    except UnicodeError as exc:
        raise PackageError("Ubuntu source definition is not ASCII") from exc
    # Ubuntu's stock file contains comment-only paragraphs before both stanzas.
    meaningful = "\n".join(line for line in source.splitlines() if not line.startswith("#"))
    stanzas = []
    for block in re.split(r"\n\s*\n", meaningful.strip()):
        if not block.strip():
            continue
        fields = {}
        for line in block.splitlines():
            match = re.fullmatch(r"([A-Za-z-]+):\s+([^\r\n]{1,512})", line)
            if not match or match.group(1) in fields:
                raise PackageError("Ubuntu source definition has an unsupported field")
            fields[match.group(1)] = match.group(2).strip()
        if not fields or set(fields) - {"Types", "URIs", "Suites", "Components", "Signed-By", "Enabled"}:
            raise PackageError("Ubuntu source definition contains unreviewed APT options")
        if (fields.get("Types") != "deb" or fields.get("Signed-By") != str(KEYRING)
                or fields.get("Enabled", "yes") != "yes"):
            raise PackageError("Ubuntu source definition is not a signed binary-package source")
        uris = set(fields.get("URIs", "").rstrip("/").split())
        suites = set(fields.get("Suites", "").split())
        components = set(fields.get("Components", "").split())
        if (len(uris) != 1 or not uris <= SOURCE_URIS or not suites
                or not suites <= SOURCE_SUITES or not components or not components <= SOURCE_COMPONENTS
                or "main" not in components):
            raise PackageError("Ubuntu source URI, suite or component is outside the lab allowlist")
        uri = next(iter(uris))
        if (uri == "http://security.ubuntu.com/ubuntu") != (suites == {"noble-security"}):
            raise PackageError("Ubuntu security source/suite pairing differs")
        stanzas.append((uri, suites))
    if (not 1 <= len(stanzas) <= 2
            or not {"noble", "noble-updates", "noble-security"} <= set.union(*(s for _, s in stanzas))):
        raise PackageError("Ubuntu source definition lacks the required Noble suites")
    return stanzas


def official_sources():
    raw = _trusted_root_file(SOURCES, MAX_SOURCE)
    keyring = _trusted_root_file(KEYRING, 1024 * 1024)
    _source_stanzas(raw)
    return hashlib.sha256(raw + b"\0" + keyring).hexdigest()


def _trusted_root_dir(path):
    path = Path(path)
    for component in (path, *path.parents):
        info = component.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise PackageError("APT configuration directory is not a trusted root-owned directory")


def apt_configuration():
    """Advisory root-owned file fingerprint and bounded effective hook identifiers.

    apt-config and apt-get can apply binary-specific settings differently. This
    inventory is a disclosure and change detector, not execution isolation.
    """
    _trusted_root_dir(APT_CONF_D)
    files = []
    if APT_CONF.exists() or APT_CONF.is_symlink():
        files.append(APT_CONF)
    entries = sorted(APT_CONF_D.iterdir())
    if len(entries) > MAX_APT_CONFIG_FILES:
        raise PackageError("too many APT configuration entries to review")
    files.extend(entries)
    digest = hashlib.sha256()
    total = 0
    for path in files:
        raw = _trusted_root_file(path, MAX_APT_CONFIG_BYTES)
        if re.search(rb"(?im)^\s*#\s*(?:include|clear)\b", raw):
            raise PackageError("APT configuration uses an unreviewed include or clear directive")
        # The official Ubuntu container suppresses persistent APT cache files.
        # This exact inert cache setting is the only reviewed Dir override.
        reviewed = raw.replace(b'Dir::Cache::pkgcache ""; Dir::Cache::srcpkgcache "";', b'')
        if re.search(rb"(?i)\b(?:Dir::|Binary::)", reviewed):
            raise PackageError("APT configuration redirects a reviewed command or source path")
        total += len(raw)
        if total > MAX_APT_CONFIG_BYTES:
            raise PackageError("APT configuration exceeds review size limit")
        digest.update(str(path).encode("utf-8") + b"\0" + raw + b"\0")
    code, output = _bounded_command(["/usr/bin/apt-config", *APT_OPTIONS, "dump"])
    if code:
        raise PackageError("effective APT configuration inventory failed")
    hooks = set()
    effective = {}
    for line in output.splitlines():
        match = re.fullmatch(r'([A-Za-z0-9:_.-]+) "(?:[^"\\]|\\.)*";', line)
        if not match:
            raise PackageError("effective APT configuration inventory is ambiguous")
        name = match.group(1)
        effective[name] = line.partition(' "')[2].rsplit('";', 1)[0]
        if ("invoke" in name.lower() or name.startswith("DPkg::Pre-Install-Pkgs")) and name.endswith("::"):
            hooks.add(name[:-2])
    for key, wanted in (("Dir::Etc::sourcelist", {str(SOURCES)}),
                        ("Dir::Etc::sourceparts", {"-"}),
                        ("Dir::Etc::preferences", {"/dev/null"}),
                        ("Dir::Etc::preferencesparts", {"-"}),
                        ("APT::Get::AllowUnauthenticated", {"0", "false"}),
                        ("Acquire::AllowInsecureRepositories", {"0", "false"})):
        if effective.get(key) not in wanted:
            raise PackageError("APT configuration changes a required transaction guard")
    return {"rootConfigSha256": digest.hexdigest(), "effectiveHookIdentifiers": sorted(hooks)}


def _apt(command, *args):
    return ["/usr/bin/apt-get", *APT_OPTIONS, *command, *args]


def _apt_cache(*args):
    return ["/usr/bin/apt-cache", *APT_OPTIONS, *args]


def _host_and_stage(stage):
    if platform.system() != "Linux" or os.geteuid() == 0 or platform.machine().lower() not in ("x86_64", "amd64"):
        raise PackageError("requires a standard-user Ubuntu 24.04 x86-64 host")
    os_release = prereqs._read_os_release(prereqs.OS_RELEASE, False)
    if os_release["id"] != "ubuntu" or os_release["versionId"] != "24.04":
        raise PackageError("only Ubuntu 24.04 is supported by this lab package helper")
    code, architecture = _bounded_command(["/usr/bin/dpkg", "--print-architecture"])
    if code != 0 or architecture.strip() != "amd64":
        raise PackageError("dpkg architecture is not amd64")
    raw = runtime.MANIFEST.read_bytes()
    if len(raw) > probe.MAX_MANIFEST_BYTES or hashlib.sha256(raw).hexdigest() != probe.PINNED_MANIFEST_SHA256:
        raise PackageError("Linux engine candidate manifest differs from reviewed bytes")
    asset = runtime.load_asset()
    if (asset["status"] != "archive-verified-execution-disabled" or asset["executionEnabled"] is not False
            or asset["sha256"] != probe.PINNED_ARCHIVE_SHA256
            or set(asset["externalNeeded"]) != EXPECTED_LIBRARIES):
        raise PackageError("unexpected Linux engine or external-library policy")
    runtime.verify_tree(Path(stage).expanduser().absolute(), asset)
    return asset


def installed_packages():
    result = {}
    for package in PACKAGES:
        code, output = _bounded_command(["/usr/bin/dpkg-query", "-W", "-f=${Status}\t${Version}\n", package])
        if code != 0:
            result[package] = None
            continue
        match = re.fullmatch(r"install ok installed\t([^\n]+)\n", output)
        if not match or not VERSION.fullmatch(match.group(1)):
            raise PackageError("installed package state is ambiguous: " + package)
        result[package] = match.group(1)
    return result


def check(stage):
    asset = _host_and_stage(stage)
    source_sha = official_sources()
    apt_config = apt_configuration()
    installed = installed_packages()
    if installed["libc6"] is None:
        raise PackageError("libc6 is missing; automatic system repair is refused")
    missing = sorted(name for name, version in installed.items() if version is None)
    return {"schemaVersion": 1, "labOnly": True, "executionEnabled": False,
            "systemPackageInstallEnabled": INSTALL_ENABLED,
            "candidateSha256": asset["sha256"], "manifestSha256": probe.PINNED_MANIFEST_SHA256,
            "officialSourceSha256": source_sha, "installed": installed, "missing": missing,
            **apt_config,
            "driverInstalled": False, "compatibilityVerified": False}


def _candidate_version(package):
    code, output = _bounded_command(_apt_cache("policy", package))
    if code != 0:
        raise PackageError("official APT candidate lookup failed: " + package)
    match = re.search(r"^\s*Candidate: ([^\s]+)$", output, re.MULTILINE)
    if not match or not VERSION.fullmatch(match.group(1)):
        raise PackageError("official APT candidate is unavailable: " + package)
    version = match.group(1)
    lines = output.splitlines()
    selected = False
    origins = []
    for line in lines:
        if re.fullmatch(r"\s*\*{0,3}\s*" + re.escape(version) + r"\s+\d+", line):
            selected = True
            continue
        if selected and re.fullmatch(r"\s*\*{0,3}\s*[0-9][A-Za-z0-9.+:~_-]*\s+\d+", line):
            break
        if selected:
            match = re.fullmatch(r"\s*\d+ (http://\S+) (noble(?:-updates|-security|-backports)?)/([^\s]+) amd64 Packages", line)
            if match:
                origins.append((match.group(1), match.group(2), match.group(3)))
            elif re.match(r"\s*\d+\s+\S+", line):
                raise PackageError("APT candidate has an unreviewed origin: " + package)
    if not origins or any(uri not in SOURCE_URIS or suite not in ("noble", "noble-updates", "noble-security")
                          or component != "main" for uri, suite, component in origins):
        raise PackageError("APT candidate is not solely from official Noble main: " + package)
    return version


def _parse_simulation(output, versions):
    planned = set(versions)
    installed = set()
    configured = set()
    for line in output.splitlines():
        if line.startswith(("Remv ", "Purg ")):
            raise PackageError("APT simulation proposes package removal")
        if line.startswith("Inst "):
            match = re.fullmatch(r"Inst ([a-z0-9+.-]+)(?::amd64)? \(([^ )]+)(?: [^)]*)?\)", line)
            if not match or match.group(1) not in planned or match.group(2) != versions[match.group(1)] or match.group(1) in installed:
                raise PackageError("APT simulation proposes an unreviewed installation or upgrade")
            installed.add(match.group(1))
        if line.startswith("Conf "):
            match = re.fullmatch(r"Conf ([a-z0-9+.-]+)(?::amd64)? \(([^ )]+)(?: [^)]*)?\)", line)
            if not match or match.group(1) not in planned or match.group(2) != versions[match.group(1)] or match.group(1) in configured:
                raise PackageError("APT simulation proposes unreviewed package configuration")
            configured.add(match.group(1))
    if installed != planned or configured != planned:
        raise PackageError("APT simulation did not install/configure exactly the missing packages")


def _sudo_apt(command, *args):
    # This source file is never elevated: sudo executes only trusted system
    # env + apt-get with fixed arguments and a deliberately blank environment.
    argv = ["/usr/bin/sudo", "--", "/usr/bin/env", "-i",
            "PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C", "LANG=C",
            "DEBIAN_FRONTEND=noninteractive", *_apt(command, *args)]
    completed = subprocess.run(argv, env=SAFE_ENV, cwd="/", check=False)
    if completed.returncode:
        raise PackageError("official Ubuntu APT operation failed; inspect its output")


def install(stage, *, confirm=input):
    before = check(stage)
    missing = before["missing"]
    if not missing:
        return dict(before, changed=False, note="declared system packages are already installed; driver/ICD unverified")
    if any(package in NEVER_INSTALL for package in missing):
        raise PackageError("core C runtime repair is not automatic")
    print("LAB ONLY: normal Ubuntu APT trust applies. Root-owned OS-configured hooks and signed-package maintainer scripts run as root.")
    print("APT hook identifiers (commands withheld; inventory is advisory): " +
          (", ".join(before["effectiveHookIdentifiers"]) or "none reported"))
    print("Root-owned APT configuration SHA-256: " + before["rootConfigSha256"])
    print("Refresh official Ubuntu Noble package indexes; no driver or package upgrade is requested.")
    print("Missing declared packages: " + ", ".join(missing))
    if confirm("Type UPDATE OFFICIAL UBUNTU INDEXES to continue: ") != "UPDATE OFFICIAL UBUNTU INDEXES":
        raise PackageError("operator did not approve official package-index refresh")
    if check(stage) != before:
        raise PackageError("host, source, APT configuration or package state changed before index refresh")
    _sudo_apt(("update", "--error-on=any"))
    versions = {package: _candidate_version(package) for package in missing}
    pinned = [package + "=" + versions[package] for package in missing]
    install_args = ("--no-remove", "--no-install-recommends", "--no-upgrade", "install", *pinned)
    code, output = _bounded_command(_apt(("-s", *install_args)), timeout=60)
    if code:
        raise PackageError("official APT simulation failed")
    _parse_simulation(output, versions)
    before_actual = check(stage)
    if before_actual != before:
        raise PackageError("host, manifest, source or package state changed before installation")
    plan_bytes = json.dumps({"manifest": before["manifestSha256"], "source": before["officialSourceSha256"],
                             "packages": versions}, sort_keys=True, separators=(",", ":")).encode("ascii")
    plan_sha = hashlib.sha256(plan_bytes).hexdigest()
    print("Exact missing official packages and versions: " + ", ".join(pinned))
    print("APT plan SHA-256: " + plan_sha)
    print("APT will also execute the disclosed OS-configured hooks and signed-package maintainer scripts as root. This does not install an AMD driver.")
    if confirm("Type INSTALL " + plan_sha[:12] + " to approve this exact plan: ") != "INSTALL " + plan_sha[:12]:
        raise PackageError("operator did not approve the exact APT plan")
    if check(stage) != before:
        raise PackageError("host, manifest, source or package state changed after approval")
    _sudo_apt(install_args)
    after = check(stage)
    if after["missing"]:
        raise PackageError("APT completed but declared prerequisites remain missing")
    if any(after["installed"][name] != before["installed"][name] for name in PACKAGES if name not in missing):
        raise PackageError("an existing system prerequisite changed during APT operation")
    if any(after["installed"][name] != versions[name] for name in missing):
        raise PackageError("installed package versions differ from approved APT plan")
    return dict(after, changed=True, approvedPlanSha256=plan_sha,
                note="system packages installed; AMD driver/ICD, model serving and compatibility remain unverified")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "install"))
    parser.add_argument("--stage", type=Path, required=True, help="existing exact verified b10698 Vulkan stage")
    parser.add_argument("--accept-system-packages", action="store_true", help="explicit lab-only opt-in to sudo apt-get")
    args = parser.parse_args(argv)
    if args.command == "install" and not args.accept_system_packages:
        parser.error("install requires --accept-system-packages")
    if args.command == "check" and args.accept_system_packages:
        parser.error("check cannot accept or install system packages")
    try:
        result = check(args.stage) if args.command == "check" else install(args.stage)
    except (OSError, PackageError, ValueError) as exc:
        parser.error(str(exc))
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
