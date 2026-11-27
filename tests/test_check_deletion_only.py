import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "check-deletion-only.py"

BODY = "line one\nline two\nline three\nline four\n"
CHANGELOG_OLD = "# Changelog\n\n## Unreleased\n\n- first\n\n## 1.0\n\n- released\n"


class DeletionOnlyTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name)
        self.git("init", "-q")

    def git(self, *args):
        subprocess.run(
            ["git", "-C", str(self.repo), "-c", "user.name=t", "-c", "user.email=t@example.com",
             "-c", "commit.gpgsign=false", *args],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )

    def commit(self, files, message):
        """files: {path: text or None}; None removes the file."""
        for rel, text in files.items():
            target = self.repo / rel
            if text is None:
                target.unlink()
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(text.encode("utf-8"))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        head = subprocess.run(["git", "-C", str(self.repo), "rev-parse", "HEAD"], check=True,
                              stdout=subprocess.PIPE).stdout.decode().strip()
        return head

    def check(self, old, new):
        result = subprocess.run([sys.executable, str(TOOL), old, new, "--repo", str(self.repo)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return result.returncode, result.stdout.decode(), result.stderr.decode()

    def test_pure_deletion_passes_and_prints_the_span(self):
        old = self.commit({"a.txt": BODY}, "old")
        new = self.commit({"a.txt": "line one\nline three\nline four\n"}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 0, out)
        self.assertIn("@@ -2,1 @@", out)
        self.assertIn("PASS", out)

    def test_deletion_inside_a_line_is_marked_partial(self):
        old = self.commit({"a.txt": BODY}, "old")
        new = self.commit({"a.txt": "line one\nlne two\nline three\nline four\n"}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 0, out)
        self.assertIn("partial", out)

    def test_one_inserted_character_fails(self):
        old = self.commit({"a.txt": BODY}, "old")
        new = self.commit({"a.txt": "line one\nline twoX\nline three\nline four\n"}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL a.txt", out)

    def test_deletion_plus_one_inserted_character_fails(self):
        old = self.commit({"a.txt": BODY}, "old")
        new = self.commit({"a.txt": "line one\nline 2\nline four\n"}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 1, out)

    def test_added_file_fails(self):
        old = self.commit({"a.txt": BODY}, "old")
        new = self.commit({"b.txt": "new file\n"}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL b.txt", out)

    def test_deleted_file_passes(self):
        old = self.commit({"a.txt": BODY, "b.txt": "x\n"}, "old")
        new = self.commit({"b.txt": None}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 0, out)
        self.assertIn("deleted file", out)

    def test_unchanged_files_are_not_reported(self):
        old = self.commit({"a.txt": BODY, "b.txt": "x\n"}, "old")
        new = self.commit({"b.txt": ""}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 0, out)
        self.assertNotIn("a.txt", out)

    def test_changelog_additions_under_unreleased_pass(self):
        old = self.commit({"CHANGELOG.md": CHANGELOG_OLD}, "old")
        new = self.commit({"CHANGELOG.md": CHANGELOG_OLD.replace("- first\n", "- first\n- second\n- third\n")}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 0, out)
        self.assertIn("2 added line(s)", out)

    def test_changelog_deleted_line_fails(self):
        old = self.commit({"CHANGELOG.md": CHANGELOG_OLD}, "old")
        new = self.commit({"CHANGELOG.md": CHANGELOG_OLD.replace("- first\n", "")}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 1, out)

    def test_changelog_deleted_line_elsewhere_fails_even_with_an_addition_under_unreleased(self):
        old = self.commit({"CHANGELOG.md": CHANGELOG_OLD}, "old")
        edited = CHANGELOG_OLD.replace("- released\n", "").replace("- first\n", "- first\n- second\n")
        new = self.commit({"CHANGELOG.md": edited}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 1, out)

    def test_changelog_addition_under_another_heading_fails(self):
        old = self.commit({"CHANGELOG.md": CHANGELOG_OLD}, "old")
        new = self.commit({"CHANGELOG.md": CHANGELOG_OLD.replace("- released\n", "- released\n- sneaked in\n")}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 1, out)

    def test_changelog_addition_above_unreleased_fails(self):
        old = self.commit({"CHANGELOG.md": CHANGELOG_OLD}, "old")
        new = self.commit({"CHANGELOG.md": CHANGELOG_OLD.replace("# Changelog\n", "# Changelog\nintro\n")}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 1, out)

    def test_changelog_character_inserted_in_an_existing_line_fails(self):
        old = self.commit({"CHANGELOG.md": CHANGELOG_OLD}, "old")
        new = self.commit({"CHANGELOG.md": CHANGELOG_OLD.replace("- first\n", "- firsts\n")}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 1, out)

    def test_a_changelog_in_another_directory_is_not_excepted(self):
        old = self.commit({"docs/CHANGELOG.md": CHANGELOG_OLD}, "old")
        new = self.commit({"docs/CHANGELOG.md": CHANGELOG_OLD.replace("- first\n", "- first\n- second\n")}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL docs/CHANGELOG.md", out)

    def test_a_similar_name_is_not_excepted(self):
        old = self.commit({"CHANGELOG.md.bak": CHANGELOG_OLD}, "old")
        new = self.commit({"CHANGELOG.md.bak": CHANGELOG_OLD.replace("- first\n", "- first\n- second\n")}, "new")
        code, out, _ = self.check(old, new)
        self.assertEqual(code, 1, out)

    def test_bad_revision_is_a_usage_error(self):
        old = self.commit({"a.txt": BODY}, "old")
        code, _, err = self.check(old, "no-such-rev")
        self.assertEqual(code, 2)
        self.assertIn("error", err)


if __name__ == "__main__":
    unittest.main()
