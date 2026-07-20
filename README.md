# Progression

A roguelite meta-progression deck for Balatro (Steamodded).

## How it works

The **Progression Deck** starts as a plain 52-card deck with no modifiers. When you beat Ante 8, you pick one reward to keep for **all future runs**, then the run repeats one level harder:

| Run | Blinds scale at | Reward for winning |
|-----|-----------------|--------------------|
| 1 | Level 1 (White Stake pace) | Keep 1 playing card from your deck |
| 2 | Level 2 (Green Stake pace) | Keep 1 Joker you're holding |
| 3 | Level 3 (Purple Stake pace) | Keep 1 Voucher you redeemed |
| 4 | Level 4 (extended scaling) | Keep 1 deck effect (any unlocked deck) |
| 5 | Level 5 | Keep a 2nd playing card |
| 6 | Level 6 | Keep a 2nd Joker |
| ... | ... | ... (the cycle loops forever) |

Losing does not reset anything. You retry the same run level with the same kept items. Only winning advances the level.

- Kept **cards** return with their enhancement, edition, and seal.
- Kept **Jokers** return with their edition (but not stickers like Eternal).
- Kept **Vouchers** are redeemed at the start of every run.
- Kept **deck effects** are merged like the Multiplayer Cocktail Deck: numeric bonuses stack, and triggered effects (Anaglyph tags, Plasma balancing) all fire.
- Blind scaling levels 1 to 3 use the vanilla White/Green/Purple Stake tables. Level 4 and beyond use Steamodded's extended scaling formula, which keeps accelerating (level 4 Ante 8 is roughly 400k, level 5 roughly 900k).

## Import / export

Progression state is saved automatically in the Steamodded config, so it survives restarts. To move it between machines or set up a test state:

- **Deck select screen** (with the Progression Deck viewed): a panel shows your current state with Paste Import / Export / Reset buttons. You can also **drag a .json file onto the game window** anywhere in the menus to import it.
- **Options menu during a run**: an Export Progression button copies the state to your clipboard and writes `progression_export.json` to the Balatro save folder (`%AppData%\Balatro`).
- **Mods menu**: the mod's config page has the same Import / Export / Reset controls.

### JSON format

```json
{
  "run": 5,
  "cards": [
    { "rank": "King", "suit": "Hearts", "enhancement": "m_glass", "edition": "e_foil", "seal": "Red" }
  ],
  "jokers": [
    { "key": "j_blueprint", "edition": "e_negative" }
  ],
  "vouchers": ["v_overstock_norm"],
  "decks": ["b_red"]
}
```

Notes:

- `rank` and `suit` accept full names (`"King"`, `"Hearts"`) or card keys (`"K"`, `"H"`; 10 is `"T"`).
- `enhancement`, `edition`, and `seal` are optional. Enhancements use center keys (`m_glass`, `m_steel`, ...), editions use full keys (`e_foil`, `e_holo`, `e_polychrome`, `e_negative`), seals use `Gold`, `Red`, `Blue`, `Purple`.
- `jokers` entries can also be plain strings (`"j_blueprint"`).
- Unknown or invalid keys are skipped safely at run start, so an import from a setup with different mods will not crash.
- Importing **overwrites** your current progression state.

## Installation

Copy (or junction) this folder into `%AppData%\Balatro\Mods`. Requires [Steamodded](https://github.com/Steamodded/smods) and [Lovely](https://github.com/ethangreen-dev/lovely-injector).

## Known limitations

- Claim your reward before quitting at the win screen. If you close the game with the reward menu open, that run's reward is lost (the run level does not advance either, so you can win it again).
- The reward is chosen from a text list rather than card art in this first version.
