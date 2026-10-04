#!/usr/bin/env python3
"""Exercise unchanged app decoder/renderer on isolated Mac Swift; no app build."""
import io
import json
import os
import pathlib
import shlex
import subprocess
import tarfile
import sys

service = pathlib.Path(__file__).resolve().parent.parent
repo = service.parent.parent
output = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else service / '.wrangler/native-probe'
# A Mac with Swift, reached over SSH: AVATAR_SWIFT_HOST (required) and AVATAR_SSH_CONFIG (optional).
host = os.environ.get('AVATAR_SWIFT_HOST', '').strip()
if not host:
    sys.exit('Set AVATAR_SWIFT_HOST to an SSH host (a Mac with Swift). AVATAR_SSH_CONFIG is optional.')
ssh = ['ssh'] + (['-F', os.environ['AVATAR_SSH_CONFIG']] if os.environ.get('AVATAR_SSH_CONFIG') else []) \
    + ['-o', 'ConnectTimeout=30', host]
remote = subprocess.check_output(ssh + ['mktemp -d "${TMPDIR:-/tmp/}avatar-native.XXXXXX"'], text=True).strip()
q = shlex.quote(remote)
archive = io.BytesIO()
with tarfile.open(fileobj=archive, mode='w') as tar:
    for name in ['AvatarKit.swift', 'AvatarKitRenderer.swift']:
        tar.add(repo / 'Bighelp/Companion/AvatarKit' / name, arcname=name)
    tar.add(service / 'scripts/verify-native.swift', arcname='probe.swift')
    data = json.dumps(json.loads((service / 'catalog.json').read_text())['kit']).encode()
    info = tarfile.TarInfo('kit.json'); info.size = len(data)
    tar.addfile(info, io.BytesIO(data))
try:
    subprocess.run(ssh + [f'tar -xf - -C {q}'], input=archive.getvalue(), check=True)
    subprocess.run(ssh + [f'cd {q} && swiftc -module-cache-path ./cache AvatarKit.swift AvatarKitRenderer.swift probe.swift -o probe && ./probe kit.json out'], check=True)
    images = subprocess.check_output(ssh + [f'COPYFILE_DISABLE=1 tar -cf - -C {q}/out .'])
    output.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(images)) as tar:
        for entry in tar:
            if entry.isfile():
                name = pathlib.PurePosixPath(entry.name).name
                if not name.endswith('.png') or entry.size > 2_000_000:
                    raise ValueError('Unexpected native probe artifact')
                stream = tar.extractfile(entry)
                if stream is None:
                    raise ValueError('Missing artifact data')
                (output / name).write_bytes(stream.read())
finally:
    subprocess.run(ssh + [f'rm -rf -- {q}; test ! -e {q}'], check=True)
