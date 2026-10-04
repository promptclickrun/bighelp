#!/usr/bin/env bash
set -euo pipefail
# Requires Python 3 locally and macOS Swift remotely; no app or Mac repo builds.
# Run from anywhere: bash scripts/export-builtin.sh
# Optional transport configuration: AVATAR_SSH_CONFIG and AVATAR_SWIFT_HOST.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import hashlib, io, json, math, os, pathlib, re, shlex, subprocess, sys, tarfile
import xml.etree.ElementTree as ET

root = pathlib.Path(sys.argv[1])
source_dir = root / 'Bighelp/Companion/HermesFaces'
blob = (source_dir / 'HermesBlobFace.swift').read_text()
shape = (source_dir / 'HermesShapeFace.swift').read_text()
view = (source_dir / 'HermesFaceViews.swift').read_text()
# Fail on native drawing changes instead of silently publishing stale geometry.
for fragment in [
    'let scale = min(size.width / 40, size.height / 44)',
    'let ring = HermesShapeFace.ring(shape)',
    'let eyeY = HermesShapeFace.eyeLine(shape)',
    'Color(red: 232 / 255, green: 220 / 255, blue: 195 / 255).opacity(0.95) : Color.black.opacity(0.85)',
    'isDark ? Color.black.opacity(0.6) : Color.white.opacity(0.85)',
    'for x in [15.4, 24.6]',
    'CGRect(x: x - 2.2, y: eyeY - 2.3, width: 4.4, height: 4.6)',
    'CGRect(x: x - 0.6 - 0.65, y: eyeY - 0.7 - 0.65, width: 1.3, height: 1.3)',
]:
    assert fragment in view, f'Native drawing changed; review exporter: {fragment}'
kinds = re.search(r'case (round[^\n]+)', blob).group(1).split(', ')
shapes = re.findall(r'"([^"]+)"', re.search(r'static let pickerShapes = \[([^\]]+)\]', shape).group(1))
ssh = ['ssh', '-F', os.environ.get('AVATAR_SSH_CONFIG', '/opt/data/.ssh/config'),
       '-o', 'ConnectTimeout=30', os.environ.get('AVATAR_SWIFT_HOST', 'mac')]
remote = subprocess.check_output(ssh + ['mktemp -d "${TMPDIR:-/tmp/}bighelp-avatars.XXXXXX"'], text=True).strip()
assert re.fullmatch(r'/[A-Za-z0-9_./-]+/bighelp-avatars\.[A-Za-z0-9]+', remote), 'Unexpected remote temp directory'
qremote = shlex.quote(remote)
try:
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode='w') as tar:
        for filename in ['HermesBlobFace.swift', 'HermesShapeFace.swift']:
            tar.add(source_dir / filename, arcname=filename)
        tar.add(root / 'scripts/export-builtin.swift', arcname='export-builtin.swift')
    subprocess.run(ssh + [f'tar -xf - -C {qremote}'], input=archive.getvalue(), check=True)
    command = (
        f'export PATH=/opt/homebrew/bin:$PATH; cd {qremote}; '
        'set -e; swiftc -module-cache-path ./module-cache HermesBlobFace.swift HermesShapeFace.swift '
        'export-builtin.swift -o export-builtin; ./export-builtin out; '
        'COPYFILE_DISABLE=1 tar -C out -cf - faces shapes'
    )
    result = subprocess.check_output(ssh + [command])
finally:
    subprocess.run(ssh + [f'rm -rf -- {qremote}'], check=True)
    subprocess.run(ssh + [f'test ! -e {qremote}'], check=True)

payloads = {}
with tarfile.open(fileobj=io.BytesIO(result), mode='r:') as tar:
    for item in tar:
        if item.isdir():
            continue
        path = pathlib.PurePosixPath(item.name)
        assert item.isfile() and len(path.parts) == 2 and path.parts[0] in ('faces', 'shapes'), item.name
        assert path.name == 'index.json' or path.suffix == '.svg', item.name
        assert item.name not in payloads, item.name
        payloads[item.name] = tar.extractfile(item).read()

ns = '{http://www.w3.org/2000/svg}'
number = r'[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?'
vectors = (root / 'BighelpTests/HermesFacesTests.swift').read_text()
expected_hashes = dict(re.findall(r'\("agent", "([^"]+)", "([0-9a-f]{64})"\)', vectors))
for category, names, prefix, style in [('faces', kinds, 'face', 'face'), ('shapes', shapes, 'shape', 'shape')]:
    entries = json.loads(payloads[f'{category}/index.json'])
    assert len(entries) == len(names) and len({entry['id'] for entry in entries}) == len(names)
    assert [entry['id'] for entry in entries] == [f'{prefix}-{name}' for name in names]
    assert len([key for key in payloads if key.startswith(category + '/') and key.endswith('.svg')]) == len(names)
    for entry, name in zip(entries, names):
        assert set(entry) == {'id', 'name', 'file', 'nativeLook'}
        assert entry['file'] == f'{prefix}-{name}.svg'
        assert entry['nativeLook'] == {'style': style, 'shape': 'blobatar::' + name if style == 'face' else name}
        data = payloads[f"{category}/{entry['file']}"]
        svg = ET.fromstring(data)
        assert svg.tag == ns + 'svg'
        assert svg.attrib['viewBox'] == ('0 0 100 100' if style == 'face' else '0 0 40 44')
        for element in svg.iter():
            assert element.tag in {ns + tag for tag in ['svg', 'g', 'path', 'circle', 'ellipse']}
            for key, value in element.attrib.items():
                if key in {'d', 'cx', 'cy', 'r', 'rx', 'ry', 'viewBox', 'fill-opacity'}:
                    assert not re.search(r'nan|inf', value, re.I), (entry['id'], key, value)
                    assert all(math.isfinite(float(token)) for token in re.findall(number, value))
                if key == 'd':
                    assert not re.sub(number + r'|[MLHVCQZ\s,]', '', value), value
                    arities = {'M': 2, 'L': 2, 'H': 1, 'V': 1, 'C': 6, 'Q': 4, 'Z': 0}
                    for command, args in re.findall(r'([MLHVCQZ])([^MLHVCQZ]*)', value):
                        assert len(re.findall(number, args)) == arities[command], (entry['id'], command)
        if style == 'face':
            assert hashlib.sha256(data).hexdigest() == expected_hashes[name], f'blobatar parity failed: {name}'
            assert len(svg.findall(ns + 'g')[1].findall(ns + 'path')) == 2
        else:
            assert len(svg.findall(ns + 'path')) == 1
            assert svg.find(ns + 'path').attrib['fill'] == '#8b5cf6'
            eye_y = 22 if name == 'cloud' else 17.2
            eyes, catchlights = svg.findall(ns + 'ellipse'), svg.findall(ns + 'circle')
            assert len(eyes) == len(catchlights) == 2
            for x, eye, light in zip([15.4, 24.6], eyes, catchlights):
                assert eye.attrib == {'cx': str(x), 'cy': str(float(eye_y)), 'rx': '2.2', 'ry': '2.3', 'fill': '#000000', 'fill-opacity': '0.85'}
                assert light.attrib == {'cx': str(x - .6), 'cy': str(eye_y - .7), 'r': '0.65', 'fill': '#ffffff', 'fill-opacity': '0.85'}
            # Compare native outline sample vectors, not a reimplemented outline.
            vector = re.search(r'\("' + re.escape(name) + r'", (\d+), \[(.*?)\]\)', vectors).groups()
            coordinates = [float(token) for token in re.findall(number, svg.find(ns + 'path').attrib['d'])]
            assert len(coordinates) == int(vector[0]) * 2
            for index, x, y in re.findall(r'\((\d+), (' + number + r'), (' + number + r')\)', vector[1]):
                assert abs(coordinates[int(index) * 2] - float(x)) < 1e-9
                assert abs(coordinates[int(index) * 2 + 1] - float(y)) < 1e-9
    print(f'PASS: {len(entries)} {category}; native metadata, finite valid SVG geometry, ' +
          ('all agent-seed blobatar SHA-256 vectors' if style == 'face' else 'native ring vectors, eyes and catchlights'))

# Do not copy unrelated runtime notices. Preserve each exact MIT notice.
notices = (root / 'Bighelp/Resources/ThirdParty-NOTICES.txt').read_text()
commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
for category, heading, files, detail in [
    ('faces', 'blobatar\n', ['HermesBlobFace.swift', 'HermesFaceViews.swift'],
     "Public preview seed: `agent`; every `HermesBlobFace.Kind.allCases` silhouette.\n"
     "SVG bytes are `HermesBlobFace.render(seed: \"agent\", kind: kind).svg`, unchanged.\n"),
    ('shapes', 'Hermes Agent, Bot Mode avatars\n', ['HermesShapeFace.swift', 'HermesFaceViews.swift'],
     'Every `HermesShapeFace.pickerShapes` entry; `primaryColor` (`#8b5cf6`).\n'
     'Exact native resting 40×44 drawing: default sampled ring, eyes and catchlights.\n'
     'Triangle includes native negative-y points; no silhouette correction or clipping is added.\n'),
]:
    section = notices[notices.index(heading):]
    if category == 'faces':
        section = section[:section.index('\nHermes Agent, Bot Mode avatars\n')]
    payloads[f'{category}/THIRD_PARTY_NOTICES.txt'] = section.encode()
    provenance = '# Built-in avatar provenance\n\n' + f'App source commit: `{commit}`.\n\n' + detail + '\nSources (SHA-256):\n'
    for filename in files:
        digest = hashlib.sha256((source_dir / filename).read_bytes()).hexdigest()
        provenance += f'- `Bighelp/Companion/HermesFaces/{filename}`: `{digest}`\n'
    provenance += '\nLicense and attribution: `THIRD_PARTY_NOTICES.txt` copied from `Bighelp/Resources/ThirdParty-NOTICES.txt`.\n'
    provenance += '\nReproduce and verify from the repo root: `bash scripts/export-builtin.sh`.\n'
    provenance += '\nCatalog nativeLook follows the chosen agent name/color; these are deterministic static previews, not locked user-specific faces.\n'
    payloads[f'{category}/PROVENANCE.md'] = provenance.encode()

for name, data in payloads.items():
    target = root / 'services/avatars/sources' / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
print('PASS: isolated Mac export directory removed; only faces/ and shapes/ outputs written.')
PY
