#!/usr/bin/env python3
"""Resolve version and channel for release.yml; prints key=value lines for $GITHUB_OUTPUT.

Tag runs: the tag must be vYYYY.MM.DD.N or vYYYY.MM.DD.N-canary, its commit must be on origin/main, and no other tag may
carry the same version (a version is used once across both channels). Other runs (workflow_dispatch) are rehearsals:
version <today>.9999, channel canary; release.yml signs and publishes nothing for them.
A tag run must be attempt 1 (a re-run never signs again), and no
GitHub release may already exist for the version on either channel. workflow_dispatch is always a rehearsal, even on a tag.
Env: REF_TYPE, REF_NAME, GITHUB_SHA, EVENT_NAME, RUN_ATTEMPT, RELEASE_TAGS (newline-separated tag names of existing releases).
"""
import datetime
import os
import re
import subprocess
import sys

TAG_RE = re.compile(r"^v([0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[1-9][0-9]{0,3})(-canary)?$")


class ResolveError(Exception):
    pass


def real_date(version):
    try:
        datetime.datetime.strptime(version.rsplit(".", 1)[0], "%Y.%m.%d")
        return True
    except ValueError:
        return False


def run_git(*args):
    if args[:2] == ("merge-base", "--is-ancestor"):
        return subprocess.run(["git", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    return subprocess.run(["git", *args], stdout=subprocess.PIPE, check=True, universal_newlines=True).stdout


def utc_today():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y.%m.%d")


def resolve(ref_type, ref_name, sha, git=run_git, today=None, event_name="push", run_attempt="1", release_tags=()):
    today = today or utc_today()
    if ref_type != "tag" or event_name == "workflow_dispatch":
        return {"version": f"{today}.9999", "channel": "canary", "tag": "", "rehearsal": "true"}
    match = TAG_RE.match(ref_name or "")
    if not match or not real_date(match.group(1)):
        raise ResolveError(f"malformed release tag: {ref_name!r} (want vYYYY.MM.DD.N or vYYYY.MM.DD.N-canary)")
    version = match.group(1)
    if str(run_attempt) != "1":
        raise ResolveError(f"run attempt {run_attempt} is a re-run: a failed or spent version is never signed again; tag a new version")
    released = sorted({f"v{version}", f"v{version}-canary"} & set(release_tags))
    if released:
        raise ResolveError(f"a GitHub release already exists for version {version}: {', '.join(released)}")
    tags = sorted(t for t in git("tag", "--list", f"v{version}", f"v{version}-canary").split() if t)
    if tags != [ref_name]:
        raise ResolveError(f"version {version} is already used by another tag: {', '.join(t for t in tags if t != ref_name)}")
    if not git("merge-base", "--is-ancestor", sha, "origin/main"):
        raise ResolveError("the tagged commit is not on main")
    return {"version": version, "channel": "canary" if match.group(2) else "stable", "tag": ref_name, "rehearsal": "false"}


def main():
    try:
        result = resolve(
            os.environ.get("REF_TYPE", ""),
            os.environ.get("REF_NAME", ""),
            os.environ.get("GITHUB_SHA", ""),
            event_name=os.environ.get("EVENT_NAME", ""),
            run_attempt=os.environ.get("RUN_ATTEMPT", ""),
            release_tags=os.environ.get("RELEASE_TAGS", "").split(),
        )
    except ResolveError as error:
        print(f"resolve_version: refusing: {error}", file=sys.stderr)
        return 2
    for key, value in result.items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
