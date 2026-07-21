# Progression

A roguelite meta-progression deck for [Balatro](https://www.playbalatro.com/). Beat a run and you keep something forever. Every run after that, the blinds scale one level faster. How long can you keep up as your deck grows and the difficulty climbs?

![The Progression Deck](assets/2x/prog_decks.png)

## Requirements

- [Balatro](https://store.steampowered.com/app/2379780/Balatro/)
- [Lovely Injector](https://github.com/ethangreen-dev/lovely-injector)
- [Steamodded](https://github.com/Steamodded/smods) (v1.0.0-beta or newer)

## Installation

1. Install **Lovely Injector** and **Steamodded** first (follow their linked guides). Confirm they work by launching Balatro once and seeing the mod list on the main menu.
2. Download this mod:
   - **Easiest:** on this page click **Code -> Download ZIP**, then unzip it.
   - **Or** with git: `git clone https://github.com/Michael-Andrzejewski/Progression-Balatro.git`
3. Put the mod folder into your Balatro `Mods` folder so the path looks like `Mods/Progression/main.lua`:
   - **Windows:** `%AppData%\Balatro\Mods`
   - **macOS:** `~/Library/Application Support/Balatro/Mods`
   - **Linux (Proton):** `.../steamapps/compatdata/2379780/pfx/drive_c/users/steamuser/AppData/Roaming/Balatro/Mods`

   If the ZIP unzipped to a nested folder like `Progression-Balatro-main`, rename it to `Progression`. The `.json`, `main.lua`, and `assets` files must sit directly inside it.
4. Launch Balatro. On the deck-select screen you'll find the **Progression Deck**.

## How to play

1. **Start a new run** and choose the **Progression Deck**. It begins as an ordinary 52-card deck with no bonuses. Stake choice is up to you (the mod's own scaling is separate from stakes).
2. **Win the run** by beating Ante 8. The reward picker opens automatically. If you ever miss it or dismiss it, open the **Options menu** (during the run) and click **Choose Progression Reward**. It's available there until you claim.
3. **Pick one thing to keep forever.** What you're offered depends on which run number you're on (see the table below). Choose a card, Joker, Voucher, or deck effect, or Skip it. Kept cards keep permanent bonuses too (extra chips from Hiker, etc.).
4. **Start the next run.** Click **Start Run N** and you're dropped into a fresh run with your kept items already in place, and the blinds now scale one level faster.
5. **Repeat.** Each win adds another permanent item and another level of blind scaling. The reward type cycles: card, then Joker, then Voucher, then deck effect, then back to a second card, and so on forever.

If you **lose**, nothing is lost. You restart the same run level with the same kept items and can try again.

Your progress saves automatically and survives closing the game.

### Reward cycle

| Run | Blinds scale at | Reward for winning |
|-----|-----------------|--------------------|
| 1 | Level 1 (White Stake pace) | Keep 1 playing card from your deck |
| 2 | Level 2 (Green Stake pace) | Keep 1 Joker you're holding |
| 3 | Level 3 (Purple Stake pace) | Keep 1 Voucher you redeemed |
| 4 | Level 4 (faster still) | Keep 1 deck effect (any unlocked deck) |
| 5 | Level 5 | Keep a 2nd playing card |
| 6 | Level 6 | Keep a 2nd Joker |
| 7 | Level 7 | Keep a 2nd Voucher |
| 8 | Level 8 | Keep a 2nd deck effect |
| ... | ... | the cycle loops forever |

- **Re-picking upgrades.** Cards and Jokers you already kept show up in the reward list marked `[kept]`. Picking one again **updates that kept copy to its current, leveled-up state** (e.g. a King that grew from +120 to +440 chips this run) instead of adding a duplicate. Pick a different, un-kept item and it's added as a new keep. So each card/Joker round you choose: refresh an existing keep, or bring a new one.
- Kept **cards** return with their enhancement, edition, and seal.
- Kept **Jokers** return with their edition (Eternal/Perishable stickers are not carried).
- Kept **Vouchers** are redeemed for free at the start of every future run.
- Kept **deck effects** stack. Multiple decks are merged the way the Multiplayer Cocktail Deck does it: numeric bonuses add together, and triggered effects (Anaglyph's tags, Plasma's balancing, etc.) all fire.
- Blind scaling levels 1 to 3 use the vanilla White/Green/Purple Stake tables. Level 4 and beyond use Steamodded's extended scaling formula, which keeps accelerating (level 4 Ante 8 is roughly 400k, level 5 roughly 900k, and up from there).

### Mod compatibility

Progression aims to work with almost any mod. Kept **cards** and **Jokers** are stored with the game's own save format (the same one used for run saves), so everything a mod added rides along: modded enhancements, editions, and seals, stickers, Paperback clips, and any custom ability state. When you start the next run they're rebuilt with the game's own loader, which calls each modded item's load hook, so the state comes back intact. Vouchers and deck effects are stored by their keys, so modded ones work too.

If a mod isn't installed on the machine you're playing on, that item degrades gracefully: a card falls back to its rank, suit, enhancement, edition, and seal where those still exist, and anything unavailable is skipped rather than crashing. So a run shared to a friend without the same mods still loads, just without the parts their game doesn't have.

One known edge case: cards carrying [Talisman](https://github.com/SMODS/Talisman) "big number" bonuses may lose the oversized value through the portable JSON format (it stores plain numbers). Everything else round-trips.

## Save, import, and export

Your progression is stored automatically in the Steamodded config, so it persists across restarts. You can also move a run between machines or set one up by hand:

- **Deck-select screen** (with the Progression Deck viewed): the deck's info panel shows your current run and next reward, with **Import**, **Export**, and **Reset** buttons right below it. You can also **drag a `.json` file onto the game window** from the main menu to import it.
- **Options menu during a run:** an **Export Progression** button copies your state to the clipboard and writes `progression_export.json` to the Balatro save folder.
- **Mods menu:** the mod's config page has the same Import / Export / Reset controls.

To resume on another machine, install this mod (plus any content mods your run uses), then Paste Import or drop the `.json` file.

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

- `run` is the run level you'll start at (blinds scale at this level).
- `rank` and `suit` accept full names (`"King"`, `"Hearts"`) or card keys (`"K"`, `"H"`; 10 is `"T"`).
- `enhancement`, `edition`, and `seal` are optional. Enhancements use center keys (`m_glass`, `m_steel`, ...), editions use full keys (`e_foil`, `e_holo`, `e_polychrome`, `e_negative`), seals are `Gold`, `Red`, `Blue`, or `Purple`.
- `jokers` entries can also be plain strings (`"j_blueprint"`).
- Modded content uses that mod's own keys. Unknown or invalid keys are skipped at run start, so importing on a machine with different mods will not crash.
- Importing **overwrites** your current progression state.

## Multiplayer (via JSON, with BalatroMultiplayer)

You can run a progression series against another player using [BalatroMultiplayer](https://github.com/Balatro-Multiplayer/BalatroMultiplayer). There's no live syncing — the JSON export/import is the sync, so each player just configures their own Progression deck between matches. Both players need the same Progression and Multiplayer versions.

A series looks like:

1. Host an **Attrition** lobby (the "4 lives" mode) and turn on **Different Decks** so each player can run their own deck.
2. Each player chooses the **Progression Deck** in the lobby. The same Import / Export / Reset panel appears there, so you can paste in a run to start from.
3. Play the match. Blinds scale by your run level as usual.
4. When it's decided, **both players pick a card to carry forward**: the winner gets the reward popup automatically; either player can also open **Options -> Choose Progression Reward** during the match to pick. Then each player **Exports** their updated JSON.
5. Next match, paste your JSON back in and go again. Rewards accumulate on the normal cycle (card, then Joker, then Voucher, then deck effect), so by the second match you're each carrying a card, by the third a card and a Joker, and so on.

**Comeback bonus.** The match loser can start the next match with extra money. On the deck panel, use the **Comeback start** control to cycle it (`$0 / $25 / $50`), or set `"bonus_dollars": 25` in your JSON. It's applied at the start of every run until you set it back to `$0`, so the loser turns it on for their comeback match and off afterward. (BalatroMultiplayer also has a native "gold on life loss" lobby toggle if you'd rather the game hand out catch-up money automatically.)

This is new and hasn't been battle-tested across two clients yet — if the deck desyncs in a match or the scaling doesn't take, let me know and it can be adjusted.

## Known limitations

- Rewards are chosen from a text list rather than clickable card art in this version.
- A few modded decks that only behave inside their own game mode (Cryptid's Antimatter, Aikoyori's Hardcore Challenges) are excluded from the deck-effect reward on purpose.
- Kept cards restore their enhancement, edition, seal, and permanent numeric bonuses (`perma_*` fields). Very exotic modded per-card effects that store state elsewhere may not fully round-trip.

## License

MIT. Do whatever you like with it.
