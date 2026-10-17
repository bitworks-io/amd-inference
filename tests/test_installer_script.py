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


if __name__ == "__main__":
    unittest.main()
