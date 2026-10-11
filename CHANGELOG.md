# Changelog

## AppleBacon 1.0.0

First release.

- Standalone: starts through its own startup hook, no loader needed. Bingus Shared Loader can stay installed for other mods.
- Creator in the game's own style: passive icon grid with names, stats table with gauges, details panel with dashed Stats and Armor Passive boxes, step progress bar.
- Sections are edited from the details panel in any order; a new variant starts from the armor you selected.
- Back, Forward and Cancel in the creator; Forward moves on keeping the current choice.
- Saved variants can be edited: **Edit variant** reopens one with its choices, and **Save** replaces it under the same identity.
- Mouse-wheel scrolling, a scrollbar, and mouse-over highlights on every choice and button.
- Korean captions when the game runs in Korean.
- Colours converted for the game's linear GUI; smoothed 64px passive icons drawn on whole pixels.
- The Armory's large armor model is shown again when the game leaves it hidden.
- Saves and logs in `%LOCALAPPDATA%\AppleBacon\Data` and `\Logs`.
