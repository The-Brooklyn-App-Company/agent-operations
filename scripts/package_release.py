#!/usr/bin/env python3
"""Package a committed source revision; never include untracked or ignored state."""
import argparse
import hashlib
import io
import json
import re
import subprocess
import tarfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ref', default='HEAD')
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--name', required=True)
args = parser.parse_args()
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}", args.name):
    raise SystemExit("Release name must be a simple filename stem")
root = Path(__file__).resolve().parents[1]
commit = subprocess.check_output(['git', 'rev-parse', args.ref + '^{commit}'], cwd=root, text=True).strip()
raw = subprocess.check_output(['git', 'archive', '--format=tar', commit], cwd=root)
with tarfile.open(fileobj=io.BytesIO(raw)) as source:
    entries = source.getmembers()
    for entry in entries:
        if not entry.isfile() and not entry.isdir():
            raise SystemExit('Refuses symlinks or special files in release source')
        path = Path(entry.name)
        if path.is_absolute() or '..' in path.parts:
            raise SystemExit('Refuses unsafe archive path')
args.output.mkdir(parents=True, exist_ok=True)
archive = args.output / (args.name + '.tar.gz')
manifest = args.output / (args.name + '.manifest.json')
if archive.exists() or manifest.exists():
    raise SystemExit('Refuses to overwrite an existing release artifact')
import gzip
with archive.open('xb') as file:
    with gzip.GzipFile(fileobj=file, mode='wb', filename='', mtime=0) as out:
        out.write(raw)
record = {'name': args.name, 'commit': commit, 'archive': archive.name, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(), 'tracked_files': sum(e.isfile() for e in entries)}
with manifest.open('x') as out:
    json.dump(record, out, indent=2); out.write('\n')
print(json.dumps(record))
