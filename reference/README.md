# Reference data

Game-format facts that the offline tests check AppleBacon's built-in tables against. Nothing here is a player capture, inventory or save; whether you own an item is always checked in game.

| File | Matches | Contents |
| --- | --- | --- |
| `current_catalog.json` | `src/catalog_data.lua` | Armor and passive identifiers, record layouts and passive definitions, with the hashes of the inputs they came from |
| `armor_display.json` | `src/catalog_labels.lua` | English armor names and passive descriptions, with source hashes |
| `passive_icon_geometry_manifest.json` | `src/passive_icon_geometry.lua` | Source hashes, sizes and rectangle counts of the 32px passive icons (no texture files). The 64px set in `src/passive_icon_geometry_hd.lua` is generated from that file by `tools/upscale_passive_icon_geometry.py`. |

Building and testing need only these files, not an installed game. Regenerating them needs your own game data; those inputs stay out of the repository.

Helldivers 2 names, text and icon shapes belong to Arrowhead Game Studios / Sony Interactive Entertainment. No license to game assets is implied.
