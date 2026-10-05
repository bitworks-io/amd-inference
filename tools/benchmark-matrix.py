#!/usr/bin/env python3
"""Print a deterministic, non-executing benchmark plan from the serving catalog.

Client concurrency and server slots are independent. The normal FastLLM recipe
uses one server slot; additional clients queue. llama-server's --ctx-size is
shared by --parallel server slots, so total context is the per-slot tier times
server slots. Multi-slot rows are marked experimental and are never launch
instructions. This program makes no fit claim.
"""

import argparse
import hashlib
import json
from pathlib import Path


CONCURRENCY = (1, 2, 4, 8)
SERVER_SLOTS = (1, 2, 4, 8)
PER_SLOT_CONTEXT = (1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072)
SCHEMA_VERSION = 1
TOKEN_OVERHEAD_RESERVE = 128


def _requests(count, prompt, output):
    return [{'request': n + 1, 'inputTokens': prompt, 'outputTokens': output}
            for n in range(count)]


def _workloads(concurrency, per_slot):
    def fixed(name, input_tokens, output_tokens):
        if input_tokens + output_tokens + TOKEN_OVERHEAD_RESERVE > per_slot:
            return {'name': name, 'status': 'insufficient-per-slot-context',
                    'requiredPerSlotContextTokens': input_tokens + output_tokens + TOKEN_OVERHEAD_RESERVE}
        return {'name': name, 'status': 'protocol-planned-runner-unqualified',
                'minimumWarmups': 1, 'minimumMeasuredWaves': 5,
                'requests': _requests(concurrency, input_tokens, output_tokens)}

    workloads = [fixed('historical-baseline-512', 512, 128),
                 fixed('historical-baseline-4096', 4096, 128),
                 fixed('interactive', 512, 256),
                 fixed('sustained-output-512', 256, 512),
                 fixed('sustained-output-1024', 256, 1024)]
    long_output = min(512, max(128, per_slot // 8))
    long_input = per_slot - long_output - TOKEN_OVERHEAD_RESERVE
    workloads.append(fixed('long-context', long_input, long_output))
    if concurrency == 1:
        workloads.append({'name': 'mixed-length', 'status': 'not-applicable-single-request'})
    else:
        mixed = [
            {'request': n + 1,
             'inputTokens': 256 if n % 2 == 0 else per_slot - 256 - TOKEN_OVERHEAD_RESERVE,
             'outputTokens': 128 if n % 2 == 0 else 256}
            for n in range(concurrency)
        ]
        workloads.append({'name': 'mixed-length', 'status': 'protocol-planned-runner-unqualified',
                          'minimumWarmups': 1, 'minimumMeasuredWaves': 5,
                          'mixVersion': 'short-long-alternating-v1', 'orderSeed': 42,
                          'requests': mixed})
    workloads.append({'name': 'agent-fan-out-quality',
                      'status': 'requires-versioned-task-harness',
                      'minimumMeasuredWaves': 5,
                      'clientTasks': concurrency,
                      'taskInputAndOutputMustFitPerSlot': per_slot,
                      'assessment': 'same independent versioned task set sequentially and concurrently; score correctness, retries, latency and fairness'})
    return workloads


def build_matrix(catalog_bytes):
    catalog = json.loads(catalog_bytes)
    models = catalog.get('models')
    if not isinstance(models, list) or not models:
        raise ValueError('Catalog must contain serving models.')
    rows = []
    ids = set()
    for model in models:
        model_id = model['id']
        ceiling = model['contextSize']
        if not isinstance(model_id, str) or not model_id or model_id in ids:
            raise ValueError('Serving model IDs must be unique, nonempty strings.')
        if type(ceiling) is not int or ceiling < 512:
            raise ValueError(f'Invalid context ceiling for {model_id}.')
        ids.add(model_id)
        for server_slots in SERVER_SLOTS:
            for concurrency in CONCURRENCY:
                for per_slot in PER_SLOT_CONTEXT:
                    total = server_slots * per_slot
                    row = {
                        'modelId': model_id,
                        'modelSha256': model['sha256'],
                        'support': model.get('support'),
                        'autoEligible': model.get('autoEligible', True),
                        'catalogEstimatedRequiredFreeVramMiB': model['requiredFreeVramMiB'],
                        'catalogContextCeilingTokens': ceiling,
                        'serverSlots': server_slots,
                        'workerCount': 1,
                        'concurrentRequests': concurrency,
                        'perSlotContextTokens': per_slot,
                        'contextTier': ('short-calibration' if per_slot < 4096 else
                                        'separate-experimental-review' if per_slot >= 65536 else 'standard'),
                        'requestedTotalContextTokens': total,
                        'capacityMeasured': False,
                        'executionStatus': 'protocol-only; no matching qualified runner or hardware fit result',
                    }
                    if total > ceiling:
                        row.update(status='outside-current-recipe-ceiling',
                                   reason='Requested total context exceeds this artifact\'s current FastLLM recipe ceiling.')
                    elif server_slots > 1:
                        row.update(status='experimental-multi-slot-unimplemented',
                                   reason='Current FastLLM launcher and readiness checks require one server slot; separate implementation and physical qualification are needed.')
                    else:
                        row.update(status='planned-unverified-fit',
                                   proposedContextSettings={'totalContextTokens': total, 'serverSlots': 1},
                                   workloads=_workloads(concurrency, per_slot))
                    rows.append(row)
    return {
        'schemaVersion': SCHEMA_VERSION,
        'kind': 'offline-benchmark-matrix-unverified',
        'catalogSha256': hashlib.sha256(catalog_bytes).hexdigest(),
        'contextSemantics': {
            'clientConcurrency': 'Number of simultaneous clients. Clients above available server slots queue; it does not multiply context.',
            'serverSlots': 'Normal service uses one slot. Higher slot counts are experimental and unimplemented.',
            'perSlotContextTokens': 'Budget for one active server slot, not for each queued client.',
            'requestedTotalContextTokens': 'Proposed --ctx-size = perSlotContextTokens multiplied by serverSlots.',
            'catalogCeiling': 'Current FastLLM recipe ceiling; it is not the model architecture maximum.',
            'requestBudget': 'Each inputTokens plus outputTokens pair plus 128 planned overhead tokens fits one slot; actual template/tool/tokenizer counts and live occupancy must be verified at run time.',
            'normalQueue': 'When concurrentRequests exceeds the one normal server slot, report queue delay and observed overlap; do not call this simultaneous decode.',
        },
        'measurementRequirements': {
            'state': 'planning-only; no model, engine, or GPU was run',
            'minimumScreeningWavesPerCell': 5,
            'minimumPublicationRequestObservationsPerWorkloadConcurrencyCell': 100,
            'minimumFreshServerLoadsForPublication': 3,
            'record': ['actual input/output tokens per request', 'first-token latency per request',
                       'completion latency per request', 'aggregate output tokens per second',
                       'per-request output tokens per second and p50/p95 latency',
                       'errors, cancellations, client wait and server queue delay only where engine evidence exists',
                       'observed simultaneous decode count, memory peak and GPU placement',
                       'exact engine/model/config hashes, host/driver/PCIe/power/thermal state'],
            'coverage': 'Run every planned workload on each qualified card/model pair; record skips and failures explicitly. Repeat across at least three fresh server loads for publication.',
            'aboveCeiling': 'Requires a separate reviewed experimental policy and measured fit; this matrix does not claim model architecture limits.',
        },
        'models': len(models),
        'rows': rows,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'config' / 'catalog.json')
    arguments = parser.parse_args()
    try:
        result = build_matrix(arguments.catalog.read_bytes())
    except (OSError, KeyError, ValueError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
