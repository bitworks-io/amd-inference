"""Verify a lab ZIP without extracting or executing any of its contents."""
import argparse
import hashlib
import json
import re
import stat
import zipfile
from pathlib import Path, PurePosixPath


def _verify(path, setup=False):
    manifest_name = 'SETUP-MANIFEST.json' if setup else 'PACKAGE-MANIFEST.json'
    expected_kind = 'unsigned-private-windows-lab-setup' if setup else 'unsigned-private-windows-lab-package'
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        if len(set(name.casefold() for name in names)) != len(names):
            raise ValueError('Duplicate or case-colliding package path')
        for entry in entries:
            name = entry.filename
            parts = PurePosixPath(name).parts
            if (not parts or name.startswith('/') or '\\' in name or ':' in name
                    or any(part in ('.', '..') for part in name.split('/'))
                    or stat.S_ISLNK(entry.external_attr >> 16) or entry.is_dir()):
                raise ValueError('Unsafe package path or entry')
            if entry.file_size > 2 * 1024 * 1024:
                raise ValueError('Lab sources unexpectedly large')
            if PurePosixPath(name).suffix.lower() not in ('.ps1', '.psm1', '.cs', '.md', '.json', '.sha256', '.cmd'):
                raise ValueError('Unexpected binary or file type in source lab package')
        if sum(entry.file_size for entry in entries) > (2 if setup else 20) * 1024 * 1024:
            raise ValueError('Lab package exceeds source-size budget')
        manifest = json.loads(archive.read(manifest_name).decode('utf-8-sig'))
        if (manifest.get('schemaVersion') != 1 or manifest.get('kind') != expected_kind
                or manifest.get('physicalQualification') is not False or manifest.get('publicReleaseApproved') is not False):
            raise ValueError('Manifest does not describe an unqualified private lab package')
        if setup and (manifest.get('publisherAuthenticated') is not False
                      or manifest.get('appZipDigestIncluded') is not False):
            raise ValueError('Setup manifest must not claim publisher or app ZIP authentication')
        declared = manifest['files']
        if len({item['path'].casefold() for item in declared}) != len(declared):
            raise ValueError('Duplicate manifest path')
        if set(names) != {manifest_name} | {item['path'] for item in declared}:
            raise ValueError('Archive file set differs from manifest')
        if setup:
            required = {'Install-FastLLM-Lab.cmd', 'tools/install-lab-app.ps1',
                        'src/FastLlm.LabApp.ps1', 'README-SETUP.md'}
            allowed = (required, required | {'src/LabPackage.cs'})
            if {item['path'] for item in declared} not in allowed:
                raise ValueError('Setup bundle is not the exact known bootstrap source set')
        for item in declared:
            payload = archive.read(item['path'])
            if not re.fullmatch('[0-9a-f]{64}', item['sha256']):
                raise ValueError('Invalid manifest digest')
            if len(payload) != item['sizeBytes'] or hashlib.sha256(payload).hexdigest() != item['sha256']:
                raise ValueError('Package file length/hash mismatch')
        return {'verifiedFiles': len(declared), 'publicReleaseApproved': False, 'publisherAuthenticated': False}


def verify(path):
    """Verify the full source-only lab package; no publisher claim is made."""
    return _verify(path)


def verify_setup(path):
    """Verify the small source-only setup bundle; trust its source separately."""
    return _verify(path, setup=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--setup', action='store_true', help='verify the separate setup source bundle')
    args = parser.parse_args()
    try:
        print(json.dumps(verify_setup(args.archive) if args.setup else verify(args.archive), indent=2))
    except (ValueError, KeyError, TypeError, OSError, zipfile.BadZipFile) as error:
        parser.error(str(error))
