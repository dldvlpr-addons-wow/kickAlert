# KickAlert

World of Warcraft addon for every client (Classic Era, TBC, Wrath, Cata, MoP Classic, retail).
Standalone version of the MyBossSuite Kick alert (`Modules/InterruptAlert`), with an added
screen glow and a graphical options panel.

When your target or focus casts an interruptible spell **and** your interrupt is
ready (and in range), three independent alerts fire:

- **Text**: configurable word (default `KICK`), font, size, outline, color (color picker),
  adjustable pulse, free position.
- **Glow**: glowing border on all 4 edges of the screen, color and intensity (alpha through the
  color picker), thickness, adjustable pulse.
- **Sound**: preset (`alarm`, `raidwarning`, `readycheck`, `ping`, `murloc`), SOUNDKIT id or
  file (`Interface\AddOns\X\kick.ogg`).

Each alert is enabled, tuned and turned off separately.

On top of these three target/focus alerts, a **KICK** word can show above the nameplate
of any hostile unit casting an interruptible spell, without having to target it.

## Detection (taken from MyBossSuite)

Three conditions, checked together and continuously during the cast:
target (or focus) is casting, the cast is not protected (`notInterruptible`), your interrupt
is actually ready and in range. A 0.15 s ticker runs during the cast: no event reports a kick
coming off cooldown in the middle of a cast.

The interrupt is detected, not configured: a per-class table filtered by what the character
actually knows (Classic ranks are covered by the spellbook). `/ka spell <id>` forces a case
the table does not cover.

On clients where `UnitCastingInfo` returns nothing for a hostile unit, the combat log
(`SPELL_CAST_START`) takes over and the spell is assumed interruptible.

On the 12.x engine (retail Midnight, WoW Forever), the client hides values from addons in combat
("secret values"): whether the target's cast is protected is only known through the
`UNIT_SPELLCAST_(NOT_)INTERRUPTIBLE` events (a cast protected from its very start is assumed
interruptible), and your interrupt's cooldown is deduced
from your own casts (`UNIT_SPELLCAST_SUCCEEDED` on `player`) plus the spell's base cooldown, or the
last cooldown read outside combat. `/ka status` tells which source is in use.

## Installation

Copy the `KickAlert` folder into `World of Warcraft/_<version>_/Interface/AddOns/`.
A single `KickAlert.toc`, with no version suffix: every client loads it, and its
`## Interface` line lists the supported versions (Classic Era, Anniversary,
Forever, TBC, Wrath, Cata, Mists, retail).

## Commands

| Command | Effect |
|---|---|
| `/ka` or `/kickalert` | Opens the options panel |
| `/ka unlock` / `/ka lock` | Shows the text permanently and makes it movable / locks it |
| `/ka test` | Plays the 3 alerts for 3 seconds |
| `/ka reset` | Puts the text back at its default position |
| `/ka wipe` | Resets every setting (SavedVariables and CVar mirror), then reloads the UI |
| `/ka spell <id>` / `/ka spell auto` | Forces the tracked interrupt spell / goes back to detection |
| `/ka status` | Detected interrupt, availability, active options |
| `/ka sounds` | State of each offered sound on this client |
| `/ka sounds <pattern>` | Searches a SOUNDKIT constant, e.g. `/ka sounds warning` |

The text and the glow stay on screen while the options panel is open: this is the preview.

## Language

The addon is in English after install. The options panel offers the 11 client
languages (plus "Auto" to follow the game language); the change applies on
UI reload, through the dedicated button.

An untranslated key falls back to English instead of disappearing.

## Sounds

`SOUNDKIT` constants differ from one client to another. Only the sounds the client
can actually play are offered — `/ka sounds` shows which ones. The free field of
the panel also accepts any `SOUNDKIT` id or file path
(`Interface\AddOns\MyAddon\kick.ogg`).

## Files

- `Compat.lua`: every API that differs between versions (spells, casts, range, sounds,
  timers, gradients, color picker, options panel). Copy of the useful part of
  `MyBossSuite/Core/Compat.lua`.
- `Mirror.lua`: copies of the settings for WoW Forever 1.60, which writes account SavedVariables but does not read them back. The table is stored in `g_addonCategoriesCollapsed` (Blizzard_AddOnList save, `WTF/SavedVariables/`, read at startup) and copied into `KickAlertMirror1..8` CVars (they survive `/reload`). If the save comes back empty, these copies replace it. Consequence: deleting `KickAlert.lua` in `WTF` no longer resets anything; use `/ka wipe`.
- `Core.lua`: SavedVariables (`KickAlertDB`), internal bus, positioning mixin, slash commands.
- `Alerts.lua`: the three alerts.
- `Detector.lua`: port of `Modules/InterruptAlert/InterruptAlert.lua` without the WCL data or the
  group rotation.
- `Nameplates.lua`: "KICK" above the nameplate of any hostile unit casting an interruptible
  spell, without targeting.
- `Config.lua`: options panel, Blizzard widgets only.
- `tests/run.sh`: syntax check + headless suite on 4 client configurations (`lua5.1` required).

## Verification

```bash
tests/run.sh
```

## Known limitations

- Old Classic Era: without `UNIT_SPELLCAST_*` on the target, only the combat log fallback works,
  and it cannot tell whether a spell is protected.
- The glow cannot be moved: it is tied to the screen edges by design.
- Extra fonts only through a LibSharedMedia embedded by another addon.

## Compliance with the Blizzard add-on policy

Points of the *World of Warcraft UI Add-On Development Policy* and how KickAlert meets them:

| Blizzard requirement | KickAlert |
|---|---|
| Free add-on, no payment or paid feature | Free, GPL-3.0-or-later license, no premium version |
| Code fully visible, neither hidden nor obfuscated | Plain Lua, no `loadstring`, no encoded string |
| No advertising, no in-game donation request | No such message in the interface or in chat |
| No game automation, no protected API call | The addon only **displays**: no `CastSpell*`, `TargetUnit`, `RunMacro`, `UseAction` or combat action. The player casts the interrupt themselves |
| No negative impact on realms or other players | No network message (`SendAddonMessage`, chat), no external request; the combat log handler exits after two string comparisons |
| No offensive content | Texts and sounds chosen by the player, neutral defaults (`KICK`, client sounds) |
| Respect of the ToS / EULA, Blizzard may disable a feature | Only public documented APIs, routed through `Compat.lua` to follow client changes |

Data: only the player's settings in `KickAlertDB` (SavedVariables). No personal
data, no telemetry.

World of Warcraft® and Blizzard Entertainment® are trademarks of Blizzard Entertainment, Inc.
KickAlert is an independent project, neither affiliated with nor endorsed by Blizzard Entertainment.

## License

GPL-3.0-or-later, like MyBossSuite from which this code derives (see `LICENSE`).
