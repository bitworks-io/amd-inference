"""Portable, synthetic contract checks for the private S1/S2 offline comparer.

The S2 producer digest is mocked only in these tests. Passing synthetic tests
alone does not qualify a physical run or authorize public performance claims.
"""

import copy
import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


TOOL = Path(__file__).resolve().parents[1] / 'tools' / 'compare_task_quality.py'
spec = importlib.util.spec_from_file_location('compare_task_quality', TOOL)
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)
MOCK_S2_TOOL_SHA256 = 'f' * 64
MOCK_S2_MANIFEST_SHA256 = 'e' * 64


def _digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def fixture(arm):
    is_s2 = arm == 's2'
    cases = []
    for index, case_id in enumerate(compare.CASE_IDS):
        cases.append({'id': case_id, 'kind': 'synthetic',
                      'promptSha256': _digest(case_id + '-prompt'),
                      'referenceSha256': _digest(case_id + '-reference'),
                      'maxOutputTokens': 96, 'responseFormat': 'explicit' if index == 0 else 'none',
                      'responseFormatSha256': _digest('format') if index == 0 else None})
    arguments = ['--model', '<verified-model-path>' if is_s2 else '<verified-model>',
                 '--offline', '--no-mmproj', '--spec-type', 'none',
                 '--alias', 'qwen3.8-27b-ud-q4-k-m', '--host', '127.0.0.1',
                 '--port', '18084' if is_s2 else '8080', '--cors-origins', 'localhost',
                 '--no-cors-credentials', '--ctx-size', '32768', '--parallel', '2' if is_s2 else '1',
                 '--n-gpu-layers', 'all', '--fit', 'on', '--fit-target', '768',
                 '--device', 'Vulkan0', '--split-mode', 'none', '--flash-attn', 'auto',
                 '--cache-type-k', 'f16', '--cache-type-v', 'f16', '--jinja', '--metrics',
                 '--log-verbosity', '4', '--no-agent', '--no-ui']
    recipe = {'backend': 'Vulkan', 'splitMode': 'none', 'cacheTypeK': 'f16',
              'cacheTypeV': 'f16', 'flashAttention': 'auto', 'speculation': 'none',
              'configurationIsolation': 'empty-per-run-config-roots-and-targeted-environment-sanitization',
              'requestedArguments': arguments}
    if is_s2:
        recipe.update({'device': 'Vulkan0', 'gpuLayers': 'all', 'fitMode': 'on',
                       'fitTargetMiB': 768, 'requestedSlots': 2, 'observedTotalSlots': 2,
                       'requestedTotalContext': 32768, 'expectedPerSlotContext': 16384,
                       'observedPerSlotContext': 16384, 'contextPolicy': 'fixed-total',
                       'allowHostModelBuffer': True, 'allowUnknownPciIdentity': True})
    else:
        recipe.update({'slots': 1, 'contextSize': 32768,
                       'catalogSha256': compare.CATALOG_SHA256,
                       'engineSha256': compare.ENGINE_SHA256})
    method = {'protocolVersion': 's2-task-quality-assessment-v1' if is_s2 else 'task-quality-assessment-v1',
              'suiteVersion': 'task-quality-v1', 'answerPolicy': 'continue-incorrect-stop-inconclusive',
              'distractorCount': 0, 'cases': cases,
              'conditionOrder': 'C1, C2, C4; same eight task IDs at each level; sequential bursts of C requests; no warmup',
              'serverSlots': 2 if is_s2 else 1, 'perLevelPlannedTasks': 8,
              'plannedTotalTasks': 24, 'stream': False, 'firstText': 'not-measured',
              'sampling': 'temperature-0-seed-42-thinking-disabled', 'prefixCache': False,
              'requestTimeoutBaseSeconds': 60, 'overallDeadlineSeconds': 600,
              'actualUsageRequired': True}
    if is_s2:
        method.update({'totalContextTokens': 32768, 'perSlotContextTokens': 16384})
    waves, summary = [], []
    for level_index, clients in enumerate(compare.LEVELS):
        rows = []
        for offset in range(0, 8, clients):
            requests = []
            for client, case_id in enumerate(compare.CASE_IDS[offset:offset + clients], 1):
                incorrect = case_id == 'arithmetic-steps-v1'
                requests.append({'client': client, 'taskId': case_id, 'dispatchStartMs': 1.0,
                                 'httpFinishMs': 51.0, 'endToEndLatencyMs': 50.0,
                                 'timeToFirstTextMs': None,
                                 'firstTextMeasurement': 'not-measured-nonstreaming',
                                 'httpStatus': 200, 'finishReason': 'stop',
                                 'actualPromptTokens': 50, 'actualOutputTokens': 8,
                                 'grade': 'incorrect' if incorrect else 'correct',
                                 'classification': 'wrong-answer' if incorrect else 'strict-pass',
                                 'errorCode': 'WRONG_ANSWER' if incorrect else None})
            rows += requests
            waves.append({'requestedClients': clients,
                          'taskIds': list(compare.CASE_IDS[offset:offset + clients]),
                          'wallMs': 100.0, 'serverParallelDecodeObserved': False,
                          'correct': sum(row['grade'] == 'correct' for row in requests),
                          'incorrect': sum(row['grade'] == 'incorrect' for row in requests),
                          'inconclusive': 0, 'requests': requests})
        summary.append({'requestedClients': clients, 'planned': 8, 'attempted': 8,
                        'correct': 7, 'incorrect': 1, 'inconclusive': 0, 'unattempted': 0,
                        'complete': True, 'wholeSuiteWallMs': 1000.0,
                        'suiteStartCollectorMs': level_index * 1000.0,
                        'suiteFinishCollectorMs': (level_index + 1) * 1000.0,
                        'usefulTasksPerSecond': 7.0,
                        'timingScope': 'level pre-dispatch checks through final post-wave checks, including inter-wave gaps'})
    provenance = {'sha256': {'s2TaskTool': MOCK_S2_TOOL_SHA256,
                              's1TaskTool': compare.S1_TOOL_SHA256,
                              'workload': compare.WORKLOAD_SHA256,
                              'catalog': compare.CATALOG_SHA256} if is_s2 else
                             {'taskTool': compare.S1_TOOL_SHA256,
                              'workload': compare.WORKLOAD_SHA256},
                  'endStatus': 'verified'}
    report = {'schemaVersion': 1,
              'resultKind': 'private-s2-task-quality-assessment' if is_s2 else 'private-task-quality-assessment',
              'reportStatus': 'complete', 'bindingStatus': 'verified',
              'abortReasonCode': None, 'failedCondition': None,
              'controllerOutcomeAuthoritative': False, 'runId': arm + '-unique-run',
              'processIdentity': {'pid': 100 if is_s2 else 101, 'startUtcTicks': 638000000000000000},
              'modelId': 'qwen3.8-27b-ud-q4-k-m', 'modelSha256': compare.MODEL_SHA256,
              'engineVersion': 'b10698', 'endpoint': 'http://127.0.0.1:18084/v1' if is_s2 else 'http://127.0.0.1:8080/v1',
              'recipe': recipe, 'methodology': method, 'sourceProvenance': provenance,
              'waves': waves, 'summary': summary,
              'totals': {'planned': 24, 'attempted': 24, 'correct': 21,
                         'incorrect': 3, 'inconclusive': 0, 'unattempted': 0},
              'qualityPass': False,
              'qualification': {'approved': False, 'qualityEvaluation': False,
                                'performanceQualified': False, 'physicalResidency': False,
                                'parallelDecodeVerified': False, 'contextQualified': False}}
    if is_s2:
        report.update({'catalogSha256': compare.CATALOG_SHA256,
                       'engineSha256': compare.ENGINE_SHA256,
                       'sourceManifestDigest': compare.S2_SOURCE_MANIFEST_SHA256,
                       'placementCaveats': {'classification': 'all-reported-layers-with-host-model-buffer',
                                            'hostModelBufferMiB': 682.03,
                                            'allowHostModelBuffer': True,
                                            'selectedDeviceIdentityVerified': False,
                                            'allowUnknownPciIdentity': True,
                                            'physicalResidencyVerified': False,
                                            'operationPlacementVerified': False}})
    return report


class TaskQualityComparisonTests(unittest.TestCase):
    def setUp(self):
        self.original_pin = compare.S2_TOOL_SHA256
        self.original_manifest_pin = compare.S2_SOURCE_MANIFEST_SHA256
        self.original_source_map = compare.S2_SOURCE_HASHES
        compare.S2_TOOL_SHA256 = MOCK_S2_TOOL_SHA256
        compare.S2_SOURCE_MANIFEST_SHA256 = MOCK_S2_MANIFEST_SHA256
        self.s1, self.s2 = fixture('s1'), fixture('s2')
        compare.S2_SOURCE_HASHES = copy.deepcopy(self.s2['sourceProvenance']['sha256'])

    def tearDown(self):
        compare.S2_TOOL_SHA256 = self.original_pin
        compare.S2_SOURCE_MANIFEST_SHA256 = self.original_manifest_pin
        compare.S2_SOURCE_HASHES = self.original_source_map

    def test_descriptive_complete_pair(self):
        result = compare.compare(self.s1, self.s2, s2_input_sha256='d' * 64)
        self.assertIsNone(result['rankingOrWinner'])
        self.assertFalse(result['qualificationApproved'])
        self.assertEqual([c['s1']['correct'] for c in result['conditions']], [7, 7, 7])
        self.assertEqual([c['s2']['incorrect'] for c in result['conditions']], [1, 1, 1])
        self.assertEqual(result['conditions'][2]['s2']['medianEndToEndLatencyMs'], 50)
        self.assertEqual(result['conditions'][0]['s2']['usefulTasksPerSecond'], 7)
        self.assertIn('host model buffer', result['explicitDifferences']['placementAndIdentity'])
        self.assertEqual(result['sourceRuns']['s2ObservedInputReportSha256'], 'd' * 64)
        self.assertIn('Host/driver equivalence', result['caution'])

    def test_unfrozen_s2_producer_denied(self):
        compare.S2_TOOL_SHA256 = None
        with self.assertRaisesRegex(ValueError, 'not been independently frozen'):
            compare.compare(self.s1, self.s2)
        compare.S2_TOOL_SHA256 = MOCK_S2_TOOL_SHA256
        compare.S2_SOURCE_MANIFEST_SHA256 = None
        with self.assertRaisesRegex(ValueError, 'not been independently frozen'):
            compare.compare(self.s1, self.s2)
        compare.S2_SOURCE_MANIFEST_SHA256 = MOCK_S2_MANIFEST_SHA256
        compare.S2_SOURCE_HASHES = None
        with self.assertRaisesRegex(ValueError, 'not been independently frozen'):
            compare.compare(self.s1, self.s2)

    def test_rejects_incomplete_or_binding_change(self):
        for field, value in (('reportStatus', 'aborted'), ('bindingStatus', 'compromised')):
            with self.subTest(field=field):
                other = copy.deepcopy(self.s2)
                other[field] = value
                with self.assertRaises(ValueError):
                    compare.compare(self.s1, other)

    def test_rejects_workload_or_model_drift(self):
        for mutation in (
            lambda r: r['methodology']['cases'][0].__setitem__('referenceSha256', 'a' * 64),
            lambda r: r.__setitem__('modelSha256', 'a' * 64),
            lambda r: r['methodology'].__setitem__('sampling', 'temperature-1'),
            lambda r: r['sourceProvenance']['sha256'].__setitem__('workload', 'a' * 64),
            lambda r: r['recipe']['requestedArguments'].__setitem__(r['recipe']['requestedArguments'].index('--fit-target') + 1, '512'),
        ):
            other = copy.deepcopy(self.s2)
            mutation(other)
            with self.assertRaises(ValueError):
                compare.compare(self.s1, other)

    def test_rejects_grade_count_latency_or_case_cardinality_drift(self):
        for mutation in (
            lambda r: r['waves'][0]['requests'][0].__setitem__('grade', 'incorrect'),
            lambda r: r['waves'][0]['requests'][0].__setitem__('endToEndLatencyMs', 4.0),
            lambda r: r['waves'][0]['requests'].pop(),
            lambda r: r['summary'][0].__setitem__('wholeSuiteWallMs', 1.0),
            lambda r: r['totals'].__setitem__('correct', 24),
        ):
            other = copy.deepcopy(self.s2)
            mutation(other)
            with self.assertRaises(ValueError):
                compare.compare(self.s1, other)

    def test_rejects_unsupported_placement_claim(self):
        other = copy.deepcopy(self.s2)
        other['placementCaveats']['selectedDeviceIdentityVerified'] = True
        with self.assertRaises(ValueError):
            compare.compare(self.s1, other)

    def test_rejects_length_completion_and_context_overrun(self):
        for mutation in (
            lambda r: r['waves'][0]['requests'][0].__setitem__('finishReason', 'length'),
            lambda r: r['waves'][0]['requests'][0].__setitem__('actualPromptTokens', 16300),
        ):
            other = copy.deepcopy(self.s2)
            mutation(other)
            with self.assertRaises(ValueError):
                compare.compare(self.s1, other)

    def test_empty_incorrect_completion_is_counted(self):
        self.s1['waves'][4]['requests'][0]['actualOutputTokens'] = 0
        self.s2['waves'][4]['requests'][0]['actualOutputTokens'] = 0
        result = compare.compare(self.s1, self.s2)
        self.assertEqual(result['conditions'][0]['perTask'][4]['s2ActualOutputTokens'], 0)

    def test_rejects_actual_prompt_usage_mismatch(self):
        other = copy.deepcopy(self.s2)
        other['waves'][0]['requests'][0]['actualPromptTokens'] = 51
        with self.assertRaisesRegex(ValueError, 'Actual prompt usage differs'):
            compare.compare(self.s1, other)

    def test_reader_rejects_duplicate_keys_and_nonfinite_json(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'bad.json'
            for text in ('{"x":1,"x":2}', '{"x":NaN}'):
                path.write_text(text)
                with self.assertRaises(ValueError):
                    compare.read_report(path)

    def test_reader_rejects_nonretained_s1_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 's1.json'
            path.write_text(json.dumps(self.s1))
            with self.assertRaisesRegex(ValueError, 'exact retained report'):
                compare.read_report(path, expected_sha256=compare.S1_REPORT_SHA256)


if __name__ == '__main__':
    unittest.main()
