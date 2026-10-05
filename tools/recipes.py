"""Inspect measured recipes. This development tool never changes serving policy.

Approval is a reviewed, source-pinned manifest digest, not a field inside a
benchmark or an operator-supplied JSON file. The shipped allowlist is empty.
"""

import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path

try:
    from tools.compare_benchmarks import validate as validate_benchmark
except ModuleNotFoundError:  # direct ``python tools/recipes.py`` invocation
    from compare_benchmarks import validate as validate_benchmark


# Add a SHA-256 only after reviewing the entire manifest and its evidence in a
# source change. A mutable status/approved flag inside a report has no authority.
REVIEWED_MANIFEST_SHA256 = frozenset()
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_EVIDENCE_BYTES = 64 * 1024 * 1024
MAX_RECORDS = 64
REQUIRED_BINDING = frozenset({
    'os', 'osBuild', 'driverVersion', 'engineVersion', 'engineAssetSha256', 'engineSha256',
    'engineBackend', 'modelId', 'modelSha256', 'catalogSha256',
    'adapters', 'topology', 'workload',
})
REQUIRED_RECIPE = frozenset({
    'placement', 'contextSize', 'slots', 'gpuLayers', 'splitMode',
    'tensorSplit', 'cacheTypeK', 'cacheTypeV', 'launchArgsSha256',
})
REQUIRED_METRICS = frozenset({
    'promptTokensPerSecond', 'generationTokensPerSecond', 'timeToFirstTextMs',
    'peakDedicatedVramMiB',
})
REQUIRED_QUALIFICATION = frozenset({
    'semanticReferencePassed', 'numericalReferencePassed', 'apiPassed',
    'soakPassed', 'placementVerified', 'residencyVerified',
    'peakVramMeasured', 'exclusiveWorkloadConfirmed',
})


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode('utf-8')


def digest(value):
    return hashlib.sha256(_canonical(value)).hexdigest()


def _sha(value):
    return isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value)


def _keys(obj, required, label):
    if not isinstance(obj, dict) or set(obj) != required:
        raise ValueError(f'{label} must contain exactly {sorted(required)}')


def _positive(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0:
        raise ValueError(f'{label} must be positive and finite')


def _positive_int(value, label):
    if type(value) is not int or value <= 0:
        raise ValueError(f'{label} must be a positive integer')


def _read_limited(path):
    with path.open('rb') as source:
        raw = source.read(MAX_JSON_BYTES + 1)
    if len(raw) > MAX_JSON_BYTES:
        raise ValueError('JSON file exceeds 8 MiB limit')
    return raw


def _evidence(root, descriptor, budget):
    _keys(descriptor, {'path', 'sha256'}, 'evidence reference')
    path = Path(descriptor['path'])
    if path.is_absolute() or '..' in path.parts or not path.parts or not _sha(descriptor['sha256']):
        raise ValueError('Unsafe or unpinned evidence reference')
    root = root.resolve(strict=True)
    full = (root / path).resolve(strict=True)
    if not full.is_relative_to(root) or not full.is_file():
        raise ValueError('Evidence escaped the registry directory')
    raw = _read_limited(full)
    budget['bytes'] += len(raw)
    if budget['bytes'] > MAX_EVIDENCE_BYTES:
        raise ValueError('Evidence bundle exceeds 64 MiB limit')
    if hashlib.sha256(raw).hexdigest() != descriptor['sha256']:
        raise ValueError(f'Evidence digest changed: {path}')
    return json.loads(raw)


def _check_observed_placement(placement, requested, recipe, observed_adapters):
    if not isinstance(placement, dict):
        raise ValueError('Observed layer placement is malformed')
    loaded, total = placement.get('reportedLayers'), placement.get('totalLayers')
    if type(loaded) is not int or type(total) is not int or loaded <= 0 or total <= 0 or loaded > total:
        raise ValueError('Observed layer placement is invalid')
    if requested == 'all':
        if loaded != total or placement.get('reportedAllLayers') is not True:
            raise ValueError('Observed placement conflicts with full GPU claim')
    elif loaded != min(int(requested), total):
        raise ValueError('Observed placement conflicts with requested GPU layers')
    if (recipe['placement'] == 'full-gpu') != (loaded == total):
        raise ValueError('Observed placement conflicts with recipe placement')
    devices = placement.get('devices')
    if not isinstance(devices, list) or sorted(devices) != sorted(adapter.get('device') for adapter in observed_adapters):
        raise ValueError('Observed GPU devices differ from benchmark adapters')


def validate_manifest(manifest, root, catalog, catalog_sha):
    """Validate identity, evidence, and metrics; does not grant approval."""
    _keys(manifest, {'schemaVersion', 'records'}, 'manifest')
    if manifest['schemaVersion'] != 1 or not isinstance(manifest['records'], list):
        raise ValueError('Unsupported recipe manifest')
    if len(manifest['records']) > MAX_RECORDS:
        raise ValueError('Recipe manifest exceeds 64 records')
    if not isinstance(catalog, dict) or 'engine' not in catalog or 'models' not in catalog:
        raise ValueError('Catalog is required')
    if not _sha(catalog_sha):
        raise ValueError('Exact catalog file digest required')
    ids = set()
    budget = {'bytes': 0}
    for record in manifest['records']:
        _keys(record, {'id', 'state', 'binding', 'recipe', 'metrics', 'evidence'}, 'recipe record')
        if not isinstance(record['id'], str) or not record['id'] or record['id'] in ids:
            raise ValueError('Recipe IDs must be unique and nonempty')
        ids.add(record['id'])
        if record['state'] not in ('candidate', 'reviewed'):
            raise ValueError('Unknown recipe state')
        binding = record['binding']
        _keys(binding, REQUIRED_BINDING, 'binding')
        if binding['catalogSha256'] != catalog_sha:
            raise ValueError('Stale catalog')
        for key in ('modelSha256', 'engineAssetSha256', 'engineSha256', 'catalogSha256'):
            if not _sha(binding[key]):
                raise ValueError(f'Invalid {key}')
        if binding['os'] not in ('windows', 'linux') or not all(
            isinstance(binding[k], str) and binding[k] for k in
            ('osBuild', 'driverVersion', 'engineVersion', 'engineBackend', 'modelId')
        ):
            raise ValueError('Incomplete OS, driver, engine, or model identity')
        engine = catalog['engine']
        asset = next((a for a in engine['assets'].values()
                      if a.get('sha256') == binding['engineAssetSha256']
                      and a.get('backend', '').lower() == binding['engineBackend'].lower()), None)
        if engine['version'] != binding['engineVersion'] or asset is None:
            raise ValueError('Engine is not the catalog-pinned build')
        asset_platform = asset.get('os')
        if binding['os'] == 'windows':
            if asset_platform not in (None, 'windows') or (asset_platform is None and '-win-' not in asset.get('file', '')):
                raise ValueError('Engine asset is not pinned for Windows')
        elif asset_platform != 'linux':
            raise ValueError('No catalog-pinned Linux engine asset')
        executable = next((entry for entry in asset.get('manifest', [])
                           if entry.get('path') == asset.get('entryPoint')), None)
        if executable is None or executable.get('sha256') != binding['engineSha256']:
            raise ValueError('Engine executable is not pinned by the catalog manifest')
        model = next((m for m in catalog['models'] if m['id'] == binding['modelId']), None)
        if model is None or model['sha256'] != binding['modelSha256']:
            raise ValueError('Model is not the catalog-pinned artifact')
        adapters = binding['adapters']
        if not isinstance(adapters, list) or len(adapters) not in (1, 2):
            raise ValueError('Expected one or two adapters')
        for adapter in adapters:
            _keys(adapter, {'pciId', 'vramMiB', 'busId', 'rootComplexId', 'upstreamPort',
                            'attachment', 'linkWidth', 'linkGeneration'}, 'adapter')
            if not all(isinstance(adapter[k], str) and adapter[k] for k in
                       ('pciId', 'busId', 'rootComplexId', 'upstreamPort')):
                raise ValueError('Stable PCI and bus identity required')
            _positive_int(adapter['vramMiB'], 'adapter VRAM')
            _positive_int(adapter['linkWidth'], 'PCIe link width')
            _positive(adapter['linkGeneration'], 'PCIe link generation')
            if adapter['attachment'] not in ('cpu', 'chipset'):
                raise ValueError('CPU/chipset attachment required')
        buses = [a['busId'] for a in adapters]
        if len(set(buses)) != len(buses):
            raise ValueError('Duplicate adapter bus identity')
        _keys(binding['topology'], {'gpuLinks', 'peerToPeer'}, 'topology')
        links = binding['topology']['gpuLinks']
        if not isinstance(links, list) or not isinstance(binding['topology']['peerToPeer'], bool):
            raise ValueError('Topology missing')
        if len(links) != len(adapters) - 1:
            raise ValueError('Expected one peer link for a dual-GPU recipe')
        for link in links:
            _keys(link, {'fromBusId', 'toBusId', 'path'}, 'GPU link')
            if {link['fromBusId'], link['toBusId']} != set(buses) or not link['path']:
                raise ValueError('GPU link does not match selected adapters')
        _keys(binding['workload'], {'id', 'promptTokens', 'generationTokens', 'concurrency',
                                    'sampling', 'corpus', 'prefixCache', 'warmupPerPrompt',
                                    'randomizedPromptOrder', 'powerPlan', 'processorCount',
                                    'systemFingerprint', 'promptArtifactSha256'}, 'workload')
        for field in ('promptTokens', 'generationTokens', 'concurrency'):
            _positive_int(binding['workload'][field], field)
        for field in ('processorCount', 'warmupPerPrompt'):
            _positive_int(binding['workload'][field], field)
        for field in ('systemFingerprint', 'promptArtifactSha256'):
            if not _sha(binding['workload'][field]):
                raise ValueError(f'Invalid {field}')
        _keys(record['recipe'], REQUIRED_RECIPE, 'recipe')
        recipe = record['recipe']
        if recipe['placement'] not in ('full-gpu', 'cpu-offload') or not _sha(recipe['launchArgsSha256']):
            raise ValueError('Placement and exact launch arguments required')
        for field in ('contextSize', 'slots'):
            _positive_int(recipe[field], field)
        if recipe['gpuLayers'] != 'all' and (type(recipe['gpuLayers']) is not int or recipe['gpuLayers'] <= 0):
            raise ValueError('GPU layer request must be all or a positive integer')
        if recipe['gpuLayers'] == 0:
            raise ValueError('AMD inference recipe needs GPU layers')
        _keys(record['metrics'], REQUIRED_METRICS, 'metrics')
        for key, value in record['metrics'].items():
            if key == 'peakDedicatedVramMiB':
                if record['state'] == 'candidate' and value is None:
                    continue
                if not isinstance(value, list) or len(value) != len(adapters):
                    raise ValueError('Peak dedicated VRAM must be measured per adapter')
                for peak in value:
                    _positive(peak, 'per-adapter peak dedicated VRAM')
                continue
            _positive(value, key)
        _keys(record['evidence'], {'benchmark', 'qualification'}, 'evidence')
        benchmark = _evidence(root, record['evidence']['benchmark'], budget)
        expected_kind = f"native-{binding['os']}-api-benchmark-not-full-qualification"
        if benchmark.get('resultKind') != expected_kind:
            raise ValueError('Benchmark OS/result kind differs')
        # The current runner is Windows only. The common sample contract also
        # applies to a future Linux runner with the same field semantics.
        sample_contract = dict(benchmark, resultKind='native-windows-api-benchmark-not-full-qualification')
        validate_benchmark(sample_contract)
        if benchmark['modelId'] != binding['modelId'] or benchmark['modelSha256'] != binding['modelSha256']:
            raise ValueError('Benchmark model differs')
        if benchmark['engineVersion'] != binding['engineVersion']:
            raise ValueError('Benchmark engine differs')
        if benchmark['os'] != binding['osBuild']:
            raise ValueError('Benchmark OS build differs')
        if benchmark['recipe']['catalogSha256'] != binding['catalogSha256'] or benchmark['recipe']['engineSha256'] != binding['engineSha256']:
            raise ValueError('Benchmark binary or catalog differs')
        observed_adapters = benchmark['recipe']['adapters']
        if not isinstance(observed_adapters, list) or len(observed_adapters) != len(adapters):
            raise ValueError('Benchmark adapter count differs')
        if any(observed.get('driverVersion') != binding['driverVersion']
               or observed.get('vramMiB') != bound['vramMiB']
               for observed, bound in zip(observed_adapters, adapters)):
            raise ValueError('Benchmark driver or adapter memory differs')
        arguments = benchmark['recipe']['requestedArguments']
        if not isinstance(arguments, list) or any(not isinstance(arg, str) for arg in arguments):
            raise ValueError('Benchmark launch arguments malformed')
        if digest(arguments) != recipe['launchArgsSha256']:
            raise ValueError('Benchmark launch arguments differ')
        layer_flags = [arguments[i + 1] for i, arg in enumerate(arguments[:-1])
                       if arg in ('--n-gpu-layers', '-ngl')]
        if len(layer_flags) != 1:
            raise ValueError('Benchmark launch needs exactly one GPU layer request')
        requested = layer_flags[0]
        if requested == 'all':
            if recipe['gpuLayers'] != 'all' or recipe['placement'] != 'full-gpu':
                raise ValueError('GPU layer request conflicts with recipe placement')
        elif not requested.isdecimal() or int(requested) != recipe['gpuLayers']:
            raise ValueError('GPU layer request conflicts with recipe placement')
        if benchmark['recipe']['contextSize'] != recipe['contextSize'] or benchmark['recipe']['slots'] != recipe['slots']:
            raise ValueError('Benchmark recipe differs')
        if benchmark['recipe']['backend'].lower() != binding['engineBackend'].lower():
            raise ValueError('Benchmark backend differs')
        if benchmark['recipe']['cacheTypeK'] != recipe['cacheTypeK'] or benchmark['recipe']['cacheTypeV'] != recipe['cacheTypeV']:
            raise ValueError('Benchmark cache recipe differs')
        if benchmark['recipe']['splitMode'] != recipe['splitMode'] or benchmark['recipe']['tensorSplit'] != recipe['tensorSplit']:
            raise ValueError('Benchmark GPU split differs')
        if benchmark['methodology']['generationTokens'] != binding['workload']['generationTokens'] or benchmark['methodology']['concurrency'] != binding['workload']['concurrency']:
            raise ValueError('Benchmark workload differs')
        if benchmark['methodology']['sampling'] != binding['workload']['sampling']:
            raise ValueError('Benchmark sampling differs')
        workload = binding['workload']
        for key in ('corpus', 'prefixCache', 'warmupPerPrompt', 'randomizedPromptOrder'):
            if benchmark['methodology'].get(key) != workload[key]:
                raise ValueError(f'Benchmark {key} differs')
        if benchmark.get('powerPlan') != workload['powerPlan'] or benchmark.get('processorCount') != workload['processorCount']:
            raise ValueError('Benchmark power plan or processor count differs')
        if digest(benchmark.get('windowsInventory')) != workload['systemFingerprint']:
            raise ValueError('Benchmark system inventory differs')
        prompts = {s['requestedPromptTokens'] for s in benchmark['samples']}
        target_prompt = binding['workload']['promptTokens']
        if target_prompt not in prompts:
            raise ValueError('Benchmark prompt workload differs')
        artifacts = benchmark['methodology'].get('promptArtifacts')
        artifact_by_prompt = None
        if artifacts is not None:
            if not isinstance(artifacts, list):
                raise ValueError('Prompt artifacts must be a list')
            artifact_by_prompt = {}
            for artifact in artifacts:
                _keys(artifact, {'requestedPromptTokens', 'tokenCount', 'sha256', 'format'}, 'prompt artifact')
                length = artifact['requestedPromptTokens']
                if (type(length) is not int or length <= 0 or type(artifact['tokenCount']) is not int
                        or artifact['tokenCount'] != length
                        or artifact['format'] != 'fastllm-prompt-tokens-v1' or not _sha(artifact['sha256'])
                        or length in artifact_by_prompt):
                    raise ValueError('Invalid or duplicate prompt artifact')
                artifact_by_prompt[length] = artifact['sha256']
            if set(artifact_by_prompt) != prompts:
                raise ValueError('Prompt artifact groups differ from measured workloads')
            if any(sample.get('promptArtifactSha256') != artifact_by_prompt[sample['requestedPromptTokens']]
                   for sample in benchmark['samples']):
                raise ValueError('Sample prompt artifact digest differs')
            if artifact_by_prompt[target_prompt] != binding['workload']['promptArtifactSha256']:
                raise ValueError('Benchmark prompt artifact differs from recipe binding')
        selected_samples = [s for s in benchmark['samples'] if s['requestedPromptTokens'] == target_prompt]
        for metric in ('promptTokensPerSecond', 'generationTokensPerSecond', 'timeToFirstTextMs'):
            if not math.isclose(statistics.median(s[metric] for s in selected_samples), record['metrics'][metric], rel_tol=1e-9):
                raise ValueError(f'{metric} is not the measured median')
        if record['state'] == 'candidate':
            if record['evidence']['qualification'] is not None:
                raise ValueError('Candidate cannot carry qualification approval')
            if benchmark.get('placement') is not None:
                _check_observed_placement(benchmark['placement'], requested, recipe, observed_adapters)
            continue
        # The existing Windows benchmark lacks authoritative PCI bus identity,
        # topology and prompt-token artifact digest. A reviewed record must
        # provide these in a future extended runner; candidates remain usable.
        if benchmark.get('hardwareIdentity') != {'adapters': adapters, 'topology': binding['topology']}:
            raise ValueError('Reviewed benchmark lacks matching authoritative PCI/topology identity')
        if artifact_by_prompt is None:
            raise ValueError('Reviewed benchmark lacks matching prompt artifact digests')
        placement = benchmark.get('placement')
        if not isinstance(placement, dict):
            raise ValueError('Reviewed benchmark lacks observed layer placement')
        _check_observed_placement(placement, requested, recipe, observed_adapters)
        qualification = _evidence(root, record['evidence']['qualification'], budget)
        _keys(qualification, {'bindingSha256', 'recipeSha256', 'benchmarkSha256',
                              'gates', 'gateEvidence', 'peakDedicatedVramMiB'}, 'qualification')
        if (qualification['bindingSha256'] != digest(binding) or qualification['recipeSha256'] != digest(recipe)
                or qualification['benchmarkSha256'] != record['evidence']['benchmark']['sha256']):
            raise ValueError('Qualification does not bind exact environment and recipe')
        _keys(qualification['gates'], REQUIRED_QUALIFICATION, 'qualification gates')
        if any(value is not True for value in qualification['gates'].values()):
            raise ValueError('Qualification gates incomplete')
        _keys(qualification['gateEvidence'], REQUIRED_QUALIFICATION, 'gate evidence')
        for gate, reference in qualification['gateEvidence'].items():
            raw_evidence = _evidence(root, reference, budget)
            _keys(raw_evidence, {'gate', 'bindingSha256', 'recipeSha256',
                                 'benchmarkSha256', 'observations'}, 'raw gate evidence')
            if (raw_evidence['gate'] != gate or raw_evidence['bindingSha256'] != digest(binding)
                    or raw_evidence['recipeSha256'] != digest(recipe)
                    or raw_evidence['benchmarkSha256'] != record['evidence']['benchmark']['sha256']
                    or not isinstance(raw_evidence['observations'], dict) or not raw_evidence['observations']):
                raise ValueError(f'Raw evidence for {gate} is missing or unbound')
        if qualification['peakDedicatedVramMiB'] != record['metrics']['peakDedicatedVramMiB']:
            raise ValueError('Peak dedicated VRAM mismatch')
    return catalog_sha


def select(manifest, inventory, root, catalog, catalog_sha):
    """Rank reviewed recipes by decode median for one exact model/workload."""
    validate_manifest(manifest, root, catalog, catalog_sha)
    _keys(inventory, REQUIRED_BINDING | {'availableDedicatedVramMiB'}, 'current inventory')
    if digest(manifest) not in REVIEWED_MANIFEST_SHA256:
        raise ValueError('Recipe manifest has no source-reviewed digest')
    available = inventory['availableDedicatedVramMiB']
    if not isinstance(available, list) or len(available) != len(inventory['adapters']):
        raise ValueError('Current free dedicated VRAM is required per adapter')
    for value in available:
        _positive(value, 'current free dedicated VRAM')
    static_inventory = {k: inventory[k] for k in REQUIRED_BINDING}
    matches = [r for r in manifest['records'] if r['state'] == 'reviewed'
               and r['binding'] == static_inventory
               and all(free >= peak + 768 for free, peak in zip(available, r['metrics']['peakDedicatedVramMiB']))]
    if not matches:
        raise ValueError('No qualified recipe for this exact model, workload, and machine tuple')
    # Model/quant and workload are fixed by the exact inventory binding. A
    # higher-level model policy must choose them before this throughput ranking.
    chosen = sorted(matches, key=lambda r: (-r['metrics']['generationTokensPerSecond'],
                                             -r['metrics']['promptTokensPerSecond'],
                                             r['metrics']['timeToFirstTextMs'], r['id']))[0]
    return dict(chosen, rankingBasis='decode-throughput-median-only')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--catalog', type=Path, default=Path(__file__).resolve().parents[1] / 'config/catalog.json')
    parser.add_argument('--inventory', type=Path, help='Operator-supplied inventory fixture; not a native hardware probe')
    args = parser.parse_args()
    try:
        manifest = json.loads(_read_limited(args.manifest))
        catalog_raw = _read_limited(args.catalog)
        catalog = json.loads(catalog_raw)
        catalog_sha = hashlib.sha256(catalog_raw).hexdigest()
        if args.inventory:
            inventory = json.loads(_read_limited(args.inventory))
            result = select(manifest, inventory, args.manifest.parent, catalog, catalog_sha)
            print(json.dumps(result, indent=2))
        else:
            validate_manifest(manifest, args.manifest.parent, catalog, catalog_sha)
            print(json.dumps({'manifestSha256': digest(manifest), 'sourceReviewed': digest(manifest) in REVIEWED_MANIFEST_SHA256,
                              'recordCount': len(manifest['records']), 'states': {r['id']: r['state'] for r in manifest['records']}}, indent=2))
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
