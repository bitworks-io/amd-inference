"""Compare like-for-like lab measurements; never promote them into executable policy."""
import argparse
import json
import math
import re
import statistics
from pathlib import Path


PROMPT_FORMAT = 'fastllm-prompt-tokens-v1'
SHA256 = re.compile(r'[0-9a-f]{64}')


def recorded_configuration(record):
    """Require the current all-GPU producer's exact, non-authoritative run snapshot."""
    recipe = record.get('recipe')
    placement = record.get('placement')
    canary = record.get('canary')
    if not isinstance(recipe, dict) or not isinstance(placement, dict) or not isinstance(canary, dict):
        raise ValueError('Missing recorded recipe, placement, or canary')
    configuration = {}
    for field in ('modelId', 'engineVersion'):
        value = record.get(field)
        if not isinstance(value, str) or not value:
            raise ValueError(f'Missing recorded {field}')
        configuration[field] = value
    for field in ('catalogSha256', 'engineSha256'):
        value = recipe.get(field)
        if not isinstance(value, str) or not SHA256.fullmatch(value):
            raise ValueError(f'Missing or invalid recorded recipe.{field}')
        configuration[f'recipe.{field}'] = value
    for field in ('backend', 'cacheTypeK', 'cacheTypeV', 'speculation', 'flashAttention', 'splitMode'):
        value = recipe.get(field)
        if not isinstance(value, str) or not value:
            raise ValueError(f'Missing recorded recipe.{field}')
        configuration[f'recipe.{field}'] = value
    if recipe['backend'] not in ('Vulkan', 'ROCm'):
        raise ValueError('Recorded recipe.backend is not a recognized benchmark backend')
    if 'tensorSplit' not in recipe or (recipe['tensorSplit'] is not None and
                                      (not isinstance(recipe['tensorSplit'], str) or not recipe['tensorSplit'])):
        raise ValueError('Missing or invalid recorded recipe.tensorSplit')
    configuration['recipe.tensorSplit'] = recipe['tensorSplit']
    arguments = recipe.get('requestedArguments')
    if not isinstance(arguments, list) or not arguments or any(not isinstance(arg, str) or not arg for arg in arguments):
        raise ValueError('Missing or invalid recorded recipe.requestedArguments')
    configuration['recipe.requestedArguments'] = arguments
    def one_flag(flag):
        indices = [i for i, arg in enumerate(arguments) if arg == flag]
        if len(indices) != 1 or indices[0] + 1 >= len(arguments):
            raise ValueError(f'Missing or ambiguous recorded {flag} argument')
        return arguments[indices[0] + 1]
    if one_flag('--model') != '<verified-model>' or one_flag('--n-gpu-layers') != 'all':
        raise ValueError('Recorded launch is not the normalized all-GPU benchmark configuration')
    for flag, field in (('--ctx-size', 'contextSize'), ('--parallel', 'slots'),
                        ('--cache-type-k', 'cacheTypeK'), ('--cache-type-v', 'cacheTypeV'),
                        ('--flash-attn', 'flashAttention'), ('--split-mode', 'splitMode'),
                        ('--spec-type', 'speculation')):
        if one_flag(flag) != str(recipe.get(field)):
            raise ValueError(f'Recorded recipe.{field} differs from {flag} launch argument')
    if one_flag('--fit') not in ('on', 'off'):
        raise ValueError('Missing or invalid recorded fit argument')
    adapters = recipe.get('adapters')
    if not isinstance(adapters, list) or not adapters:
        raise ValueError('Missing recorded recipe.adapters')
    selected = []
    for adapter in adapters:
        if not isinstance(adapter, dict):
            raise ValueError('Malformed recorded recipe.adapters')
        entry = tuple(adapter.get(key) for key in ('device', 'name', 'vramMiB', 'driverVersion', 'backend'))
        if (any(value is None or value == '' for value in entry) or not isinstance(entry[0], str)
                or not isinstance(entry[1], str) or type(entry[2]) is not int or entry[2] <= 0
                or not isinstance(entry[3], str) or entry[4] != recipe['backend']):
            raise ValueError('Missing recorded adapter identity or memory')
        selected.append(entry)
    devices = [adapter[0] for adapter in selected]
    if len(set(devices)) != len(devices) or one_flag('--device') != ','.join(devices):
        raise ValueError('Recorded launch devices differ from selected adapters')
    configuration['recipe.adapters'] = selected
    for field in ('reportedLayers', 'totalLayers'):
        if type(placement.get(field)) is not int or placement[field] <= 0:
            raise ValueError(f'Missing or invalid recorded placement.{field}')
        configuration[f'placement.{field}'] = placement[field]
    if (placement.get('reportedAllLayers') is not True or
            placement['reportedLayers'] != placement['totalLayers']):
        raise ValueError('Recorded placement is not full GPU')
    if not isinstance(placement.get('devices'), list) or sorted(placement['devices']) != sorted(devices):
        raise ValueError('Recorded placement devices differ from selected adapters')
    configuration['placement.devices'] = sorted(devices)
    if (type(canary.get('effectiveContext')) is not int or
            canary['effectiveContext'] != recipe.get('contextSize') or canary.get('modelIdentity') is not True):
        raise ValueError('Recorded canary effective context or model identity differs from recipe')
    configuration['canary.effectiveContext'] = canary['effectiveContext']
    return configuration


def prompt_identities(record, groups):
    """Return prompt-length -> digest, or None for a legacy unbound report."""
    methodology = record['methodology']
    if 'promptArtifacts' not in methodology:
        if any('promptArtifactSha256' in sample for sample in record['samples']):
            raise ValueError('Sample prompt digest exists without prompt artifact map')
        return None
    artifacts = methodology['promptArtifacts']
    if not isinstance(artifacts, list):
        raise ValueError('Prompt artifact map must be a list')
    identities = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict) or set(artifact) != {'requestedPromptTokens', 'tokenCount', 'sha256', 'format'}:
            raise ValueError('Malformed prompt artifact entry')
        length = artifact['requestedPromptTokens']
        if (type(length) is not int or length <= 0 or type(artifact['tokenCount']) is not int
                or artifact['tokenCount'] != length or artifact['format'] != PROMPT_FORMAT
                or not isinstance(artifact['sha256'], str)
                or not re.fullmatch('[0-9a-f]{64}', artifact['sha256']) or length in identities):
            raise ValueError('Invalid or duplicate prompt artifact entry')
        identities[length] = artifact['sha256']
    if set(identities) != set(groups):
        raise ValueError('Prompt artifact groups differ from measured workloads')
    if any(sample.get('promptArtifactSha256') != identities[sample['requestedPromptTokens']]
           for sample in record['samples']):
        raise ValueError('Sample prompt artifact digest differs')
    return identities


def recorded_legacy_host(inventory):
    """Require actual CIM host evidence; two absent sections are not a match."""
    processors = inventory.get('processors')
    system = inventory.get('system')
    os = inventory.get('os')
    if not isinstance(processors, list) or not processors or not isinstance(system, dict) or not isinstance(os, dict):
        raise ValueError('Missing recorded legacy Windows host inventory')
    cpu = []
    for processor in processors:
        if not isinstance(processor, dict):
            raise ValueError('Malformed recorded legacy Windows processor inventory')
        name = processor.get('Name')
        cores = processor.get('NumberOfCores')
        logical = processor.get('NumberOfLogicalProcessors')
        if (not isinstance(name, str) or not name or type(cores) is not int or cores <= 0
                or type(logical) is not int or logical <= 0):
            raise ValueError('Incomplete recorded legacy Windows processor inventory')
        cpu.append((name, cores, logical))
    manufacturer, model = system.get('Manufacturer'), system.get('Model')
    memory = system.get('TotalPhysicalMemory')
    if (not isinstance(manufacturer, str) or not manufacturer or not isinstance(model, str) or not model
            or type(memory) is not int or memory <= 0):
        raise ValueError('Incomplete recorded legacy Windows system inventory')
    version, build, architecture = (os.get(key) for key in ('Version', 'BuildNumber', 'OSArchitecture'))
    if any(not isinstance(value, str) or not value for value in (version, build, architecture)):
        raise ValueError('Incomplete recorded legacy Windows OS inventory')
    # Total physical memory is a usable-memory capacity, not free/available RAM.
    return ('legacy-cim', tuple(cpu), manufacturer, model, memory, version, build, architecture)


def recorded_host(inventory):
    """Keep legacy CIM and additive native-host provenance separate."""
    if not isinstance(inventory, dict):
        raise ValueError('Missing recorded Windows host inventory')
    if 'nativeHost' not in inventory:
        return recorded_legacy_host(inventory)
    host = inventory['nativeHost']
    if (not isinstance(host, dict) or type(host.get('schemaVersion')) is not int
            or host['schemaVersion'] != 1 or host.get('kind') != 'windows-native-host-inventory'
            or host.get('qualified') is not False or host.get('status') != 'captured'):
        raise ValueError('Missing or incomplete recorded native Windows host inventory')
    memory, logical, os, advisory = (host.get(key) for key in
                                      ('physicalMemoryBytes', 'activeLogicalProcessors', 'os', 'advisory'))
    if not all(isinstance(section, dict) for section in (memory, logical, os, advisory)):
        raise ValueError('Missing recorded native Windows host section')
    if (memory.get('status') != 'captured' or memory.get('source') != 'GlobalMemoryStatusEx.ullTotalPhys'
            or type(memory.get('value')) is not int or memory['value'] <= 0):
        raise ValueError('Missing recorded native physical memory')
    if (logical.get('status') != 'captured' or logical.get('source') != 'GetActiveProcessorCount.ALL_PROCESSOR_GROUPS'
            or type(logical.get('value')) is not int or logical['value'] <= 0):
        raise ValueError('Missing recorded native logical processor count')
    if (os.get('status') != 'captured' or os.get('versionSource') != 'RtlGetVersion'
            or os.get('ubrSource') != 'HKLM.CurrentVersion.UBR'
            or os.get('architectureSource') != 'GetNativeSystemInfo'
            or os.get('architecture') not in ('x64', 'arm64', 'x86')
            or any(type(os.get(field)) is not int or os[field] < 0
                   for field in ('major', 'minor', 'build', 'ubr')) or os['major'] == 0):
        raise ValueError('Missing recorded native Windows OS identity')
    cpu = advisory.get('cpuNames')
    if (not isinstance(cpu, dict) or cpu.get('status') != 'captured'
            or cpu.get('source') != 'HKLM.HARDWARE.CentralProcessor.ProcessorNameString'
            or cpu.get('completeScan') is not True or type(cpu.get('enumeratedKeys')) is not int
            or not 1 <= cpu['enumeratedKeys'] <= 256 or cpu.get('scanLimit') != 256
            or not isinstance(cpu.get('value'), list) or not 1 <= len(cpu['value']) <= 4
            or any(not isinstance(name, str) or not name or len(name) > 128 for name in cpu['value'])
            or len(set(cpu['value'])) != len(cpu['value'])):
        raise ValueError('Missing recorded native CPU name identity')
    board = []
    for key, source in (('systemManufacturer', 'HKLM.HARDWARE.System.BIOS.SystemManufacturer'),
                        ('systemProductName', 'HKLM.HARDWARE.System.BIOS.SystemProductName')):
        item = advisory.get(key)
        if not isinstance(item, dict) or item.get('source') != source:
            raise ValueError(f'Missing recorded native {key} provenance')
        if item.get('status') == 'captured':
            value = item.get('value')
            if not isinstance(value, str) or not value or len(value) > 128:
                raise ValueError(f'Incomplete recorded native {key}')
            board.append(value)
        elif item.get('status') == 'unavailable' and item.get('value') is None:
            board.append(None)
        else:
            raise ValueError(f'Incomplete recorded native {key}')
    # These are descriptive OS/API/registry facts, not authoritative motherboard
    # or selected-GPU attestation. Exact parity still requires equal recorded facts.
    return ('native-host-v1', memory['value'], logical['value'], tuple(cpu['value']),
            os['major'], os['minor'], os['build'], os['ubr'], os['architecture'], *board)


def validate(record):
    if record.get('schemaVersion') != 1 or record.get('resultKind') != 'native-windows-api-benchmark-not-full-qualification':
        raise ValueError('Expected a versioned native-Windows API benchmark result')
    if not re.fullmatch('[0-9a-f]{64}', record.get('modelSha256', '')):
        raise ValueError('Missing model artifact identity')
    samples = record.get('samples', [])
    if not samples:
        raise ValueError('No samples')
    expected = record['methodology']['repetitions']
    if expected < 5:
        raise ValueError('At least five measured repetitions are required')
    groups = {}
    for sample in samples:
        for key in ('promptTokensPerSecond', 'generationTokensPerSecond', 'timeToFirstTextMs', 'completionMs'):
            value = sample[key]
            if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
                raise ValueError('Non-positive or non-finite measurement')
        if sample['outputTokens'] != record['methodology']['generationTokens']:
            raise ValueError('Generated token count changed')
        if sample['promptTokens'] not in (sample['requestedPromptTokens'], sample['requestedPromptTokens'] + 1):
            raise ValueError('Evaluated prompt length differs from the fixed workload')
        groups.setdefault(sample['requestedPromptTokens'], []).append(sample)
    for group in groups.values():
        if len(group) != expected or sorted(s['repetition'] for s in group) != list(range(1, expected + 1)):
            raise ValueError('Missing or duplicate repetitions')
        if len({s['promptTokens'] for s in group}) != 1:
            raise ValueError('Evaluated prompt token count changed within the fixed workload')
    prompt_identities(record, groups)
    return groups


def compare(baseline, candidate):
    left, right = validate(baseline), validate(candidate)
    left_configuration, right_configuration = recorded_configuration(baseline), recorded_configuration(candidate)
    for field, value in left_configuration.items():
        if value != right_configuration[field]:
            raise ValueError(f'Cannot compare changed {field}')
    for field in ('modelSha256', 'os', 'powerPlan'):
        if baseline[field] != candidate[field]:
            raise ValueError(f'Cannot compare changed {field}')
    if baseline.get('processorCount') != candidate.get('processorCount'):
        raise ValueError('CPU processor count differs')
    a_host = recorded_host(baseline.get('windowsInventory'))
    b_host = recorded_host(candidate.get('windowsInventory'))
    if a_host[0] != b_host[0]:
        raise ValueError('Cannot compare legacy and native Windows host inventory provenance')
    if a_host != b_host:
        raise ValueError('Recorded Windows host identity differs')
    for field in ('corpus', 'sampling', 'prefixCache', 'generationTokens', 'concurrency',
                  'warmupPerPrompt', 'repetitions', 'randomizedPromptOrder'):
        if field not in baseline['methodology'] or field not in candidate['methodology']:
            raise ValueError(f'Missing recorded methodology.{field}')
        if baseline['methodology'][field] != candidate['methodology'][field]:
            raise ValueError(f'Cannot compare changed workload {field}')
    for field in ('contextSize', 'slots'):
        if baseline['recipe'][field] != candidate['recipe'][field]:
            raise ValueError(f'Cannot compare changed {field}')
    # Matching reported adapter indices/names is not stable PCI identity.
    if left.keys() != right.keys():
        raise ValueError('Prompt workloads differ')
    left_identity = prompt_identities(baseline, left)
    right_identity = prompt_identities(candidate, right)
    if (left_identity is None) != (right_identity is None):
        raise ValueError('Cannot compare one prompt-identified report with one legacy report')
    if left_identity is not None and left_identity != right_identity:
        raise ValueError('Prompt token artifacts differ')
    comparisons = []
    for prompt in sorted(left):
        if {s['promptTokens'] for s in left[prompt]} != {s['promptTokens'] for s in right[prompt]}:
            raise ValueError('Actual prefill token counts differ')
        row = {'promptTokens': prompt}
        for field in ('promptTokensPerSecond', 'generationTokensPerSecond', 'timeToFirstTextMs', 'completionMs'):
            a = statistics.median(s[field] for s in left[prompt])
            b = statistics.median(s[field] for s in right[prompt])
            row[field] = {'baselineMedian': a, 'candidateMedian': b, 'changePercent': 100 * (b / a - 1)}
        comparisons.append(row)
    return {
        'schemaVersion': 1,
        'decision': 'descriptive-comparison-only',
        'qualificationApproved': False,
        'hostInventoryProvenance': a_host[0],
        'promptIdentityVerified': left_identity is not None,
        'cautions': [
            'This tool does not modify settings or the catalog.',
            'Quality, memory residency, soak, exclusive workload, and authoritative device identity still require review.',
            'Positive throughput change is faster; positive latency change is slower.',
            'Do not select winners from differences within measurement noise.',
            *(['Prompt token identity is unverified in legacy benchmark reports.'] if left_identity is None else []),
        ],
        'comparisons': comparisons,
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('candidate', type=Path)
    args = parser.parse_args()
    try:
        records = [json.loads(path.read_text(encoding='utf-8-sig')) for path in (args.baseline, args.candidate)]
        print(json.dumps(compare(*records), indent=2, allow_nan=False))
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.error(str(error))
