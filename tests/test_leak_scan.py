import importlib.util, json, os, subprocess, sys, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "leak-scan.py"

DOT = "."
MARKERS = {
    "private-ipv4": "10" + DOT + "1" + DOT + "2" + DOT + "3",
    "windows-user-path": "C:" + "\\Users\\" + "alice" + "\\x",
    "mac-user-path": "/Us" + "ers/alice/x",
    "linux-home-path": "/ho" + "me/alice/x",
    "email": "alice" + "@" + "corp" + DOT + "test",
    "private-key": "-----BEGIN " + "RSA PRIVATE KEY-----",
    "github-token": "gh" + "p_" + "A" * 36,
    "aws-access-key": "AK" + "IA" + "B" * 16,
    "slack-token": "xo" + "xb-" + "1" * 12,
    "azure-storage-key": "Account" + "Key=" + "a" * 44,
    "jwt": "ey" + "J" + "a" * 12 + DOT + "ey" + "J" + "b" * 12 + DOT + "c" * 12,
    "pnp-instance-suffix": "PCI\\VEN_1002&DEV_744C&SUBSYS_0E3B1002&REV_C8\\" + "6&2A3B4C5D&0&00000019",
    "machine-name": "DESK" + "TOP-ABC1234",
    "windows-sid": "S-1-5-" + "21-1234567-2345678-3456789",
    "mac-address": "00:1" + "A:2B:3C:4D:5E",
}


def run(tree, *extra):
    return subprocess.run([sys.executable, str(SCRIPT), str(tree), *extra], capture_output=True, text=True)


class LeakScanTests(unittest.TestCase):
    def tree(self, files):
        root = Path(tempfile.mkdtemp())
        for rel, text in files.items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return root

    def test_clean_tree_passes(self):
        result = run(self.tree({"src/a.ps1": "Start-Process 'http://127.0.0.1:8080/v1'\n",
                                "docs/a.md": "Contact security@bitworks.io or 192.0.2.10 (TEST-NET).\n"}))
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_every_rule_catches_its_marker_without_printing_it(self):
        for rule, marker in MARKERS.items():
            with self.subTest(rule=rule):
                result = run(self.tree({"tests/fixtures/f.txt": "x " + marker + " y\n"}))
                self.assertEqual(result.returncode, 1, rule)
                self.assertIn("tests/fixtures/f.txt:1: " + rule, result.stdout)
                self.assertNotIn(marker, result.stdout + result.stderr)

    def test_allowed_addresses_and_placeholders_pass(self):
        text = ("git" + "@github.com:bitworks-io/amd-inference.git\n"
                "261824696+bitworks-io" + "@users.noreply.github.com\n"
                "someone" + "@example.com\n"
                "C:" + "\\Users\\Public\\x and C:" + "\\Users\\runneradmin\\y\n")
        self.assertEqual(run(self.tree({"a.md": text})).returncode, 0)

    def test_key_file_extension_is_flagged_by_name(self):
        result = run(self.tree({"config/test.pem": "not really a key\n"}))
        self.assertEqual(result.returncode, 1)
        self.assertIn("config/test.pem:0: key-file", result.stdout)

    def test_allowlist_suppresses_one_rule_in_one_file(self):
        root = self.tree({"tests/fixtures/f.txt": MARKERS["private-ipv4"] + "\n", "a.txt": MARKERS["private-ipv4"] + "\n"})
        allow = root / "allow.json"
        allow.write_text(json.dumps({"entries": [{"path": "tests/fixtures/f.txt", "rule": "private-ipv4", "reason": "synthetic"}]}))
        result = run(root, "--allow", str(allow))
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("tests/fixtures/f.txt", result.stdout)
        self.assertIn("a.txt:1: private-ipv4", result.stdout)

    def test_stale_allowlist_entry_refuses(self):
        root = self.tree({"a.txt": "ok\n"})
        allow = root / "allow.json"
        allow.write_text(json.dumps({"entries": [{"path": "gone.txt", "rule": "email", "reason": "x"}]}))
        self.assertEqual(run(root, "--allow", str(allow)).returncode, 2)

    def test_git_tracked_mode(self):
        root = self.tree({"a.txt": "ok\n"})
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "add", "a.txt"], check=True)
        (root / "b.txt").write_text(MARKERS["email"] + "\n")
        self.assertEqual(run(root, "--git-tracked").returncode, 0)

    def test_repo_allowlist_is_well_formed(self):
        document = json.loads((ROOT / "tools" / "leak-scan-allow.json").read_text())
        self.assertEqual(set(document), {"entries"})
        for entry in document["entries"]:
            self.assertEqual(set(entry), {"path", "rule", "reason"})
            self.assertTrue(entry["reason"].strip())


if __name__ == "__main__":
    unittest.main()
