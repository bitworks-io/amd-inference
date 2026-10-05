#!/usr/bin/env python3
"""Acquire exact catalog GGUFs for a standard-user Linux lab cache.

This module never starts an inference engine. The public CLI has no fixture URL
or catalog override; the injectable transport exists only for offline tests.
"""

import argparse
from contextlib import contextmanager
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import sys
import time
import urllib.request
from urllib.parse import urlsplit
import uuid

CATALOG = Path(__file__).resolve().parents[1] / "config" / "catalog.json"
CHUNK = 64 * 1024
DEADLINE_SECONDS = 3600
MODEL_ID = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}\Z")


def _sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _real_ancestors(path):
    path = path.expanduser().absolute()
    for item in (path, *path.parents):
        try:
            mode = item.lstat().st_mode
        except FileNotFoundError:
            if item == path:
                continue
            raise ValueError(f"missing cache ancestor: {item}")
        if not stat.S_ISDIR(mode):
            raise ValueError(f"cache path contains symlink or non-directory: {item}")


def _private_root(root):
    root = root.expanduser().absolute()
    _real_ancestors(root.parent)
    if not root.exists() and not root.is_symlink():
        root.mkdir(mode=0o700)
    metadata = root.lstat()
    if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid()
            or stat.S_IMODE(metadata.st_mode) != 0o700):
        raise ValueError("cache root must be a real, user-owned 0700 directory")
    return root


def _regular_private(path, *, optional=False):
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        if optional:
            return None
        raise
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600):
        raise ValueError(f"unsafe cache file: {path.name}")
    return metadata


def _create_private(path):
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    return os.fdopen(fd, "wb")


def _quarantine_private(path, reason):
    _regular_private(path)
    os.replace(path, path.with_name(f"{path.name}.{reason}-{uuid.uuid4().hex}"))


def _append_private(path):
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK)
    metadata = os.fstat(fd)
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
            or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600):
        os.close(fd)
        raise ValueError("unsafe partial model file")
    return os.fdopen(fd, "ab")


@contextmanager
def _lock(root, deadline):
    path = root / ".acquire.lock"
    try:
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    except OSError as exc:
        raise ValueError("cannot safely open acquisition lock") from exc
    try:
        metadata = os.fstat(fd)
        if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid()
                or metadata.st_nlink != 1 or stat.S_IMODE(metadata.st_mode) != 0o600):
            raise ValueError("unsafe acquisition lock")
        while True:
            if time.monotonic() >= deadline:
                raise TimeoutError("model acquisition lock deadline exceeded")
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                    raise
                time.sleep(min(0.05, max(0, deadline - time.monotonic())))
        yield
    finally:
        os.close(fd)


def _require_https(url):
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError("model and license URLs must be HTTPS without credentials")


class _HttpsRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        _require_https(newurl)
        return super().redirect_request(request, fp, code, msg, headers, newurl)


class UrlTransport:
    def __init__(self):
        self.opener = urllib.request.build_opener(_HttpsRedirect())

    def open(self, url, offset):
        _require_https(url)
        headers = {"User-Agent": "FastLLM-Linux-lab/1"}
        if offset:
            headers["Range"] = f"bytes={offset}-"
        return self.opener.open(urllib.request.Request(url, headers=headers), timeout=5)


def load_catalog():
    line = (CATALOG.parent / "catalog.sha256").read_text(encoding="ascii").strip().split()
    if len(line) != 2 or line[1] != "catalog.json" or not re.fullmatch(r"[0-9a-fA-F]{64}", line[0]):
        raise ValueError("invalid catalog digest manifest")
    raw = CATALOG.read_bytes()
    if hashlib.sha256(raw).hexdigest() != line[0].lower():
        raise ValueError("catalog digest differs")
    return json.loads(raw)


def _model(catalog, model_id):
    if not MODEL_ID.fullmatch(model_id):
        raise ValueError("unsafe model ID")
    matches = [item for item in catalog["models"] if item["id"] == model_id]
    if len(matches) != 1:
        raise ValueError("model ID is not unique in approved catalog")
    item = matches[0]
    for key in ("url", "upstreamLicenseUrl", "artifactLicenseMetadataUrl"):
        _require_https(item[key])
    for key in ("sha256", "upstreamLicenseSha256"):
        if not re.fullmatch(r"[0-9a-f]{64}", item[key]):
            raise ValueError("invalid catalog artifact/license digest")
    if type(item["sizeBytes"]) is not int or item["sizeBytes"] <= 0:
        raise ValueError("invalid catalog model size")
    if not re.fullmatch(r"[0-9a-f]{40}", item["upstreamRevision"]):
        raise ValueError("invalid upstream license revision")
    if not re.fullmatch(r"[0-9a-f]{40}", item["revision"]):
        raise ValueError("invalid conversion revision")
    for key in ("repository", "artifactLicense", "upstreamModel", "upstreamLicense"):
        if not isinstance(item[key], str) or not item[key].strip():
            raise ValueError(f"invalid model provenance: {key}")
    return item


def _receipt(item):
    return {"schemaVersion": 2, "modelId": item["id"], "artifactSha256": item["sha256"],
            "artifactSizeBytes": item["sizeBytes"], "upstreamModel": item["upstreamModel"],
            "upstreamRevision": item["upstreamRevision"], "upstreamLicense": item["upstreamLicense"],
            "upstreamLicenseUrl": item["upstreamLicenseUrl"],
            "upstreamLicenseSha256": item["upstreamLicenseSha256"],
            "artifactUrl": item["url"], "conversionRepository": item["repository"],
            "conversionRevision": item["revision"], "artifactLicense": item["artifactLicense"],
            "artifactLicenseMetadataUrl": item["artifactLicenseMetadataUrl"]}


def _provenance_sha256(item):
    return hashlib.sha256(json.dumps(_receipt(item), sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _read_license(item, transport, deadline):
    digest = hashlib.sha256()
    total = 0
    blocks = []
    with transport.open(item["upstreamLicenseUrl"], 0) as response:
        if response.status != 200:
            raise ValueError("license fetch did not return 200")
        while True:
            if time.monotonic() >= deadline:
                raise TimeoutError("license acquisition deadline exceeded")
            block = response.read(CHUNK)
            if time.monotonic() >= deadline:
                raise TimeoutError("license acquisition deadline exceeded")
            if not block:
                break
            total += len(block)
            if total > 256 * 1024:
                raise ValueError("upstream license exceeded size ceiling")
            digest.update(block)
            blocks.append(block)
    if digest.hexdigest() != item["upstreamLicenseSha256"]:
        raise ValueError("upstream license digest differs")
    return b"".join(blocks)


def preview_license(catalog, model_id, *, transport=None, deadline_seconds=60):
    """Fetch, hash-check, and display the exact upstream license before opt-in."""
    item = _model(catalog, model_id)
    license_bytes = _read_license(item, transport or UrlTransport(), time.monotonic() + deadline_seconds)
    return {**_receipt(item), "consentProvenanceSha256": _provenance_sha256(item),
            "licenseText": license_bytes.decode("utf-8")}


def _download(item, part, transport, deadline):
    expected = item["sizeBytes"]
    metadata = _regular_private(part, optional=True)
    offset = metadata.st_size if metadata else 0
    if offset > expected:
        raise ValueError("partial model exceeds catalog size")
    if offset == expected:
        if _sha256(part) == item["sha256"]:
            return
        _quarantine_private(part, "corrupt")
        metadata = None
        offset = 0
    # If a server does not honor Range, restart with a fresh zero-offset request.
    for attempt in range(2):
        with transport.open(item["url"], offset) as response:
            status = response.status
            if offset and status == 200 and attempt == 0:
                _quarantine_private(part, "ignored-range")
                metadata = None
                offset = 0
                continue
            if status != (206 if offset else 200):
                raise ValueError("model server returned unexpected HTTP status")
            if offset:
                content_range = response.headers.get("Content-Range", "")
                if content_range != f"bytes {offset}-{expected - 1}/{expected}":
                    raise ValueError("model server returned unexpected Content-Range")
            content_length = response.headers.get("Content-Length")
            if content_length is not None and int(content_length) != expected - offset:
                raise ValueError("model server returned unexpected Content-Length")
            if metadata is not None:
                _regular_private(part)
                output = _append_private(part)
            else:
                output = _create_private(part)
            with output:
                total = offset
                while True:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("model acquisition deadline exceeded")
                    block = response.read(CHUNK)
                    if time.monotonic() >= deadline:
                        raise TimeoutError("model acquisition deadline exceeded")
                    if not block:
                        break
                    total += len(block)
                    if total > expected:
                        raise ValueError("model exceeded pinned catalog size")
                    output.write(block)
                output.flush()
                os.fsync(output.fileno())
            if total != expected or _sha256(part) != item["sha256"]:
                raise ValueError("model size or SHA-256 differs; partial retained for inspection")
            return
    raise ValueError("model server ignored resume request")


def acquire_model(catalog, model_id, cache_root, *, accept_license_for=None,
                  reviewed_license_sha256=None, reviewed_upstream_revision=None,
                  reviewed_artifact_sha256=None, reviewed_provenance_sha256=None,
                  transport=None, deadline_seconds=DEADLINE_SECONDS):
    if os.geteuid() == 0:
        raise ValueError("model acquisition requires a standard user")
    if platform.system() != "Linux":
        raise ValueError("model acquisition requires Linux")
    item = _model(catalog, model_id)
    if accept_license_for is not None and accept_license_for != model_id:
        raise ValueError("license acceptance must name the exact model ID")
    reviewed = (reviewed_license_sha256 == item["upstreamLicenseSha256"]
                and reviewed_upstream_revision == item["upstreamRevision"]
                and reviewed_artifact_sha256 == item["sha256"]
                and reviewed_provenance_sha256 == _provenance_sha256(item))
    if accept_license_for is not None and not reviewed:
        raise ValueError("acceptance requires reviewed exact license, upstream, artifact, and conversion provenance")
    root = _private_root(Path(cache_root))
    transport = transport or UrlTransport()
    deadline = time.monotonic() + deadline_seconds
    final = root / f"{item['id']}-{item['sha256']}.gguf"
    part = root / f"{item['id']}-{item['sha256']}.gguf.part"
    receipt_path = root / f"{item['id']}-{item['sha256']}.consent.json"
    expected_receipt = _receipt(item)
    with _lock(root, deadline):
        current = _regular_private(receipt_path, optional=True)
        if current:
            if current.st_size > 8192:
                raise ValueError("consent receipt exceeds size ceiling")
            if json.loads(receipt_path.read_text(encoding="utf-8")) != expected_receipt:
                if accept_license_for != model_id or not reviewed:
                    raise ValueError("consent receipt differs; renewed exact-provenance acceptance required")
                _read_license(item, transport, deadline)
                os.replace(receipt_path, root / f"{receipt_path.name}.superseded-{uuid.uuid4().hex}")
                current = None
        else:
            if accept_license_for != model_id:
                raise ValueError(f"exact license consent required for {model_id}: {item['upstreamLicenseUrl']}")
            _read_license(item, transport, deadline)
        if not current:
            with _create_private(receipt_path) as output:
                output.write((json.dumps(expected_receipt, sort_keys=True) + "\n").encode())
                output.flush()
                os.fsync(output.fileno())
        existing = _regular_private(final, optional=True)
        if existing and existing.st_size == item["sizeBytes"] and _sha256(final) == item["sha256"]:
            return {"modelId": model_id, "path": str(final), "sha256": item["sha256"], "reused": True}
        if existing:
            _quarantine_private(final, "corrupt")
        _download(item, part, transport, deadline)
        _regular_private(part)
        os.replace(part, final)
        dir_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
        return {"modelId": model_id, "path": str(final), "sha256": item["sha256"], "reused": False}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model_id", help="exact ID from the verified catalog")
    parser.add_argument("--cache-root", type=Path, default=Path.home() / ".fastllm-models")
    parser.add_argument("--preview-license", action="store_true", help="verify and display exact license text and artifact provenance; makes no cache changes")
    parser.add_argument("--accept-license-for", help="explicitly consent to this exact model ID and upstream license revision")
    parser.add_argument("--reviewed-license-sha256", help="exact digest shown by --preview-license")
    parser.add_argument("--reviewed-upstream-revision", help="exact revision shown by --preview-license")
    parser.add_argument("--reviewed-artifact-sha256", help="exact artifact digest shown by --preview-license")
    parser.add_argument("--reviewed-provenance-sha256", help="exact conversion/consent provenance digest shown by --preview-license")
    args = parser.parse_args(argv)
    try:
        catalog = load_catalog()
        if args.preview_license:
            if args.accept_license_for or args.reviewed_license_sha256 or args.reviewed_upstream_revision or args.reviewed_artifact_sha256 or args.reviewed_provenance_sha256:
                parser.error("preview and acceptance options cannot be combined")
            result = preview_license(catalog, args.model_id)
        else:
            result = acquire_model(catalog, args.model_id, args.cache_root,
                                   accept_license_for=args.accept_license_for,
                                   reviewed_license_sha256=args.reviewed_license_sha256,
                                   reviewed_upstream_revision=args.reviewed_upstream_revision,
                                   reviewed_artifact_sha256=args.reviewed_artifact_sha256,
                                   reviewed_provenance_sha256=args.reviewed_provenance_sha256)
    except (OSError, ValueError, TimeoutError, KeyError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
