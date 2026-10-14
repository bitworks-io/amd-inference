#!/usr/bin/env python3
"""Stage an explicitly bounded, source-only public FastLLM snapshot.

This tool never creates a repository, commits, pushes, or publishes anything.
The staged tree still requires human review before publication.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat


ROOT_FILES = (
    ".gitattributes",
    ".gitignore",
    ".github/workflows/test.yml",
    "FastLLM.cmd",
    "Install-FastLLM-Lab.cmd",
    "fast-llm.ps1",
    "fast-llm-ui.ps1",
    "SECURITY.md",
    "THIRD_PARTY_NOTICES.md",
)
PUBLIC_DOCS = (
    "docs/PUBLIC-README.md",
    "docs/PUBLIC-LAB-GUIDE.md",
    "docs/BENCHMARK-METHODOLOGY.md",
)
SOURCE_EXTENSIONS = frozenset({
    ".c", ".cmd", ".cs", ".json", ".md", ".ps1", ".psm1",
    ".py", ".sh", ".sha256",
})
SOURCE_DIRS = ("src", "config", "linux", "tests", "tools")
TEST_SOURCE_EXTENSIONS = {
    (): frozenset({".ps1", ".py"}),
    ("fixtures",): frozenset({".cs", ".json", ".ps1", ".txt"}),
    ("helpers",): frozenset({".cs", ".ps1"}),
}
MANIFEST_NAME = "PUBLIC-SOURCE-MANIFEST.json"
# This test binds private editorial research registers, which are deliberately
# outside the public documentation allowlist. Keep it with those inputs.
# Matched case-folded (a case-insensitive disk may hand back another spelling); outside a public re-staging, every listed file must also
# exist in its exact case in the tree, otherwise the constant is stale (same rule as the exclusion list).
PRIVATE_TEST_FILES = frozenset({"tests/test_community_coverage.py"})
_FOLDED_PRIVATE_TEST_FILES = frozenset(item.casefold() for item in PRIVATE_TEST_FILES)
# Files and directories that must not be staged are listed in a private file inside the source tree's ops/ directory
# (never staged itself). Staging fails closed: the list is REQUIRED, must not be empty, and every file it names must exist in the
# tree (a missing one means the list is stale). A tree without ops/ (re-staging from a public checkout) is refused unless the
# caller says so explicitly with --public-tree.
EXCLUSION_FILE = "ops/public-export/internal-only.json"


def _safe_relative(value: object, directory: bool) -> str:
    if not isinstance(value, str) or not value or value.startswith("/") or "\\" in value or "\x00" in value:
        raise ValueError("exclusion list entry is not a safe relative path")
    if any(part in ("", ".", "..") for part in value.rstrip("/").split("/")):
        raise ValueError("exclusion list entry is not a safe relative path")
    if directory != value.endswith("/"):
        raise ValueError("exclusion list entry has the wrong form (directory prefixes end with a slash)")
    return value


def _exists_exact_case(root: Path, relative: str, directory: bool) -> bool:
    """True when every component of relative exists in its exact case.

    Directory listings are compared, never is_file()/is_dir() alone: those ignore case on a case-insensitive disk (macOS APFS,
    Windows NTFS), where a list entry whose case differs from the real name would otherwise look present.
    """
    cursor = root
    for part in relative.rstrip("/").split("/"):
        try:
            if part not in os.listdir(cursor):
                return False
        except OSError:
            return False
        cursor = cursor / part
    return cursor.is_dir() if directory else cursor.is_file()


def load_exclusions(root: Path, public_tree: bool = False) -> tuple[frozenset, tuple]:
    """Return (excluded files, excluded directory prefixes) for a source tree.

    Fails closed: an absent ops/ directory is an error unless public_tree is set (explicit re-staging from a public
    checkout); the list must be non-empty; every listed file and directory prefix must exist in the tree (otherwise the list is stale).
    """
    ops = root / "ops"
    if not ops.exists() and not ops.is_symlink():
        if public_tree:
            return frozenset(), ()
        raise ValueError("the source tree has no ops directory, so the internal-only list cannot be applied "
                         "(pass --public-tree only when re-staging from a public checkout)")
    path = root / EXCLUSION_FILE
    problem = f"{EXCLUSION_FILE} is missing or malformed while the source tree has an ops directory"
    cursor = root
    for component in Path(EXCLUSION_FILE).parts:
        cursor = cursor / component
        if cursor.is_symlink():
            raise ValueError(problem)
    if not path.is_file():
        raise ValueError(problem)
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        if (not isinstance(document, dict) or set(document) != {"files", "directoryPrefixes"} or
                not isinstance(document["files"], list) or not isinstance(document["directoryPrefixes"], list)):
            raise ValueError("shape")
        files = frozenset(_safe_relative(item, False) for item in document["files"])
        prefixes = tuple(_safe_relative(item, True) for item in document["directoryPrefixes"])
    except (ValueError, OSError):
        raise ValueError(problem) from None
    if not files and not prefixes:
        raise ValueError(f"{EXCLUSION_FILE} is empty: refusing to stage without an internal-only list")
    for relative in sorted(files):
        if not _exists_exact_case(root, relative, False):
            raise ValueError(f"{EXCLUSION_FILE} is stale: listed file is missing from the tree (or its case differs): {relative}")
    for prefix in sorted(prefixes):
        if not _exists_exact_case(root, prefix, True):
            raise ValueError(f"{EXCLUSION_FILE} is stale: listed directory prefix is missing from the tree (or its case differs): {prefix}")
    return files, prefixes


def _inside(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def _regular_source(root: Path, relative: str) -> Path:
    path = root / relative
    cursor = root
    for component in Path(relative).parts:
        cursor = cursor / component
        if cursor.is_symlink():
            raise ValueError(f"symlink in required source: {relative}")
    if not path.is_file():
        raise ValueError(f"required source is missing or not a file: {relative}")
    return path


def _iter_source_files(root: Path, excluded_files: frozenset = frozenset(), excluded_prefixes: tuple = ()):
    # Exclusions match case-folded: a source path is excluded whatever its case (a case-insensitive disk may hand back another spelling).
    folded_files = frozenset(item.casefold() for item in excluded_files)
    folded_prefixes = tuple(item.casefold() for item in excluded_prefixes)
    for directory in SOURCE_DIRS:
        base = root / directory
        if base.is_symlink() or not base.is_dir():
            raise ValueError(f"required source directory is missing or a symlink: {directory}")
        for current, dirs, files in os.walk(base, followlinks=False):
            current_path = Path(current)
            subdir = current_path.relative_to(base).parts
            for name in dirs + files:
                if (current_path / name).is_symlink():
                    raise ValueError(f"symlink in source directory: {(current_path / name).relative_to(root)}")
            if directory == "tests":
                # Only these actual, reviewed test-source locations are public.
                # Runtime scratch trees (including nonce-named JSON reports) stay
                # private even when their suffixes resemble fixture data.
                dirs[:] = sorted(name for name in dirs if not subdir and
                                 (name,) in TEST_SOURCE_EXTENSIONS)
            else:
                dirs[:] = sorted(name for name in dirs if name != "__pycache__" and not name.startswith("."))
            for name in sorted(files):
                path = current_path / name
                relative = path.relative_to(root)
                posix = relative.as_posix()
                folded = posix.casefold()
                if folded in _FOLDED_PRIVATE_TEST_FILES or folded in folded_files or folded.startswith(folded_prefixes):
                    continue
                if (name.startswith(".") or name.endswith(".pub") or
                        any(part.startswith(".") for part in relative.parts) or
                        "__pycache__" in relative.parts):
                    continue
                if directory == "tests":
                    allowed = path.suffix.lower() in TEST_SOURCE_EXTENSIONS.get(subdir, ())
                else:
                    allowed = path.suffix.lower() in SOURCE_EXTENSIONS
                if allowed:
                    if not path.is_file():
                        raise ValueError(f"source is not a regular file: {relative}")
                    yield relative.as_posix(), path


def source_map(root: Path, public_tree: bool = False) -> dict[str, Path]:
    excluded_files, excluded_prefixes = load_exclusions(root, public_tree)
    ops = root / "ops"
    # Skip the private-test check only on a real public tree: --public-tree AND no ops/ (the same signal load_exclusions uses).
    # --public-tree on a tree that still has ops/ keeps enforcing it.
    real_public_tree = public_tree and not ops.exists() and not ops.is_symlink()
    if not real_public_tree:
        for relative in sorted(PRIVATE_TEST_FILES):
            if not _exists_exact_case(root, relative, False):
                raise ValueError(f"PRIVATE_TEST_FILES is stale: listed file is missing from the tree (or its case differs): {relative}")
    sources = {relative: path for relative, path in _iter_source_files(root, excluded_files, excluded_prefixes)}
    for relative in ROOT_FILES:
        sources[relative] = _regular_source(root, relative)
    for relative in PUBLIC_DOCS:
        sources[relative] = _regular_source(root, relative)
    sources["README.md"] = sources["docs/PUBLIC-README.md"]
    return dict(sorted(sources.items()))


def _read_regular_file(path: Path) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError(f"source is not a regular file: {path.name}")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            return stream.read()
    finally:
        os.close(fd)


def stage(source_root: Path, output: Path, public_tree: bool = False) -> dict:
    if source_root.is_symlink() or not source_root.is_dir():
        raise ValueError("source root is missing or a symlink")
    root = source_root.resolve(strict=True)
    if output.name in ("", ".", ".."):
        raise ValueError("output must name a new directory")
    if not output.parent.is_dir():
        raise ValueError("output parent directory does not exist")
    destination = output.parent.resolve(strict=True) / output.name
    if _inside(destination.resolve(strict=False), root):
        raise ValueError("output must be outside the source tree")
    if destination.exists() or destination.is_symlink():
        raise ValueError("output must be a new, nonexistent directory")
    sources = source_map(root, public_tree)
    # Exclusive creation is important: Path.rename may replace an empty
    # directory that appears between an exists check and the rename on POSIX.
    # A failed stage may leave this directory without a manifest; it never
    # deletes or overwrites files subsequently placed there by another actor.
    destination.mkdir()
    entries = []
    for relative, original in sources.items():
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        payload = _read_regular_file(original)
        with target.open("xb") as stream:
            stream.write(payload)
        entries.append({
            "path": relative,
            "sizeBytes": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
        })
    manifest = {"schemaVersion": 1, "kind": "source-only-public-staging", "files": entries}
    with (destination / MANIFEST_NAME).open("xb") as stream:
        stream.write((json.dumps(manifest, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path, help="new, nonexistent output directory")
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="source checkout (defaults to this script's parent repository)")
    parser.add_argument("--public-tree", action="store_true",
                        help="the source root is a public checkout without ops/ (re-staging); without this flag a tree "
                             "without ops/ is refused")
    args = parser.parse_args()
    try:
        manifest = stage(args.source_root, args.output, args.public_tree)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Source staging failed: {exc}\n")
    print(f"Staged {len(manifest['files'])} source files in {args.output}")
    print("Review the staged tree and manifest before publication.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
