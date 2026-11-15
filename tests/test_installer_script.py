import re
import unittest
from pathlib import Path

ISS = (Path(__file__).resolve().parents[1] / "installer" / "FastLLM.iss").read_text(encoding="utf-8")


class InstallerScriptTests(unittest.TestCase):
    def test_uninstall_offers_only_models_and_engines_and_defaults_to_no(self):
        prompt = re.search(r"(?s)MsgBox\(.*?\) = IDYES", ISS).group(0)
        for word in ("downloaded models and engines", "ModelsDir", "EnginesDir", "are kept"):
            self.assertIn(word, prompt)
        self.assertIn("MB_YESNO or MB_DEFBUTTON2", prompt)
        self.assertIn("DelTree(ModelsDir, ", ISS)
        self.assertIn("DelTree(EnginesDir, ", ISS)
        self.assertNotIn("DelTree(DataDir", ISS)

    def test_uninstall_size_uses_int64_and_covers_components(self):
        self.assertNotIn("* 4294967296", ISS)
        self.assertIn("Hi, Lo: Int64;", ISS)
        self.assertIn("Hi * 65536 * 65536 + Lo", ISS)
        prompt = re.search(r"(?s)MsgBox\(.*?\) = IDYES", ISS).group(0)
        self.assertIn("ComponentsDir", prompt)
        self.assertIn("DirSizeBytes(ComponentsDir)", ISS)
        self.assertIn("DelTree(ComponentsDir, ", ISS)

    def test_install_refuses_a_foreign_non_empty_folder_before_install_delete(self):
        self.assertIn("function PrepareToInstall(var NeedsRestart: Boolean): String;", ISS)
        body = ISS[ISS.index("function PrepareToInstall"):]
        self.assertRegex(body, r"DirExists\(Dir\) and DirHasEntries\(Dir\) and not IsFastLlmInstall\(Dir\)")
        self.assertIn("'FastLLM.cat'", ISS)
        self.assertIn("'_uninstall\\unins000.dat'", ISS)

    def test_upgrade_still_clears_the_previous_version(self):
        for line in ('Type: files; Name: "{app}\\*"', 'Type: filesandordirs; Name: "{app}\\src"', 'Type: filesandordirs; Name: "{app}\\tools"'):
            self.assertIn(line, ISS)

    def test_install_never_registers_start_at_sign_in_and_uninstall_removes_it(self):
        self.assertNotRegex(ISS, r"(?im)^\[Registry\]")
        before = ISS[:ISS.index("procedure CurUninstallStepChanged")]
        self.assertNotRegex(before, r"(?i)CurrentVersion\\Run")
        body = ISS[ISS.index("procedure CurUninstallStepChanged"):]
        self.assertIn("RegDeleteValue(HKCU, 'Software\\Microsoft\\Windows\\CurrentVersion\\Run', 'FastLLM')", body)
        self.assertIn("RegDeleteValue(HKCU, 'Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run', 'FastLLM')", body)
        # The values go away before the early exit that skips the data-folder prompt.
        self.assertLess(body.index("RegDeleteValue(HKCU, 'Software\\Microsoft\\Windows\\CurrentVersion\\Run'"), body.index("if UninstallSilent"))

    def test_previous_release_is_recorded_before_install_delete_runs(self):
        # Setup runs PrepareToInstall before it starts the install step, which is where [InstallDelete] runs.
        self.assertIn("procedure RecordPreviousRelease;", ISS)
        record = ISS[ISS.index("procedure RecordPreviousRelease;"):ISS.index("function PrepareToInstall")]
        for needle in ("'\\RELEASE.json'", "'\\config\\release-policy.json'", "state\\previous-release", "FileCopy(", "DelTree(RecordDir"):
            self.assertIn(needle, record)
        self.assertRegex(record, r"if not FileExists\(\w+\) then")  # no installed release: nothing is copied
        prepare = ISS[ISS.index("function PrepareToInstall"):]
        prepare = prepare[:prepare.index("\nend;")]
        self.assertIn("RecordPreviousRelease;", prepare)
        self.assertGreater(prepare.index("RecordPreviousRelease;"), prepare.index("Result := 'FastLLM was not installed."))
        self.assertNotIn("ssInstall", ISS)
        self.assertLess(ISS.index("procedure RecordPreviousRelease;"), ISS.index("function PrepareToInstall"))

    def test_recording_the_previous_release_never_fails_the_install(self):
        record = ISS[ISS.index("procedure RecordPreviousRelease;"):ISS.index("function PrepareToInstall")]
        self.assertIn("try", record)
        self.assertIn("except", record)
        self.assertNotIn("Result :=", record)


if __name__ == "__main__":
    unittest.main()
