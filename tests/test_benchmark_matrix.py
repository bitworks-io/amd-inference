import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'tools' / 'benchmark-matrix.py'
SPEC = importlib.util.spec_from_file_location('benchmark_matrix', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BenchmarkMatrixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.catalog_bytes = (ROOT / 'config' / 'catalog.json').read_bytes()
        cls.catalog = json.loads(cls.catalog_bytes)
        cls.matrix = MODULE.build_matrix(cls.catalog_bytes)

    def test_all_serving_artifacts_and_requested_dimensions_are_explicit(self):
        models = self.catalog['models']
        rows = self.matrix['rows']
        self.assertEqual(len(models), 10)
        self.assertEqual(len(rows), len(models) * 4 * 4 * 8)
        self.assertEqual({r['modelId'] for r in rows}, {m['id'] for m in models})
        self.assertEqual({r['concurrentRequests'] for r in rows}, {1, 2, 4, 8})
        self.assertEqual({r['serverSlots'] for r in rows}, {1, 2, 4, 8})
        self.assertEqual({r['perSlotContextTokens'] for r in rows},
                         {1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072})
        self.assertTrue(any(not r['autoEligible'] for r in rows))

    def test_context_arithmetic_and_no_default_ceiling_escape(self):
        for row in self.matrix['rows']:
            with self.subTest(model=row['modelId'], slots=row['serverSlots'],
                              clients=row['concurrentRequests'], context=row['perSlotContextTokens']):
                self.assertEqual(row['requestedTotalContextTokens'],
                                 row['serverSlots'] * row['perSlotContextTokens'])
                if row['status'] == 'planned-unverified-fit':
                    self.assertEqual(row['serverSlots'], 1)
                    self.assertLessEqual(row['requestedTotalContextTokens'], row['catalogContextCeilingTokens'])
                    self.assertEqual(row['proposedContextSettings']['serverSlots'], 1)
                elif row['status'] == 'experimental-multi-slot-unimplemented':
                    self.assertGreater(row['serverSlots'], 1)
                    self.assertNotIn('proposedContextSettings', row)
                else:
                    self.assertEqual(row['status'], 'outside-current-recipe-ceiling')
                    self.assertGreater(row['requestedTotalContextTokens'], row['catalogContextCeilingTokens'])
                self.assertFalse(row['capacityMeasured'])
                self.assertIn('protocol-only', row['executionStatus'])
                self.assertNotIn('requestedServerArguments', row)

    def test_client_queue_does_not_divide_slot_context(self):
        rows = [r for r in self.matrix['rows'] if r['modelId'] == 'qwen3.8-27b-ud-q4-k-m'
                and r['serverSlots'] == 1 and r['perSlotContextTokens'] == 8192]
        self.assertEqual(len(rows), 4)
        self.assertEqual({r['requestedTotalContextTokens'] for r in rows}, {8192})
        self.assertEqual({r['status'] for r in rows}, {'planned-unverified-fit'})

    def test_boundary_slots_vs_clients_and_recipe_ceiling(self):
        model = 'qwen3.5-4b-iq4-xs'  # Current ceiling 8192, independent of client count.
        def row(slots, clients, per_slot):
            return next(r for r in self.matrix['rows'] if r['modelId'] == model
                        and r['serverSlots'] == slots and r['concurrentRequests'] == clients
                        and r['perSlotContextTokens'] == per_slot)
        self.assertEqual(row(1, 8, 8192)['status'], 'planned-unverified-fit')
        self.assertEqual(row(1, 8, 8192)['requestedTotalContextTokens'], 8192)
        self.assertEqual(row(2, 1, 4096)['status'], 'experimental-multi-slot-unimplemented')
        self.assertEqual(row(2, 1, 4096)['requestedTotalContextTokens'], 8192)
        self.assertEqual(row(2, 1, 8192)['status'], 'outside-current-recipe-ceiling')
        self.assertEqual(row(8, 2, 1024)['requestedTotalContextTokens'], 8192)
        self.assertEqual(row(8, 2, 1024)['status'], 'experimental-multi-slot-unimplemented')

    def test_planned_request_budgets_fit_and_are_actual_work(self):
        for row in self.matrix['rows']:
            if row['status'] != 'planned-unverified-fit':
                continue
            for workload in row['workloads']:
                if workload['status'] != 'protocol-planned-runner-unqualified':
                    continue
                self.assertGreaterEqual(workload['minimumMeasuredWaves'], 5)
                requests = workload['requests']
                for request in requests:
                    self.assertGreater(request['inputTokens'], 0)
                    self.assertGreater(request['outputTokens'], 0)
                    self.assertLessEqual(request['inputTokens'] + request['outputTokens'] + 128,
                                         row['perSlotContextTokens'])
            names = {w['name'] for w in row['workloads']}
            self.assertEqual(names, {'historical-baseline-512', 'historical-baseline-4096',
                                     'interactive', 'sustained-output-512', 'sustained-output-1024',
                                     'long-context', 'mixed-length', 'agent-fan-out-quality'})

    def test_historical_4096_input_requires_output_and_overhead_space(self):
        def workload(context):
            row = next(r for r in self.matrix['rows'] if r['modelId'] == 'qwen3.8-27b-ud-q4-k-m'
                       and r['serverSlots'] == 1 and r['concurrentRequests'] == 1
                       and r['perSlotContextTokens'] == context)
            return next(w for w in row['workloads'] if w['name'] == 'historical-baseline-4096')
        self.assertEqual(workload(4096)['status'], 'insufficient-per-slot-context')
        self.assertEqual(workload(8192)['status'], 'protocol-planned-runner-unqualified')
        self.assertEqual(workload(4096)['requiredPerSlotContextTokens'], 4352)

    def test_cli_is_deterministic_and_contains_no_measurements(self):
        first = subprocess.check_output([sys.executable, str(SCRIPT)], cwd=ROOT)
        second = subprocess.check_output([sys.executable, str(SCRIPT)], cwd=ROOT)
        self.assertEqual(first, second)
        result = json.loads(first)
        self.assertEqual(result['kind'], 'offline-benchmark-matrix-unverified')
        self.assertIn('planning-only', result['measurementRequirements']['state'])
        self.assertEqual(result['measurementRequirements']['minimumPublicationRequestObservationsPerWorkloadConcurrencyCell'], 100)


if __name__ == '__main__':
    unittest.main()
