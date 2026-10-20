import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROBE = (ROOT / ".github" / "workflows" / "adlx-probe.yml").read_text(encoding="utf-8")
RELEASE = (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
BUILD_SCRIPT = (ROOT / "tools" / "build-adlx-identity-vram.sh").read_text(encoding="utf-8")


def job(text, name):
    match = re.search(r"^  " + re.escape(name) + r":\n(.*?)(?=^  [a-z][a-z-]*:\n|\Z)", text, re.S | re.M)
    assert match, name
    return match.group(1)


def action_pin(text, action):
    pins = set(re.findall(re.escape(action) + r"@([0-9a-f]{40})", text))
    return pins


class AdlxProbeWorkflowTests(unittest.TestCase):
    def test_triggers_only_on_probe_tags(self):
        on_block = re.search(r"^on:\n(.*?)^permissions:", PROBE, re.S | re.M).group(1)
        self.assertEqual(re.findall(r"^  ([a-z_]+):", on_block, re.M), ["push"])
        self.assertIn("tags: ['adlx-probe-v*']", on_block)
        self.assertNotIn("branches", on_block)

    def test_tag_is_validated_to_a_number(self):
        self.assertIn(r"^adlx-probe-v([1-9][0-9]{0,3})$", PROBE)

    def test_permissions_read_only_except_publish(self):
        self.assertRegex(PROBE, r"(?m)^permissions:\n  contents: read\n")
        self.assertIn("contents: write", job(PROBE, "publish"))
        self.assertEqual(PROBE.count("contents: write"), 1)
        for name in ("build", "sign"):
            self.assertNotIn("contents: write", job(PROBE, name))

    def test_zig_is_pinned_by_sha256(self):
        self.assertRegex(PROBE, r"(?m)^  ZIG_URL: https://ziglang\.org/download/0\.16\.0/zig-x86_64-linux-0\.16\.0\.tar\.xz$")
        self.assertRegex(PROBE, r"(?m)^  ZIG_SHA256: [0-9a-f]{64}$")
        self.assertIn('sha256sum -c -', PROBE)
        self.assertIn("0.16.0", BUILD_SCRIPT)

    def test_unsigned_hash_is_checked_in_build_and_sign(self):
        self.assertRegex(PROBE, r"(?m)^  EXPECTED_UNSIGNED_SHA256: [0-9a-f]{64}$")
        self.assertIn('"$actual" != "$EXPECTED_UNSIGNED_SHA256"', job(PROBE, "build"))
        self.assertIn("$env:EXPECTED_UNSIGNED_SHA256", job(PROBE, "sign"))

    def test_signing_matches_release_workflow(self):
        pins = action_pin(PROBE, "azure/artifact-signing-action")
        self.assertEqual(len(pins), 1)
        self.assertEqual(pins, action_pin(RELEASE, "azure/artifact-signing-action"))
        self.assertEqual(action_pin(PROBE, "azure/login"), action_pin(RELEASE, "azure/login"))
        sign = job(PROBE, "sign")
        self.assertIn("environment: release", sign)
        for line in ("endpoint: ${{ secrets.AZURE_ENDPOINT }}",
                     "signing-account-name: ${{ secrets.AZURE_SIGNING_ACCOUNT }}",
                     "certificate-profile-name: ${{ secrets.AZURE_SIGNING_CERTIFICATE }}",
                     "file-digest: SHA256",
                     "timestamp-rfc3161: http://timestamp.acs.microsoft.com",
                     "timestamp-digest: SHA256"):
            self.assertIn(line, sign)
            self.assertIn(line, RELEASE)
        self.assertEqual(re.search(r"runs-on: (\S+)", sign).group(1), re.search(r"runs-on: (\S+)", job(RELEASE, "sign")).group(1))

    def test_signature_is_verified(self):
        sign = job(PROBE, "sign")
        self.assertIn("Get-AuthenticodeSignature", sign)
        self.assertIn("'Valid'", sign)
        self.assertIn("Bitworks LLC", sign)

    def test_every_action_is_pinned_to_a_commit(self):
        for use in re.findall(r"uses: (\S+)", PROBE):
            self.assertRegex(use, r"@[0-9a-f]{40}$", use)

    def test_zip_members(self):
        self.assertIn("'EULA.txt|NOTICE.txt|adlx-identity-vram.exe'", PROBE)
        self.assertEqual(sorted(re.findall(r"Copy-Item .*?-Destination \(Join-Path \$stage '([^']+)'\)", PROBE)), ["EULA.txt", "adlx-identity-vram.exe"])
        self.assertIn("NOTICE.txt", PROBE)
        self.assertIn("licenses/adlx-probe/EULA.md", PROBE)
        self.assertIn('"adlx-probe-$env:NUMBER.zip"', PROBE)
        self.assertIn("'SHA256SUMS'", PROBE)

    def test_release_is_a_prerelease_with_zip_and_checksums(self):
        publish = job(PROBE, "publish")
        self.assertIn("gh release create", publish)
        self.assertIn("--prerelease", publish)
        self.assertIn('--title "FastLLM ADLX probe v$NUMBER"', publish)
        self.assertIn("--notes-file notes.md", publish)
        self.assertIn('assets/adlx-probe-"$NUMBER".zip assets/SHA256SUMS', publish)
        self.assertNotIn("--latest", publish)

    def test_no_sdk_files_are_stored(self):
        tracked = [p for p in ROOT.rglob("*") if p.is_file() and ".git" not in p.parts]
        self.assertEqual([p for p in tracked if p.name in ("ADLX.h", "ADLXDefines.h", "ADLXStructures.h") or p.name.endswith("adlx-identity-vram.exe")], [])


if __name__ == "__main__":
    unittest.main()
