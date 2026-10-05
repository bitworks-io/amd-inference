import copy
import unittest
from tools.compare_benchmarks import compare


def record(rate=32):
    return {
        'schemaVersion': 1, 'resultKind': 'native-windows-api-benchmark-not-full-qualification',
        'modelId': 'synthetic-model', 'modelSha256': 'a' * 64, 'engineVersion': 'synthetic-engine',
        'os': 'synthetic-windows', 'powerPlan': 'test', 'processorCount': 8,
        'recipe': {'catalogSha256': 'b' * 64, 'engineSha256': 'c' * 64, 'backend': 'Vulkan',
                   'contextSize': 4096, 'slots': 1, 'cacheTypeK': 'f16', 'cacheTypeV': 'f16',
                   'speculation': 'none', 'flashAttention': 'auto', 'splitMode': 'none', 'tensorSplit': None,
                   'requestedArguments': ['--model', '<verified-model>', '--n-gpu-layers', 'all',
                                          '--ctx-size', '4096', '--parallel', '1', '--cache-type-k', 'f16',
                                          '--cache-type-v', 'f16', '--flash-attn', 'auto', '--split-mode', 'none',
                                          '--spec-type', 'none', '--fit', 'on', '--device', 'Vulkan0'],
                   'adapters': [{'device': 'Vulkan0', 'name': 'test GPU', 'vramMiB': 24576,
                                 'driverVersion': 'test', 'backend': 'Vulkan'}]},
        'placement': {'reportedLayers': 41, 'totalLayers': 41, 'reportedAllLayers': True,
                      'devices': ['Vulkan0']},
        'canary': {'modelIdentity': True, 'effectiveContext': 4096},
        'windowsInventory': {
            'processors': [{'Name': 'Synthetic CPU', 'NumberOfCores': 4,
                            'NumberOfLogicalProcessors': 8}],
            'system': {'Manufacturer': 'Synthetic', 'Model': 'Bench',
                       'TotalPhysicalMemory': 32_000_000_000},
            'os': {'Version': '10.0.26200', 'BuildNumber': '26200', 'OSArchitecture': '64-bit'},
        },
        'methodology': {'repetitions': 5, 'generationTokens': 128, 'corpus': 'test', 'sampling': 'greedy', 'prefixCache': False, 'concurrency': 1, 'warmupPerPrompt': 1, 'randomizedPromptOrder': True},
        'samples': [{'requestedPromptTokens': 512, 'promptTokens': 512, 'repetition': i, 'outputTokens': 128, 'promptTokensPerSecond': 500, 'generationTokensPerSecond': rate, 'timeToFirstTextMs': 1000, 'completionMs': 5000} for i in range(1, 6)],
    }


def identified(rate=32, digest='a' * 64):
    result = record(rate)
    result['methodology']['promptArtifacts'] = [{
        'requestedPromptTokens': 512, 'tokenCount': 512,
        'sha256': digest, 'format': 'fastllm-prompt-tokens-v1',
    }]
    for sample in result['samples']:
        sample['promptArtifactSha256'] = digest
    return result


def native_host():
    return {
        'schemaVersion': 1, 'kind': 'windows-native-host-inventory',
        'qualified': False, 'status': 'captured',
        'physicalMemoryBytes': {'value': 32_000_000_000,
                                'source': 'GlobalMemoryStatusEx.ullTotalPhys', 'status': 'captured'},
        'activeLogicalProcessors': {'value': 8,
                                    'source': 'GetActiveProcessorCount.ALL_PROCESSOR_GROUPS',
                                    'status': 'captured'},
        'os': {'major': 10, 'minor': 0, 'build': 26200, 'ubr': 9168, 'architecture': 'x64',
               'versionSource': 'RtlGetVersion', 'ubrSource': 'HKLM.CurrentVersion.UBR',
               'architectureSource': 'GetNativeSystemInfo', 'status': 'captured'},
        'advisory': {
            'cpuNames': {'value': ['Synthetic CPU'], 'source': 'HKLM.HARDWARE.CentralProcessor.ProcessorNameString',
                         'status': 'captured', 'enumeratedKeys': 1, 'scanLimit': 256, 'completeScan': True},
            'systemManufacturer': {'value': 'Synthetic', 'source': 'HKLM.HARDWARE.System.BIOS.SystemManufacturer',
                                   'status': 'captured'},
            'systemProductName': {'value': 'Bench', 'source': 'HKLM.HARDWARE.System.BIOS.SystemProductName',
                                  'status': 'captured'},
        },
    }


class BenchmarkComparisonTests(unittest.TestCase):
    def test_both_missing_or_partial_legacy_host_sections_rejected(self):
        for section in ('processors', 'system', 'os'):
            with self.subTest(section=section):
                left, right = record(), record()
                left['windowsInventory'][section] = None
                right['windowsInventory'][section] = None
                with self.assertRaisesRegex(ValueError, 'legacy Windows host inventory'):
                    compare(left, right)
        left, right = record(), record()
        left.pop('windowsInventory')
        right.pop('windowsInventory')
        with self.assertRaisesRegex(ValueError, 'Windows host inventory'):
            compare(left, right)
        left, right = record(), record()
        right['windowsInventory']['system']['TotalPhysicalMemory'] += 4096
        with self.assertRaisesRegex(ValueError, 'host identity differs'):
            compare(left, right)

    def test_native_host_complete_provenance_and_stable_fields(self):
        left, right = record(), record(40)
        left['windowsInventory']['nativeHost'] = native_host()
        right['windowsInventory']['nativeHost'] = native_host()
        compared = compare(left, right)
        self.assertFalse(compared['qualificationApproved'])
        self.assertEqual('native-host-v1', compared['hostInventoryProvenance'])
        right['windowsInventory']['nativeHost']['physicalMemoryBytes']['value'] += 4096
        with self.assertRaisesRegex(ValueError, 'host identity differs'):
            compare(left, right)
        right['windowsInventory']['nativeHost']['physicalMemoryBytes']['value'] -= 4096
        right['windowsInventory']['nativeHost']['advisory']['cpuNames']['value'] = ['Other CPU name']
        with self.assertRaisesRegex(ValueError, 'host identity differs'):
            compare(left, right)
        right['windowsInventory']['nativeHost']['advisory']['cpuNames']['value'] = ['Synthetic CPU']
        right['windowsInventory']['nativeHost']['advisory']['systemManufacturer']['value'] = 'Other board'
        with self.assertRaisesRegex(ValueError, 'host identity differs'):
            compare(left, right)
        right['windowsInventory']['nativeHost']['advisory']['systemManufacturer'].update(value=None, status='unavailable')
        with self.assertRaisesRegex(ValueError, 'host identity differs'):
            compare(left, right)
        right['windowsInventory']['nativeHost']['advisory']['systemManufacturer'].update(value='Synthetic', status='captured')
        for field, value in (('build', 26201), ('ubr', 9169), ('architecture', 'arm64')):
            with self.subTest(field=field):
                candidate = copy.deepcopy(right)
                candidate['windowsInventory']['nativeHost']['os'][field] = value
                with self.assertRaisesRegex(ValueError, 'host identity differs'):
                    compare(left, candidate)
        candidate = copy.deepcopy(right)
        candidate['windowsInventory']['nativeHost']['activeLogicalProcessors']['value'] = 16
        with self.assertRaisesRegex(ValueError, 'host identity differs'):
            compare(left, candidate)
        candidate = copy.deepcopy(right)
        candidate['windowsInventory']['nativeHost']['advisory']['systemManufacturer'].update(value=None, status='unavailable')
        left['windowsInventory']['nativeHost']['advisory']['systemManufacturer'].update(value=None, status='unavailable')
        self.assertFalse(compare(left, candidate)['qualificationApproved'])

    def test_partial_native_host_and_mixed_provenance_rejected(self):
        left, right = record(), record()
        left['windowsInventory']['nativeHost'] = native_host()
        with self.assertRaisesRegex(ValueError, 'legacy and native'):
            compare(left, right)
        both_partial = copy.deepcopy(left)
        both_partial['windowsInventory']['nativeHost']['status'] = 'partial'
        with self.assertRaisesRegex(ValueError, 'incomplete recorded native'):
            compare(both_partial, copy.deepcopy(both_partial))
        for change in (
            lambda h: h.update(status='partial'),
            lambda h: h['physicalMemoryBytes'].update(value=None, status='unavailable'),
            lambda h: h['activeLogicalProcessors'].update(value=None),
            lambda h: h['os'].update(ubr=None, status='partial'),
            lambda h: h['os'].update(architectureSource='unknown'),
            lambda h: h['advisory']['cpuNames'].update(value=[], status='unavailable'),
            lambda h: h['advisory']['cpuNames'].update(source='unknown'),
            lambda h: h['advisory']['cpuNames'].update(completeScan=False),
            lambda h: h['advisory']['cpuNames'].update(enumeratedKeys=0),
            lambda h: h['advisory']['cpuNames'].update(enumeratedKeys=257),
            lambda h: h['advisory']['cpuNames'].update(scanLimit=16),
            lambda h: h['advisory']['systemProductName'].update(value=None, status='captured'),
        ):
            with self.subTest(change=change):
                candidate = copy.deepcopy(left)
                change(candidate['windowsInventory']['nativeHost'])
                with self.assertRaises(ValueError):
                    compare(left, candidate)

    def test_measured_delta_is_not_qualification(self):
        result = compare(record(), record(40))
        self.assertEqual(25, result['comparisons'][0]['generationTokensPerSecond']['changePercent'])
        self.assertFalse(result['qualificationApproved'])
        self.assertEqual('legacy-cim', result['hostInventoryProvenance'])
        self.assertFalse(result['promptIdentityVerified'])

    def test_missing_driver_version_still_rejected_even_with_native_host(self):
        left, right = record(), record()
        for report in (left, right):
            report['recipe']['adapters'][0]['driverVersion'] = None
            report['windowsInventory']['nativeHost'] = native_host()
        with self.assertRaisesRegex(ValueError, 'adapter identity or memory'):
            compare(left, right)

    def test_matching_prompt_artifacts_verify_identity_without_qualification(self):
        result = compare(identified(), identified(40))
        self.assertTrue(result['promptIdentityVerified'])
        self.assertFalse(result['qualificationApproved'])

    def test_one_sided_or_different_prompt_artifacts_rejected(self):
        with self.assertRaisesRegex(ValueError, 'one prompt-identified'):
            compare(record(), identified())
        with self.assertRaisesRegex(ValueError, 'Prompt token artifacts differ'):
            compare(identified(), identified(digest='b' * 64))

    def test_inconsistent_prompt_artifact_metadata_rejected(self):
        changes = [
            lambda r: r['methodology'].update(promptArtifacts=None),
            lambda r: r['methodology'].update(promptArtifacts=[]),
            lambda r: r['methodology']['promptArtifacts'].append(dict(r['methodology']['promptArtifacts'][0])),
            lambda r: r['methodology']['promptArtifacts'][0].update(tokenCount=511),
            lambda r: r['methodology']['promptArtifacts'][0].update(sha256='z' * 64),
            lambda r: r['samples'][0].update(promptArtifactSha256='b' * 64),
            lambda r: r['samples'][0].pop('promptArtifactSha256'),
        ]
        for change in changes:
            with self.subTest(change=change):
                candidate = identified()
                change(candidate)
                with self.assertRaises(ValueError):
                    compare(identified(), candidate)
        legacy = record()
        legacy['samples'][0]['promptArtifactSha256'] = 'a' * 64
        with self.assertRaisesRegex(ValueError, 'without prompt artifact map'):
            compare(record(), legacy)

    def test_rejects_confounded_or_incomplete_measurements(self):
        changes = [
            lambda r: r.update(modelSha256='b' * 64),
            lambda r: r.update(os='other'),
            lambda r: r['methodology'].update(prefixCache=True),
            lambda r: r['recipe'].update(contextSize=8192),
            lambda r: r['recipe']['adapters'][0].update(driverVersion='other'),
            lambda r: r['samples'][0].update(generationTokensPerSecond=float('nan')),
            lambda r: r['samples'][0].update(outputTokens=64),
            lambda r: r['samples'][0].update(repetition=2),
            lambda r: r['samples'][0].update(promptTokens=1),
            lambda r: r['samples'][0].update(promptTokens=513),
            lambda r: r.update(modelSha256='z' * 64),
            lambda r: r.update(processorCount=16),
            lambda r: r.update(windowsInventory={'system': {'TotalPhysicalMemory': 128}}),
        ]
        for change in changes:
            with self.subTest(change=change):
                candidate = copy.deepcopy(record())
                change(candidate)
                with self.assertRaises(ValueError):
                    compare(record(), candidate)

    def test_mixed_evaluated_prompt_counts_rejected_within_one_group(self):
        candidate = identified()
        candidate['samples'][0]['promptTokens'] = 513
        with self.assertRaisesRegex(ValueError, 'count changed within'):
            compare(identified(), candidate)

    def test_strict_configuration_changes_rejected_with_field_messages(self):
        changes = [
            ('engineVersion', lambda r: r.update(engineVersion='other')),
            ('recipe.catalogSha256', lambda r: r['recipe'].update(catalogSha256='d' * 64)),
            ('recipe.engineSha256', lambda r: r['recipe'].update(engineSha256='d' * 64)),
            ('recipe.backend', lambda r: (r['recipe'].update(backend='ROCm'),
                                         r['recipe']['adapters'][0].update(backend='ROCm'))),
            ('recipe.cacheTypeK', lambda r: (r['recipe'].update(cacheTypeK='q8_0'),
                                            r['recipe']['requestedArguments'].__setitem__(
                                                r['recipe']['requestedArguments'].index('--cache-type-k') + 1,
                                                'q8_0'))),
            ('recipe.tensorSplit', lambda r: r['recipe'].update(tensorSplit='1,1')),
            ('recipe.requestedArguments', lambda r: r['recipe']['requestedArguments'].extend(['--threads', '4'])),
            ('recipe.requestedArguments', lambda r: r['recipe']['requestedArguments'].__setitem__(
                r['recipe']['requestedArguments'].index('--fit') + 1, 'off')),
            ('placement.reportedLayers', lambda r: (r['placement'].update(totalLayers=42),
                                                    r['placement'].update(reportedLayers=42))),
        ]
        for field, change in changes:
            with self.subTest(field=field, change=change):
                candidate = record()
                change(candidate)
                with self.assertRaisesRegex(ValueError, field.replace('.', r'\.')):
                    compare(record(), candidate)

    def test_inconsistent_or_missing_configuration_rejected(self):
        changes = [
            lambda r: r['recipe'].pop('engineSha256'),
            lambda r: r['recipe'].update(catalogSha256='invalid'),
            lambda r: r['recipe'].update(cacheTypeV=''),
            lambda r: r['recipe']['requestedArguments'].__setitem__(
                r['recipe']['requestedArguments'].index('--n-gpu-layers') + 1, '20'),
            lambda r: r['recipe']['requestedArguments'].__setitem__(
                r['recipe']['requestedArguments'].index('--device') + 1, 'Vulkan1'),
            lambda r: r['recipe']['adapters'][0].update(backend='ROCm'),
            lambda r: r['placement'].update(reportedLayers=40),
            lambda r: r['placement'].update(devices=['Vulkan1']),
            lambda r: r['canary'].update(effectiveContext=2048),
            lambda r: r.pop('canary'),
            lambda r: r['methodology'].pop('randomizedPromptOrder'),
        ]
        for change in changes:
            with self.subTest(change=change):
                candidate = record()
                change(candidate)
                with self.assertRaises(ValueError):
                    compare(record(), candidate)


if __name__ == '__main__':
    unittest.main()
