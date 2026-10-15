#!/usr/bin/env python3
"""Build a pinned CoCo ZIP and text upload from committed, allowlisted files only."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
KEY = re.compile(rb'(?:sk|pk)-lf-[A-Za-z0-9]{8}-[A-Za-z0-9-]{20,}')


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def build(output):
    if git('status', '--porcelain', '--untracked-files=normal').strip():
        raise SystemExit('Commit or clean changes first: the package pins committed HEAD, never a mixed working tree.')
    sha = git('rev-parse', 'HEAD').decode().strip()
    names = git('ls-tree', '-r', '--name-only', 'HEAD').decode().splitlines()
    version = git('show', 'HEAD:VERSION').decode().strip()
    contents = {}
    for name in names:
        path = Path(name)
        if name.startswith('deploy/coco/') and path.suffix in ('.md', '.json'):
            target = path.name
        elif name in ('LICENSE', 'README.md', 'VERSION', 'CHANGELOG.md', 'CONTRIBUTING.md', 'tools/build_coco_package.py') or (
            path.parent.as_posix() in ('sql', 'docs', 'tests') and path.suffix in ('.sql', '.md', '.py')):
            target = 'reference/' + name
        else:
            continue
        data = git('show', 'HEAD:' + name)
        if KEY.search(data):
            raise SystemExit('Credential-shaped value found in ' + name + '; no package written.')
        contents[target] = data
    config = json.loads(contents['02_CONFIG.template.json'])
    config['source_commit'] = sha
    if config['exporter_version'] != version:
        raise SystemExit('Version mismatch between VERSION and CoCo config')
    contents['02_CONFIG.template.json'] = (json.dumps(config, indent=2) + '\n').encode()
    contents['SOURCE.json'] = (json.dumps({
        'repository': 'https://github.com/borismichel/snowflake-cortex-langfuse',
        'commit': sha, 'version': version, 'live_validation': 'NOT RUN by package builder',
        'source': 'reference files copied unchanged from git blobs',
        'sql_files': sum(n.startswith('reference/sql/') for n in contents),
        'configuration': 'interview worksheet; CoCo generates configured SQL, no runtime JSON loader'
    }, indent=2) + '\n').encode()
    contents['SHA256SUMS'] = ''.join(
        hashlib.sha256(data).hexdigest() + '  ' + name + '\n' for name, data in sorted(contents.items())).encode()
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    archive = output / ('coco-snowflake-langfuse-v' + version + '.zip')
    text = output / 'COCO_UPLOAD.txt'
    # Fixed member times and ordering make the same commit yield identical ZIP bytes.
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in sorted(contents.items()):
            info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)
    with text.open('w') as f:
        f.write('CoCo v' + version + ' upload. Read 00_START_HERE.md and 01_COCO_RUNBOOK.md first.\n'
                'These are separate files, NOT a single SQL script.\n')
        for name, data in sorted(contents.items()):
            f.write('\n===== BEGIN FILE: ' + name + ' =====\n' + data.decode() +
                    '===== END FILE: ' + name + ' =====\n')
    with zipfile.ZipFile(archive) as z:
        if z.testzip() is not None:
            raise SystemExit('ZIP verification failed')
        for name, data in contents.items():
            assert z.read(name) == data
    print(json.dumps({'version': version, 'commit': sha, 'files': len(contents),
                      'zip': str(archive), 'text': str(text)}, indent=2))
    return contents


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    build(parser.parse_args().output)
