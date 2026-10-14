import importlib.util, os, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("resolve_version", os.path.join(HERE, "resolve_version.py"))
rv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rv)


def fake_git(tags=(), on_main=True):
    def git(*args):
        if args[:2] == ("tag", "--list"):
            return "\n".join(t for t in tags if t in args[2:]) + "\n"
        if args[:2] == ("merge-base", "--is-ancestor"):
            return on_main
        raise AssertionError(args)
    return git


class ResolveTests(unittest.TestCase):
    def test_stable_tag(self):
        r = rv.resolve("tag", "v2026.10.16.1", "abc", fake_git(["v2026.10.16.1"]))
        self.assertEqual(r, {"version": "2026.10.16.1", "channel": "stable", "tag": "v2026.10.16.1", "rehearsal": "false"})

    def test_canary_tag(self):
        r = rv.resolve("tag", "v2026.10.16.2-canary", "abc", fake_git(["v2026.10.16.2-canary"]))
        self.assertEqual((r["version"], r["channel"]), ("2026.10.16.2", "canary"))

    def test_version_reused_across_channels_is_refused(self):
        with self.assertRaisesRegex(rv.ResolveError, "already used"):
            rv.resolve("tag", "v2026.10.16.1", "abc", fake_git(["v2026.10.16.1", "v2026.10.16.1-canary"]))

    def test_tag_not_on_main_is_refused(self):
        with self.assertRaisesRegex(rv.ResolveError, "not on main"):
            rv.resolve("tag", "v2026.10.16.1", "abc", fake_git(["v2026.10.16.1"], on_main=False))

    def test_malformed_tags_are_refused(self):
        for tag in ("v2026.10.16.01", "v2026.13.01.1", "2026.10.16.1", "v2026.10.16.1-beta", "v2026.10.16.0"):
            with self.subTest(tag=tag), self.assertRaises(rv.ResolveError):
                rv.resolve("tag", tag, "abc", fake_git([tag]))

    def test_dispatch_is_a_rehearsal(self):
        r = rv.resolve("branch", "main", "abc", fake_git(), today="2026.10.16")
        self.assertEqual(r, {"version": "2026.10.16.9999", "channel": "canary", "tag": "", "rehearsal": "true"})


if __name__ == "__main__":
    unittest.main()
