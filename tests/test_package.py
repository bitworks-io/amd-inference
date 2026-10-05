import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from tools.verify_lab_package import verify, verify_setup


class LabPackageTests(unittest.TestCase):
    def test_lab_builder_includes_driver_guidance_catalog(self):
        builder = (Path(__file__).resolve().parents[1] / 'tools/build-lab-package.ps1').read_text()
        self.assertIn("'config/driver-guidance.json'", builder)
        self.assertIn("'tools/collect-prerequisite-inventory.ps1'", builder)
        self.assertIn("'config/windows-prerequisites.json'", builder)
        self.assertIn("'tools/prepare-vc-runtime.ps1'", builder)
        self.assertIn("'tools/install-vc-runtime.ps1'", builder)
        self.assertIn("'Install-FastLLM-Lab.cmd'", builder)
        self.assertIn("'tools/install-lab-app.ps1'", builder)
        self.assertIn("'src/FastLlm.LabApp.ps1'", builder)
        self.assertIn("'tools/lab-setup-README.md'", builder)
        self.assertIn("'unsigned-private-windows-lab-setup'", builder)
        self.assertIn("'SETUP-MANIFEST.json'", builder)

    def test_builder_writes_portable_zip_member_names_on_windows(self):
        builder = (Path(__file__).resolve().parents[1] / 'tools/build-lab-package.ps1').read_text()
        self.assertIn('[IO.Compression.ZipFileExtensions]::CreateEntryFromFile(', builder)
        self.assertIn(".Replace('\\','/')", builder)
        self.assertIn('New-FastLlmPortableSourceZip -SourceRoot $stage -ArchivePath $archive', builder)
        self.assertIn('New-FastLlmPortableSourceZip -SourceRoot $setupStage -ArchivePath $setupArchive', builder)
        self.assertNotIn('[IO.Compression.ZipFile]::CreateFromDirectory(', builder)

    def test_private_diagnostics_include_worker_and_manifest_companions(self):
        builder = (Path(__file__).resolve().parents[1] / 'tools/build-lab-package.ps1').read_text()
        for path in ('tools/collect-ggml-vulkan-identity.ps1',
                     'tools/collect-ggml-vulkan-capabilities.ps1',
                     'tools/collect-pci-identity-join.ps1', 'tools/semantic-smoke.ps1',
                     'tools/collect-windows-vulkan-pnp-bridge.ps1',
                     'tools/collect-vulkan-driver-modules.ps1',
                     'tools/collect-smbios-memory.ps1',
                     'tools/vulkan-coopmat-screen.ps1',
                     'tools/offload-lab.ps1', 'tools/offload-benchmark.ps1',
                     'tools/probe-lemonade-hip-b1339.ps1',
                     'tools/hip-candidate-native-worker.ps1',
                     'tools/hip-model-trial.ps1', 'tools/hip-benchmark.ps1',
                     'tools/hip-semantic-smoke.ps1', 'tools/hip-soak.ps1',
                     'tools/vulkan-fit-trial.ps1', 'tools/vulkan-fit-benchmark.ps1',
                     'config/experiments/lemonade-hip-b1339-gfx110x.json'):
            with self.subTest(path=path):
                self.assertIn(repr(path), builder)

        self.assertIn("foreach($directory in @('src','docs'))", builder)
        self.assertIn("@('.ps1','.psm1','.cs')", builder)
        self.assertTrue((Path(__file__).resolve().parents[1] / 'src/FastLlm.VulkanModuleBinding.ps1').is_file())
        self.assertTrue((Path(__file__).resolve().parents[1] / 'src/WindowsSmbiosMemory.cs').is_file())

    def make_package(self, path, extra=None, changed=None, promoted=False):
        payload = b'@echo off\r\n'
        manifest = {
            'schemaVersion': 1, 'kind': 'unsigned-private-windows-lab-package',
            'physicalQualification': False, 'publicReleaseApproved': promoted,
            'files': [{'path': 'FastLLM.cmd', 'sizeBytes': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()}],
        }
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('FastLLM.cmd', changed or payload)
            archive.writestr('PACKAGE-MANIFEST.json', json.dumps(manifest))
            if extra:
                archive.writestr(extra, 'unexpected')

    def test_integrity_is_not_publisher_or_gpu_qualification(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'lab.zip'
            self.make_package(path)
            result = verify(path)
            self.assertEqual(1, result['verifiedFiles'])
            self.assertFalse(result['publicReleaseApproved'])
            self.assertFalse(result['publisherAuthenticated'])

    def test_rejects_changed_undeclared_or_unsafe_contents(self):
        for options in ({'changed': b'changed'}, {'extra': 'secret.json'}, {'extra': '../escape.md'},
                        {'extra': 'fastllm.CMD'}, {'extra': 'model.gguf'}, {'promoted': True}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'lab.zip'
                self.make_package(path, **options)
                with self.assertRaises(ValueError):
                    verify(path)

    def make_setup(self, path, omitted=None, extra=None, changed=None, promoted=False,
                   publisher_authenticated=False, digest_included=False, include_csharp=False):
        contents = {
            'Install-FastLLM-Lab.cmd': b'@echo off\r\n',
            'tools/install-lab-app.ps1': b'# private lab UI\r\n',
            'src/FastLlm.LabApp.ps1': b'# private lab helper\r\n',
            'README-SETUP.md': b'Unsigned source; trust separately.\n',
        }
        if include_csharp:
            contents['src/LabPackage.cs'] = b'// private lab helper\n'
        if omitted:
            del contents[omitted]
        manifest = {
            'schemaVersion': 1, 'kind': 'unsigned-private-windows-lab-setup',
            'physicalQualification': False, 'publicReleaseApproved': promoted,
            'publisherAuthenticated': publisher_authenticated, 'appZipDigestIncluded': digest_included,
            'files': [{'path': name, 'sizeBytes': len(payload), 'sha256': hashlib.sha256(payload).hexdigest()}
                      for name, payload in contents.items()],
        }
        with zipfile.ZipFile(path, 'w') as archive:
            for name, payload in contents.items():
                archive.writestr(name, b'changed' if changed == name else payload)
            if extra:
                archive.writestr(extra, b'unexpected')
            archive.writestr('SETUP-MANIFEST.json', json.dumps(manifest))

    def test_setup_bundle_exact_sources_are_integrity_only(self):
        for include_csharp in (False, True):
            with self.subTest(include_csharp=include_csharp), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'lab-setup.zip'
                self.make_setup(path, include_csharp=include_csharp)
                result = verify_setup(path)
                self.assertEqual(5 if include_csharp else 4, result['verifiedFiles'])
                self.assertFalse(result['publisherAuthenticated'])
                self.assertFalse(result['publicReleaseApproved'])

    def test_setup_rejects_omissions_extras_mutation_and_promotion(self):
        for options in (
            {'omitted': 'src/FastLlm.LabApp.ps1'},
            {'extra': 'README.md'},
            {'extra': '../escape.md'},
            {'extra': 'tools\\unsafe.ps1'},
            {'changed': 'tools/install-lab-app.ps1'},
            {'promoted': True},
            {'publisher_authenticated': True},
            {'digest_included': True},
        ):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'lab-setup.zip'
                self.make_setup(path, **options)
                with self.assertRaises((ValueError, KeyError)):
                    verify_setup(path)


if __name__ == '__main__':
    unittest.main()
