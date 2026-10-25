# KickAlert

## 1.2.2

### Features
- **Three alerts** when your target or focus casts an interruptible spell and your interrupt is ready and in range: text, screen glow and sound, each tuned and turned off separately.
- **Nameplate alert**: a **KICK** word above any hostile unit casting an interruptible spell, without targeting it.
- **Interrupt detected, not configured**: per-class table filtered by the spells the character knows. `/ka spell <id>` forces a case the table does not cover.
- **12.x engine** (WoW Forever): interruptible state read from cast events, cooldown deduced from your own casts. `/ka status` shows the source in use.
