"""Offline comparator tests use synthetic reports; none is evidence about a model or engine."""

import contextlib
import copy
import io
import json
import tempfile
import unittest
from pathlib import Path

from tools import compare_backend_parity as comparator
from tools.compare_backend_parity import compare, render

BODY = 'b' * 64
G3_BODY = 'c' * 64
QUALIFICATION = {'approved': False, 'qualityEvaluation': False, 'semanticQualified': False,
                 'performanceQualified': False, 'physicalResidency': False, 'throughputClaim': False,
                 'gdnClaim': False, 'generalCorrectnessClaim': False}


def arguments(target):
    cpu = target == 'CpuReference'
    base = ['--model', '<verified-model>', '--offline', '--no-mmproj', '--spec-type', 'none', '--alias',
            'qwen3.8-27b-ud-q4-k-m', '--host', '127.0.0.1', '--port', '18089' if cpu else '8080', '--ctx-size', '32768',
            '--parallel', '1', '--n-gpu-layers', '0' if cpu else 'all', '--fit', 'off' if cpu else 'on',
            '--fit-target', '768', '--device', 'none' if cpu else 'Vulkan0', '--split-mode', 'none']
    if cpu:
        base += ['--no-op-offload', '--no-kv-offload']
    return base + ['--flash-attn', 'auto', '--jinja']


def positions(first='6', logprobs=(-0.12, -0.5, -0.01, -0.3), sampled=('6', '4', '<|im_end|>', '<other>')):
    rows = []
    for index, value in enumerate(logprobs):
        piece = first if index == 0 else sampled[index]
        rows.append({'position': index + 1, 'sampledPiece': sampled[index], 'sampledLogprob': value,
                     'top1Piece': piece, 'top1Logprob': value,
                     'top': [{'piece': piece, 'logprob': value}]})
    return rows


def generation(step, value, strict, grade, body, with_logprobs, first='6', logprobs=(-0.12, -0.5, -0.01, -0.3)):
    classification = 'integer' if value is not None else 'non-integer'
    row = {'step': step, 'caseId': 'arithmetic-steps-v1', 'expected': '63', 'requestBodySha256': body,
           'logprobsRequested': with_logprobs, 'httpStatus': 200, 'finishReason': 'stop',
           'actualPromptTokens': 60, 'actualOutputTokens': 3, 'grade': grade,
           'errorCode': None if strict else 'WRONG_ANSWER', 'strictClassification': 'wrong-answer',
           'strictPass': strict, 'answer': {'classification': classification, 'value': value, 'length': 2},
           'answerMatchesExpected': value == '63'}
    if with_logprobs:
        row['logprobStatus'] = 'captured'
        row['positions'] = positions(first=first, logprobs=logprobs)
    return row


def arm(target, g1='64', g2=None, first='6', g3_pass=True, logprobs=(-0.12, -0.5, -0.01, -0.3)):
    g2 = g1 if g2 is None else g2
    g1_pass = g1 == '63'
    g3 = generation('G3', '869' if g3_pass else '870', g3_pass, 'correct' if g3_pass else 'incorrect',
                    G3_BODY, True, first='8', logprobs=logprobs)
    g3['caseId'] = 'arithmetic-invoice-v1'
    g3['expected'] = '869'
    ids = list(range(100, 150))
    report = {
        'schemaVersion': 1, 'resultKind': 'private-backend-parity-diagnostic',
        'protocolVersion': 'qwen38-backend-parity-v1', 'recordedAt': '2026-10-06T00:00:00.0000000Z',
        'target': target, 'reportStatus': 'complete', 'failureCode': None, 'bindingStatus': 'verified',
        'runId': ('a' if target == 'Normal' else 'b') * 32,
        'processIdentity': {'pid': 1, 'startUtcTicks': 2}, 'modelId': 'qwen3.8-27b-ud-q4-k-m',
        'modelSha256': comparator.PROTOCOL_HASHES['modelSha256'], 'engineVersion': 'b10698',
        'engineSha256': comparator.PROTOCOL_HASHES['engineSha256'],
        'catalogSha256': comparator.PROTOCOL_HASHES['catalogSha256'], 'contextSize': 32768,
        'requestedArguments': arguments(target),
        'startupDiagnostics': {'status': 'captured', 'reportedFlashAttentionMode': 'auto',
                               'reportedFlashAttentionResolved': True},
        'placementEvidence': ({'reportedGpuLayers': 0, 'reportedTotalLayers': 65, 'cpuModelBufferMiB': 15700.5,
                               'gpuBufferLinesObserved': 0} if target == 'CpuReference'
                              else {'reportedLayers': 66, 'totalLayers': 66, 'devices': ['Vulkan0']}),
        'historicalBodyPinVerified': True,
        'sourceProvenance': {'endStatus': 'verified', 'sha256': {'diagnostic': '1' * 64, 'tool': '2' * 64}},
        'methodology': {'issuedRequests': 5, 'retryCount': 0, 'g1RequestBodySha256': BODY},
        't1': {'status': 'captured', 'matchesLocalRender': True, 'renderedPromptSha256': 'd' * 64,
               'renderedPrompt': 'SYNTHETIC', 'renderedPromptRetained': True},
        't2': {'status': 'captured', 'matchesLocalTokenIds': True, 'tokenIds': ids, 'tokenCount': 50},
        'g1': generation('G1', g1, g1_pass, 'correct' if g1_pass else 'incorrect', BODY, False),
        'g2': generation('G2', g2, g2 == '63', 'correct' if g2 == '63' else 'incorrect', 'e' * 64, True, first=first,
                         logprobs=logprobs),
        'g3': g3,
        'g3Passed': g3_pass, 'valid': g3_pass, 'rawPromptRetained': True, 'completionTextRetained': False,
        'qualification': dict(QUALIFICATION),
    }
    return report


def pair(normal=None, cpu=None):
    return compare(normal or arm('Normal'), cpu or arm('CpuReference'))


class ClassificationTests(unittest.TestCase):
    def test_same_wrong_integer_with_agreeing_top1_supports_h_model(self):
        result = pair()
        self.assertEqual(result['classification'], 'h-model-supported')
        self.assertTrue(result['comparable'])
        self.assertTrue(result['firstPositionTop1Agreement'])
        self.assertEqual(result['reasons'], [])
        self.assertIn('model/quantization limitation', result['reading'])

    def test_cpu_63_with_vulkan_wrong_is_vulkan_lead(self):
        self.assertEqual(pair(cpu=arm('CpuReference', g1='63', first='6'))['classification'], 'h-vulkan-lead')

    def test_cpu_63_with_vulkan_non_integer_is_vulkan_lead(self):
        normal = arm('Normal')
        normal['g1']['answer'] = {'classification': 'non-integer', 'value': None, 'length': 9}
        normal['g2']['answer'] = dict(normal['g1']['answer'])
        self.assertEqual(pair(normal=normal, cpu=arm('CpuReference', g1='63'))['classification'], 'h-vulkan-lead')

    def test_different_wrong_integers_are_a_numerical_lead(self):
        result = pair(cpu=arm('CpuReference', g1='65'))
        self.assertEqual(result['classification'], 'numerical-divergence-lead')
        self.assertEqual(result['reasons'], ['different-wrong-integers'])

    def test_first_position_top1_disagreement_is_a_numerical_lead(self):
        result = pair(cpu=arm('CpuReference', first='7'))
        self.assertEqual(result['classification'], 'numerical-divergence-lead')
        self.assertEqual(result['reasons'], ['first-position-top1-disagree'])
        self.assertFalse(result['firstPositionTop1Agreement'])

    def test_vulkan_63_with_cpu_wrong_is_outside_the_table(self):
        result = pair(normal=arm('Normal', g1='63'), cpu=arm('CpuReference', g1='64'))
        self.assertEqual(result['classification'], 'outside-predeclared-table')
        self.assertEqual(result['reasons'], ['vulkan-returned-63-cpu-did-not'])
        self.assertNotIn('investigation', result['reading'].replace('No next step', ''))
        self.assertIn('No next step is predeclared', result['reading'])

    def test_both_63_is_both_correct(self):
        result = pair(normal=arm('Normal', g1='63'), cpu=arm('CpuReference', g1='63'))
        self.assertEqual(result['classification'], 'both-correct')
        self.assertIn('run-condition', result['reading'])

    def test_unretained_answers_in_both_arms_are_incomplete(self):
        normal, cpu = arm('Normal'), arm('CpuReference')
        for report in (normal, cpu):
            report['g1']['answer'] = {'classification': 'non-integer', 'value': None, 'length': 12}
            report['g2']['answer'] = dict(report['g1']['answer'])
        result = pair(normal=normal, cpu=cpu)
        self.assertEqual(result['classification'], 'incomplete')
        self.assertFalse(result['comparable'])

    def test_one_unretained_answer_is_a_numerical_lead(self):
        cpu = arm('CpuReference')
        cpu['g1']['answer'] = {'classification': 'integer-too-long', 'value': None, 'length': 9}
        cpu['g2']['answer'] = dict(cpu['g1']['answer'])
        self.assertEqual(pair(cpu=cpu)['classification'], 'numerical-divergence-lead')

    def test_other_first_position_piece_cannot_support_h_model(self):
        result = pair(normal=arm('Normal', first='<other>'), cpu=arm('CpuReference', first='<other>'))
        self.assertEqual(result['classification'], 'incomplete')
        self.assertEqual(result['reasons'], ['first-position-top1-not-comparable'])

    def test_g3_failure_makes_the_comparison_invalid(self):
        for normal_pass, cpu_pass, label in ((False, True, 'normal'), (True, False, 'cpu'), (False, False, 'normal-and-cpu')):
            result = pair(normal=arm('Normal', g3_pass=normal_pass), cpu=arm('CpuReference', g3_pass=cpu_pass))
            self.assertEqual(result['classification'], 'invalid-control')
            self.assertEqual(result['reasons'], ['g3-failed-in-' + label])
            self.assertFalse(result['comparable'])
            self.assertIn('invalid', result['reading'])

    def test_invalid_control_outranks_a_would_be_vulkan_lead(self):
        result = pair(normal=arm('Normal', g3_pass=False), cpu=arm('CpuReference', g1='63'))
        self.assertEqual(result['classification'], 'invalid-control')


class CompletenessAndBindingTests(unittest.TestCase):
    def assert_incomplete(self, normal=None, cpu=None, fragment=''):
        result = pair(normal=normal, cpu=cpu)
        self.assertEqual(result['classification'], 'incomplete')
        self.assertFalse(result['comparable'])
        self.assertTrue(any(fragment in reason for reason in result['reasons']), result['reasons'])
        self.assertEqual(result['arms'], {})
        return result

    def test_aborted_arm_is_incomplete(self):
        cpu = arm('CpuReference')
        cpu['reportStatus'] = 'aborted'
        cpu['failureCode'] = 'deadline'
        cpu['g3'] = {'step': 'G3', 'status': 'aborted', 'errorCode': 'deadline', 'grade': 'inconclusive'}
        result = self.assert_incomplete(cpu=cpu, fragment='cpu:aborted-or-incomplete:deadline')
        self.assertIn('cpu:g3-aborted', result['reasons'])

    def test_missing_rows_are_incomplete(self):
        normal = arm('Normal')
        normal['g2'] = None
        normal['t2'] = None
        self.assert_incomplete(normal=normal, fragment='normal:g2-missing')

    def test_unverified_binding_or_source_is_incomplete(self):
        normal = arm('Normal')
        normal['bindingStatus'] = 'compromised'
        self.assert_incomplete(normal=normal, fragment='binding-not-verified')
        cpu = arm('CpuReference')
        cpu['sourceProvenance']['endStatus'] = 'changed'
        self.assert_incomplete(cpu=cpu, fragment='source-not-verified')

    def test_model_engine_catalog_or_context_mismatch_is_incomplete(self):
        for field, value in (('modelSha256', '1' * 64), ('engineSha256', '2' * 64), ('catalogSha256', '3' * 64),
                             ('modelId', 'qwen3.8-27b-ud-q5-k-m'), ('contextSize', 16384), ('engineVersion', 'b10829')):
            cpu = arm('CpuReference')
            cpu[field] = value
            result = self.assert_incomplete(cpu=cpu, fragment='binding-mismatch:' + field)
            if field.endswith('Sha256'):
                self.assertIn('cpu:' + field + '-differs-from-protocol', result['reasons'])

    def test_g1_body_hash_mismatch_is_incomplete(self):
        cpu = arm('CpuReference')
        cpu['methodology']['g1RequestBodySha256'] = '4' * 64
        cpu['g1']['requestBodySha256'] = '4' * 64
        self.assert_incomplete(cpu=cpu, fragment='binding-mismatch:g1RequestBodySha256')

    def test_row_body_hash_must_match_the_bound_body(self):
        cpu = arm('CpuReference')
        cpu['g1']['requestBodySha256'] = '5' * 64
        self.assert_incomplete(cpu=cpu, fragment='cpu:g1-row-body-differs-from-bound-body')

    def test_g3_body_hash_mismatch_is_incomplete(self):
        cpu = arm('CpuReference')
        cpu['g3']['requestBodySha256'] = '6' * 64
        self.assert_incomplete(cpu=cpu, fragment='binding-mismatch:g3RequestBodySha256')

    def test_missing_logprobs_are_incomplete(self):
        normal = arm('Normal')
        normal['g2']['logprobStatus'] = 'missing'
        normal['g2']['positions'] = []
        self.assert_incomplete(normal=normal, fragment='normal:g2-logprobs-not-captured')

    def test_retry_or_extra_requests_are_incomplete(self):
        cpu = arm('CpuReference')
        cpu['methodology']['retryCount'] = 1
        self.assert_incomplete(cpu=cpu, fragment='not-five-requests-without-retry')

    def test_template_and_token_mismatch_does_not_block_a_classification(self):
        normal = arm('Normal')
        normal['t1']['matchesLocalRender'] = False
        normal['t2']['matchesLocalTokenIds'] = False
        result = pair(normal=normal)
        self.assertEqual(result['classification'], 'h-model-supported')
        agreement = result['templateAndTokenizerAgreement']
        self.assertFalse(agreement['bothRenderedPromptsMatchLocal'])
        self.assertFalse(agreement['bothTokenIdsMatchLocal'])
        self.assertTrue(agreement['renderedPromptsIdenticalAcrossArms'])

    def test_malformed_inputs_are_rejected(self):
        for mutate in (
            lambda r: r.update(resultKind='private-task-quality'),
            lambda r: r.update(schemaVersion=2),
            lambda r: r.update(protocolVersion='other'),
            lambda r: r.update(target='CpuReference'),
            lambda r: r['qualification'].update(approved=True),
            lambda r: r['qualification'].pop('gdnClaim'),
            lambda r: r.update(rawPromptRetained=False),
            lambda r: r['t1'].update(renderedPromptRetained=False),
            lambda r: r.update(completionTextRetained=True),
        ):
            normal = arm('Normal')
            mutate(normal)
            with self.assertRaises(ValueError):
                compare(normal, arm('CpuReference'))
        with self.assertRaises(ValueError):
            compare([], arm('CpuReference'))
        with self.assertRaises(ValueError):
            compare(arm('Normal'), arm('Normal'))


class OutputTests(unittest.TestCase):
    def test_top1_logprob_deltas_per_position(self):
        normal = arm('Normal', logprobs=(-0.2, -0.5, -0.01, -0.3))
        cpu = arm('CpuReference', logprobs=(-0.1235, -0.4, -0.01, -1.0))
        table = pair(normal=normal, cpu=cpu)['g2Top1Positions']
        self.assertEqual([row['position'] for row in table], [1, 2, 3, 4])
        self.assertEqual([row['top1LogprobDelta'] for row in table], [0.0765, 0.1, 0.0, -0.7])
        self.assertTrue(table[0]['top1Agree'])
        self.assertEqual(table[0]['normalTop1Logprob'], -0.2)
        self.assertEqual(table[0]['cpuTop1Logprob'], -0.1235)
        self.assertIsNone(table[3]['top1Agree'])  # both '<other>' pieces cannot be compared

    def test_position_tables_use_the_shorter_arm(self):
        normal = arm('Normal')
        normal['g2']['positions'] = normal['g2']['positions'][:2]
        result = pair(normal=normal)
        self.assertEqual(len(result['g2Top1Positions']), 2)
        self.assertEqual(len(result['g3Top1Positions']), 4)

    def test_output_is_deterministic_and_has_no_timestamp(self):
        first = render(pair())
        second = render(pair(normal=copy.deepcopy(arm('Normal')), cpu=copy.deepcopy(arm('CpuReference'))))
        self.assertEqual(first, second)
        self.assertEqual(json.loads(first), json.loads(second))
        self.assertTrue(first.endswith('\n'))
        keys = list(json.loads(first).keys())
        self.assertEqual(keys, sorted(keys))
        self.assertNotIn('recordedAt', first)
        reordered = arm('Normal')
        reordered = dict(reversed(list(reordered.items())))
        self.assertEqual(render(pair(normal=reordered)), first)

    def test_output_has_no_completion_or_prompt_text_and_false_qualification(self):
        text = render(pair())
        self.assertNotIn('SYNTHETIC', text)
        result = json.loads(text)
        self.assertEqual(result['qualification'], QUALIFICATION)
        self.assertEqual(result['resultKind'], 'private-backend-parity-comparison')
        self.assertIn(result['classification'], comparator.CLASSIFICATIONS)
        self.assertEqual(result['arms']['normal']['g1']['answerValue'], '64')
        self.assertEqual(result['arms']['cpu']['g3']['strictPass'], True)

    def test_every_predeclared_classification_is_reachable(self):
        seen = {
            pair()['classification'],
            pair(cpu=arm('CpuReference', g1='63'))['classification'],
            pair(cpu=arm('CpuReference', g1='65'))['classification'],
            pair(normal=arm('Normal', g1='63'), cpu=arm('CpuReference', g1='63'))['classification'],
            pair(cpu=arm('CpuReference', g3_pass=False))['classification'],
            pair(normal=arm('Normal', g1='63'), cpu=arm('CpuReference', g1='64'))['classification'],
        }
        cpu = arm('CpuReference')
        cpu['reportStatus'] = 'aborted'
        seen.add(pair(cpu=cpu)['classification'])
        self.assertEqual(seen, set(comparator.CLASSIFICATIONS))


class ReviewFixTests(unittest.TestCase):
    def incomplete(self, normal=None, cpu=None, fragment=''):
        result = pair(normal=normal, cpu=cpu)
        self.assertEqual(result['classification'], 'incomplete', result.get('reasons'))
        self.assertFalse(result['comparable'])
        self.assertTrue(any(fragment in reason for reason in result['reasons']), result['reasons'])
        return result

    # M1
    def test_g1_and_g2_grades_must_be_correct_or_incorrect_with_stop(self):
        for step in ('g1', 'g2'):
            for field, value, fragment in (('grade', 'inconclusive', 'grade-not-correct-or-incorrect'),
                                           ('finishReason', 'length', 'finish-reason-not-stop')):
                cpu = arm('CpuReference')
                cpu[step][field] = value
                self.incomplete(cpu=cpu, fragment=f'cpu:{step}-{fragment}')
                normal = arm('Normal')
                normal[step][field] = value
                self.incomplete(normal=normal, fragment=f'normal:{step}-{fragment}')

    # M2
    def test_source_provenance_maps_must_be_identical(self):
        cpu = arm('CpuReference')
        cpu['sourceProvenance']['sha256']['tool'] = '9' * 64
        self.incomplete(cpu=cpu, fragment='source-provenance-differs')
        cpu = arm('CpuReference')
        cpu['sourceProvenance']['sha256'] = {}
        self.incomplete(cpu=cpu, fragment='cpu:source-not-verified')

    def test_render_hash_token_ids_prompt_tokens_and_g2_body_must_match(self):
        cpu = arm('CpuReference')
        cpu['t1']['renderedPromptSha256'] = '7' * 64
        self.incomplete(cpu=cpu, fragment='t1-render-differs')
        cpu = arm('CpuReference')
        cpu['t2']['tokenIds'] = list(range(200, 250))
        self.incomplete(cpu=cpu, fragment='t2-token-ids-differ')
        cpu = arm('CpuReference')
        cpu['g1']['actualPromptTokens'] = 61
        self.incomplete(cpu=cpu, fragment='g1-prompt-tokens-differ')
        cpu = arm('CpuReference')
        cpu['g2']['requestBodySha256'] = '8' * 64
        self.incomplete(cpu=cpu, fragment='binding-mismatch:g2RequestBodySha256')

    def test_cpu_placement_must_be_zero_layers_and_zero_gpu_buffers(self):
        for key, value in (('reportedGpuLayers', 1), ('gpuBufferLinesObserved', 1), ('cpuModelBufferMiB', 0),
                           ('reportedGpuLayers', True), ('gpuBufferLinesObserved', False)):
            cpu = arm('CpuReference')
            cpu['placementEvidence'][key] = value
            self.incomplete(cpu=cpu, fragment='cpu:placement-not-zero')
        cpu = arm('CpuReference')
        cpu['placementEvidence'] = None
        self.incomplete(cpu=cpu, fragment='cpu:placement-not-zero')

    def test_requested_arguments_may_differ_only_by_the_declared_set(self):
        self.assertEqual(pair()['classification'], 'h-model-supported')
        mutations = {
            'extra option': lambda a: a + ['--cache-ram', '0'],
            'port': lambda a: [('18090' if x == '18089' else x) for x in a],
            'ngl': lambda a: [('1' if x == '0' else x) for x in a],
            'fit': lambda a: [('on' if x == 'off' else x) for x in a],
            'device': lambda a: [('Vulkan0' if x == 'none' else x) for x in a],
            'missing no-kv-offload': lambda a: [x for x in a if x != '--no-kv-offload'],
            'missing no-op-offload': lambda a: [x for x in a if x != '--no-op-offload'],
            'ctx': lambda a: [('16384' if x == '32768' else x) for x in a],
            'unparseable': lambda a: ['bad'] + a,
            'duplicate': lambda a: a + ['--jinja'],
        }
        for name, mutate in mutations.items():
            cpu = arm('CpuReference')
            cpu['requestedArguments'] = mutate(cpu['requestedArguments'])
            result = pair(cpu=cpu)
            self.assertEqual(result['classification'], 'incomplete', name)
            self.assertTrue(any(r.startswith('requested-arguments') for r in result['reasons']), (name, result['reasons']))
        normal = arm('Normal')
        normal['requestedArguments'] = normal['requestedArguments'] + ['--no-kv-offload']
        self.incomplete(normal=normal, fragment='requested-arguments-differ:--no-kv-offload')

    # S3
    def test_flash_attention_resolution_must_match_and_be_captured(self):
        cpu = arm('CpuReference')
        cpu['startupDiagnostics']['reportedFlashAttentionResolved'] = False
        result = self.incomplete(cpu=cpu, fragment='flash-attention-differs')
        self.assertIn('flash-attention-differs', result['reasons'])
        cpu = arm('CpuReference')
        cpu['startupDiagnostics']['reportedFlashAttentionMode'] = 'enabled'
        self.incomplete(cpu=cpu, fragment='flash-attention-differs')
        for role in ('normal', 'cpu'):
            normal, cpu = arm('Normal'), arm('CpuReference')
            (normal if role == 'normal' else cpu)['startupDiagnostics'] = None
            self.incomplete(normal=normal, cpu=cpu, fragment=f'{role}:flash-attention-not-captured')

    # S4
    def test_retention_flag_follows_t1_retention(self):
        for report in (arm('Normal'), arm('CpuReference')):
            report['t1']['renderedPromptRetained'] = False
            report['t1']['renderedPrompt'] = None
            report['rawPromptRetained'] = False
        self.assertEqual(pair(normal=_with(arm('Normal'), False), cpu=_with(arm('CpuReference'), False))['classification'],
                         'h-model-supported')
        with self.assertRaises(ValueError):
            compare(_with(arm('Normal'), True, flag=False), arm('CpuReference'))
        with self.assertRaises(ValueError):
            compare(_with(arm('Normal'), False, flag=True), arm('CpuReference'))

    # S5
    def test_historical_body_pin_must_be_verified_in_both_arms(self):
        for role, key in (('normal', 'normal'), ('cpu', 'cpu')):
            normal, cpu = arm('Normal'), arm('CpuReference')
            (normal if role == 'normal' else cpu)['historicalBodyPinVerified'] = False
            self.incomplete(normal=normal, cpu=cpu, fragment=f'{role}:historical-body-pin-not-verified')
        cpu = arm('CpuReference')
        del cpu['historicalBodyPinVerified']
        self.incomplete(cpu=cpu, fragment='cpu:historical-body-pin-not-verified')

    # S10
    def test_g1_g2_disagreement_within_an_arm_is_incomplete(self):
        cpu = arm('CpuReference', g1='64', g2='65')
        self.incomplete(cpu=cpu, fragment='cpu:g1-g2-disagree')
        normal = arm('Normal', g1='64', g2='65')
        self.incomplete(normal=normal, fragment='normal:g1-g2-disagree')

    def test_digit_ranking_is_recorded_but_not_used_to_classify(self):
        cpu = arm('CpuReference')
        cpu['g2']['positions'][0]['top'] = [{'piece': '7', 'logprob': -0.1}, {'piece': '6', 'logprob': -0.2}]
        cpu['g2']['positions'][0]['top1Piece'] = '6'
        normal = arm('Normal')
        normal['g2']['positions'][0]['top'] = [{'piece': '6', 'logprob': -0.1}, {'piece': '7', 'logprob': -0.2}]
        result = pair(normal=normal, cpu=cpu)
        self.assertEqual(result['classification'], 'h-model-supported')
        self.assertFalse(result['firstPositionDigitRankingAgreement'])
        first = result['g2Top1Positions'][0]
        self.assertEqual(first['normalDigitRanking'], ['6', '7'])
        self.assertEqual(first['cpuDigitRanking'], ['7', '6'])
        self.assertIn('first-position top-1 agreement only', result['top1OnlyNote'])

    # N8
    def test_malformed_positions_and_boolean_numbers_are_rejected(self):
        mutations = (
            lambda r: r['g2']['positions'].__setitem__(0, 'x'),
            lambda r: r['g2']['positions'][0].update(top1Logprob=True),
            lambda r: r['g2']['positions'][0].update(position=True),
            lambda r: r['g2']['positions'][0].update(top='x'),
            lambda r: r['g2']['positions'][0].update(top=[{'piece': 6, 'logprob': -1}]),
            lambda r: r['g2']['positions'][0]['top'][0].update(logprob=True),
            lambda r: r['g2'].update(positions=r['g2']['positions'] * 2),
            lambda r: r['g3']['positions'][0].pop('sampledPiece'),
        )
        for mutate in mutations:
            cpu = arm('CpuReference')
            mutate(cpu)
            self.incomplete(cpu=cpu, fragment='cpu:')

    def test_boolean_is_not_an_integer_for_issued_requests_or_context(self):
        cpu = arm('CpuReference')
        cpu['methodology']['issuedRequests'] = True
        self.incomplete(cpu=cpu, fragment='not-five-requests')
        cpu = arm('CpuReference')
        cpu['contextSize'] = True
        self.incomplete(cpu=cpu, fragment='binding-mismatch:contextSize')

    def test_output_states_that_support_rests_on_top1_only(self):
        self.assertIn('top-1', pair()['top1OnlyNote'])


def _with(report, retained, flag=None):
    report['t1']['renderedPromptRetained'] = retained
    report['rawPromptRetained'] = retained if flag is None else flag
    if not retained:
        report['t1']['renderedPrompt'] = None
    return report


class CommandLineTests(unittest.TestCase):
    def write(self, directory, name, report):
        path = Path(directory) / name
        path.write_text(json.dumps(report), encoding='utf-8')
        return path

    def test_cli_prints_json_and_binds_input_hashes(self):
        with tempfile.TemporaryDirectory() as directory:
            normal = self.write(directory, 'normal.json', arm('Normal'))
            cpu = self.write(directory, 'cpu.json', arm('CpuReference'))
            buffers = []
            for _ in range(2):
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    comparator.main([str(normal), str(cpu)])
                buffers.append(out.getvalue())
            self.assertEqual(buffers[0], buffers[1])
            result = json.loads(buffers[0])
            self.assertEqual(result['classification'], 'h-model-supported')
            self.assertRegex(result['arms']['normal']['reportSha256'], '^[0-9a-f]{64}$')
            self.assertNotEqual(result['arms']['normal']['reportSha256'], result['arms']['cpu']['reportSha256'])

    def test_cli_output_file_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            normal = self.write(directory, 'normal.json', arm('Normal'))
            cpu = self.write(directory, 'cpu.json', arm('CpuReference'))
            target = Path(directory) / 'comparison.json'
            comparator.main([str(normal), str(cpu), '--output', str(target)])
            self.assertEqual(json.loads(target.read_text(encoding='utf-8'))['classification'], 'h-model-supported')
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                comparator.main([str(normal), str(cpu), '--output', str(target)])

    def test_cli_rejects_invalid_json_and_non_finite_constants(self):
        with tempfile.TemporaryDirectory() as directory:
            cpu = self.write(directory, 'cpu.json', arm('CpuReference'))
            bad = Path(directory) / 'bad.json'
            for content in ('not json', '{"a": NaN}', '\xff'):
                bad.write_bytes(content.encode('latin-1'))
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    comparator.main([str(bad), str(cpu)])
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                comparator.main([str(Path(directory) / 'missing.json'), str(cpu)])


if __name__ == '__main__':
    unittest.main()
