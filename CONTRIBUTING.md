# Building AppleBacon

## Requirements

- Python 3.10 or newer with `pip install -r requirements-dev.txt`
- LuaJIT 2.1 on `PATH` as `luajit` (used by the tests and the build's syntax check)
- An installed copy of Helldivers 2, only when refreshing game-derived files

The packaging helpers `archive.py` and `build_addon.py` are fetched, checksum-pinned, by:

```sh
python tools/setup_dependencies.py
```

## Test and build

```sh
python -m pytest -q tests
python tools/build.py
```

The build writes `dist/AppleBacon-<version>.zip`, ready to import in Arsenal, and a `.sha256` file next to it.

## Layout

| Path | What it is |
| --- | --- |
| `src/main.lua` | Startup, wiring and the per-frame update |
| `src/boot_hook.lua` | Standalone startup hook (replaces `core/wwise/lua/wwise_bank_reference`) |
| `src/wizard_panel.lua` | Creator and details-panel drawing |
| `src/variant_wizard.lua`, `src/ui_workflow.lua` | Creator model and input flow |
| `src/state.lua`, `src/platform.lua` | Saved variants and file access |
| `tests/` | Offline tests (no game needed) |
| `tools/build.py` | Bundles `src/` into one Lua resource and writes the install ZIP |

Development-only modules (`debug_bridge.lua`, probes) stay in `src/` for tests and the opt-in debug channel, but `tools/build.py` does not ship them. The debug channel only exists in a development build and additionally needs a `debug.enabled` marker file.

## The game's original hook script

AppleBacon's startup hook embeds the game's original `wwise_bank_reference` bytecode. That file belongs to the game, so the source repository does not publish it: before your first build, extract it from your own Helldivers 2 install:

```sh
python tools/extract_hook_original.py --output vendor/game/wwise_bank_reference.luac
```

## After a game update

Check whether the game's original hook script changed:

```sh
python tools/extract_hook_original.py --output new.luac
```

If the SHA-256 printed differs from `HOOK_ORIGINAL_SHA256` in `tools/build.py`, replace `vendor/game/wwise_bank_reference.luac` with the new file, update the constant, and rebuild. Native memory layouts can also change with an update; the in-game status line and `%LOCALAPPDATA%\AppleBacon\Logs\AppleBacon.log` report a compatibility stop.

## Artwork and icons

- `python tools/make_artwork.py` redraws `assets/applebacon-icon.png` and `assets/applebacon-banner.png`.
- `python tools/upscale_passive_icon_geometry.py` rebuilds the smoothed 64px passive icons from the 32px set.

## Credits

Keep [CREDITS.md](CREDITS.md) with every release.
