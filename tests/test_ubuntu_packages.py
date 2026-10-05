"""No-network policy/transaction tests for the opt-in Ubuntu package helper."""

import importlib.util
import io
from pathlib import Path
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fastllm_ubuntu_packages_test", ROOT / "linux" / "ubuntu_packages.py")
packages = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(packages)

OFFICIAL = b"""Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
"""


class UbuntuPackageTests(unittest.TestCase):
    def test_fixed_manifest_package_map_and_public_execution_disabled(self):
        asset = packages.runtime.load_asset()
        self.assertEqual(set(asset["externalNeeded"]), packages.EXPECTED_LIBRARIES)
        self.assertEqual(asset["executionEnabled"], False)
        self.assertEqual(packages.PACKAGE_BY_LIBRARY["libgomp.so.1"], "libgomp1")
        self.assertEqual(packages.PACKAGE_BY_LIBRARY["libvulkan.so.1"], "libvulkan1")
        self.assertEqual(packages.NEVER_INSTALL, {"libc6"})
        self.assertNotIn("mesa-vulkan-drivers", packages.PACKAGES)
        self.assertTrue(packages.INSTALL_ENABLED)

    def test_source_accepts_official_noble_only_and_rejects_trust_changes(self):
        self.assertEqual(len(packages._source_stanzas(OFFICIAL)), 2)
        with_comments = (b"# Ubuntu stock comment paragraph\n# More instructions\n\n" +
                         OFFICIAL.replace(b"\n\nTypes: deb\n", b"\n\n# Security notes\n\nTypes: deb\n"))
        self.assertEqual(len(packages._source_stanzas(with_comments)), 2)
        changes = (
            (b"http://archive.ubuntu.com/ubuntu", b"http://ppa.example/ubuntu"),
            (b"noble-security", b"noble-proposed"),
            (b"Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg", b"Trusted: yes"),
            (b"Types: deb", b"Types: deb deb-src"),
            (b"Components: main", b"Components: universe"),
            (b"noble noble-updates noble-backports", b"noble noble-updates noble-proposed"),
            (b"noble noble-updates noble-backports", b"noble noble-backports"),
        )
        for old, new in changes:
            with self.subTest(change=new):
                with self.assertRaises(packages.PackageError):
                    packages._source_stanzas(OFFICIAL.replace(old, new, 1))
        with self.assertRaises(packages.PackageError):
            packages._source_stanzas(OFFICIAL + b"\nTrusted: yes\n")

    def test_apt_argv_is_fixed_but_ambient_hooks_are_not_isolated(self):
        argv = packages._apt(("--no-remove", "--no-install-recommends", "--no-upgrade", "install", "libgomp1=14.2.0"))
        self.assertEqual(argv[0], "/usr/bin/apt-get")
        self.assertIn("Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources", argv)
        for setting in ("Dir::Etc::sourceparts=-",
                        "Dir::Etc::preferences=/dev/null", "Dir::Etc::preferencesparts=-",
                        "APT::Get::AllowUnauthenticated=false"):
            self.assertIn(setting, argv)
        self.assertEqual(argv[-5:], ["--no-remove", "--no-install-recommends", "--no-upgrade", "install", "libgomp1=14.2.0"])

    def test_advisory_hook_inventory_exposes_identifiers_and_checks_guards(self):
        dump = ('Dir::Etc::sourcelist "/etc/apt/sources.list.d/ubuntu.sources";\n'
                'Dir::Etc::sourceparts "-";\nDir::Etc::preferences "/dev/null";\n'
                'Dir::Etc::preferencesparts "-";\nAPT::Get::AllowUnauthenticated "0";\n'
                'Acquire::AllowInsecureRepositories "0";\n'
                'APT::Update::Pre-Invoke:: "secret command";\n'
                'DPkg::Pre-Invoke:: "another secret";\n')
        with mock.patch.object(packages, "_trusted_root_dir"), \
             mock.patch.object(packages.APT_CONF_D.__class__, "iterdir", return_value=[packages.APT_CONF_D / "99test"]), \
             mock.patch.object(packages, "_trusted_root_file", return_value=b'APT::Update::Pre-Invoke { "secret command"; };'), \
             mock.patch.object(packages, "_bounded_command", return_value=(0, dump)):
            report = packages.apt_configuration()
        self.assertEqual(report["effectiveHookIdentifiers"], ["APT::Update::Pre-Invoke", "DPkg::Pre-Invoke"])
        self.assertNotIn("secret", repr(report))
        with mock.patch.object(packages, "_trusted_root_dir"), \
             mock.patch.object(packages.APT_CONF_D.__class__, "iterdir", return_value=[packages.APT_CONF_D / "docker-clean"]), \
             mock.patch.object(packages, "_trusted_root_file", return_value=b'Dir::Cache::pkgcache ""; Dir::Cache::srcpkgcache "";'), \
             mock.patch.object(packages, "_bounded_command", return_value=(0, dump)):
            self.assertEqual(packages.apt_configuration()["effectiveHookIdentifiers"], report["effectiveHookIdentifiers"])
        with mock.patch.object(packages, "_trusted_root_dir"), \
             mock.patch.object(packages.APT_CONF_D.__class__, "iterdir", return_value=[packages.APT_CONF_D / "99test"]), \
             mock.patch.object(packages, "_trusted_root_file", return_value=b'#include "/tmp/unsafe"'), \
             mock.patch.object(packages, "_bounded_command", return_value=(0, dump)):
            with self.assertRaises(packages.PackageError):
                packages.apt_configuration()
        with mock.patch.object(packages, "_trusted_root_dir"), \
             mock.patch.object(packages.APT_CONF_D.__class__, "iterdir", return_value=[packages.APT_CONF_D / "99test"]), \
             mock.patch.object(packages, "_trusted_root_file", return_value=b'Dir::Bin::dpkg "/tmp/fake-dpkg";'), \
             mock.patch.object(packages, "_bounded_command", return_value=(0, dump)):
            with self.assertRaises(packages.PackageError):
                packages.apt_configuration()
        with mock.patch.object(packages, "_trusted_root_dir"), \
             mock.patch.object(packages.APT_CONF_D.__class__, "iterdir", return_value=[packages.APT_CONF_D / "99test"]), \
             mock.patch.object(packages, "_trusted_root_file", return_value=b'APT::Update::Pre-Invoke { "secret command"; };'), \
             mock.patch.object(packages, "_bounded_command", return_value=(0, dump.replace('sourcelist "', 'sourcelist "/tmp/'))):
            with self.assertRaises(packages.PackageError):
                packages.apt_configuration()

    def test_simulation_requires_exact_missing_versions_and_nothing_else(self):
        good = "Inst libgomp1 (14.2.0-4ubuntu2~24.04.1 Ubuntu:24.04/noble-updates [amd64])\nConf libgomp1 (14.2.0-4ubuntu2~24.04.1 Ubuntu:24.04/noble-updates [amd64])\n"
        wanted = {"libgomp1": "14.2.0-4ubuntu2~24.04.1"}
        packages._parse_simulation(good, wanted)
        for bad in (good + "Inst libc6 (2.40 Ubuntu:24.04/noble-updates [amd64])\n",
                    good + "Remv mesa-vulkan-drivers [1]\n",
                    good.replace("14.2.0-4ubuntu2~24.04.1", "14.3.0", 1),
                    good.replace("Conf libgomp1", "Conf libvulkan1"),
                    "Inst libgomp1 (14.2.0-4ubuntu2~24.04.1 Ubuntu:24.04/noble-updates [amd64])\n"):
            with self.subTest(bad=bad):
                with self.assertRaises(packages.PackageError):
                    packages._parse_simulation(bad, wanted)

    def test_candidate_requires_official_noble_main_origin(self):
        good = """libgomp1:
  Installed: (none)
  Candidate: 14.2.0-4ubuntu2~24.04.1
  Version table:
     14.2.0-4ubuntu2~24.04.1 500
        500 http://archive.ubuntu.com/ubuntu noble-updates/main amd64 Packages
        500 http://security.ubuntu.com/ubuntu noble-security/main amd64 Packages
"""
        with mock.patch.object(packages, "_bounded_command", return_value=(0, good)):
            self.assertEqual(packages._candidate_version("libgomp1"), "14.2.0-4ubuntu2~24.04.1")
        for bad in (good.replace("archive.ubuntu.com", "ppa.example"),
                    good + "        500 file:/tmp/packages noble-updates/main amd64 Packages\n",
                    good.replace("noble-updates/main", "noble-backports/main"),
                    good.replace("noble-updates/main", "noble-updates/universe"),
                    good.replace("Candidate: 14.2.0-4ubuntu2~24.04.1", "Candidate: (none)")):
            with mock.patch.object(packages, "_bounded_command", return_value=(0, bad)):
                with self.assertRaises(packages.PackageError):
                    packages._candidate_version("libgomp1")

    def test_check_never_uses_sudo_and_rejects_missing_libc(self):
        asset = packages.runtime.load_asset()
        state = {name: "1.0" for name in packages.PACKAGES}
        state["libgomp1"] = None
        with mock.patch.object(packages, "_host_and_stage", return_value=asset), \
             mock.patch.object(packages, "official_sources", return_value="a" * 64), \
             mock.patch.object(packages, "apt_configuration", return_value={"rootConfigSha256": "d" * 64, "effectiveHookIdentifiers": ["DPkg::Pre-Invoke"]}), \
             mock.patch.object(packages, "installed_packages", return_value=state), \
             mock.patch.object(packages, "_sudo_apt") as sudo:
            result = packages.check("/never-used")
            self.assertEqual(result["missing"], ["libgomp1"])
            self.assertFalse(result["executionEnabled"])
            self.assertTrue(result["systemPackageInstallEnabled"])
            sudo.assert_not_called()
            state["libc6"] = None
            with self.assertRaises(packages.PackageError):
                packages.check("/never-used")

    def test_install_requires_two_confirmations_and_exact_simulation(self):
        before = {"schemaVersion": 1, "labOnly": True, "executionEnabled": False,
                  "systemPackageInstallEnabled": True,
                  "candidateSha256": "a" * 64, "manifestSha256": "b" * 64,
                  "officialSourceSha256": "c" * 64,
                  "rootConfigSha256": "d" * 64, "effectiveHookIdentifiers": ["DPkg::Pre-Invoke"],
                  "installed": {name: (None if name == "libgomp1" else "1.0") for name in packages.PACKAGES},
                  "missing": ["libgomp1"], "driverInstalled": False, "compatibilityVerified": False}
        after = dict(before, installed=dict(before["installed"], libgomp1="14.2.0"), missing=[])
        state = [before, before, before, before, after]
        simulated = "Inst libgomp1 (14.2.0 Ubuntu:24.04/noble-updates [amd64])\nConf libgomp1 (14.2.0 Ubuntu:24.04/noble-updates [amd64])\n"
        confirmations = []
        def accept(prompt):
            confirmations.append(prompt)
            return "UPDATE OFFICIAL UBUNTU INDEXES" if len(confirmations) == 1 else "INSTALL " + prompt.split("INSTALL ")[1].split(" ")[0]
        with mock.patch.object(packages, "check", side_effect=lambda stage: state.pop(0)), \
             mock.patch.object(packages, "official_sources", return_value="c" * 64), \
             mock.patch.object(packages, "_candidate_version", return_value="14.2.0"), \
             mock.patch.object(packages, "_bounded_command", return_value=(0, simulated)), \
             mock.patch.object(packages, "_sudo_apt") as sudo, \
             mock.patch("sys.stdout", new_callable=io.StringIO):
            result = packages.install("/never-used", confirm=accept)
        self.assertTrue(result["changed"])
        self.assertEqual(len(confirmations), 2)
        self.assertEqual(sudo.call_count, 2)
        self.assertEqual(sudo.call_args_list[0].args[0], ("update", "--error-on=any"))
        self.assertEqual(sudo.call_args_list[1].args[0][-1], "libgomp1=14.2.0")

    def test_changed_root_config_before_first_sudo_refuses_transaction(self):
        before = {"missing": ["libgomp1"], "rootConfigSha256": "a" * 64,
                  "effectiveHookIdentifiers": ["APT::Update::Pre-Invoke"],
                  "officialSourceSha256": "b" * 64}
        changed = dict(before, rootConfigSha256="c" * 64)
        with mock.patch.object(packages, "check", side_effect=[before, changed]), \
             mock.patch.object(packages, "_sudo_apt") as sudo, \
             mock.patch("sys.stdout", new_callable=io.StringIO):
            with self.assertRaisesRegex(packages.PackageError, "changed before index refresh"):
                packages.install("/never-used", confirm=lambda prompt: "UPDATE OFFICIAL UBUNTU INDEXES")
        sudo.assert_not_called()

    def test_cli_never_elevates_without_explicit_install_opt_in(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO), mock.patch.object(packages, "_sudo_apt") as sudo:
            with self.assertRaises(SystemExit) as missing:
                packages.main(["install", "--stage", "/x"])
            self.assertEqual(missing.exception.code, 2)
            with self.assertRaises(SystemExit) as invalid:
                packages.main(["check", "--stage", "/x", "--accept-system-packages"])
            self.assertEqual(invalid.exception.code, 2)
            sudo.assert_not_called()


if __name__ == "__main__":
    unittest.main()
