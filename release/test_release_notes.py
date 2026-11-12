import importlib.util, os, subprocess, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("release_notes", os.path.join(HERE, "release_notes.py"))
rn = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rn)

FIXED = "FastLLM 2026.11.12.1, Preview, for Windows PCs with AMD Radeon graphics. Install with FastLLM-Setup-2026.11.12.1.exe; checksums are in SHA256SUMS."
VER = "2026.11.12.1"


def fake_git(kind="tag", body="Line one\n\nLine three\n", header="object abc\ntype commit\ntag v1\ntagger A <a@example.com> 0 +0000\n"):
    def git(*args):
        if args[:2] == ("cat-file", "-t"):
            return kind + "\n"
        if args[:2] == ("cat-file", "tag"):
            return header + "\n" + body
        raise AssertionError(args)
    return git


class FakeGitTests(unittest.TestCase):
    def test_pgp_signature_is_dropped(self):
        sig = "-----BEGIN PGP SIGNATURE-----\n\nabcd\n-----END PGP SIGNATURE-----\n"
        notes = rn.build_notes("v1", VER, git=fake_git(body="Signed notes\n" + sig))
        self.assertEqual(notes, "Signed notes\n\n" + FIXED)

    def test_ssh_signature_is_dropped(self):
        sig = "-----BEGIN SSH SIGNATURE-----\nabcd\n-----END SSH SIGNATURE-----\n"
        notes = rn.build_notes("v1", VER, git=fake_git(body="Signed notes\n" + sig))
        self.assertEqual(notes, "Signed notes\n\n" + FIXED)

    def test_signature_only_message_is_refused(self):
        sig = "-----BEGIN PGP SIGNATURE-----\n\nabcd\n-----END PGP SIGNATURE-----\n"
        with self.assertRaises(rn.NotesError):
            rn.build_notes("v1", VER, git=fake_git(body=sig))


class RealRepoTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = self._tmp.name
        self.run_git("init", "-q")
        self.run_git("config", "user.name", "Test User")
        self.run_git("config", "user.email", "test@example.com")
        self.run_git("config", "commit.gpgsign", "false")
        self.run_git("config", "tag.gpgsign", "false")
        self.run_git("commit", "-q", "--allow-empty", "-m", "commit message that must not be used")

    def run_git(self, *args):
        return subprocess.run(["git", *args], cwd=self.dir, stdout=subprocess.PIPE, check=True, universal_newlines=True).stdout

    def git(self, *args):
        return self.run_git(*args)

    def test_annotated_tag_message_is_used_exactly(self):
        self.run_git("tag", "-a", "v1", "-m", "First line\n\nSecond paragraph\n- item")
        notes = rn.build_notes("v1", VER, git=self.git)
        self.assertEqual(notes, "First line\n\nSecond paragraph\n- item\n\n" + FIXED)

    def test_lightweight_tag_is_refused(self):
        self.run_git("tag", "v1")
        with self.assertRaises(rn.NotesError) as ctx:
            rn.build_notes("v1", VER, git=self.git)
        self.assertIn("not an annotated tag", str(ctx.exception))

    def test_whitespace_only_annotation_is_refused(self):
        self.run_git("tag", "-a", "--cleanup=verbatim", "v1", "-m", "   \n\n  ")
        with self.assertRaises(rn.NotesError):
            rn.build_notes("v1", VER, git=self.git)

    def test_missing_tag_is_refused(self):
        with self.assertRaises(rn.NotesError):
            rn.build_notes("v404", VER, git=self.git)

    def test_main_exit_code_for_lightweight_tag(self):
        self.run_git("tag", "v1")
        old = os.getcwd()
        os.chdir(self.dir)
        try:
            self.assertEqual(rn.main(["v1", VER]), 2)
        finally:
            os.chdir(old)


if __name__ == "__main__":
    unittest.main()
