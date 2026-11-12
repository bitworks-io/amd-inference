#!/usr/bin/env python3
"""Print the GitHub release notes for release.yml: the annotated tag's message, then the fixed install line.

Usage: release_notes.py TAG VERSION
The tag must be an annotated tag object (a lightweight tag would silently fall back to the commit message) and its message
must not be empty. Anything else exits 2 with a "release_notes: refusing" message, so nothing is published.
"""
import re
import subprocess
import sys

SIGNATURE_RE = re.compile(r"^-----BEGIN (?:PGP|SSH) SIGNATURE-----$", re.MULTILINE)


class NotesError(Exception):
    pass


def run_git(*args):
    return subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True, universal_newlines=True).stdout


def tag_message(tag, git=run_git):
    try:
        kind = git("cat-file", "-t", tag).strip()
    except (subprocess.CalledProcessError, OSError):
        kind = ""
    if kind != "tag":
        raise NotesError(f"the release tag is not an annotated tag: {tag!r} ({kind or 'missing'})")
    raw = git("cat-file", "tag", tag).replace("\r\n", "\n")
    _, sep, message = raw.partition("\n\n")
    if not sep:
        message = ""
    signature = SIGNATURE_RE.search(message)
    if signature:
        message = message[:signature.start()]
    message = message.rstrip("\n")
    if not message.strip():
        raise NotesError(f"the annotation of release tag {tag!r} is empty")
    return message


def build_notes(tag, version, git=run_git):
    fixed = (f"FastLLM {version}, Preview, for Windows PCs with AMD Radeon graphics. "
             f"Install with FastLLM-Setup-{version}.exe; checksums are in SHA256SUMS.")
    return f"{tag_message(tag, git)}\n\n{fixed}"


def main(argv):
    if len(argv) != 2:
        print("usage: release_notes.py TAG VERSION", file=sys.stderr)
        return 2
    try:
        notes = build_notes(argv[0], argv[1])
    except NotesError as error:
        print(f"release_notes: refusing: {error}", file=sys.stderr)
        return 2
    sys.stdout.write(notes + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
