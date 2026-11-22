import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# FastLLM.cmd as it was before the sign-in branch was added, with the one exit-code-3 change (the window already told the user why).
# The window path must stay exactly this text.
ORIGINAL_LINES = r"""@echo off
setlocal
set "FASTLLM_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "FASTLLM_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
REM The extra outer quotes keep cmd /c from stripping the quotes around the executable path.
REM A Process-scope policy reaches child processes through PSExecutionPolicyPreference.
REM Set it only when the effective policy would block FastLLM's signed scripts; never weaken AllSigned or Group Policy.
for /f "usebackq delims=" %%P in (`""%FASTLLM_PS%" -NoLogo -NoProfile -NonInteractive -Command Get-ExecutionPolicy"`) do set "FASTLLM_POLICY=%%P"
set "FASTLLM_EP="
if /i "%FASTLLM_POLICY%"=="Restricted" set "FASTLLM_EP=-ExecutionPolicy RemoteSigned"
if /i "%FASTLLM_POLICY%"=="Undefined" set "FASTLLM_EP=-ExecutionPolicy RemoteSigned"
"%FASTLLM_PS%" -NoLogo -NoProfile %FASTLLM_EP% -STA -File "%~dp0fast-llm-ui.ps1"
set "FASTLLM_EXIT=%errorlevel%"
if "%FASTLLM_EXIT%"=="3" goto fastllm_done
if not "%FASTLLM_EXIT%"=="0" (
  echo FastLLM could not open. If PowerShell says running scripts is disabled, a script policy is blocking it.
  echo Otherwise, run FastLLM as a standard user, not as administrator.
  echo For script policy help, see the FastLLM README:
  echo https://github.com/bitworks-io/amd-inference
  pause
)
:fastllm_done
endlocal
""".split("\n")[:-1]

# The only lines the sign-in branch adds.
INSERTED_LINES = [
    'if /i "%~1"=="/signin" goto signin',
    "goto :eof",
    "",
    ":signin",
    '"%FASTLLM_PS%" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden %FASTLLM_EP% -File "%~dp0tools\\signin-start.ps1"',
    "endlocal & exit /b %errorlevel%",
]


def tracked_cmd_files():
    out = subprocess.run(["git", "ls-files", "*.cmd", "*.bat"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [line for line in out.splitlines() if line]


class LauncherPolicyTests(unittest.TestCase):
    def test_only_fastllm_cmd_names_an_execution_policy(self):
        named = [p for p in tracked_cmd_files()
                 if "executionpolicy" in (ROOT / p).read_text(encoding="utf-8", errors="replace").lower()]
        # tools/setup-windows-lab.cmd is the lab-only admin launcher that tests/test_execution_policy.py allowlists.
        self.assertEqual(sorted(p for p in named if p != "tools/setup-windows-lab.cmd"), ["FastLLM.cmd"])

    def test_no_second_root_launcher(self):
        self.assertEqual(sorted(p.name for p in ROOT.glob("*.cmd")), ["FastLLM.cmd", "Install-FastLLM-Lab.cmd"])

    def test_window_path_is_unchanged_apart_from_the_sign_in_branch(self):
        lines = (ROOT / "FastLLM.cmd").read_text(encoding="utf-8").split("\n")[:-1]
        for inserted in INSERTED_LINES:
            self.assertIn(inserted, lines)
            lines.remove(inserted)
        self.assertEqual(lines, ORIGINAL_LINES)

    def test_exit_code_3_skips_the_generic_failure_text(self):
        lines = (ROOT / "FastLLM.cmd").read_text(encoding="utf-8").split("\n")
        window = next(i for i, l in enumerate(lines) if "fast-llm-ui.ps1" in l and "FASTLLM_PS%" in l)
        # The exit code is saved on its own line right after the window line: %errorlevel% inside a parenthesised block is read at parse time.
        self.assertEqual(lines[window + 1], 'set "FASTLLM_EXIT=%errorlevel%"')
        self.assertEqual(lines[window + 2], 'if "%FASTLLM_EXIT%"=="3" goto fastllm_done')
        self.assertEqual(lines[window + 3], 'if not "%FASTLLM_EXIT%"=="0" (')
        # The skip lands after the generic text and before endlocal; every other non-zero code still gets the text.
        done = lines.index(":fastllm_done")
        self.assertEqual(lines[done + 1], "endlocal")
        self.assertGreater(done, max(i for i, l in enumerate(lines) if l.startswith("  echo FastLLM could not open")))
        self.assertLess(done, lines.index(":signin"))
        self.assertEqual(sum(1 for l in lines if l.strip() == "pause"), 1)

    def test_sign_in_branch_runs_only_the_sign_in_tool(self):
        text = (ROOT / "FastLLM.cmd").read_text(encoding="utf-8")
        branch = text[text.index("\n:signin\n"):]
        runs = [l for l in branch.splitlines() if "FASTLLM_PS%\"" in l]
        self.assertEqual(len(runs), 1)
        self.assertIn("tools\\signin-start.ps1", runs[0])
        self.assertNotIn("fast-llm-ui.ps1", branch)
        self.assertNotIn("pause", branch)
        self.assertNotIn("echo", branch)
        self.assertNotIn("-ExecutionPolicy", branch)
        # The branch is taken only by the exact first argument, before the window launch.
        self.assertLess(text.index('if /i "%~1"=="/signin" goto signin'), text.index("fast-llm-ui.ps1"))


if __name__ == "__main__":
    unittest.main()
