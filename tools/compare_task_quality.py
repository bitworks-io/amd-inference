"""Private, offline S1/S2 task-quality description; never a serving selector.

The S1 input is the exact retained XTX host report. S2 is restricted to the
separately reviewed task producer and the same pinned model/workload. Neither
matching task scores nor observed HTTP overlap proves GPU parallelism.
"""

import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path


MAX_BYTES = 2 * 1024 * 1024
TOLERANCE_MS = 1.0
S1_REPORT_SHA256 = '0d4a480d4ba30438b20f85025294284859c5959085e77d0d53c7a271bc858a9a'
S1_TOOL_SHA256 = 'be66f618d98d8ecc0f7bc671113fa73a23512a9fe8264eec2e1b2042779fab08'
WORKLOAD_SHA256 = '8a11399d783569b4e3fdd5bb2542258eb5431d1705fce4cdf7a40e6f77212bfb'
MODEL_SHA256 = '322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482'
ENGINE_SHA256 = '9f4dd930c50cdd3f7946b679ff67eaa124343096abdb56f2978199cf035758c7'
CATALOG_SHA256 = '65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6'
# Reviewed pre-run, frozen 50-file S2 task package. These pins are not learned
# from a supplied report or the mutable working tree.
S2_SOURCE_MANIFEST_SHA256 = 'c1903c721f3df268f20f90772fe8b3f781e2dc1f20c8c314857190b55f081041'
S2_TOOL_SHA256 = '3b7b7dec5c063999d2be49f822c8f84eee6463e3f6b53070813f0dc950f97617'
S2_SOURCE_HASHES = {
    's2TaskTool': S2_TOOL_SHA256,
    's1TaskTool': S1_TOOL_SHA256,
    'workload': WORKLOAD_SHA256,
    'multiTool': '4b93972b6111b30c0b60c68955a3270f50e6083b14b54dd47771c7e213e53a0b',
    'multiSource': '2201823293c8f71976fc5cd3e4afcb10e682e134473ce290633561865d4f032d',
    'fitSource': '74456437847888d0153aa4a00219c9174a839a9ab7857c054b7a4cae52ac5c98',
    'semantic': 'd0438f6ec2744600e341fe7f4426ff3327ac750ec98d6fda39d41adb045d6125',
    'concurrency': 'af1bc3f18833e84f1bf260972bca927e5eafabc99865d44d46e1f72140d2cbde',
    'module': 'a933613a5454cde94202efafdb3d181526ad1f3b063d0f0fdcc207ab0d2e6f5b',
    'processHost': '6a59b6008ac181be57922ee00f47916f24eb3f164adf91eed4e6abb702544e65',
    'catalog': CATALOG_SHA256,
}
CASE_IDS = (
    'extract-order-v1', 'filter-candidates-v1', 'sort-integers-v1',
    'arithmetic-invoice-v1', 'arithmetic-steps-v1', 'dependency-chain-v1',
    'retrieve-head-v1', 'retrieve-tail-v1',
)
LEVELS = (1, 2, 4)
COMMON_METHOD = (
    'suiteVersion', 'answerPolicy', 'distractorCount', 'conditionOrder',
    'perLevelPlannedTasks', 'plannedTotalTasks', 'stream', 'firstText',
    'sampling', 'prefixCache', 'requestTimeoutBaseSeconds',
    'overallDeadlineSeconds', 'actualUsageRequired',
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value, label, *, positive=False):
    require(type(value) in (int, float) and math.isfinite(value) and
            (value > 0 if positive else value >= 0), f'Invalid {label}')
    return value


def integer(value, label, *, minimum=0):
    require(type(value) is int and value >= minimum, f'Invalid {label}')
    return value


def sha(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def _unique_object(pairs):
    obj = {}
    for key, value in pairs:
        require(key not in obj, f'Duplicate JSON key: {key}')
        obj[key] = value
    return obj


def read_report(path, *, expected_sha256=None):
    with Path(path).open('rb') as stream:
        raw = stream.read(MAX_BYTES + 1)
    require(len(raw) <= MAX_BYTES, 'Task report exceeds 2 MiB')
    digest = hashlib.sha256(raw).hexdigest()
    if expected_sha256 is not None:
        require(digest == expected_sha256, 'S1 report is not the exact retained report')
    report = json.loads(raw, object_pairs_hook=_unique_object,
                        parse_constant=lambda value: require(False, f'Non-finite JSON: {value}'))
    require(isinstance(report, dict), 'Malformed task report')
    return report, digest


def _qualification_false(report):
    flags = report.get('qualification')
    require(isinstance(flags, dict) and flags and all(value is False for value in flags.values()),
            'Task report contains missing or affirmative qualification flag')
    require(report.get('controllerOutcomeAuthoritative') is False,
            'Task report is not the completed collector outcome')


def _source_pin(report, arm):
    provenance = report.get('sourceProvenance')
    require(isinstance(provenance, dict) and provenance.get('endStatus') == 'verified',
            f'{arm} source provenance not verified')
    hashes = provenance.get('sha256')
    require(isinstance(hashes, dict) and all(sha(value) for value in hashes.values()),
            f'{arm} source hashes malformed')
    if arm == 's1':
        require(hashes.get('taskTool') == S1_TOOL_SHA256 and
                hashes.get('workload') == WORKLOAD_SHA256,
                'S1 source digests differ from retained producer')
    else:
        require(S2_TOOL_SHA256 is not None and S2_SOURCE_MANIFEST_SHA256 is not None and
                S2_SOURCE_HASHES is not None,
                'S2 complete source map and manifest digests have not been independently frozen')
        require(hashes.get('s2TaskTool') == S2_TOOL_SHA256 and
                hashes.get('s1TaskTool') == S1_TOOL_SHA256 and
                hashes.get('workload') == WORKLOAD_SHA256 and
                hashes.get('catalog') == CATALOG_SHA256 and
                report.get('sourceManifestDigest') == S2_SOURCE_MANIFEST_SHA256 and
                hashes == S2_SOURCE_HASHES,
                'S2 source digests differ from reviewed producer')
    return hashes


def _cases(method, arm):
    cases = method.get('cases')
    require(isinstance(cases, list) and len(cases) == len(CASE_IDS), f'{arm} case count differs')
    require(tuple(case.get('id') for case in cases) == CASE_IDS, f'{arm} case order differs')
    for case in cases:
        require(isinstance(case, dict), f'{arm} case malformed')
        for field in ('promptSha256', 'referenceSha256'):
            require(sha(case.get(field)), f'{arm} case {field} invalid')
        require(case.get('responseFormat') in ('explicit', 'none'), f'{arm} response format invalid')
        format_sha = case.get('responseFormatSha256')
        require(sha(format_sha) if case['responseFormat'] == 'explicit' else format_sha is None,
                f'{arm} response-format digest invalid')
        integer(case.get('maxOutputTokens'), f'{arm} max output', minimum=1)
    return cases


def _recipe(report, arm):
    recipe = report.get('recipe')
    require(isinstance(recipe, dict), f'{arm} recipe missing')
    if arm == 's1':
        require(recipe.get('slots') == 1 and recipe.get('contextSize') == 32768,
                'S1 must be one slot / 32768 total context')
    else:
        require(recipe.get('requestedSlots') == recipe.get('observedTotalSlots') == 2 and
                recipe.get('requestedTotalContext') == 32768 and
                recipe.get('expectedPerSlotContext') == recipe.get('observedPerSlotContext') == 16384 and
                recipe.get('contextPolicy') == 'fixed-total',
                'S2 must be two observed slots / 32768 total / 16384 each')
        caveats = report.get('placementCaveats')
        require(isinstance(caveats, dict) and
                caveats.get('classification') == 'all-reported-layers-with-host-model-buffer' and
                caveats.get('physicalResidencyVerified') is False and
                caveats.get('operationPlacementVerified') is False,
                'S2 placement caveats absent or falsely verified')
        for flag in ('allowHostModelBuffer', 'allowUnknownPciIdentity'):
            require(caveats.get(flag) is True and recipe.get(flag) is True,
                    f'S2 {flag} mismatch')
        require(caveats.get('selectedDeviceIdentityVerified') is False,
                'S2 identity claim is outside reviewed fallback')
        number(caveats.get('hostModelBufferMiB'), 'S2 host model buffer', positive=True)
    return recipe


def _arguments(recipe, arm):
    args = recipe.get('requestedArguments')
    require(isinstance(args, list) and all(isinstance(arg, str) for arg in args),
            f'{arm} launch arguments malformed')
    expected = {'--parallel': '1' if arm == 's1' else '2',
                '--ctx-size': '32768', '--fit-target': '768', '--device': 'Vulkan0',
                '--cache-type-k': 'f16', '--cache-type-v': 'f16', '--spec-type': 'none'}
    for flag, value in expected.items():
        positions = [i for i, arg in enumerate(args) if arg == flag]
        require(len(positions) == 1 and positions[0] + 1 < len(args) and
                args[positions[0] + 1] == value, f'{arm} {flag} differs')
    normalized = list(args)
    for flag, replacement in (('--parallel', '<slots>'), ('--port', '<port>'),
                              ('--model', '<model-path>')):
        i = normalized.index(flag)
        normalized[i + 1] = replacement
    return normalized


def _validate_waves(report, arm):
    waves = report.get('waves')
    summary = report.get('summary')
    totals = report.get('totals')
    require(isinstance(waves, list) and len(waves) == 14 and
            isinstance(summary, list) and len(summary) == 3 and
            isinstance(totals, dict), f'{arm} incomplete fixed suite')
    cases = {case['id']: case for case in report['methodology']['cases']}
    by_level = {}
    all_rows = []
    cursor = 0
    for clients in LEVELS:
        level_waves = waves[cursor:cursor + 8 // clients]
        cursor += 8 // clients
        rows = []
        for offset, wave in zip(range(0, 8, clients), level_waves):
            require(isinstance(wave, dict) and wave.get('requestedClients') == clients,
                    f'{arm} wave order differs')
            expected_ids = list(CASE_IDS[offset:offset + clients])
            requests = wave.get('requests')
            require(wave.get('taskIds') == expected_ids and isinstance(requests, list) and
                    len(requests) == clients, f'{arm} wave tasks differ')
            require(wave.get('serverParallelDecodeObserved') is False,
                    f'{arm} unsupported parallel decode claim')
            number(wave.get('wallMs'), f'{arm} wave wall', positive=True)
            grades = {'correct': 0, 'incorrect': 0}
            starts, finishes = [], []
            for index, request in enumerate(requests, 1):
                require(isinstance(request, dict) and request.get('client') == index and
                        request.get('taskId') == expected_ids[index - 1],
                        f'{arm} request identity differs')
                start = number(request.get('dispatchStartMs'), f'{arm} dispatch')
                finish = number(request.get('httpFinishMs'), f'{arm} finish')
                latency = number(request.get('endToEndLatencyMs'), f'{arm} latency', positive=True)
                require(finish >= start and abs((finish - start) - latency) <= TOLERANCE_MS,
                        f'{arm} request latency inconsistent')
                require(request.get('timeToFirstTextMs') is None and
                        request.get('firstTextMeasurement') == 'not-measured-nonstreaming',
                        f'{arm} unsupported first-text measurement')
                require(request.get('httpStatus') == 200 and request.get('grade') in grades and
                        isinstance(request.get('classification'), str) and request['classification'],
                        f'{arm} non-complete or ungraded request')
                require((request.get('errorCode') is None if request['grade'] == 'correct' else
                         isinstance(request.get('errorCode'), str) and bool(request['errorCode'])),
                        f'{arm} grade/error classification mismatch')
                prompt_tokens = integer(request.get('actualPromptTokens'), f'{arm} prompt usage', minimum=1)
                output_tokens = integer(request.get('actualOutputTokens'), f'{arm} output usage')
                require(output_tokens <= cases[request['taskId']]['maxOutputTokens'],
                        f'{arm} output exceeds case bound')
                context_limit = 32768 if arm == 's1' else 16384
                require(prompt_tokens + cases[request['taskId']]['maxOutputTokens'] + 8 <= context_limit,
                        f'{arm} task exceeds per-slot context allowance')
                require(request.get('finishReason') == 'stop',
                        f'{arm} completion did not stop normally')
                grades[request['grade']] += 1
                starts.append(start)
                finishes.append(finish)
                rows.append({'taskId': request['taskId'], 'grade': request['grade'],
                             'classification': request['classification'],
                             'endToEndLatencyMs': latency, 'actualPromptTokens': prompt_tokens,
                             'actualOutputTokens': output_tokens})
            require(wave.get('correct') == grades['correct'] and
                    wave.get('incorrect') == grades['incorrect'] and wave.get('inconclusive') == 0,
                    f'{arm} wave grades inconsistent')
            require(wave['wallMs'] + TOLERANCE_MS >= max(finishes) - min(starts),
                    f'{arm} wave wall shorter than HTTP interval')
        require(len(rows) == 8 and [row['taskId'] for row in rows] == list(CASE_IDS),
                f'{arm} level tasks incomplete')
        level = summary[LEVELS.index(clients)]
        correct = sum(row['grade'] == 'correct' for row in rows)
        incorrect = 8 - correct
        require(isinstance(level, dict) and level.get('requestedClients') == clients and
                level.get('planned') == level.get('attempted') == 8 and
                level.get('correct') == correct and level.get('incorrect') == incorrect and
                level.get('inconclusive') == level.get('unattempted') == 0 and
                level.get('complete') is True and
                level.get('timingScope') == 'level pre-dispatch checks through final post-wave checks, including inter-wave gaps',
                f'{arm} level summary inconsistent')
        wall = number(level.get('wholeSuiteWallMs'), f'{arm} full suite wall', positive=True)
        begin = number(level.get('suiteStartCollectorMs'), f'{arm} suite start')
        end = number(level.get('suiteFinishCollectorMs'), f'{arm} suite finish')
        require(end >= begin and abs((end - begin) - wall) <= TOLERANCE_MS and
                wall + TOLERANCE_MS >= sum(wave['wallMs'] for wave in level_waves),
                f'{arm} full suite interval inconsistent')
        rate = 1000.0 * correct / wall
        number(level.get('usefulTasksPerSecond'), f'{arm} recorded useful rate')
        require(abs(level['usefulTasksPerSecond'] - rate) <= 1e-6,
                f'{arm} useful rate inconsistent')
        by_level[clients] = {'correct': correct, 'incorrect': incorrect, 'inconclusive': 0,
                             'unattempted': 0, 'wholeSuiteWallMs': wall,
                             'usefulTasksPerSecond': rate,
                             'medianEndToEndLatencyMs': statistics.median(row['endToEndLatencyMs'] for row in rows),
                             'tasks': rows}
        all_rows.extend(rows)
    correct = sum(row['grade'] == 'correct' for row in all_rows)
    require(totals.get('planned') == totals.get('attempted') == 24 and
            totals.get('correct') == correct and totals.get('incorrect') == 24 - correct and
            totals.get('inconclusive') == totals.get('unattempted') == 0 and
            report.get('qualityPass') is (correct == 24), f'{arm} totals inconsistent')
    return by_level


def validate(report, arm):
    expected_kind = ('private-task-quality-assessment' if arm == 's1' else
                     'private-s2-task-quality-assessment')
    protocol = ('task-quality-assessment-v1' if arm == 's1' else
                's2-task-quality-assessment-v1')
    require(isinstance(report, dict) and report.get('schemaVersion') == 1 and
            report.get('resultKind') == expected_kind and report.get('reportStatus') == 'complete' and
            report.get('bindingStatus') == 'verified' and report.get('abortReasonCode') is None and
            report.get('failedCondition') is None, f'{arm} is not a verified completed assessment')
    require(isinstance(report.get('runId'), str) and report['runId'] and
            isinstance(report.get('processIdentity'), dict), f'{arm} process identity missing')
    integer(report['processIdentity'].get('pid'), f'{arm} PID', minimum=1)
    integer(report['processIdentity'].get('startUtcTicks'), f'{arm} process start ticks', minimum=1)
    _qualification_false(report)
    hashes = _source_pin(report, arm)
    recipe = _recipe(report, arm)
    method = report.get('methodology')
    require(isinstance(method, dict) and method.get('protocolVersion') == protocol and
            method.get('serverSlots') == (1 if arm == 's1' else 2),
            f'{arm} methodology mismatch')
    if arm == 's2':
        require(method.get('totalContextTokens') == 32768 and
                method.get('perSlotContextTokens') == 16384,
                'S2 methodology context mismatch')
    cases = _cases(method, arm)
    levels = _validate_waves(report, arm)
    return {'hashes': hashes, 'recipe': recipe, 'method': method,
            'cases': cases, 'levels': levels, 'arguments': _arguments(recipe, arm)}


def compare(s1, s2, *, s2_input_sha256=None):
    require(s2_input_sha256 is None or sha(s2_input_sha256), 'Invalid observed S2 report digest')
    a, b = validate(s1, 's1'), validate(s2, 's2')
    require(s1['runId'] != s2['runId'], 'Assessment run IDs must be distinct')
    for field, value in (('modelId', 'qwen3.8-27b-ud-q4-k-m'),
                         ('modelSha256', MODEL_SHA256), ('engineVersion', 'b10698')):
        require(s1.get(field) == s2.get(field) == value, f'Model/engine {field} differs')
    require(s1['recipe'].get('catalogSha256') == s2.get('catalogSha256') == CATALOG_SHA256 and
            s1['recipe'].get('engineSha256') == s2.get('engineSha256') == ENGINE_SHA256,
            'Catalog/engine artifact differs')
    require(a['cases'] == b['cases'], 'Task prompts/references/formats differ')
    for field in COMMON_METHOD:
        require(field in a['method'] and a['method'][field] == b['method'].get(field),
                f'Task method {field} differs')
    require(a['method']['suiteVersion'] == 'task-quality-v1' and
            a['method']['sampling'] == 'temperature-0-seed-42-thinking-disabled' and
            a['method']['answerPolicy'] == 'continue-incorrect-stop-inconclusive' and
            a['method']['conditionOrder'] == 'C1, C2, C4; same eight task IDs at each level; sequential bursts of C requests; no warmup' and
            a['method']['plannedTotalTasks'] == 24 and a['method']['perLevelPlannedTasks'] == 8 and
            a['method']['stream'] is False and a['method']['firstText'] == 'not-measured' and
            a['method']['prefixCache'] is False and a['method']['distractorCount'] == 0 and
            a['method']['actualUsageRequired'] is True,
            'Unsupported workload method')
    require(a['arguments'] == b['arguments'], 'Launch arguments differ beyond model path, port and slots')
    s1_recipe, s2_recipe = a['recipe'], b['recipe']
    for s1field, s2field, expected in (
        ('backend', 'backend', 'Vulkan'), ('splitMode', 'splitMode', 'none'),
        ('cacheTypeK', 'cacheTypeK', 'f16'), ('cacheTypeV', 'cacheTypeV', 'f16'),
        ('flashAttention', 'flashAttention', 'auto'), ('speculation', 'speculation', 'none'),
        ('configurationIsolation', 'configurationIsolation',
         'empty-per-run-config-roots-and-targeted-environment-sanitization')):
        require(s1_recipe.get(s1field) == s2_recipe.get(s2field) == expected,
                f'Recipe {s1field} differs')
    require(s2_recipe.get('device') == 'Vulkan0' and s2_recipe.get('gpuLayers') == 'all' and
            s2_recipe.get('fitMode') == 'on' and s2_recipe.get('fitTargetMiB') == 768,
            'S2 GPU/fit request differs')
    require(s1.get('endpoint') == 'http://127.0.0.1:8080/v1' and
            s2.get('endpoint') == 'http://127.0.0.1:18084/v1',
            'Endpoint is not the reviewed S1/S2 pair')
    conditions = []
    for clients in LEVELS:
        left, right = a['levels'][clients], b['levels'][clients]
        for index, task_id in enumerate(CASE_IDS):
            require(left['tasks'][index]['taskId'] == right['tasks'][index]['taskId'] == task_id and
                    left['tasks'][index]['actualPromptTokens'] == right['tasks'][index]['actualPromptTokens'],
                    f'Actual prompt usage differs for {task_id} at C{clients}')
        conditions.append({'requestedClients': clients,
                           's1': {key: value for key, value in left.items() if key != 'tasks'},
                           's2': {key: value for key, value in right.items() if key != 'tasks'},
                           'perTask': [{'taskId': task_id,
                                        's1Grade': left['tasks'][index]['grade'],
                                        's2Grade': right['tasks'][index]['grade'],
                                        's1EndToEndLatencyMs': left['tasks'][index]['endToEndLatencyMs'],
                                        's2EndToEndLatencyMs': right['tasks'][index]['endToEndLatencyMs'],
                                        's1ActualPromptTokens': left['tasks'][index]['actualPromptTokens'],
                                        's2ActualPromptTokens': right['tasks'][index]['actualPromptTokens'],
                                        's1ActualOutputTokens': left['tasks'][index]['actualOutputTokens'],
                                        's2ActualOutputTokens': right['tasks'][index]['actualOutputTokens']}
                                       for index, task_id in enumerate(CASE_IDS)]})
    return {
        'kind': 'private-s1-s2-task-quality-descriptive-comparison', 'schemaVersion': 1,
        'qualificationApproved': False, 'rankingOrWinner': None, 'automaticSelection': False,
        'sourceRuns': {'s1RunId': s1['runId'], 's2RunId': s2['runId'],
                       's1QualityPass': s1['qualityPass'], 's2QualityPass': s2['qualityPass'],
                       's1InputReportSha256': S1_REPORT_SHA256,
                       's2ObservedInputReportSha256': s2_input_sha256},
        'reviewedPins': {'s1ReportSha256': S1_REPORT_SHA256,
                         's1TaskToolSha256': S1_TOOL_SHA256,
                         's2TaskToolSha256': S2_TOOL_SHA256,
                         'modelSha256': MODEL_SHA256, 'engineSha256': ENGINE_SHA256,
                         'workloadSha256': WORKLOAD_SHA256,
                         's2SourceManifestSha256': S2_SOURCE_MANIFEST_SHA256},
        'explicitDifferences': {
            'producerAndSupervisor': 'normal S1 versus separate private S2, exact tool hashes pinned; not identical loaded-code attestation',
            'listener': 'S1 loopback 8080 versus private S2 loopback 18084',
            'slotsAndContext': 'S1 one slot/32768 per slot versus S2 two slots/16384 per slot; total context 32768',
            'placementAndIdentity': 'S2 explicitly allows a host model buffer and unknown PCI identity; S1 Ready has weaker host-buffer/device evidence',
            's2ReportedHostModelBufferMiB': s2['placementCaveats']['hostModelBufferMiB'],
            's2ReportedIdentityVerified': s2['placementCaveats']['selectedDeviceIdentityVerified'],
        },
        'caution': 'Descriptive task results only. Whole-suite intervals include harness pre/post checks and inter-wave gaps; useful-task rates are not raw engine tokens/s. Host/driver equivalence and owned-process cleanup are not established by this comparator. No tail SLA, first-text timing, causal slot/CPU/GPU attribution, parallel GPU decode, physical residency, quality qualification or transferable ranking.',
        'companionCleanupEvidence': 'not-evaluated-by-this-comparator',
        'conditions': conditions,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('s1_report', type=Path)
    parser.add_argument('s2_report', type=Path)
    args = parser.parse_args()
    try:
        s1, _ = read_report(args.s1_report, expected_sha256=S1_REPORT_SHA256)
        s2, s2_digest = read_report(args.s2_report)
        print(json.dumps(compare(s1, s2, s2_input_sha256=s2_digest), indent=2, allow_nan=False))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
