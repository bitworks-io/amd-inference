import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# Lab-only admin scripts that may name an execution policy. They are never packaged (see tools/build-release.py).
ALLOWLIST = {
    "tools/setup-windows-lab.cmd": "private bench administration launcher (admin SSH setup); excluded from the release package",
}
# Product files that only READ the effective policy and PRINT the user-approved hint text; they must never set one (checked below).
PRODUCT_TEXT_ONLY = {
    "src/FastLlm.UiFluentSupport.ps1": "builds the user-approved unsupported-PC hint text and reads the effective policy; never sets one",
}
EXTS = {".ps1", ".psm1", ".psd1", ".cmd", ".bat", ".py", ".sh"}


def scanned():
    files = [ROOT / "fast-llm.ps1", ROOT / "fast-llm-ui.ps1"]
    for d in ("src", "tools"):
        files += [p for p in (ROOT / d).rglob("*") if p.is_file() and p.suffix.lower() in EXTS]
    return files


class ExecutionPolicyTests(unittest.TestCase):
    def test_only_allowlisted_lab_scripts_name_a_policy(self):
        for p in scanned():
            rel = p.relative_to(ROOT).as_posix()
            if rel in ALLOWLIST or rel in PRODUCT_TEXT_ONLY:
                continue
            self.assertNotIn("executionpolicy", p.read_text(encoding="utf-8", errors="replace").lower(), rel)

    def test_allowlist_entries_are_live(self):
        for rel, why in ALLOWLIST.items():
            self.assertTrue(why)
            self.assertIn("executionpolicy", (ROOT / rel).read_text(encoding="utf-8").lower(), rel)

    def test_product_text_only_allowlist_entries_are_live(self):
        for rel, why in PRODUCT_TEXT_ONLY.items():
            self.assertTrue(why)
            self.assertIn("executionpolicy", (ROOT / rel).read_text(encoding="utf-8").lower(), rel)

    def test_product_text_only_files_never_set_a_policy(self):
        for rel in PRODUCT_TEXT_ONLY:
            lines = (ROOT / rel).read_text(encoding="utf-8").lower().splitlines()
            for n, line in enumerate(lines, 1):
                where = f"{rel}:{n}"
                self.assertNotIn("set-executionpolicy", line, where)
                # Reading the policy (Get-ExecutionPolicy) is allowed; any other -ExecutionPolicy must be inside a '...' literal or a comment.
                checked = line.replace("get-executionpolicy", "get-")
                if checked.lstrip().startswith("#"):
                    continue
                start = 0
                while True:
                    i = checked.find("-executionpolicy", start)
                    if i < 0:
                        break
                    self.assertEqual(checked[:i].count("'") % 2, 1, where + ": -ExecutionPolicy outside a quoted string")
                    start = i + 1
                if "start-process" in line or "powershell.exe" in line or "pwsh.exe" in line:
                    self.assertNotIn("executionpolicy", line, where)

    def test_fastllm_cmd_is_the_only_product_launcher_setting_a_policy(self):
        self.assertIn("executionpolicy", (ROOT / "FastLLM.cmd").read_text(encoding="utf-8").lower())
        for p in ROOT.iterdir():
            if p.is_file() and p.name != "FastLLM.cmd" and p.suffix.lower() in {".cmd", ".bat", ".ps1"}:
                self.assertNotIn("executionpolicy", p.read_text(encoding="utf-8", errors="replace").lower(), p.name)
        self.assertNotIn("executionpolicy", (ROOT / "installer" / "FastLLM.iss").read_text(encoding="utf-8").lower())


if __name__ == "__main__":
    unittest.main()
