# Credits

## Original mod

AppleBacon is a modified version of **HD2 Transmog (Armor Transmog)** by **RatInPlat**
(Nexus Mods: https://www.nexusmods.com/helldivers2/mods/16633,
source: https://github.com/tyrypyrking/HD2-Transmog). RatInPlat is the original
creator of the transmog runtime, the native integration and the armor catalog
work that AppleBacon builds on.

Used under the permissions the author published on Nexus Mods:

- Modification: allowed to modify the files and release bug fixes or feature
  improvements, crediting the author as the original creator.
- Upload: allowed to upload to other sites, crediting the author.
- Assets: may not be used in mods or files that are sold; earning Donation
  Points with them requires the author's permission.

## Third-party components

- **LuaJIT x86/x64 disassembler** (`dis_x86.lua`) by Mike Pall, MIT license.
  See THIRD-PARTY-LICENSES.txt.
- **Bingus Shared Loader** by CowboyBingus: no loader code is included;
  AppleBacon works alongside the loader.

## Game content

Helldivers 2 is © Arrowhead Game Studios / Sony Interactive Entertainment.
AppleBacon's startup hook contains the game's own compiled
`core/wwise/lua/wwise_bank_reference` script, unchanged, so that the game
keeps working exactly as before when AppleBacon replaces that script. Passive icon
shapes are sampled from the game's icons for display only.
