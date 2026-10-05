#!/usr/bin/env python3
"""Read-only inventory of the disabled, exact Lemonade b1339 Windows HIP ZIP.

This is static evidence only: imports do not enumerate LoadLibrary, kernel-data
opens, actual Windows loader resolution, compatibility, or redistribution rights.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import zipfile


ROOT = Path(__file__).resolve().parents[1]
POLICY = ROOT / "config/experiments/lemonade-hip-b1339-gfx110x.json"
MAX_ENTRIES = 1200
MAX_TOTAL_BYTES = 700_000_000
MAX_FILE_BYTES = 300_000_000
MAX_PE_BYTES = 260_000_000
MAX_ARCHIVE_BYTES = 200_000_000
MAX_IMPORT_DESCRIPTORS = 4096
NAME_RE = re.compile(r"^[A-Za-z0-9_./+\-]+$")
NOTICE_RE = re.compile(r"^(?:licen[sc]e|notice|copying|readme)(?:[._-].*)?$", re.I)
VC_RE = re.compile(r"^(?:msvcp\d+|vcruntime\d+(?:_\d+)?|concrt\d+|ucrtbase|api-ms-win-crt-[a-z0-9_-]+)\.dll$", re.I)
OS_DLLS = frozenset({
    "advapi32.dll", "bcrypt.dll", "combase.dll", "comctl32.dll", "comdlg32.dll",
    "crypt32.dll", "d3d11.dll", "d3d12.dll", "dbghelp.dll", "dxgi.dll",
    "gdi32.dll", "imm32.dll", "iphlpapi.dll", "kernel32.dll", "kernelbase.dll",
    "mpr.dll", "msimg32.dll", "mswsock.dll", "ntdll.dll", "ole32.dll",
    "oleaut32.dll", "psapi.dll", "rpcrt4.dll", "secur32.dll", "setupapi.dll",
    "shell32.dll", "shlwapi.dll", "user32.dll", "userenv.dll", "version.dll",
    "winhttp.dll", "winmm.dll", "ws2_32.dll", "wtsapi32.dll",
})
DRIVER_DLLS = frozenset({"atidxx64.dll"})  # A possible external driver module, not a proven load.


def _u16(data: bytes, at: int) -> int:
    if at < 0 or at + 2 > len(data):
        raise ValueError("PE field outside file")
    return struct.unpack_from("<H", data, at)[0]


def _u32(data: bytes, at: int) -> int:
    if at < 0 or at + 4 > len(data):
        raise ValueError("PE field outside file")
    return struct.unpack_from("<I", data, at)[0]


def _u64(data: bytes, at: int) -> int:
    if at < 0 or at + 8 > len(data):
        raise ValueError("PE field outside file")
    return struct.unpack_from("<Q", data, at)[0]


def _dll_name(data: bytes, at: int) -> str:
    if at < 0 or at >= len(data):
        raise ValueError("DLL name outside PE")
    end = data.find(b"\0", at, min(at + 261, len(data)))
    if end < 0:
        raise ValueError("Unterminated or oversized DLL name")
    try:
        name = data[at:end].decode("ascii")
    except UnicodeDecodeError as exc:
        raise ValueError("Non-ASCII DLL import name") from exc
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,260}\.dll", name, re.I):
        raise ValueError("Invalid DLL import name")
    return name.lower()


def pe_imports(data: bytes) -> dict[str, list[str]]:
    """Parse PE32/PE32+ direct and delay import DLL names with strict RVA bounds."""
    if len(data) < 0x100 or data[:2] != b"MZ":
        raise ValueError("Not a PE image")
    pe = _u32(data, 0x3C)
    if pe < 0x40 or pe > len(data) - 24 or data[pe:pe + 4] != b"PE\0\0":
        raise ValueError("Missing or misplaced PE header")
    sections = _u16(data, pe + 6)
    opt_size = _u16(data, pe + 20)
    opt = pe + 24
    end_opt = opt + opt_size
    if sections < 1 or sections > 96 or end_opt > len(data):
        raise ValueError("Invalid PE section/optional-header bounds")
    magic = _u16(data, opt)
    if magic == 0x20B:  # PE32+
        directory_start, image_base, dir_count_at = opt + 112, _u64(data, opt + 24), opt + 108
    elif magic == 0x10B:  # PE32
        directory_start, image_base, dir_count_at = opt + 96, _u32(data, opt + 28), opt + 92
    else:
        raise ValueError("Unknown PE optional-header kind")
    directory_count = _u32(data, dir_count_at)
    if directory_count > 16 or directory_start + min(directory_count, 16) * 8 > end_opt:
        raise ValueError("Invalid PE data-directory count")
    size_of_headers = _u32(data, opt + 60)
    table = end_opt
    if table + sections * 40 > len(data):
        raise ValueError("PE section table outside file")
    mappings = []
    for index in range(sections):
        at = table + index * 40
        virtual_size, virtual_addr = _u32(data, at + 8), _u32(data, at + 12)
        raw_size, raw_addr = _u32(data, at + 16), _u32(data, at + 20)
        if raw_addr + raw_size > len(data):
            raise ValueError("PE raw section outside file")
        mappings.append((virtual_addr, max(virtual_size, raw_size), raw_addr, raw_size))

    def rva_offset(rva: int, needed: int = 1) -> int:
        matches = []
        if rva < size_of_headers and rva + needed <= min(size_of_headers, len(data)):
            matches.append(rva)
        for va, virtual_span, raw, raw_size in mappings:
            if va <= rva and rva + needed <= va + virtual_span:
                delta = rva - va
                if delta + needed <= raw_size and raw + delta + needed <= len(data):
                    matches.append(raw + delta)
        if len(matches) != 1:
            raise ValueError("PE RVA is unmapped or ambiguously mapped")
        return matches[0]

    def directory(index: int) -> tuple[int, int]:
        if index >= directory_count:
            return (0, 0)
        at = directory_start + index * 8
        rva, size = _u32(data, at), _u32(data, at + 4)
        if bool(rva) != bool(size) or size > 1_000_000:
            raise ValueError("Malformed PE import directory")
        return (rva, size)

    imports: dict[str, list[str]] = {"direct": [], "delay": []}
    for kind, index, stride in (("direct", 1, 20), ("delay", 13, 32)):
        rva, size = directory(index)
        if not rva:
            continue
        if size < stride or size // stride > MAX_IMPORT_DESCRIPTORS:
            raise ValueError("Excessive or truncated import directory")
        terminated = False
        for item in range(size // stride):
            descriptor = rva_offset(rva + item * stride, stride)
            raw = data[descriptor:descriptor + stride]
            if raw == b"\0" * stride:
                terminated = True
                break
            if kind == "direct":
                name_rva = _u32(data, descriptor + 12)
            else:
                attrs = _u32(data, descriptor)
                name_field = _u32(data, descriptor + 4)
                if attrs not in (0, 1):
                    raise ValueError("Unknown delay-import address mode")
                name_rva = name_field if attrs == 1 else name_field - image_base
            if name_rva <= 0 or name_rva > 0xFFFFFFFF:
                raise ValueError("Invalid imported DLL name RVA")
            name = _dll_name(data, rva_offset(name_rva))
            # A first-byte RVA is insufficient: the NUL-terminated name must
            # stay in one unique mapped raw region, not spill into other bytes.
            rva_offset(name_rva, len(name) + 1)
            imports[kind].append(name)
        if not terminated:
            raise ValueError("Import descriptor table has no terminator")
        imports[kind] = sorted(set(imports[kind]))
    return imports


def _valid_entry(info: zipfile.ZipInfo) -> tuple[str, bool]:
    name = info.filename
    is_dir = name.endswith("/")
    path = name[:-1] if is_dir else name
    if (not path or len(path) > 240 or not NAME_RE.fullmatch(path) or "\\" in path or ":" in path or
            path.startswith("/") or any(part in ("", ".", "..") or part.endswith((".", " "))
                                      for part in path.split("/"))):
        raise ValueError("Unsafe ZIP entry path")
    mode = (info.external_attr >> 16) & 0xFFFF
    kind = stat.S_IFMT(mode)
    if kind not in (0, stat.S_IFDIR if is_dir else stat.S_IFREG):
        raise ValueError("ZIP contains a link or non-regular entry")
    if info.flag_bits & 1 or info.file_size > MAX_FILE_BYTES or info.file_size < 0:
        raise ValueError("Encrypted or oversized ZIP entry")
    return path, is_dir


def _hash_stream(stream) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    stream.seek(0)
    for block in iter(lambda: stream.read(1 << 20), b""):
        size += len(block)
        if size > MAX_ARCHIVE_BYTES:
            raise ValueError("HIP ZIP exceeds byte limit")
        digest.update(block)
    return size, digest.hexdigest()


def _external_category(name: str) -> str:
    if VC_RE.fullmatch(name):
        return "microsoft-vc-ucrt-prerequisite"
    if name.startswith(("api-ms-win-", "ext-ms-win-")) or name in OS_DLLS:
        return "windows-system-api-prerequisite"
    if name in DRIVER_DLLS:
        return "amd-driver-candidate-unverified"
    return "external-unclassified"


def _reject_symlink_ancestors(path: Path) -> None:
    current = path
    while True:
        if current.is_symlink():
            raise ValueError("Audit path traverses a symlink")
        if current == current.parent:
            return
        current = current.parent


def audit_archive(archive: Path, policy: dict, *, enforce_identity: bool = True) -> dict:
    archive = Path(archive)
    if not archive.is_absolute():
        raise ValueError("HIP ZIP path must be absolute")
    _reject_symlink_ancestors(archive)
    if not archive.is_file():
        raise ValueError("HIP ZIP must be a regular file")
    if enforce_identity and (policy.get("id") != "lemonade-hip-b1339-windows-gfx110x" or
                             policy.get("executionEnabled") is not False):
        raise ValueError("HIP audit requires the disabled pinned experiment")
    files = []
    pe_rows = []
    seen_paths = set()
    dll_locations: dict[str, list[str]] = {}
    directories = 0
    total_bytes = 0
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(archive, flags)
    with os.fdopen(descriptor, "rb") as archive_stream:
        if not stat.S_ISREG(os.fstat(archive_stream.fileno()).st_mode):
            raise ValueError("HIP ZIP must be a regular file")
        size, archive_sha = _hash_stream(archive_stream)
        if size != policy["archive"]["sizeBytes"] or archive_sha != policy["archive"]["sha256"]:
            raise ValueError("HIP ZIP size or SHA-256 differs from reviewed pin")
        archive_stream.seek(0)
        with zipfile.ZipFile(archive_stream) as zipped:
            entries = zipped.infolist()
            if len(entries) > MAX_ENTRIES:
                raise ValueError("HIP ZIP has too many entries")
            prepared = []
            seen_files = set()
            for info in entries:
                path, is_dir = _valid_entry(info)
                key = path.casefold()
                if key in seen_paths:
                    raise ValueError("HIP ZIP has case-insensitive path collision")
                seen_paths.add(key)
                prepared.append((info, path, is_dir))
                if not is_dir:
                    seen_files.add(key)
            for _, path, _ in prepared:
                parts = path.split("/")
                for length in range(1, len(parts)):
                    if "/".join(parts[:length]).casefold() in seen_files:
                        raise ValueError("HIP ZIP has a file as a directory ancestor")
            for info, path, is_dir in prepared:
                if is_dir:
                    directories += 1
                    if info.file_size:
                        raise ValueError("ZIP directory has data")
                    continue
                total_bytes += info.file_size
                if total_bytes > MAX_TOTAL_BYTES:
                    raise ValueError("HIP ZIP uncompressed bytes exceed bound")
                digest = hashlib.sha256()
                copied = 0
                prefix = b""
                pe_data = bytearray()
                with zipped.open(info, "r") as stream:
                    for block in iter(lambda: stream.read(1 << 20), b""):
                        copied += len(block)
                        if copied > info.file_size or copied > MAX_FILE_BYTES:
                            raise ValueError("ZIP entry expanded beyond declared size")
                        digest.update(block)
                        if not prefix:
                            prefix = block[:2]
                        if prefix == b"MZ":
                            if copied > MAX_PE_BYTES:
                                raise ValueError("PE image exceeds audit bound")
                            pe_data.extend(block)
                if copied != info.file_size:
                    raise ValueError("ZIP entry length differs")
                if path.lower().endswith((".exe", ".dll")) and prefix != b"MZ":
                    raise ValueError("Expected PE file lacks MZ signature")
                file_sha = digest.hexdigest()
                files.append({"path": path, "sizeBytes": copied, "sha256": file_sha})
                if prefix == b"MZ":
                    parsed = pe_imports(bytes(pe_data))
                    pe_rows.append({"path": path, **parsed})
                if path.lower().endswith(".dll"):
                    dll_locations.setdefault(Path(path).name.casefold(), []).append(path)
        final_size, final_sha = _hash_stream(archive_stream)
        if final_size != size or final_sha != archive_sha:
            raise ValueError("HIP ZIP changed during held-descriptor audit")
    if (len(files) != policy["extractedFileCount"] or
            directories != policy["extractedDirectoryCount"] or
            total_bytes != policy["extractedSizeBytes"]):
        raise ValueError("HIP ZIP extracted count or byte total differs")
    file_set = hashlib.sha256()
    for row in sorted(files, key=lambda item: item["path"]):
        file_set.update(f'{row["path"]}\0{row["sizeBytes"]}\0{row["sha256"]}\n'.encode("utf-8"))
    file_set_sha = file_set.hexdigest()
    if file_set_sha != policy["fileSetDigest"]["sha256"]:
        raise ValueError("HIP ZIP complete file-set digest differs")
    collisions = {name: paths for name, paths in sorted(dll_locations.items()) if len(paths) > 1}
    edges = []
    for row in pe_rows:
        for kind in ("direct", "delay"):
            for name in row[kind]:
                locations = dll_locations.get(name, [])
                edges.append({"from": row["path"], "kind": kind, "dll": name,
                              "classification": "app-local-name-present" if len(locations) == 1 else
                              "app-local-name-collision" if locations else _external_category(name),
                              "archivePath": locations[0] if len(locations) == 1 else None})
    notices = sorted(row["path"] for row in files if NOTICE_RE.fullmatch(Path(row["path"]).name) or
                     "/share/doc/" in f'/{row["path"].lower()}/')
    return {
        "schemaVersion": 1, "kind": "offline-static-hip-archive-inventory",
        "archiveSha256": archive_sha, "archiveSizeBytes": size,
        "fileSetSha256": file_set_sha, "fileCount": len(files), "directoryCount": directories,
        "uncompressedBytes": total_bytes, "files": sorted(files, key=lambda row: row["path"]),
        "peImports": sorted(pe_rows, key=lambda row: row["path"]),
        "importEdges": sorted(edges, key=lambda row: (row["from"], row["kind"], row["dll"])),
        "dllNameCollisions": collisions, "noticeCandidates": notices,
        "staticImportNamesClassified": not collisions and all(
            row["classification"] == "app-local-name-present" or
            row["classification"] in ("windows-system-api-prerequisite", "microsoft-vc-ucrt-prerequisite", "amd-driver-candidate-unverified")
            for row in edges),
        "dynamicLoadClosureVerified": False, "legalReviewComplete": False,
        "fullBuildSourceRevisionAttested": False, "runtimeCompatibilityQualified": False,
        "limitations": ["Static import names do not prove Windows loader resolution or dynamic LoadLibrary/file opens.",
                        "Windows, Microsoft VC++/UCRT and AMD driver remain external machine prerequisites.",
                        "License/notice presence is not a legal redistribution determination.",
                        "Release metadata provides only a five-character llama.cpp source prefix."],
    }


def _safe_output(path: Path) -> None:
    if not path.is_absolute() or path.exists() or path.is_symlink() or not path.parent.is_dir():
        raise ValueError("Output must be a fresh absolute file in an existing directory")
    _reject_symlink_ancestors(path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    policy = json.loads(POLICY.read_text(encoding="utf-8"))
    result = audit_archive(args.archive, policy)
    _safe_output(args.output)
    with args.output.open("x", encoding="utf-8") as stream:
        json.dump(result, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print(f"Static HIP inventory written: {args.output}")
    print("Dynamic closure, compatibility and redistribution remain unverified.")


if __name__ == "__main__":
    main()
