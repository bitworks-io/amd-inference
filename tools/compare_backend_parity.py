"""Private comparator for the Qwen3.8-27B Q4 backend-parity diagnostic (Vulkan vs CPU reference).

It reads the two reports written by tools/backend-parity-diagnostic.ps1 (-Target Normal and
-Target CpuReference), verifies both are complete and bound to the same model, engine, catalog and G1 request
body, checks validity (the G3 positive control passed in both arms) and emits exactly one classification
predeclared in docs/research/QWEN38-BACKEND-PARITY-PROTOCOL-2026-10-06.md.

It never reads a model or contacts a server, and the output is deterministic for the same input bytes. No
throughput, speed, quality-qualification, GDN or general-correctness claim follows from any classification.
"""

import argparse
import hashlib
import json
import math
import re
import sys
from pathlib import Path

RESULT_KIND = 'private-backend-parity-diagnostic'
PROTOCOL_VERSION = 'qwen38-backend-parity-v1'
COMPARISON_KIND = 'private-backend-parity-comparison'
MAX_BYTES = 1024 * 1024
EXPECTED_ANSWER = '63'
PROTOCOL_HASHES = {
    'catalogSha256': '65b8f2f9ca340dab273274086aba9e8f01cb14a2b8cf4bb65c5ed5f6e779caa6',
    'engineSha256': '9f4dd930c50cdd3f7946b679ff67eaa124343096abdb56f2978199cf035758c7',
    'modelSha256': '322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482',
}
BOUND_FIELDS = ('modelId', 'modelSha256', 'engineSha256', 'catalogSha256', 'engineVersion', 'contextSize')
STEPS = ('t1', 't2', 'g1', 'g2', 'g3')
CLASSIFICATIONS = ('h-model-supported', 'h-vulkan-lead', 'numerical-divergence-lead',
                   'both-correct', 'outside-predeclared-table', 'invalid-control', 'incomplete')
CPU_PORT = '18089'
# requestedArguments of the two arms may differ only by this declared set (port, -ngl, fit, device, offload flags).
DECLARED_VALUE_DIFFERENCES = {'--port': ('8080', CPU_PORT), '--n-gpu-layers': ('all', '0'),
                              '--fit': ('on', 'off'), '--device': ('Vulkan0', 'none')}
DECLARED_CPU_ONLY_FLAGS = ('--no-op-offload', '--no-kv-offload')
TOP1_NOTE = ('H-model support rests on first-position top-1 agreement only; digit-ranking agreement is recorded '
             'but never used to classify.')
READINGS = {
    'h-model-supported': 'H-model supported: the same wrong integer and agreeing first-position top-1 on both backends. '
                         'The backend does not explain this failure; classify as a model/quantization limitation for this '
                         'prompt shape in non-thinking mode.',
    'h-vulkan-lead': 'H-vulkan lead: the CPU arm returned 63 while the Vulkan arm did not. Open a bounded op-level '
                     'Vulkan investigation; no default changes.',
    'numerical-divergence-lead': 'Numerical-divergence lead: different outcomes or first-position top-1 disagreement. '
                                 'Next step is a logit-level comparison, not a recipe change.',
    'outside-predeclared-table': 'Outside the predeclared table: the Vulkan arm returned 63 and the CPU arm did not. '
                                 'No next step is predeclared; record it and draw no conclusion.',
    'both-correct': 'Both arms returned 63. This contradicts all earlier observations; record it as a run-condition '
                    'difference to investigate. It is not a fix.',
    'invalid-control': 'The G3 positive control failed in at least one arm. The comparison is invalid; draw no conclusion.',
    'incomplete': 'An arm is incomplete, aborted or the two reports do not bind the same inputs. Draw no conclusion; '
                  'any later attempt is a new, separately declared run.',
}
QUALIFICATION = {'approved': False, 'qualityEvaluation': False, 'semanticQualified': False,
                 'performanceQualified': False, 'physicalResidency': False, 'throughputClaim': False,
                 'gdnClaim': False, 'generalCorrectnessClaim': False}


def _require(test, message):
    if not test:
        raise ValueError(message)


def _is_sha(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def _number(value):
    return type(value) in (int, float) and math.isfinite(value)


def _read(path):
    path = Path(path)
    data = path.read_bytes()
    _require(len(data) <= MAX_BYTES, 'Report exceeds the private size bound')
    try:
        report = json.loads(data.decode('utf-8-sig'), parse_constant=_reject_constant)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f'Report is not valid JSON: {error}')
    return report, hashlib.sha256(data).hexdigest()


def _reject_constant(name):
    raise ValueError('Non-finite JSON constant')


def _validate_shape(report, role, target):
    _require(isinstance(report, dict), f'{role} report is not an object')
    _require(report.get('resultKind') == RESULT_KIND and report.get('schemaVersion') == 1 and
             report.get('protocolVersion') == PROTOCOL_VERSION, f'{role} report is not a backend-parity v1 report')
    _require(report.get('target') == target, f'{role} report has target {report.get("target")!r}, expected {target!r}')
    qualification = report.get('qualification')
    _require(isinstance(qualification, dict) and qualification == QUALIFICATION,
             f'{role} report claims a qualification or lacks the explicit false flags')
    # The T1 rendered prompt (which contains the full G1 prompt) is declared retained by the protocol, so the
    # flag must say exactly whether T1 kept it. No other prompt or completion text may be retained.
    t1 = report.get('t1')
    t1_retained = isinstance(t1, dict) and t1.get('renderedPromptRetained') is True
    _require(report.get('rawPromptRetained') is t1_retained and report.get('completionTextRetained') is False,
             f'{role} report retention flags do not match the declared retention')


def _valid_positions(positions):
    if not isinstance(positions, list) or not positions or len(positions) > 4:
        return False
    for index, item in enumerate(positions):
        if not isinstance(item, dict) or type(item.get('position')) is not int or item.get('position') != index + 1:
            return False
        if not isinstance(item.get('sampledPiece'), str):
            return False
        if item.get('top1Piece') is not None and not isinstance(item.get('top1Piece'), str):
            return False
        for key in ('top1Logprob', 'sampledLogprob'):
            if item.get(key) is not None and not _number(item.get(key)):
                return False
        top = item.get('top')
        if not isinstance(top, list) or len(top) > 10:
            return False
        for alternative in top:
            if (not isinstance(alternative, dict) or not isinstance(alternative.get('piece'), str) or
                    (alternative.get('logprob') is not None and not _number(alternative.get('logprob')))):
                return False
    return True


def _answer_key(row):
    answer = row.get('answer') if isinstance(row, dict) else None
    if not isinstance(answer, dict):
        return None
    return (answer.get('classification'), answer.get('value'), answer.get('length'))


def _completeness(report, role):
    """Return reason codes; an empty list means the arm is complete and bound."""
    reasons = []
    if report.get('reportStatus') != 'complete' or report.get('failureCode') is not None:
        reasons.append(f'{role}:aborted-or-incomplete:{report.get("failureCode")}')
    if report.get('bindingStatus') != 'verified':
        reasons.append(f'{role}:binding-not-verified')
    provenance = report.get('sourceProvenance')
    if not isinstance(provenance, dict) or provenance.get('endStatus') != 'verified' or \
            not isinstance(provenance.get('sha256'), dict) or not provenance.get('sha256'):
        reasons.append(f'{role}:source-not-verified')
    if report.get('historicalBodyPinVerified') is not True:
        reasons.append(f'{role}:historical-body-pin-not-verified')
    methodology = report.get('methodology')
    if not isinstance(methodology, dict) or methodology.get('issuedRequests') != 5 or methodology.get('retryCount') != 0:
        reasons.append(f'{role}:not-five-requests-without-retry')
    for step in STEPS:
        row = report.get(step)
        if not isinstance(row, dict):
            reasons.append(f'{role}:{step}-missing')
        elif row.get('status') == 'aborted':
            reasons.append(f'{role}:{step}-aborted')
    for step in ('t1', 't2'):
        row = report.get(step)
        if isinstance(row, dict) and row.get('status') not in ('aborted', 'captured'):
            reasons.append(f'{role}:{step}-{row.get("status")}')
    for step in ('g1', 'g2', 'g3'):
        row = report.get(step)
        if isinstance(row, dict) and row.get('status') != 'aborted':
            if row.get('grade') not in ('correct', 'incorrect', 'inconclusive'):
                reasons.append(f'{role}:{step}-ungraded')
            if not isinstance(row.get('answer'), dict):
                reasons.append(f'{role}:{step}-answer-missing')
    for step in ('g1', 'g2'):
        row = report.get(step)
        if isinstance(row, dict) and row.get('status') != 'aborted':
            if row.get('grade') not in ('correct', 'incorrect'):
                reasons.append(f'{role}:{step}-grade-not-correct-or-incorrect')
            if row.get('finishReason') != 'stop':
                reasons.append(f'{role}:{step}-finish-reason-not-stop')
    for step in ('g2', 'g3'):
        row = report.get(step)
        if isinstance(row, dict) and row.get('status') != 'aborted':
            if row.get('logprobStatus') != 'captured' or not _valid_positions(row.get('positions')):
                reasons.append(f'{role}:{step}-logprobs-not-captured-or-malformed')
    g1, g2 = report.get('g1'), report.get('g2')
    if (isinstance(g1, dict) and isinstance(g2, dict) and g1.get('status') != 'aborted' and g2.get('status') != 'aborted'
            and _answer_key(g1) != _answer_key(g2)):
        reasons.append(f'{role}:g1-g2-disagree')
    for field in ('catalogSha256', 'engineSha256', 'modelSha256'):
        if not _is_sha(report.get(field)):
            reasons.append(f'{role}:{field}-invalid')
        elif report.get(field) != PROTOCOL_HASHES[field]:
            reasons.append(f'{role}:{field}-differs-from-protocol')
    methodology = methodology if isinstance(methodology, dict) else {}
    if not _is_sha(methodology.get('g1RequestBodySha256')):
        reasons.append(f'{role}:g1-body-sha-invalid')
    if isinstance(g1, dict) and g1.get('status') != 'aborted' and g1.get('requestBodySha256') != methodology.get('g1RequestBodySha256'):
        reasons.append(f'{role}:g1-row-body-differs-from-bound-body')
    startup = report.get('startupDiagnostics')
    if (not isinstance(startup, dict) or startup.get('reportedFlashAttentionMode') is None or
            startup.get('reportedFlashAttentionResolved') is None):
        reasons.append(f'{role}:flash-attention-not-captured')
    if role == 'cpu':
        placement = report.get('placementEvidence')
        if (not isinstance(placement, dict) or type(placement.get('reportedGpuLayers')) is not int or
                placement.get('reportedGpuLayers') != 0 or type(placement.get('gpuBufferLinesObserved')) is not int or
                placement.get('gpuBufferLinesObserved') != 0 or not _number(placement.get('cpuModelBufferMiB')) or
                placement.get('cpuModelBufferMiB') <= 0):
            reasons.append('cpu:placement-not-zero-gpu-layers-and-buffers')
    return reasons


def _parse_arguments(arguments):
    if not isinstance(arguments, list) or not all(isinstance(item, str) for item in arguments):
        return None
    options, index = {}, 0
    while index < len(arguments):
        token = arguments[index]
        if not token.startswith('--') or token in options:
            return None
        if index + 1 < len(arguments) and not arguments[index + 1].startswith('--'):
            options[token] = arguments[index + 1]
            index += 2
        else:
            options[token] = True
            index += 1
    return options


def _argument_differences(normal, cpu):
    n_options, c_options = _parse_arguments(normal.get('requestedArguments')), _parse_arguments(cpu.get('requestedArguments'))
    if n_options is None or c_options is None:
        return ['requested-arguments-unparseable']
    reasons = []
    for key in sorted(set(n_options) | set(c_options)):
        if key in DECLARED_VALUE_DIFFERENCES:
            expected_n, expected_c = DECLARED_VALUE_DIFFERENCES[key]
            if n_options.get(key) != expected_n or c_options.get(key) != expected_c:
                reasons.append(f'requested-arguments-differ:{key}')
        elif key in DECLARED_CPU_ONLY_FLAGS:
            if key in n_options or c_options.get(key) is not True:
                reasons.append(f'requested-arguments-differ:{key}')
        elif key not in n_options or key not in c_options or n_options[key] != c_options[key]:
            reasons.append(f'requested-arguments-differ:{key}')
    for key in tuple(DECLARED_VALUE_DIFFERENCES) + DECLARED_CPU_ONLY_FLAGS:
        if key not in n_options and key not in DECLARED_CPU_ONLY_FLAGS or key not in c_options:
            reasons.append(f'requested-arguments-differ:{key}')
    return reasons


def _flash_tuple(report):
    startup = report.get('startupDiagnostics') or {}
    return (startup.get('reportedFlashAttentionMode'), startup.get('reportedFlashAttentionResolved'))


def _binding_mismatches(normal, cpu):
    reasons = []
    for field in BOUND_FIELDS:
        if normal.get(field) != cpu.get(field):
            reasons.append(f'binding-mismatch:{field}')
    n_method, c_method = normal.get('methodology') or {}, cpu.get('methodology') or {}
    if n_method.get('g1RequestBodySha256') != c_method.get('g1RequestBodySha256'):
        reasons.append('binding-mismatch:g1RequestBodySha256')
    for step, label in (('g2', 'g2RequestBodySha256'), ('g3', 'g3RequestBodySha256')):
        if (normal.get(step) or {}).get('requestBodySha256') != (cpu.get(step) or {}).get('requestBodySha256'):
            reasons.append(f'binding-mismatch:{label}')
    if (normal.get('sourceProvenance') or {}).get('sha256') != (cpu.get('sourceProvenance') or {}).get('sha256'):
        reasons.append('source-provenance-differs')
    if (normal.get('t1') or {}).get('renderedPromptSha256') != (cpu.get('t1') or {}).get('renderedPromptSha256'):
        reasons.append('t1-render-differs')
    if (normal.get('t2') or {}).get('tokenIds') != (cpu.get('t2') or {}).get('tokenIds'):
        reasons.append('t2-token-ids-differ')
    if (normal.get('g1') or {}).get('actualPromptTokens') != (cpu.get('g1') or {}).get('actualPromptTokens'):
        reasons.append('g1-prompt-tokens-differ')
    if _flash_tuple(normal) != _flash_tuple(cpu):
        reasons.append('flash-attention-differs')
    reasons += _argument_differences(normal, cpu)
    return reasons


def _answer(row):
    answer = row.get('answer') if isinstance(row, dict) else None
    if isinstance(answer, dict) and answer.get('classification') == 'integer' and isinstance(answer.get('value'), str):
        return answer['value']
    return None


def _top1_comparable(piece):
    return isinstance(piece, str) and piece != '<other>'


def _digit_ranking(position):
    ranked = sorted((a for a in position.get('top') or [] if _number(a.get('logprob'))),
                    key=lambda a: -a['logprob'])
    return [a['piece'] for a in ranked if len(a['piece']) == 1 and a['piece'] in '0123456789']


def _position_table(normal_row, cpu_row):
    normal_positions = normal_row.get('positions') or []
    cpu_positions = cpu_row.get('positions') or []
    table = []
    for index in range(min(len(normal_positions), len(cpu_positions))):
        n, c = normal_positions[index], cpu_positions[index]
        n_piece, c_piece = n.get('top1Piece'), c.get('top1Piece')
        n_lp, c_lp = n.get('top1Logprob'), c.get('top1Logprob')
        agree = (n_piece == c_piece) if _top1_comparable(n_piece) and _top1_comparable(c_piece) else None
        n_digits, c_digits = _digit_ranking(n), _digit_ranking(c)
        table.append({
            'position': index + 1,
            'normalTop1Piece': n_piece, 'cpuTop1Piece': c_piece, 'top1Agree': agree,
            'normalTop1Logprob': n_lp, 'cpuTop1Logprob': c_lp,
            'top1LogprobDelta': (round(c_lp - n_lp, 4) if _number(n_lp) and _number(c_lp) else None),
            'normalSampledPiece': n.get('sampledPiece'), 'cpuSampledPiece': c.get('sampledPiece'),
            'normalDigitRanking': n_digits, 'cpuDigitRanking': c_digits, 'digitRankingAgree': n_digits == c_digits,
        })
    return table


def _arm_summary(report, digest):
    g1, g2, g3 = report['g1'], report['g2'], report['g3']
    summary = {
        'reportSha256': digest, 'target': report.get('target'), 'reportStatus': report.get('reportStatus'),
        'failureCode': report.get('failureCode'), 'valid': report.get('valid'), 'runId': report.get('runId'),
    }
    for step in ('t1', 't2'):
        row = report.get(step) or {}
        summary[step] = {'status': row.get('status'),
                         'matchesLocal': row.get('matchesLocalRender', row.get('matchesLocalTokenIds'))}
    summary['t1']['renderedPromptSha256'] = (report.get('t1') or {}).get('renderedPromptSha256')
    for name, row in (('g1', g1), ('g2', g2), ('g3', g3)):
        if row.get('status') == 'aborted':
            summary[name] = {'status': 'aborted'}
            continue
        summary[name] = {'grade': row.get('grade'), 'strictPass': row.get('strictPass'),
                         'answerClassification': (row.get('answer') or {}).get('classification'),
                         'answerValue': _answer(row), 'finishReason': row.get('finishReason'),
                         'actualOutputTokens': row.get('actualOutputTokens')}
    return summary


def _decide(normal, cpu, g2_positions):
    """Return (classification, reasons) for two complete, bound, valid arms."""
    n_answer, c_answer = _answer(normal['g1']), _answer(cpu['g1'])
    first = g2_positions[0] if g2_positions else None
    if n_answer == EXPECTED_ANSWER and c_answer == EXPECTED_ANSWER:
        return 'both-correct', []
    if c_answer == EXPECTED_ANSWER:
        # CPU returned 63 and the Vulkan arm did not (including a non-integer or unretained answer).
        return 'h-vulkan-lead', []
    if n_answer == EXPECTED_ANSWER:
        # Not an enumerated table row: Vulkan correct, CPU not. No reading or next step is predeclared.
        return 'outside-predeclared-table', ['vulkan-returned-63-cpu-did-not']
    if n_answer is None and c_answer is None:
        return 'incomplete', ['g1-answers-not-retained-integers-in-either-arm']
    if n_answer is None or c_answer is None:
        return 'numerical-divergence-lead', ['one-arm-answer-not-a-retained-integer']
    if n_answer != c_answer:
        return 'numerical-divergence-lead', ['different-wrong-integers']
    if first is None or first['top1Agree'] is None:
        return 'incomplete', ['first-position-top1-not-comparable']
    if not first['top1Agree']:
        return 'numerical-divergence-lead', ['first-position-top1-disagree']
    return 'h-model-supported', []


def compare(normal, cpu, normal_sha256='', cpu_sha256=''):
    _validate_shape(normal, 'normal', 'Normal')
    _validate_shape(cpu, 'cpu', 'CpuReference')
    reasons = _completeness(normal, 'normal') + _completeness(cpu, 'cpu')
    reasons += _binding_mismatches(normal, cpu)
    result = {
        'schemaVersion': 1, 'resultKind': COMPARISON_KIND, 'protocolVersion': PROTOCOL_VERSION,
        'classification': None, 'reading': None, 'reasons': [], 'comparable': False,
        'qualification': dict(QUALIFICATION),
        'caution': 'Single-prompt, single-seed, two-run comparison. No throughput, speed, quality-qualification, GDN '
                   'or general-correctness claim follows from any classification.',
    }
    if reasons:
        result.update(classification='incomplete', reasons=sorted(set(reasons)))
        result['reading'] = READINGS['incomplete']
        result['arms'] = {}
        return result
    result['arms'] = {'normal': _arm_summary(normal, normal_sha256), 'cpu': _arm_summary(cpu, cpu_sha256)}
    result['comparable'] = True
    g2_table = _position_table(normal['g2'], cpu['g2'])
    g3_table = _position_table(normal['g3'], cpu['g3'])
    first = g2_table[0] if g2_table else None
    result['firstPositionTop1Agreement'] = None if first is None else first['top1Agree']
    result['top1OnlyNote'] = TOP1_NOTE
    result['firstPositionDigitRankingAgreement'] = None if first is None else first['digitRankingAgree']
    result['g2Top1Positions'] = g2_table
    result['g3Top1Positions'] = g3_table
    result['templateAndTokenizerAgreement'] = {
        'bothRenderedPromptsMatchLocal': bool(normal['t1'].get('matchesLocalRender') and cpu['t1'].get('matchesLocalRender')),
        'bothTokenIdsMatchLocal': bool(normal['t2'].get('matchesLocalTokenIds') and cpu['t2'].get('matchesLocalTokenIds')),
        'renderedPromptsIdenticalAcrossArms': normal['t1'].get('renderedPromptSha256') == cpu['t1'].get('renderedPromptSha256'),
        'tokenIdsIdenticalAcrossArms': normal['t2'].get('tokenIds') == cpu['t2'].get('tokenIds'),
    }
    result['g1G2AnswerAgreement'] = {'normal': _answer(normal['g1']) == _answer(normal['g2']),
                                     'cpu': _answer(cpu['g1']) == _answer(cpu['g2'])}
    if not (normal['g3'].get('strictPass') is True and cpu['g3'].get('strictPass') is True):
        result['comparable'] = False
        result.update(classification='invalid-control', reasons=['g3-failed-in-' + '-and-'.join(
            arm for arm, report in (('normal', normal), ('cpu', cpu)) if report['g3'].get('strictPass') is not True)])
    else:
        classification, why = _decide(normal, cpu, g2_table)
        result.update(classification=classification, reasons=why)
        result['comparable'] = classification != 'incomplete'
    result['reading'] = READINGS[result['classification']]
    assert result['classification'] in CLASSIFICATIONS
    return result


def render(result):
    return json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + '\n'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('normal', type=Path, help='Report written with -Target Normal (Arm V)')
    parser.add_argument('cpu', type=Path, help='Report written with -Target CpuReference (Arm C)')
    parser.add_argument('--output', type=Path, help='Create this new file instead of printing; never overwrites')
    args = parser.parse_args(argv)
    try:
        normal, normal_digest = _read(args.normal)
        cpu, cpu_digest = _read(args.cpu)
        text = render(compare(normal, cpu, normal_digest, cpu_digest))
        if args.output is None:
            sys.stdout.write(text)
        else:
            with open(args.output, 'x', encoding='utf-8', newline='\n') as handle:
                handle.write(text)
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
