#!/usr/bin/env python3
"""Check/refresh the vendored RKN Watcher sources from the pinned local Git object."""
import argparse
import hashlib
import pathlib
import subprocess
import sys

sys.dont_write_bytecode = True
from build_standalone import RKN_EXECUTABLES, VENDOR, VENDOR_FILES, manifest_bytes

REVISION = '3c88c27a65181a93921a21b2d8a28f2292df1e03'
ADAPTATIONS = {
    'lib/config.sh': (
        b'SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"',
        b'SCRIPT_DIR="$RKN_ROOT"',
    ),
    'installer.sh': (
        b'    ensure_nftables y || { error "',
        b'    ensure_nftables n || { error "',
    ),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('upstream_clone', type=pathlib.Path)
    parser.add_argument('--check', action='store_true', help='do not write; compare vendor/ to the pinned source with the two adaptations')
    args = parser.parse_args()

    def git_file(name):
        return subprocess.check_output(['git', '-C', str(args.upstream_clone), 'show', f'{REVISION}:{name}'])

    checksums = dict(line.split()[::-1] for line in git_file('SHA256SUMS').decode('utf-8').splitlines() if line.strip())
    files = {name: git_file(name) for name in VENDOR_FILES if name != 'UPSTREAM_COMMIT'}
    for name, data in files.items():
        if hashlib.sha256(data).hexdigest() != checksums.get(name):
            raise SystemExit(f'upstream SHA256SUMS mismatch: {name}')
    for name, (old, new) in ADAPTATIONS.items():
        if files[name].count(old) != 1:
            raise SystemExit(f'expected adaptation not found exactly once: {name}')
        files[name] = files[name].replace(old, new, 1)
    files['UPSTREAM_COMMIT'] = (REVISION + '\n').encode('ascii')
    files['SHA256SUMS'] = manifest_bytes(files)
    for name, data in files.items():
        afile = VENDOR / name
        if args.check:
            if not afile.is_file() or afile.read_bytes() != data:
                raise SystemExit(f'different pinned vendor file: {name}')
        else:
            afile.parent.mkdir(exist_ok=True, parents=True)
            afile.write_bytes(data)
            afile.chmod(0o755 if name in RKN_EXECUTABLES else 0o644)
    version = files['VERSION'].decode('ascii').strip()
    print(f'RKN Watcher {version} ({REVISION}): {len(files)} vendor files')


if __name__ == '__main__':
    main()
