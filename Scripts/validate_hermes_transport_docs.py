#!/usr/bin/env python3
"""Check Hermes documentation artifacts, without executing a host or client.

This is a documentation consistency check, not an implementation of the Hermes
wire decoder and not a substitute for the conformance tests in the contract.
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / 'docs' / 'hermes'


def validate() -> list[str]:
    errors: list[str] = []
    documents = [ROOT / 'docs' / 'NATIVE_TRANSPORT.md', *sorted(DOCS.glob('*.md'))]
    block_count = 0
    link_count = 0
    for path in documents:
        source = path.read_text(encoding='utf-8')
        label = str(path.relative_to(ROOT))
        fenced = False
        table_columns = None
        for line_number, line in enumerate(source.splitlines(), 1):
            if line.lstrip().startswith('```'):
                fenced = not fenced
            if fenced or not line.lstrip().startswith('|'):
                table_columns = None
                continue
            columns = len(re.findall(r'(?<!\\)\|', line))
            if table_columns is None:
                table_columns = columns
            elif columns != table_columns:
                errors.append(f'{label}:{line_number}: inconsistent Markdown table columns')
        if fenced:
            errors.append(f'{label}: unclosed Markdown code fence')
        for match in re.finditer(r'^[ \t]*```json[ \t]*\n(.*?)^[ \t]*```[ \t]*$', source, re.S | re.M):
            block_count += 1
            try:
                json.loads(match[1])
            except ValueError as error:
                line = source.count('\n', 0, match.start()) + 1
                errors.append(f'{label}:{line}: invalid JSON example: {error}')
        # Remove fenced code so literal Markdown in protocol examples is ignored.
        prose = re.sub(r'```.*?```', '', source, flags=re.S)
        for target in re.findall(r'\[[^\]\n]+\]\(([^\s)]+)\)', prose):
            if re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', target) or target.startswith('#'):
                continue
            link_count += 1
            relative = target.split('#', 1)[0]
            if not (path.parent / relative).exists():
                errors.append(f'{label}: missing local link: {target}')
    vector = DOCS / 'vectors' / 'wire.json'
    try:
        value = json.loads(vector.read_text(encoding='utf-8'))
        assert value['schemaVersion'] == 1, 'unsupported vector schema'
        assert value['profile'] == 'bighelp-hermes-native', 'unexpected profile'
        assert re.fullmatch('[a-f0-9]{40}', value['sourceRevision']), 'invalid source revision'
        cases = value['cases']
        assert isinstance(cases, list) and cases, 'missing cases'
        ids: set[str] = set()
        accepted = 0
        for case in cases:
            name = case['id']
            assert isinstance(name, str) and name and name not in ids, f'duplicate/invalid name: {name!r}'
            ids.add(name)
            assert isinstance(case['frame'], str), f'{name}: frame must be text'
            assert isinstance(case['purpose'], str) and case['purpose'], f'{name}: missing purpose'
            expected = case['expected']
            assert isinstance(expected, list) and expected, f'{name}: missing expectations'
            assert all(isinstance(item, str) and re.match(r'^(event|request|result|failure|reject):', item) for item in expected), f'{name}: invalid category'
            if expected[0].startswith('reject:'):
                assert len(expected) == 1, f'{name}: rejection must be atomic'
                continue
            accepted += 1
            frames = [line for line in case['frame'].split('\n') if line.strip(' \t\r')]
            assert len(frames) == len(expected), f'{name}: expected classification count differs'
            for frame in frames:
                decoded = json.loads(frame)
                assert isinstance(decoded, dict) and decoded.get('jsonrpc') == '2.0', f'{name}: valid vector envelope missing'
        print(f'Validated {len(cases)} wire fixtures ({accepted} accepted, {len(cases)-accepted} rejected).')
    except (OSError, ValueError, AssertionError, KeyError, TypeError) as error:
        errors.append(f'{vector.relative_to(ROOT)}: {error}')
    # Cover static core HTTP path literals, without pretending to evaluate
    # interpolated paths or extract request/response schemas from Swift.
    reference_text = '\n'.join(path.read_text(encoding='utf-8') for path in documents)
    for source_path in sorted((ROOT / 'Bighelp' / 'DirectHermes').glob('*.swift')):
        paths = set(re.findall(r'"(/api/[^"\\]+)"', source_path.read_text()))
        for route_path in sorted(paths):
            if route_path.startswith('/api/plugins/loopdy/native/'):
                continue
            if route_path not in reference_text:
                errors.append(f'{source_path.relative_to(ROOT)}: core path absent from docs: {route_path}')
    # Native literal suffixes are stable inventory anchors. Dynamic path families
    # are documented as families and reviewed separately, not evaluated as Swift.
    registry = (ROOT / 'Bighelp' / 'DirectHermes' / 'DirectHermesNativeContext.swift').read_text()
    extensions = DOCS / 'EXTENSIONS.md'
    if extensions.exists():
        reference = extensions.read_text()
        for suffix in sorted(set(re.findall(r'Route\(path:\s*"([^"]+)"', registry))):
            if suffix not in reference:
                errors.append(f'{extensions.relative_to(ROOT)}: native route suffix absent: {suffix}')
    else:
        errors.append('docs/hermes/EXTENSIONS.md: missing reference')
    print(f'Checked {len(documents)} Markdown files, {link_count} local links and {block_count} JSON examples.')
    return errors


if __name__ == '__main__':
    failures = validate()
    for failure in failures:
        print(f'ERROR: {failure}', file=sys.stderr)
    if failures:
        sys.exit(1)
    print('Hermes documentation checks passed (static checks only).')
