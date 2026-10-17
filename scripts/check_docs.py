#!/usr/bin/env python3
"""Validate portable Markdown links and obvious unsafe payload markers, offline."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
errors = []
files = [p for p in ROOT.rglob('*') if p.is_file() and not set(p.relative_to(ROOT).parts) & {'.git', 'dist', '__pycache__'}]
for p in files:
    if p.is_symlink():
        errors.append(f'{p.relative_to(ROOT)}: packaged source must not be a symlink')
        continue
    if p.suffix not in {'.md', '.json', '.py', '.txt', '.example'}:
        continue
    text = p.read_text(encoding='utf-8')
    if p.suffix == '.md':
        for target in re.findall(r'!?\[[^\]]*\]\(([^)]+)\)', text):
            target = target.strip('<>')
            if re.match(r'^(https?://|mailto:|#)', target):
                continue
            local = target.split('#', 1)[0]
            if not local or not (p.parent / local).exists():
                errors.append(f'{p.relative_to(ROOT)}: missing local link {target}')
        if re.search(r'(?:/Users/[^/\s]+/|/home/[^/\s]+/|file://|localhost:\d+)', text):
            errors.append(f'{p.relative_to(ROOT)}: machine-specific link/path')
    # Avoid echoing candidate secrets in diagnostics.
    for marker in ('-----BEGIN ' + 'PRIVATE KEY-----', 'ghp_' + r'[A-Za-z0-9]{30,}', 'sk-' + r'[A-Za-z0-9]{35,}'):
        if re.search(marker, text):
            errors.append(f'{p.relative_to(ROOT)}: possible credential marker')
    if p.name == 'SKILL.md':
        if not text.startswith('---\n') or not re.search(r'^name: [a-z0-9-]+$', text, re.M) or not re.search(r'^description: .+', text, re.M):
            errors.append(f'{p.relative_to(ROOT)}: malformed skill frontmatter')
    if p.suffix == '.json':
        import json
        try:
            json.loads(text)
        except ValueError:
            errors.append(f'{p.relative_to(ROOT)}: invalid JSON')
if errors:
    print('\n'.join(errors))
    sys.exit(1)
print(f'PASS: {len(files)} source files; local links, JSON, skill headers and payload markers checked.')
print('Limit: this is not semantic privacy review, external-link access or installed behavior proof.')
