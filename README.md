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
2. **Win the run** by beating Ante 8. The reward flow opens automatically on the **You Win** screen.
3. **Re-select your whole loadout.** You step through cards, then Jokers, then Vouchers, then deck effects, choosing up to the number of each you've unlocked. Your currently-kept items are **pre-checked**, so usually you just confirm; deselect one to drop it, or check a different one to swap. Everything is captured at its **current, leveled-up state** (a Joker's grown sell value, a card's accumulated chips, etc.).
4. **Start the next run.** Click **Start Run N** and you're dropped into a fresh run with your selected loadout in place, and the blinds now scale one level faster.
5. **Repeat.** Each win unlocks more keep-slots and faster blind scaling, according to your carry-over mode (see below).

If you **lose**, nothing is lost. You restart the same run level with the same kept items and can try again.

Your progress saves automatically and survives closing the game.

### Carry-over modes

A **Mode** control sits on the deck panel (and in the Mods config tab and the multiplayer lobby panel). It sets what a win carries over and how fast the blinds scale. The mode is saved with your progression and travels in the JSON. The tables show how many of each type you may keep after winning that run; you re-select your full loadout every run either way.

**Full Loadout** (the default): every win adds one keep-slot of *each* type, and the blinds scale four levels per run.

| Run | Blinds scale at | Cards | Jokers | Vouchers | Deck effects |
|-----|-----------------|-------|--------|----------|--------------|
| 1 | Level 1 (White Stake pace) | 1 | 1 | 1 | 1 |
| 2 | Level 5 | 2 | 2 | 2 | 2 |
| 3 | Level 9 | 3 | 3 | 3 | 3 |
| ... | +4 levels per run | | | | +1 of each per win |

**Versus**: rules for a head-to-head series (see the Multiplayer section for the series flow). Every win adds one keep-slot of each type like Full Loadout, but the blind level doubles after the second run, and the deck-effect rewards for the first three rounds come from fixed pools.

| Run | Blinds scale at | Keeps | Deck-effect reward pool |
|-----|-----------------|-------|-------------------------|
| 1 | Level 1 | 1 of each | Red, Blue, Green, Yellow, Magic |
| 2 | Level 5 | 2 of each | + Ghost, Black, Painted, Anaglyph, Abandoned |
| 3 | Level 10 | 3 of each | + Plasma, Heidelberg, Echo, Fabled |
| 4 | Level 20 | 4 of each | every deck |
| 5 | Level 40 | 5 of each | every deck |
| ... | doubles each run | +1 of each per win | every deck |

The pools are cumulative, so a deck effect you kept earlier can always be re-selected. Heidelberg and Echo come from BalatroMultiplayer and Fabled from All in Jest; if one of those mods is missing, that entry simply doesn't appear.

**Unlimited**: no keep limits on cards, Jokers, and Vouchers. Every win lets you carry over as many of those as you want (the reward screen gains **Keep all** / **Keep none** buttons to make that fast). Deck effects cannot be kept in this mode. The blind levels follow the Versus schedule:

| Run | Blinds scale at | Cards / Jokers / Vouchers | Deck effects |
|-----|-----------------|---------------------------|--------------|
| 1 | Level 1 | unlimited | none |
| 2 | Level 5 | unlimited | none |
| 3 | Level 10 | unlimited | none |
| 4 | Level 20 | unlimited | none |
| 5 | Level 40 | unlimited | none |
| ... | doubles each run | unlimited | none |

**Classic**: each win unlocks a single new keep-slot, cycling through the four types, and the blinds scale one level per run.

| Run | Blinds scale at | Cards | Jokers | Vouchers | Deck effects |
|-----|-----------------|-------|--------|----------|--------------|
| 1 | Level 1 (White Stake pace) | 1 | – | – | – |
| 2 | Level 2 (Green Stake pace) | 1 | 1 | – | – |
| 3 | Level 3 (Purple Stake pace) | 1 | 1 | 1 | – |
| 4 | Level 4 (faster still) | 1 | 1 | 1 | 1 |
| 5 | Level 5 | 2 | 1 | 1 | 1 |
| 6 | Level 6 | 2 | 2 | 1 | 1 |
| ... | ... | | | | the cycle loops forever |

Saves and JSON exports from before v0.10.0 load as Classic, since that was the only pacing then. Switching modes keeps your run number and reinterprets it under the new rules (the panel shows the resulting blind level next to the run number), so Classic run 5 becomes Full Loadout run 5: five of each, level 17. If that is not what you want, edit `"run"` in your JSON and re-import. A run already in progress keeps the mode it started with; the switch applies from the next run.

Because you re-select every run, a kept item always carries its **current** state forward. There's no "stale copy" problem: if your Blueprint's sell value grew or your King gained chips this run, re-confirming it at the reward screen saves the grown version.

- Kept **cards** return with their enhancement, edition, and seal.
- Kept **Jokers** return with their edition (Eternal/Perishable stickers are not carried).
- Kept **Vouchers** are redeemed for free at the start of every future run.
- Kept **deck effects** stack. Multiple decks are merged the way the Multiplayer Cocktail Deck does it: numeric bonuses add together, and triggered effects (Anaglyph's tags, Plasma's balancing, etc.) all fire.
- Blind scaling levels 1 to 3 use the vanilla White/Green/Purple Stake tables. Level 4 and beyond use Steamodded's extended scaling formula, which keeps accelerating.
- From level 6 on, each level adds one skipped step to the blind curve, placed at antes in the cycling order 4, 6, 8, 5, 7, then repeating for second skips. A skip pushes that ante and everything after it one extra step up the curve, so the offsets stack: level 6 has ante 4 play like ante 5, level 7 has ante 6 play like ante 8, level 8 has ante 8 play like ante 11, and by level 15 ante 8 sits at effective ante 18 (an Ante 8 boss around 2.7e34). Levels 1 to 5 and antes 1 to 3 always stay vanilla.

### Mod compatibility

Progression aims to work with almost any mod. Kept **cards** and **Jokers** are stored with the game's own save format (the same one used for run saves), so everything a mod added rides along: modded enhancements, editions, and seals, stickers, Paperback clips, and any custom ability state. When you start the next run they're rebuilt with the game's own loader, which calls each modded item's load hook, so the state comes back intact. Vouchers and deck effects are stored by their keys, so modded ones work too.

If a mod isn't installed on the machine you're playing on, that item degrades gracefully: a card falls back to its rank, suit, enhancement, edition, and seal where those still exist, and anything unavailable is skipped rather than crashing. So a run shared to a friend without the same mods still loads, just without the parts their game doesn't have.

One known edge case: cards carrying [Talisman](https://github.com/SMODS/Talisman) "big number" bonuses may lose the oversized value through the portable JSON format (it stores plain numbers). Everything else round-trips.

## Save, import, and export

Your progression is stored automatically in the Steamodded config, so it persists across restarts. You can also move a run between machines or set one up by hand:

- **Deck-select screen** (with the Progression Deck viewed): the deck's info panel shows your current run, mode, and next reward, with **Import**, **Export**, **Reset**, and **Mode** controls right below it. You can also **drag a `.json` file onto the game window** from the main menu to import it.
- **Options menu during a run:** an **Export Progression** button copies your state to the clipboard and writes `progression_export.json` to the Balatro save folder.
- **Mods menu:** the mod's config page has the same Import / Export / Reset controls.

To resume on another machine, install this mod (plus any content mods your run uses), then Paste Import or drop the `.json` file.

### JSON format

```json
{
  "run": 5,
  "mode": "full",
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

- `run` is the run number you'll start at.
- `mode` is the carry-over mode: `"full"` (Full Loadout), `"classic"`, `"versus"`, or `"unlimited"`. If it's missing, a JSON with any progress loads as Classic and a fresh one as Full Loadout.
- `bonus_dollars` (optional) is the comeback bonus, extra starting money each run.
- `meta_lives` (optional, 1 to 4) is your remaining meta-lives in a Versus series.
- `rank` and `suit` accept full names (`"King"`, `"Hearts"`) or card keys (`"K"`, `"H"`; 10 is `"T"`).
- `enhancement`, `edition`, and `seal` are optional. Enhancements use center keys (`m_glass`, `m_steel`, ...), editions use full keys (`e_foil`, `e_holo`, `e_polychrome`, `e_negative`), seals are `Gold`, `Red`, `Blue`, or `Purple`.
- `jokers` entries can also be plain strings (`"j_blueprint"`).
- Modded content uses that mod's own keys. Unknown or invalid keys are skipped at run start, so importing on a machine with different mods will not crash.
- Importing **overwrites** your current progression state.

## Multiplayer (via JSON, with BalatroMultiplayer)

You can run a progression series against another player using [BalatroMultiplayer](https://github.com/Balatro-Multiplayer/BalatroMultiplayer). There's no live syncing — the JSON export/import is the sync, so each player just configures their own Progression deck between matches. Both players need the same Progression and Multiplayer versions.

A series looks like:

1. Host an **Attrition** lobby (the "4 lives" mode) and turn on **Different Decks** so each player can run their own deck.
2. Each player chooses the **Progression Deck** in the lobby. A **Progression panel with Import / Export / Mode / Comeback buttons sits right on the lobby screen** for both the host and the joiner, so either player can paste in their JSON there. Agree on the same carry-over mode for a fair series. (The full deck panel also appears inside Choose Deck; note the joiner's Choose Deck button only unlocks when the host enables Different Decks.)
3. Play the match. Blinds scale by your run level as usual.
4. When it's decided, **both players re-select their loadout** on their end screen: the winner on the **You Win** screen, the loser on the **Game Over** screen. Then each player **Exports** their updated JSON.
5. Next match, paste your JSON back in and go again. Rewards accumulate per your carry-over mode: in Full Loadout the second match already has each of you carrying a card, a Joker, a Voucher, and a deck effect; in Classic you build up one keep at a time.

**Meta-lives and series play.** Each player has **4 meta-lives**, shown on the deck panel and the lobby panel. Losing a multiplayer match (running out of in-match lives) costs one meta-life automatically. When a player loses their fourth, the **series is over**: that player's comeback money goes up by **$25** and their meta-lives refill to 4 for the next series. Both players then import their stats as usual and start the next series. Because nothing is synced between clients, the series **winner** refreshes their own side by hand: click the **Lives** control to cycle back to 4 (it counts down and wraps, `4 / 3 / 2 / 1 / 4`), and if you had comeback money from losing a previous series, cycle **Comeback $** back to `$0`. The Lives control also fixes the count if a disconnect or crash miscounted a match.

**Comeback bonus.** The match loser can start the next match with extra money. On the deck panel, use the **Comeback start** control to cycle it in $25 steps up to $100, or set `"bonus_dollars": 25` in your JSON. It's applied at the start of every run until you set it back to `$0`. Series losses add $25 to it automatically (see meta-lives above). (BalatroMultiplayer also has a native "gold on life loss" lobby toggle if you'd rather the game hand out catch-up money automatically.)

This is new and hasn't been battle-tested across two clients yet — if the deck desyncs in a match or the scaling doesn't take, let me know and it can be adjusted.

## Known limitations

- Rewards are chosen from a text list rather than clickable card art in this version.
- A few modded decks that only behave inside their own game mode (Cryptid's Antimatter, Aikoyori's Hardcore Challenges) are excluded from the deck-effect reward on purpose.
- Kept cards restore their enhancement, edition, seal, and permanent numeric bonuses (`perma_*` fields). Very exotic modded per-card effects that store state elsewhere may not fully round-trip.

## License

MIT. Do whatever you like with it.
