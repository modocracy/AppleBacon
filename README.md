# AppleBacon

**English** · [한국어](README.ko.md)

AppleBacon lets you build your own armor in **Helldivers 2** from pieces you already own: take one armor's **look**, another's **base stats** and a third one's **passive**, save the combination, and wear it.

AppleBacon is standalone. It does not need Bingus Shared Loader or any other loader, and it works alongside one if your other mods use it.

## Features

- **Mix and match** an owned look, base-stat profile and passive into a saved variant.
- **Edit from the details panel**: select an armor, press **+**, and the selected armor becomes the look. Click the **Stats** or **Armor Passive** box to change that part, in any order.
- **Passive icon grid** with names, a compact **stats table** with gauges, mouse-wheel scrolling and mouse-over highlights.
- **Native look and Korean captions**: the panels follow the game's own style and switch to Korean when the game is in Korean.
- **Controller support** (XInput / Steam Input): D-pad or stick to move, A to select, B back, Y cancel, LB/RB to jump.
- **Saved variants** survive restarts and can also be picked on the pre-mission Equipment screen.
- **Client-side**: only you need the mod.

Only equipment you own can be combined. AppleBacon does not unlock anything.

## Install

1. Close Helldivers 2.
2. Import `AppleBacon-<version>.zip` in **Arsenal** (or another manager that reads the same format) and enable it.
   You can also use **Modocracy**, the author's own mod manager: https://github.com/modocracy/modocracy/releases/latest
3. **Purge / Deploy**, then start the game.
4. Open **Armory → Armor**. Your variants and the **+** card are at the top of the list.

## Use

1. Click an armor to select it, then press **+ (Create variant)**. That armor becomes the look.
2. Click **Stats** in the details panel to choose base stats, and **Armor Passive** to choose a passive. The box you are editing is outlined in yellow.
3. To change the look, click the **Look** line.
4. Press **Create** to save. Select the new card and press the game's **Equip** button to wear it.

To change a saved variant, select it and press **Edit variant**: the creator opens with its look, stats and passive, and **Save** replaces it. If you were wearing it, equip it again to wear the changes. **Remove variant** deletes it.

## Settings (in Arsenal → Options)

| Option | Default | What it does |
| --- | --- | --- |
| Base stats | Choose separately | Off: base stats always follow the look. |
| Helmet and cape variants | On | Lets helmets and capes use the same creator when another mod gives them passives. |
| Passive icons on armor cards | On | Shows each card's passive as a small badge. |

## Files and uninstall

Saved variants: `%LOCALAPPDATA%\AppleBacon\Data`
Logs: `%LOCALAPPDATA%\AppleBacon\Logs\AppleBacon.log` (`STATUS.txt` in the Data folder shows the last start-up result)

To uninstall, disable AppleBacon in your mod manager and deploy. The `%LOCALAPPDATA%\AppleBacon` folder is kept in case you reinstall; delete it yourself to remove your variants.

## Good to know

- AppleBacon starts through the game's small `core/wwise/lua/wwise_bank_reference` script: it runs the game's original code for that script first, unchanged, then starts AppleBacon. A game update that changes that script needs a AppleBacon update.
- Combat behaviour of every combination has not been verified; AppleBacon only confirms what the game reports in the Armory.
- Tested on Steam build 25480438.

## License and credits

See [CREDITS.md](CREDITS.md). Not for sale; no paid or donation-point distribution without the original author's permission.
