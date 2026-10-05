"""Synthetic contract fixtures. These are not hardware qualification evidence."""

import copy
import hashlib
import json
import statistics
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools import recipes
from tools.recipes import digest, select, validate_manifest


CATALOG_PATH = Path(__file__).resolve().parents[1] / 'config/catalog.json'
CATALOG_RAW = CATALOG_PATH.read_bytes()
CATALOG = json.loads(CATALOG_RAW)
CATALOG_SHA = hashlib.sha256(CATALOG_RAW).hexdigest()
ENGINE = CATALOG['engine']
MODEL = CATALOG['models'][0]
ENGINE_SHA = next(entry['sha256'] for entry in ENGINE['assets']['vulkan']['manifest']
                  if entry['path'] == ENGINE['assets']['vulkan']['entryPoint'])


class RecipeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.binding = {
            'os': 'windows', 'osBuild': 'synthetic-build', 'driverVersion': 'synthetic-driver',
            'engineVersion': ENGINE['version'], 'engineAssetSha256': ENGINE['assets']['vulkan']['sha256'],
            'engineSha256': ENGINE_SHA, 'engineBackend': 'Vulkan', 'modelId': MODEL['id'],
            'modelSha256': MODEL['sha256'], 'catalogSha256': CATALOG_SHA,
            'adapters': [{'pciId': 'synthetic-1002:744c', 'vramMiB': 24576,
                          'busId': 'synthetic-01:00.0', 'rootComplexId': 'synthetic-root',
                          'upstreamPort': 'synthetic-port', 'attachment': 'cpu',
                          'linkWidth': 16, 'linkGeneration': 4}],
            'topology': {'gpuLinks': [], 'peerToPeer': False},
            'workload': {'id': 'synthetic-512-128', 'promptTokens': 512, 'generationTokens': 128,
                         'concurrency': 1, 'sampling': 'greedy-seed42',
                         'corpus': 'synthetic-corpus', 'prefixCache': False,
                         'warmupPerPrompt': 1, 'randomizedPromptOrder': True,
                         'powerPlan': 'synthetic-power', 'processorCount': 8,
                         'systemFingerprint': digest({'synthetic': 'inventory'}),
                         'promptArtifactSha256': 'b' * 64},
        }
        self.recipe = {'placement': 'full-gpu', 'contextSize': 4096, 'slots': 1, 'gpuLayers': 'all',
                       'splitMode': 'none', 'tensorSplit': None, 'cacheTypeK': 'f16', 'cacheTypeV': 'f16',
                       'launchArgsSha256': digest(['--model', '<verified-model>', '--n-gpu-layers', 'all'])}

    def write(self, name, obj):
        raw = json.dumps(obj, sort_keys=True).encode()
        (self.root / name).write_bytes(raw)
        return {'path': name, 'sha256': hashlib.sha256(raw).hexdigest()}

    def fixture(self, state='reviewed', rate=40):
        samples = [{'requestedPromptTokens': 512, 'promptTokens': 512, 'outputTokens': 128,
                    'repetition': i, 'promptTokensPerSecond': 1000,
                    'generationTokensPerSecond': rate, 'timeToFirstTextMs': 200,
                    'completionMs': 3000,
                    'promptArtifactSha256': self.binding['workload']['promptArtifactSha256']} for i in range(1, 6)]
        benchmark = {
            'schemaVersion': 1, 'resultKind': 'native-windows-api-benchmark-not-full-qualification',
            'modelId': MODEL['id'], 'modelSha256': MODEL['sha256'], 'engineVersion': ENGINE['version'],
            'os': 'synthetic-build', 'powerPlan': 'synthetic-power', 'processorCount': 8,
            'windowsInventory': {'synthetic': 'inventory'},
            'recipe': {'catalogSha256': CATALOG_SHA, 'engineSha256': ENGINE_SHA, 'contextSize': 4096,
                       'slots': 1, 'backend': 'Vulkan', 'cacheTypeK': 'f16', 'cacheTypeV': 'f16',
                       'splitMode': 'none', 'tensorSplit': None,
                       'requestedArguments': ['--model', '<verified-model>', '--n-gpu-layers', 'all'],
                       'adapters': [{'driverVersion': 'synthetic-driver', 'vramMiB': 24576,
                                     'device': 'Vulkan0'}]},
            'methodology': {'repetitions': 5, 'generationTokens': 128, 'concurrency': 1,
                            'sampling': 'greedy-seed42', 'corpus': 'synthetic-corpus',
                            'prefixCache': False, 'warmupPerPrompt': 1,
                            'randomizedPromptOrder': True,
                            'promptArtifacts': [{'requestedPromptTokens': 512, 'tokenCount': 512,
                                                 'sha256': self.binding['workload']['promptArtifactSha256'],
                                                 'format': 'fastllm-prompt-tokens-v1'}]}, 'samples': samples,
        }
        if state == 'reviewed':
            benchmark['hardwareIdentity'] = {'adapters': self.binding['adapters'],
                                             'topology': self.binding['topology']}
            benchmark['placement'] = {'reportedLayers': 100, 'totalLayers': 100,
                                      'reportedAllLayers': True, 'devices': ['Vulkan0']}
        benchmark_ref = self.write(f'benchmark-{rate}.json', benchmark)
        metrics = {'promptTokensPerSecond': statistics.median(s['promptTokensPerSecond'] for s in samples),
                   'generationTokensPerSecond': rate, 'timeToFirstTextMs': 200,
                   'peakDedicatedVramMiB': [16000] if state == 'reviewed' else None}
        qualification_ref = None
        if state == 'reviewed':
            gates = {key: True for key in ('semanticReferencePassed', 'numericalReferencePassed',
                     'apiPassed', 'soakPassed', 'placementVerified', 'residencyVerified',
                     'peakVramMeasured', 'exclusiveWorkloadConfirmed')}
            gate_evidence = {gate: self.write(f'{gate}-{rate}.json', {
                'gate': gate, 'bindingSha256': digest(self.binding),
                'recipeSha256': digest(self.recipe), 'benchmarkSha256': benchmark_ref['sha256'],
                'observations': {'synthetic': 'test fixture; not hardware evidence'},
            }) for gate in gates}
            qualification_ref = self.write(f'qualification-{rate}.json', {
                'bindingSha256': digest(self.binding), 'recipeSha256': digest(self.recipe),
                'benchmarkSha256': benchmark_ref['sha256'], 'peakDedicatedVramMiB': [16000],
                'gates': gates, 'gateEvidence': gate_evidence,
            })
        return {'id': f'synthetic-{rate}', 'state': state, 'binding': copy.deepcopy(self.binding),
                'recipe': copy.deepcopy(self.recipe), 'metrics': metrics,
                'evidence': {'benchmark': benchmark_ref, 'qualification': qualification_ref}}

    def inventory(self):
        return dict(copy.deepcopy(self.binding), availableDedicatedVramMiB=[18000])

    def test_default_allowlist_is_empty_even_with_reviewed_flag(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture()]}
        validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)
        with self.assertRaisesRegex(ValueError, 'source-reviewed digest'):
            select(manifest, self.inventory(), self.root, CATALOG, CATALOG_SHA)

    def test_source_pinned_manifest_selects_fastest_same_tuple(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture(rate=40), self.fixture(rate=44)]}
        with patch.object(recipes, 'REVIEWED_MANIFEST_SHA256', frozenset({digest(manifest)})):
            result = select(manifest, self.inventory(), self.root, CATALOG, CATALOG_SHA)
        self.assertEqual(result['id'], 'synthetic-44')
        self.assertEqual(result['rankingBasis'], 'decode-throughput-median-only')

    def test_candidate_is_never_selected(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate', 50), self.fixture(rate=40)]}
        with patch.object(recipes, 'REVIEWED_MANIFEST_SHA256', frozenset({digest(manifest)})):
            result = select(manifest, self.inventory(), self.root, CATALOG, CATALOG_SHA)
        self.assertEqual(result['id'], 'synthetic-40')

    def test_stale_identity_and_fit_fail_closed(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture()]}
        trusted = frozenset({digest(manifest)})
        for field, value in [('driverVersion', 'new-driver'), ('engineSha256', 'b' * 64),
                             ('modelSha256', 'c' * 64), ('osBuild', 'new-os'),
                             ('topology', {'gpuLinks': [], 'peerToPeer': True}),
                             ('workload', dict(self.binding['workload'], promptTokens=4096))]:
            with self.subTest(field=field):
                current = self.inventory()
                current[field] = value
                with patch.object(recipes, 'REVIEWED_MANIFEST_SHA256', trusted):
                    with self.assertRaisesRegex(ValueError, 'No qualified recipe'):
                        select(manifest, current, self.root, CATALOG, CATALOG_SHA)
        current = self.inventory()
        current['availableDedicatedVramMiB'] = [16000]
        with patch.object(recipes, 'REVIEWED_MANIFEST_SHA256', trusted):
            with self.assertRaisesRegex(ValueError, 'No qualified recipe'):
                select(manifest, current, self.root, CATALOG, CATALOG_SHA)

    def test_evidence_and_catalog_tampering_rejected(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture()]}
        with self.assertRaisesRegex(ValueError, 'Stale catalog'):
            validate_manifest(manifest, self.root, CATALOG, 'f' * 64)
        (self.root / manifest['records'][0]['evidence']['benchmark']['path']).write_text('{}')
        with self.assertRaisesRegex(ValueError, 'Evidence digest changed'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)

    def test_qualification_gate_cannot_be_self_declared(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture()]}
        qpath = self.root / manifest['records'][0]['evidence']['qualification']['path']
        qualification = json.loads(qpath.read_text())
        qualification['gates']['semanticReferencePassed'] = False
        manifest['records'][0]['evidence']['qualification'] = self.write(qpath.name, qualification)
        with self.assertRaisesRegex(ValueError, 'gates incomplete'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)

    def test_linux_claim_cannot_reuse_windows_engine(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate')]}
        manifest['records'][0]['binding']['os'] = 'linux'
        with self.assertRaisesRegex(ValueError, 'Linux engine asset'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)

    def test_executable_must_match_catalog_entrypoint_digest(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate')]}
        manifest['records'][0]['binding']['engineSha256'] = 'f' * 64
        with self.assertRaisesRegex(ValueError, 'executable is not pinned'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)

    def test_reviewed_requires_benchmark_identity_and_prompt_provenance(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture()]}
        ref = manifest['records'][0]['evidence']['benchmark']
        benchmark = json.loads((self.root / ref['path']).read_text())
        benchmark.pop('hardwareIdentity')
        manifest['records'][0]['evidence']['benchmark'] = self.write(ref['path'], benchmark)
        with self.assertRaisesRegex(ValueError, 'authoritative PCI/topology'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)

    def test_reviewed_prompt_digest_is_required_and_bound_to_samples(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture()]}
        ref = manifest['records'][0]['evidence']['benchmark']
        benchmark = json.loads((self.root / ref['path']).read_text())
        benchmark['methodology'].pop('promptArtifacts')
        manifest['records'][0]['evidence']['benchmark'] = self.write(ref['path'], benchmark)
        with self.assertRaisesRegex(ValueError, 'prompt artifact map'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)
        manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate')]}
        ref = manifest['records'][0]['evidence']['benchmark']
        benchmark = json.loads((self.root / ref['path']).read_text())
        benchmark['samples'][0]['promptArtifactSha256'] = 'f' * 64
        manifest['records'][0]['evidence']['benchmark'] = self.write(ref['path'], benchmark)
        with self.assertRaisesRegex(ValueError, 'Sample prompt artifact digest differs'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)

    def test_multi_prompt_report_binds_only_selected_group(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate')]}
        ref = manifest['records'][0]['evidence']['benchmark']
        benchmark = json.loads((self.root / ref['path']).read_text())
        other_sha = 'c' * 64
        benchmark['methodology']['promptArtifacts'].append({
            'requestedPromptTokens': 4096, 'tokenCount': 4096,
            'sha256': other_sha, 'format': 'fastllm-prompt-tokens-v1',
        })
        benchmark['samples'].extend({
            'requestedPromptTokens': 4096, 'promptTokens': 4096, 'outputTokens': 128,
            'repetition': i, 'promptTokensPerSecond': 2000,
            'generationTokensPerSecond': 90, 'timeToFirstTextMs': 300,
            'completionMs': 4000, 'promptArtifactSha256': other_sha,
        } for i in range(1, 6))
        manifest['records'][0]['evidence']['benchmark'] = self.write(ref['path'], benchmark)
        validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)

    def test_recipe_rejects_mixed_evaluated_prompt_counts(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate')]}
        ref = manifest['records'][0]['evidence']['benchmark']
        benchmark = json.loads((self.root / ref['path']).read_text())
        benchmark['samples'][0]['promptTokens'] = 513
        manifest['records'][0]['evidence']['benchmark'] = self.write(ref['path'], benchmark)
        with self.assertRaisesRegex(ValueError, 'count changed within'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)

    def test_changed_corpus_and_duplicate_bus_rejected(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate')]}
        manifest['records'][0]['binding']['workload']['corpus'] = 'different-corpus'
        with self.assertRaisesRegex(ValueError, 'corpus differs'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)
        manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate')]}
        second = copy.deepcopy(manifest['records'][0]['binding']['adapters'][0])
        manifest['records'][0]['binding']['adapters'].append(second)
        with self.assertRaisesRegex(ValueError, 'Duplicate adapter bus'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)

    def test_gate_evidence_and_size_limit(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture()]}
        qref = manifest['records'][0]['evidence']['qualification']
        qualification = json.loads((self.root / qref['path']).read_text())
        qualification['gateEvidence'].pop('residencyVerified')
        manifest['records'][0]['evidence']['qualification'] = self.write(qref['path'], qualification)
        with self.assertRaisesRegex(ValueError, 'gate evidence'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)
        manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate')]}
        ref = manifest['records'][0]['evidence']['benchmark']
        oversized = b'x' * (recipes.MAX_JSON_BYTES + 1)
        (self.root / ref['path']).write_bytes(oversized)
        ref['sha256'] = hashlib.sha256(oversized).hexdigest()
        with self.assertRaisesRegex(ValueError, '8 MiB limit'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)

    def test_gpu_layer_and_placement_claims_match_launch_and_observation(self):
        manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate')]}
        manifest['records'][0]['recipe']['gpuLayers'] = 999999
        with self.assertRaisesRegex(ValueError, 'GPU layer request conflicts'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)
        manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate')]}
        ref = manifest['records'][0]['evidence']['benchmark']
        benchmark = json.loads((self.root / ref['path']).read_text())
        benchmark['placement'] = {'reportedLayers': 1, 'totalLayers': 100,
                                  'reportedAllLayers': False, 'devices': ['Vulkan0']}
        manifest['records'][0]['evidence']['benchmark'] = self.write(ref['path'], benchmark)
        with self.assertRaisesRegex(ValueError, 'Observed placement conflicts'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)

    def test_fractional_integer_fields_and_record_count_rejected(self):
        for section, field in [('binding', 'adapters'), ('binding', 'workload'),
                               ('recipe', 'contextSize'), ('recipe', 'slots')]:
            manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate')]}
            record = manifest['records'][0]
            if field == 'adapters':
                record['binding']['adapters'][0]['vramMiB'] = 24576.5
            elif field == 'workload':
                record['binding']['workload']['promptTokens'] = 512.5
            else:
                record[section][field] = 4096.5
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'positive integer'):
                validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)
        manifest = {'schemaVersion': 1, 'records': [self.fixture('candidate')] * 65}
        with self.assertRaisesRegex(ValueError, '64 records'):
            validate_manifest(manifest, self.root, CATALOG, CATALOG_SHA)


if __name__ == '__main__':
    unittest.main()
