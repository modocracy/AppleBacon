#!/usr/bin/env python3
"""Copy the game's original core/wwise/lua/wwise_bank_reference bytecode (read-only).

AppleBacon's startup hook (src/boot_hook.lua) replaces that module and runs this
original first. After a game update, run this against the installed game, then
update HOOK_ORIGINAL_SHA256 in tools/build.py if the bytecode changed.
"""
import argparse
import hashlib
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'vendor/BingusSharedLoader/scripts'))
from hd2_bundles import BundleIndex, DSAR, archive_entries, LUA_TYPE  # noqa: E402
from archive import resource_hash  # noqa: E402

BASE_ARCHIVE = '9ba626afa44a3aa3'
MODULE = 'core/wwise/lua/wwise_bank_reference'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-data', type=Path,
                        default=Path(r'C:/Program Files (x86)/Steam/steamapps/common/Helldivers 2/data'))
    parser.add_argument('--output', type=Path, default=ROOT / 'vendor/game/wwise_bank_reference.luac')
    args = parser.parse_args()
    index = BundleIndex(DSAR(str(args.game_data / 'bundles.nxa')).all(), str(args.game_data))
    main_file = index.read(BASE_ARCHIVE)
    wanted = resource_hash(MODULE)
    for name, kind, offset, _, _, size, _, _ in archive_entries(main_file):
        if name == wanted and kind == LUA_TYPE:
            length, _ = struct.unpack_from('<II', main_file, offset)
            body = main_file[offset + 8:offset + 8 + length]
            if not body.startswith(b'\x1bLJ'):
                raise SystemExit('the module is no longer LuaJIT bytecode')
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(body)
            print(f'{args.output} {len(body)} bytes sha256 {hashlib.sha256(body).hexdigest()}')
            return
    raise SystemExit(f'{MODULE} not found in {BASE_ARCHIVE}')


if __name__ == '__main__':
    main()
