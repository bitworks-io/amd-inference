#!/usr/bin/env python3
"""Record the llama-server surface FastLLM depends on, for one llama.cpp tag.

Reads three source files of the tag (common/arg.cpp, tools/server/server-task.cpp, tools/server/server-http.cpp)
and writes a fixture (bitworks.fastllm-engine-surface/v1) with:
  options                 every accepted command-line option name (short, long and negated forms)
  envNames                every LLAMA_ARG_* environment name, and LLAMA_API_KEY
  metricsCounters         the llamacpp:* names the /metrics endpoint renders
  publicEndpointsWithKey  paths that answer without an API key when one is set
  secretLogLabels         the label of every server log line printed from a branch that tests the configured API keys
                          (llama-server prints "api_keys: ****<last chars>"); FastLLM's capture filter must drop each one
  source                  where it came from (and, for a build, its release assets)

Usage:
  audit-engine-surface.py --tag b12345 [--out FILE]          read raw.githubusercontent.com and api.github.com
  audit-engine-surface.py --tag b12345 --from-dir DIR        offline: DIR mirrors the repo paths above
  audit-engine-surface.py --find-candidate [--before YYYY-MM-DD]   print the newest tag with both Windows zips
Only public GitHub is read, with plain unauthenticated GETs. Nothing is executed or downloaded beyond text.
"""
import argparse
import json
import re
import sys
import urllib.request

SCHEMA = 'bitworks.fastllm-engine-surface/v1'
REPO = 'ggml-org/llama.cpp'
RAW = 'https://raw.githubusercontent.com/%s/%%s/%%s' % REPO
API = 'https://api.github.com/repos/%s' % REPO
FILES = ('common/arg.cpp', 'tools/server/server-task.cpp', 'tools/server/server-http.cpp')
UI_MARKER = '<embedded-ui-assets>'


class AuditError(Exception):
    """The source no longer has a shape the audit can read; no fixture is written."""


def http_get(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'fastllm-engine-surface-audit'})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode('utf-8')


class RemoteSource(object):
    def __init__(self, tag):
        self.tag = tag

    def text(self, path):
        return http_get(RAW % (self.tag, path))

    def release(self):
        return json.loads(http_get('%s/releases/tags/%s' % (API, self.tag)))


class DirSource(object):
    def __init__(self, root):
        self.root = root

    def text(self, path):
        with open('%s/%s' % (self.root, path), encoding='utf-8') as handle:
            return handle.read()

    def release(self):
        try:
            return json.loads(self.text('release.json'))
        except (IOError, OSError, ValueError):
            return None


_ARG_RE = re.compile(r'common_arg\(\s*(\{[^{}]*\})(?:\s*,\s*(\{[^{}]*\}))?')
_NAME_RE = re.compile(r'"(-[^"\s]*)"')
_ENV_RE = re.compile(r'set_env\(\s*"([A-Z0-9_]+)"\s*\)')


def parse_arg_cpp(text):
    options = set()
    for match in _ARG_RE.finditer(text):
        for group in match.groups():
            if group:
                options.update(_NAME_RE.findall(group))
    return sorted(options), sorted(set(_ENV_RE.findall(text)))


def parse_metrics(text):
    start = text.find('::to_metrics()')
    if start < 0:
        return []
    body = text[start:]
    names = re.findall(r'\{\s*"([a-z][a-z0-9_]*)"\s*,\s*"', body)
    return sorted('llamacpp:' + n for n in set(names))


def parse_public_endpoints(text):
    match = re.search(r'get_public_endpoints\s*=\s*\[\]\(\)\s*\{\s*std::unordered_set<std::string>\s+endpoints\s*\{([^}]*)\}', text)
    paths = re.findall(r'"(/[^"]*)"', match.group(1)) if match else []
    if re.search(r'endpoints\.insert\(\s*frontend_paths', text):
        paths.append(UI_MARKER)
    if re.search(r'frontend_paths\s*=.*?paths\s*\{\s*"/"\s*\}', text, re.S):
        paths.append('/')
    return sorted(set(paths))


# A branch that tests the configured keys: `if (params.api_keys.size() ...) { body }` or an `else if` of the same, with a body that has no
# nested braces. The key-printing statements are the log macros (SRV_TRC, LOG_INF, ...) inside such a body, and the label is the text
# before the first colon of the format string. A branch that tests api_keys.empty() is not matched (it prints no key material).
_KEY_BRANCH_RE = re.compile(r'if\s*\(\s*params\.api_keys\.size\(\)[^)]*\)\s*\{([^{}]*)\}')
_LOG_LABEL_RE = re.compile(r'\b[A-Z][A-Z0-9]*_[A-Z]+\(\s*"([A-Za-z_][A-Za-z0-9_]*):')


def parse_secret_log_labels(text):
    """Labels of the log statements that print API key material. Fails (AuditError) rather than return an empty list."""
    labels = set()
    for branch in _KEY_BRANCH_RE.finditer(text):
        labels.update(_LOG_LABEL_RE.findall(branch.group(1)))
    if not labels:
        raise AuditError('no log statement that prints API key material was found in tools/server/server-http.cpp; '
                         'the engine changed shape, so the audit cannot say which label the capture filter must drop')
    return sorted(labels)


def build_fixture(tag, source):
    options, envs = parse_arg_cpp(source.text('common/arg.cpp'))
    http_text = source.text('tools/server/server-http.cpp')
    info = {'repository': 'https://github.com/%s' % REPO, 'files': list(FILES)}
    release = source.release()
    if release:
        info['publishedAt'] = release.get('published_at')
        info['releaseAssets'] = sorted(a['name'] for a in release.get('assets', []))
    return {
        'schema': SCHEMA,
        'tag': tag,
        'source': info,
        'options': options,
        'envNames': envs,
        'metricsCounters': parse_metrics(source.text('tools/server/server-task.cpp')),
        'publicEndpointsWithKey': parse_public_endpoints(http_text),
        'secretLogLabels': parse_secret_log_labels(http_text),
    }


def choose_candidate(releases, before):
    """Newest bNNNN release published on or before `before` (YYYY-MM-DD) with both Windows zips."""
    best = None
    for rel in releases:
        tag = rel.get('tag_name', '')
        if not re.match(r'^b[0-9]+$', tag) or rel.get('draft'):
            continue
        if rel.get('published_at', '')[:10] > before:
            continue
        names = set(a['name'] for a in rel.get('assets', []))
        if 'llama-%s-bin-win-vulkan-x64.zip' % tag not in names or 'llama-%s-bin-win-rocm-10.0-x64.zip' % tag not in names:
            continue
        if best is None or int(tag[1:]) > int(best['tag_name'][1:]):
            best = rel
    return best


def list_releases(pages=5):
    releases = []
    for page in range(1, pages + 1):
        chunk = json.loads(http_get('%s/releases?per_page=100&page=%d' % (API, page)))
        releases.extend(chunk)
    return releases


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--tag')
    parser.add_argument('--from-dir')
    parser.add_argument('--out')
    parser.add_argument('--find-candidate', action='store_true')
    parser.add_argument('--before', default='2026-11-13')
    args = parser.parse_args(argv)
    if args.find_candidate:
        rel = choose_candidate(list_releases(), args.before)
        if rel is None:
            print('no candidate found', file=sys.stderr)
            return 1
        print(rel['tag_name'])
        return 0
    if not args.tag or not re.match(r'^b[0-9]+$', args.tag):
        parser.error('--tag bNNNN is required')
    source = DirSource(args.from_dir) if args.from_dir else RemoteSource(args.tag)
    try:
        fixture = build_fixture(args.tag, source)
    except AuditError as error:
        print('audit failed: %s' % error, file=sys.stderr)
        return 2
    text = json.dumps(fixture, indent=2) + '\n'
    if args.out:
        with open(args.out, 'w', encoding='utf-8', newline='\n') as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
