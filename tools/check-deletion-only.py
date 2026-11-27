#!/usr/bin/env python3
"""Proves that a change between two git revisions only deletes characters.

Usage: check-deletion-only.py <old-rev> <new-rev> [--repo DIR]

For every file that differs between the two revisions, the new text must be a
subsequence of the old text (character level, greedy two-pointer). A deleted
file passes; an added file fails. For each file it prints the deleted spans as
unified-diff-style line ranges of the OLD file ("@@ -start,count @@"; lines
that lose only some of their characters are marked "partial"). The exit code is 1 if
any file breaks the rule, 2 for a usage or git error, else 0.

One named exception (the exact path CHANGELOG.md, no pattern, no other
directory): it may only gain lines. It must lose none, and every added line
must lie between the line "## Unreleased" and the next line that starts with
"## ".
"""

import argparse
import difflib
import subprocess
import sys

CHANGELOG = "CHANGELOG.md"
UNRELEASED = "## Unreleased"


class GitError(Exception):
    pass


def git(repo, *args):
    result = subprocess.run(
        ["git", "-C", repo, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if result.returncode != 0:
        raise GitError(
            "git %s failed: %s" % (" ".join(args), result.stderr.decode("utf-8", "replace").strip())
        )
    return result.stdout


def changed_files(repo, old_rev, new_rev):
    """[(status, path)] with status A, D or M (a type change counts as M, a rename as D plus A)."""
    raw = git(repo, "diff", "--name-status", "--no-renames", "-z", old_rev, new_rev)
    parts = raw.decode("utf-8", "surrogateescape").split("\0")
    entries = []
    index = 0
    while index + 1 < len(parts):
        status, path = parts[index], parts[index + 1]
        index += 2
        entries.append(("M" if status.startswith("T") else status[0], path))
    return entries


def read_text(repo, rev, path):
    data = git(repo, "show", "%s:%s" % (rev, path))
    return data.decode("utf-8", "surrogateescape")


def deleted_spans(old, new):
    """Greedy subsequence match. Returns the list of deleted (start, end) offsets in old, or None if new is not a subsequence."""
    spans = []
    position = 0
    for char in new:
        found = old.find(char, position)
        if found < 0:
            return None
        if found > position:
            spans.append((position, found))
        position = found + 1
    if position < len(old):
        spans.append((position, len(old)))
    return spans


def first_mismatch(old, new):
    """The offset in new of the first character that has no place in old (for the failure message)."""
    position = 0
    for offset, char in enumerate(new):
        found = old.find(char, position)
        if found < 0:
            return offset
        position = found + 1
    return len(new)


def report_ranges(old, new):
    """Unified-diff-style old line ranges of what was deleted: whole lines, or 'partial' for lines edited in place (a deletion inside a line)."""
    old_lines = old.split("\n")
    new_lines = new.split("\n")
    matcher = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)
    ranges = []
    for tag, a1, a2, _b1, _b2 in matcher.get_opcodes():
        if tag == "delete":
            ranges.append((a1 + 1, a2 - a1, False))
        elif tag == "replace":
            ranges.append((a1 + 1, a2 - a1, True))
    return ranges


def check_subsequence(path, old, new):
    if deleted_spans(old, new) is None:
        offset = first_mismatch(old, new)
        line = new.count("\n", 0, offset) + 1
        return False, ["FAIL %s: the new text is not a subsequence of the old text (first extra character at new line %d)" % (path, line)]
    ranges = report_ranges(old, new)
    out = ["OK   %s: %d characters deleted in %d range(s)" % (path, len(old) - len(new), len(ranges))]
    for start, count, partial in ranges:
        out.append("  @@ -%d,%d @@%s" % (start, count, " partial (lines edited in place)" if partial else ""))
    return True, out


def section_bounds(lines):
    """(start, end): the indexes of '## Unreleased' and of the next '## ' line (or len(lines)); None if there is no such heading."""
    for index, line in enumerate(lines):
        if line.rstrip("\r") == UNRELEASED:
            end = len(lines)
            for later in range(index + 1, len(lines)):
                if lines[later].startswith("## "):
                    end = later
                    break
            return index, end
    return None


def is_subsequence(small, big):
    position = 0
    for item in small:
        try:
            position = big.index(item, position) + 1
        except ValueError:
            return False
    return True


def check_changelog(path, old, new):
    old_lines = old.split("\n")
    new_lines = new.split("\n")
    old_bounds = section_bounds(old_lines)
    new_bounds = section_bounds(new_lines)
    if old_bounds is None or new_bounds is None:
        return False, ["FAIL %s: both versions need a '%s' heading" % (path, UNRELEASED)]
    old_out = old_lines[: old_bounds[0] + 1] + old_lines[old_bounds[1]:]
    new_out = new_lines[: new_bounds[0] + 1] + new_lines[new_bounds[1]:]
    if old_out != new_out:
        return False, ["FAIL %s: a line outside the Unreleased section was added, deleted or changed" % path]
    old_in = old_lines[old_bounds[0] + 1 : old_bounds[1]]
    new_in = new_lines[new_bounds[0] + 1 : new_bounds[1]]
    if not is_subsequence(old_in, new_in):
        return False, ["FAIL %s: a line of the Unreleased section was deleted or changed" % path]
    added = len(new_in) - len(old_in)
    first = new_bounds[0] + 2
    return True, [
        "OK   %s: 0 deleted lines, %d added line(s) under %s" % (path, added, UNRELEASED),
        "  @@ -0,0 +%d,%d @@ (added lines in the new file, section starts at line %d)" % (first, added, first),
    ]


def run(repo, old_rev, new_rev):
    ok = True
    entries = changed_files(repo, old_rev, new_rev)
    for status, path in entries:
        if status == "D":
            if path == CHANGELOG:
                print("FAIL %s: deleted (the exception allows only added lines)" % path)
                ok = False
            else:
                print("OK   %s: deleted file" % path)
            continue
        if status == "A":
            print("FAIL %s: an added file (a change that only deletes cannot add one)" % path)
            ok = False
            continue
        old = read_text(repo, old_rev, path)
        new = read_text(repo, new_rev, path)
        if path == CHANGELOG:
            good, lines = check_changelog(path, old, new)
        else:
            good, lines = check_subsequence(path, old, new)
        ok = ok and good
        for line in lines:
            print(line)
    print("%s: %d changed file(s) between %s and %s" % ("PASS" if ok else "FAIL", len(entries), old_rev, new_rev))
    return ok


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check that a change between two git revisions only deletes characters.")
    parser.add_argument("old_rev")
    parser.add_argument("new_rev")
    parser.add_argument("--repo", default=".")
    args = parser.parse_args(argv)
    try:
        ok = run(args.repo, args.old_rev, args.new_rev)
    except GitError as error:
        print("error: %s" % error, file=sys.stderr)
        return 2
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
