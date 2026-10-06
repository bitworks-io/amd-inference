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
PRIVATE_TEST_FILES = frozenset({"tests/test_community_coverage.py"})


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


def _iter_source_files(root: Path):
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
                if relative.as_posix() in PRIVATE_TEST_FILES:
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


def source_map(root: Path) -> dict[str, Path]:
    sources = {relative: path for relative, path in _iter_source_files(root)}
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


def stage(source_root: Path, output: Path) -> dict:
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
    sources = source_map(root)
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
    args = parser.parse_args()
    try:
        manifest = stage(args.source_root, args.output)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Source staging failed: {exc}\n")
    print(f"Staged {len(manifest['files'])} source files in {args.output}")
    print("Review the staged tree and manifest before publication.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
