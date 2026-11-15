import importlib.util
import json
import re
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'tests' / 'fixtures'
TOOL = ROOT / 'tools' / 'audit-engine-surface.py'
SCHEMA = 'bitworks.fastllm-engine-surface/v1'
PINNED_TAGS = ('b10698', 'b11658')
# The candidate is the newest tag published on or before this date that has both Windows zips.
CANDIDATE_CUTOFF = '2026-11-13T23:59:59Z'
EXTRA_FLAGS = ('--reasoning', '--tensor-split', '--no-ui')
# A known, named difference in the public endpoints between two builds goes here as {tag: [extra endpoints]}.
KNOWN_PUBLIC_ENDPOINT_DIFFERENCES = {}


def load_tool():
    spec = importlib.util.spec_from_file_location('audit_engine_surface', TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture_paths():
    return sorted(FIXTURES.glob('engine-surface-b*.json'))


def load_fixtures():
    return {p.stem[len('engine-surface-'):]: json.loads(p.read_text(encoding='utf-8')) for p in fixture_paths()}


def default_flags():
    golden = json.loads((FIXTURES / 'default-server-arguments.json').read_text(encoding='utf-8'))
    flags = set()
    for row in golden['rows']:
        for arg in row['arguments']:
            if isinstance(arg, str) and arg.startswith('--'):
                flags.add(arg)
    return flags


def idle_counter_names():
    text = (ROOT / 'src' / 'FastLlm.Runtime.ps1').read_text(encoding='utf-8')
    match = re.search(r'\$script:FastLlmIdleCounterNames\s*=\s*@\(([^)]*)\)', text)
    return re.findall(r"'([^']+)'", match.group(1))


class EngineSurfaceFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = load_fixtures()

    def test_three_fixtures_two_pinned_and_one_candidate(self):
        tags = sorted(self.fixtures)
        self.assertEqual(len(tags), 3, tags)
        for pinned in PINNED_TAGS:
            self.assertIn(pinned, tags)
        candidate = [t for t in tags if t not in PINNED_TAGS]
        self.assertEqual(len(candidate), 1)
        self.assertGreater(int(candidate[0][1:]), int(PINNED_TAGS[1][1:]))

    def test_schema_and_keys(self):
        for tag, fx in self.fixtures.items():
            self.assertEqual(fx['schema'], SCHEMA, tag)
            self.assertEqual(fx['tag'], tag)
            for key in ('source', 'options', 'envNames', 'metricsCounters', 'publicEndpointsWithKey'):
                self.assertIn(key, fx, tag)
            for key in ('options', 'envNames', 'metricsCounters', 'publicEndpointsWithKey'):
                self.assertIsInstance(fx[key], list, (tag, key))
                self.assertEqual(fx[key], sorted(set(fx[key])), (tag, key))
                self.assertTrue(fx[key], (tag, key))

    def test_candidate_records_tag_and_both_windows_assets(self):
        for tag, fx in self.fixtures.items():
            if tag in PINNED_TAGS:
                continue
            assets = fx['source']['releaseAssets']
            self.assertIn('llama-%s-bin-win-vulkan-x64.zip' % tag, assets)
            self.assertIn('llama-%s-bin-win-rocm-10.0-x64.zip' % tag, assets)
            self.assertLessEqual(fx['source']['publishedAt'], CANDIDATE_CUTOFF)
            self.assertNotIn('latest', json.dumps(fx['source']))

    def test_every_flag_fastllm_sends_is_accepted(self):
        flags = sorted(default_flags() | set(EXTRA_FLAGS))
        self.assertIn('--model', flags)
        self.assertIn('--spec-type', flags)
        for tag, fx in self.fixtures.items():
            missing = [f for f in flags if f not in fx['options']]
            self.assertEqual(missing, [], tag)

    def test_idle_stop_counters_exist(self):
        names = idle_counter_names()
        self.assertEqual(len(names), 4)
        for tag, fx in self.fixtures.items():
            for name in names:
                self.assertIn(name, fx['metricsCounters'], tag)

    def test_api_key_env_name_exists(self):
        for tag, fx in self.fixtures.items():
            self.assertIn('LLAMA_API_KEY', fx['envNames'], tag)

    def test_public_endpoints_with_key_match_or_are_named(self):
        base = set(self.fixtures[PINNED_TAGS[0]]['publicEndpointsWithKey'])
        self.assertIn('/health', base)
        for tag, fx in self.fixtures.items():
            extra = set(fx['publicEndpointsWithKey']) ^ base
            self.assertEqual(sorted(extra), sorted(KNOWN_PUBLIC_ENDPOINT_DIFFERENCES.get(tag, [])), tag)


class RemovedFlagTests(unittest.TestCase):
    PATTERN = re.compile(r'--draft(?:-n-min|-n|-max|-min)?(?![A-Za-z0-9-])')

    def test_no_argument_builder_emits_draft_flags(self):
        hits = []
        for folder in ('src', 'tools'):
            for path in sorted((ROOT / folder).rglob('*')):
                if not path.is_file() or path.suffix.lower() not in ('.ps1', '.psm1', '.py', '.cs', '.json', '.cmd', '.sh'):
                    continue
                text = path.read_text(encoding='utf-8', errors='replace')
                if self.PATTERN.search(text):
                    hits.append(str(path.relative_to(ROOT)))
        self.assertEqual(hits, [])


SAMPLE_ARG = '''
    add_opt(common_arg(
        {"-ts", "--tensor-split"}, "N0,N1",
        "split",
        [](common_params & params, const std::string & value) {}
    ).set_env("LLAMA_ARG_TENSOR_SPLIT"));
    add_opt(common_arg(
        {"--ui", "--webui"},
        {"--no-ui", "--no-webui"},
        "ui",
        [](common_params & params, bool value) {}
    ).set_examples({LLAMA_EXAMPLE_SERVER}).set_env("LLAMA_ARG_UI"));
    add_opt(common_arg(
        {"--api-key"}, "KEY",
        "key",
        [](common_params & params, const std::string & value) {}
    ).set_env("LLAMA_API_KEY"));
'''

SAMPLE_HTTP = '''
    static const std::unordered_set<std::string> get_public_endpoints = []() {
        std::unordered_set<std::string> endpoints {
            "/health",
            "/v1/health",
        };
        endpoints.insert(frontend_paths.begin(), frontend_paths.end());
        return endpoints;
    }();
'''

SAMPLE_TASK = '''
std::string server_task_result_metrics::to_metrics() {
    const std::vector<metric_item> counters = {
        {
            "prompt_tokens_total",
            "Number of prompt tokens",
            (double) 1
        }, {
            "tokens_predicted_total",
            "Number of tokens",
            (double) 2
        },
    };
    const std::vector<metric_item> gauges = {
        {
            "requests_processing",
            "Number of requests processing",
            (double) 3
        },
    };
    prometheus << "llamacpp:" << item.name;
}
'''


class AuditToolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tool = load_tool()

    def test_parse_options_envs_and_negations(self):
        options, envs = self.tool.parse_arg_cpp(SAMPLE_ARG)
        self.assertEqual(options, ['--api-key', '--no-ui', '--no-webui', '--tensor-split', '--ui', '--webui', '-ts'])
        self.assertEqual(envs, ['LLAMA_API_KEY', 'LLAMA_ARG_TENSOR_SPLIT', 'LLAMA_ARG_UI'])

    def test_parse_metrics_counters(self):
        self.assertEqual(
            self.tool.parse_metrics(SAMPLE_TASK),
            ['llamacpp:prompt_tokens_total', 'llamacpp:requests_processing', 'llamacpp:tokens_predicted_total'])

    def test_parse_public_endpoints(self):
        self.assertEqual(self.tool.parse_public_endpoints(SAMPLE_HTTP), ['/', '/health', '/v1/health', '<embedded-ui-assets>'])

    def test_from_dir_builds_fixture_without_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for rel, text in (('common/arg.cpp', SAMPLE_ARG),
                              ('tools/server/server-http.cpp', SAMPLE_HTTP),
                              ('tools/server/server-task.cpp', SAMPLE_TASK)):
                target = root / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text, encoding='utf-8')
            fx = self.tool.build_fixture('b1', self.tool.DirSource(str(root)))
        self.assertEqual(fx['schema'], SCHEMA)
        self.assertEqual(fx['tag'], 'b1')
        self.assertIn('--no-ui', fx['options'])
        self.assertIn('LLAMA_API_KEY', fx['envNames'])
        self.assertEqual(fx['publicEndpointsWithKey'], ['/', '/health', '/v1/health', '<embedded-ui-assets>'])

    def test_candidate_rule_picks_newest_tag_with_both_assets_before_cutoff(self):
        def rel(tag, when, vulkan=True, rocm=True):
            assets = []
            if vulkan:
                assets.append('llama-%s-bin-win-vulkan-x64.zip' % tag)
            if rocm:
                assets.append('llama-%s-bin-win-rocm-10.0-x64.zip' % tag)
            return {'tag_name': tag, 'published_at': when, 'draft': False, 'assets': [{'name': a} for a in assets]}
        releases = [
            rel('b9', '2026-11-14T00:08:02Z'),
            rel('v1.0.0', '2026-11-13T22:00:00Z', vulkan=False, rocm=False),
            rel('b8', '2026-11-13T23:12:58Z', rocm=False),
            rel('b7', '2026-11-13T10:00:00Z'),
            rel('b6', '2026-11-12T10:00:00Z'),
        ]
        self.assertEqual(self.tool.choose_candidate(releases, '2026-11-13')['tag_name'], 'b7')


if __name__ == '__main__':
    unittest.main()
