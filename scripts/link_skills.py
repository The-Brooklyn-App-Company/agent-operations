#!/usr/bin/env python3
"""Preview selected skill-directory links; --apply never replaces existing entries."""
import argparse
import json
import os
import subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--target', type=Path, required=True, help='Actual supported skills root for this client')
p.add_argument('--skill', action='append', required=True, choices=['operator-setup', 'scheduled-worker', 'review-handoff', 'release-closeout'])
p.add_argument('--apply', action='store_true')
a = p.parse_args()
r = Path(__file__).resolve().parents[1]
target = a.target.expanduser().absolute()
if os.name == 'nt':
    raise SystemExit('Use the documented explicit kit profile route on Windows; this helper uses POSIX directory symlinks.')
plan = []
for name in dict.fromkeys(a.skill):
    src, dst = r / 'skills' / name, target / name
    if not (src / 'SKILL.md').is_file():
        raise SystemExit('Missing source skill')
    if os.path.lexists(dst):
        if dst.is_symlink() and dst.resolve() == src.resolve():
            continue
        raise SystemExit(f'Refuses existing entry: {dst.name}; reconcile local drift first')
    plan.append((src, dst))
print(json.dumps({'mode': 'apply' if a.apply else 'preview', 'links': [{'source': str(s), 'destination': str(d)} for s,d in plan]}, indent=2))
if a.apply:
    try:
        tag = subprocess.check_output(['git', 'describe', '--exact-match', '--tags', 'HEAD'], cwd=r, text=True, stderr=subprocess.DEVNULL).strip()
        dirty = subprocess.check_output(['git', 'status', '--porcelain'], cwd=r, text=True)
    except subprocess.CalledProcessError:
        raise SystemExit('Apply requires a clean tagged Git checkout; use the repository/tag instead of an extracted archive for linked installation')
    if dirty or not tag:
        raise SystemExit('Apply requires a clean tagged Git checkout')
    created = []
    made_target = not target.exists()
    try:
        target.mkdir(parents=True, exist_ok=True)
        for src, dst in plan:
            # symlink fails if an entry appeared since preflight; never overwrite.
            dst.symlink_to(src, target_is_directory=True)
            created.append((src,dst))
    except OSError:
        for src, dst in reversed(created):
            if dst.is_symlink() and dst.resolve() == src.resolve():
                dst.unlink()
        if made_target:
            try: target.rmdir()
            except OSError: pass
        raise
    print(f'Linked {len(created)} selected skills from {tag}; verify discovery in a fresh client conversation.')
