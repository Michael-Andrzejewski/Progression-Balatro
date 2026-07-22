--- Progression Mod
--- A roguelite deck for Balatro. Each win lets you keep something for all future runs,
--- but every run level makes the blinds scale one level faster.
--- Reward cycle: playing card, Joker, Voucher, deck effect, then it loops.

local mod = SMODS.current_mod

PROG = PROG or {}
PROG.mod = mod

local PAGE_SIZE = 8

----------------------------------------------------------------
-- State
----------------------------------------------------------------
-- Stored in the mod config (persists across runs and game restarts):
-- state = {
--   run      = 1,   -- current run level (1-based); blinds scale at this level
--   cards    = { {rank='King', suit='Hearts', enhancement='m_glass', edition='e_foil', seal='Red'}, ... },
--   jokers   = { {key='j_blueprint', edition='e_negative'}, ... },
--   vouchers = { 'v_overstock_norm', ... },
--   decks    = { 'b_red', ... },
-- }

local function default_state()
	return { run = 1, cards = {}, jokers = {}, vouchers = {}, decks = {}, bonus_dollars = 0 }
end

function PROG.state()
	mod.config.state = mod.config.state or default_state()
	local st = mod.config.state
	st.run = st.run or 1
	st.cards = st.cards or {}
	st.jokers = st.jokers or {}
	st.vouchers = st.vouchers or {}
	st.decks = st.decks or {}
	st.bonus_dollars = st.bonus_dollars or 0
	return st
end

function PROG.save()
	SMODS.save_mod_config(mod)
end

function PROG.reset()
	mod.config.state = default_state()
	PROG.save()
end

PROG.REWARD_CYCLE = { 'card', 'joker', 'voucher', 'deck' }
PROG.REWARD_NAMES = { card = 'playing card', joker = 'Joker', voucher = 'Voucher', deck = 'deck effect' }

function PROG.reward_type(run)
	run = run or PROG.state().run
	return PROG.REWARD_CYCLE[(run - 1) % 4 + 1]
end

-- Live UI strings (referenced by ref_table text nodes so they update in place)
PROG.ui = { summary = '', next = '', note = '', run_line = '', next_short = '', kept_line = '', comeback = '' }

function PROG.refresh_ui_strings()
	local st = PROG.state()
	PROG.ui.summary = string.format('Run %d. Kept: %d cards, %d Jokers, %d Vouchers, %d deck effects.',
		st.run, #st.cards, #st.jokers, #st.vouchers, #st.decks)
	PROG.ui.next = 'Next reward on win: ' .. PROG.REWARD_NAMES[PROG.reward_type()]
	-- Compact variants for the narrow deck-select panel
	PROG.ui.run_line = 'Run ' .. st.run
	PROG.ui.next_short = 'Next win: ' .. PROG.REWARD_NAMES[PROG.reward_type()]
	PROG.ui.kept_line = string.format('Kept: %dc %dj %dv %dd', #st.cards, #st.jokers, #st.vouchers, #st.decks)
	PROG.ui.comeback = 'Comeback start: $' .. (st.bonus_dollars or 0)
end

----------------------------------------------------------------
-- Helpers
----------------------------------------------------------------

local function center_name(key, set)
	local center = G.P_CENTERS[key]
	if not center then return key end
	local ok, res = pcall(function()
		return localize({ type = 'name_text', set = set, key = key })
	end)
	if ok and type(res) == 'string' and res ~= 'ERROR' then return res end
	return center.name or key
end

-- Serialize any card or Joker with the game's own save format, but only keep it if it
-- round-trips through JSON cleanly. This captures everything a mod put on the card:
-- arbitrary ability fields, modded editions/seals/enhancements, stickers, Paperback
-- clips, and so on. Restored later with the game's own Card:load, which calls each
-- center's load hook, so modded state comes back intact.
function PROG.capture_full(card)
	local ok, saved = pcall(function() return card:save() end)
	if not ok or type(saved) ~= 'table' or not (saved.save_fields and saved.save_fields.center) then
		return nil
	end
	local enc_ok, enc = pcall(JSON.encode, saved)
	if not enc_ok then return nil end
	local dec_ok, dec = pcall(JSON.decode, enc)
	if not dec_ok or type(dec) ~= 'table' then return nil end
	-- Drop our own bookkeeping markers so stored/exported data stays clean.
	if type(dec.ability) == 'table' then
		dec.ability.prog_kept_card = nil
		dec.ability.prog_kept_joker = nil
	end
	return dec -- exactly what will round-trip, nothing that can break export later
end

-- Rebuild a card from a full save table using the game's own loader. Returns the Card,
-- or nil if the needed content (e.g. a mod) isn't installed on this machine.
function PROG.load_card_from_save(saved)
	local sf = saved and saved.save_fields
	if not (sf and sf.center and G.P_CENTERS[sf.center]) then return nil end
	if sf.card and not G.P_CARDS[sf.card] then return nil end
	loading = true
	local card = Card(0, 0, G.CARD_W, G.CARD_H, G.P_CENTERS.j_joker, G.P_CENTERS.c_base)
	loading = nil
	local ok = pcall(function() card:load(copy_table(saved)) end)
	if not ok then
		if card and card.remove then pcall(function() card:remove() end) end
		return nil
	end
	card.added_to_deck = nil -- so add_to_deck reapplies passive effects (slots, hand size)
	return card
end

function PROG.capture_playing_card(card)
	local entry = { rank = card.base.value, suit = card.base.suit }
	local center = card.config.center
	if center and center.key and center.key ~= 'c_base' then entry.enhancement = center.key end
	if card.edition and card.edition.key then entry.edition = card.edition.key end
	if card.seal then entry.seal = card.seal end
	-- Permanent per-card bonuses: Hiker chips (perma_bonus), permanent retriggers
	-- (perma_repetitions), and any modded perma_* field, so a juiced card comes back.
	local perma = {}
	if card.ability then
		for k, v in pairs(card.ability) do
			if type(k) == 'string' and type(v) == 'number' and v ~= 0
				and (string.match(k, '^perma') or string.match(k, 'retrigger')) then
				perma[k] = v
			end
		end
		-- Some enhancements accumulate chips/mult into the card's own bonus/mult
		-- (e.g. All-in-Jest Fervent grows ability.bonus by 10 per score). Capture the
		-- amount above the enhancement's default and fold it into perma_bonus/perma_mult,
		-- which add to score regardless of the enhancement it's restored with.
		local cfg = (center and center.config) or {}
		local bonus_delta = (card.ability.bonus or 0) - (cfg.bonus or 0)
		if bonus_delta ~= 0 then perma.perma_bonus = (perma.perma_bonus or 0) + bonus_delta end
		local mult_delta = (card.ability.mult or 0) - (cfg.mult or 0)
		if mult_delta ~= 0 then perma.perma_mult = (perma.perma_mult or 0) + mult_delta end
	end
	if next(perma) then entry.perma = perma end
	return entry
end

function PROG.capture_joker(card)
	local entry = { key = card.config.center.key }
	if card.edition and card.edition.key then entry.edition = card.edition.key end
	if type(card.sell_cost) == 'number' then entry.sell_cost = card.sell_cost end
	return entry
end

function PROG.describe_card_entry(c)
	local parts = { tostring(c.rank or '?') .. ' of ' .. tostring(c.suit or '?') }
	if c.enhancement and G.P_CENTERS[c.enhancement] then
		parts[#parts + 1] = center_name(c.enhancement, 'Enhanced')
	end
	if c.edition and G.P_CENTERS[c.edition] then
		parts[#parts + 1] = center_name(c.edition, 'Edition')
	end
	if c.seal then
		parts[#parts + 1] = tostring(c.seal) .. ' Seal'
	end
	if c.perma then
		if c.perma.perma_bonus then parts[#parts + 1] = '+' .. c.perma.perma_bonus .. ' chips' end
		if c.perma.perma_mult then parts[#parts + 1] = '+' .. c.perma.perma_mult .. ' mult' end
		if c.perma.perma_repetitions then parts[#parts + 1] = '+' .. c.perma.perma_repetitions .. ' retrigger' end
		local extras = 0
		for k in pairs(c.perma) do
			if k ~= 'perma_bonus' and k ~= 'perma_mult' and k ~= 'perma_repetitions' then extras = extras + 1 end
		end
		if extras > 0 then parts[#parts + 1] = '+bonuses' end
	end
	return table.concat(parts, ', ')
end

-- Spawn a kept playing card into the deck. Prefer a full-fidelity restore from the
-- saved card; fall back to rebuilding from friendly fields (for hand-written JSON, or
-- when the exact modded content isn't installed).
function PROG.spawn_kept_card(entry)
	local card = entry.save and PROG.load_card_from_save(entry.save)
	if card then
		G.playing_card = (G.playing_card and G.playing_card + 1) or 1
		card.playing_card = G.playing_card
		card:add_to_deck()
		G.deck:emplace(card)
		table.insert(G.playing_cards, card)
		return card
	end
	return PROG.spawn_kept_card_basic(entry)
end

-- Field-based reconstruction: enhancement, edition, seal, and captured permanent bonuses.
function PROG.spawn_kept_card_basic(entry)
	local proto = PROG.card_proto(entry)
	if not proto then return end
	G.playing_card = (G.playing_card and G.playing_card + 1) or 1
	local _card = Card(G.deck.T.x, G.deck.T.y, G.CARD_W, G.CARD_H,
		G.P_CARDS[proto.s .. '_' .. proto.r], G.P_CENTERS[proto.e or 'c_base'],
		{ playing_card = G.playing_card })
	if proto.d then _card:set_edition({ [proto.d] = true }, true, true) end
	if proto.g then _card:set_seal(proto.g, true, true) end
	if entry.perma and _card.ability then
		for k, v in pairs(entry.perma) do
			if type(v) == 'number' then
				_card.ability[k] = (_card.ability[k] or 0) + v
			else
				_card.ability[k] = v
			end
		end
	end
	_card:add_to_deck()
	G.deck:emplace(_card)
	table.insert(G.playing_cards, _card)
	return _card
end

-- Convert a stored card entry into a card_from_control proto ({s, r, e, d, g}).
-- Accepts full names ('King', 'Hearts') or card keys ('K', 'H'). Returns nil if invalid.
function PROG.card_proto(entry)
	local rank = SMODS.Ranks[entry.rank]
	local suit = SMODS.Suits[entry.suit]
	if not rank then
		for _, r in pairs(SMODS.Ranks) do
			if r.card_key == entry.rank then rank = r break end
		end
	end
	if not suit then
		for _, s in pairs(SMODS.Suits) do
			if s.card_key == entry.suit then suit = s break end
		end
	end
	if not (rank and suit) then return nil end
	if not G.P_CARDS[suit.card_key .. '_' .. rank.card_key] then return nil end
	local e = entry.enhancement
	if e and not G.P_CENTERS[e] then e = nil end
	local d = entry.edition
	if d and not G.P_CENTERS[d] then d = nil end
	if d then d = string.sub(d, 3) end -- 'e_foil' becomes 'foil' for card_from_control
	local g = entry.seal
	if g and SMODS.Seals and not SMODS.Seals[g] then g = nil end
	return { s = suit.card_key, r = rank.card_key, e = e, d = d, g = g }
end

-- Deep merge of deck configs, numeric values summed (same approach as the Cocktail deck)
function PROG.merge(t1, t2)
	local function merge(a, b, safe)
		local t3 = {}
		for k, v in pairs(a) do
			if type(v) == 'table' then t3[k] = merge(v, {}) else t3[k] = v end
		end
		for k, v in pairs(b) do
			local existing = t3[k]
			if type(existing) == 'number' and type(v) == 'number' then
				t3[k] = existing + v
			elseif type(existing) == 'table' and type(v) == 'table' then
				t3[k] = merge(existing, v, true)
			else
				if type(v) == 'table' then
					t3[k] = merge(v, {})
				else
					local index = safe and #t3 + 1 or k
					t3[index] = v
				end
			end
		end
		return t3
	end
	return merge(t1 or {}, t2 or {})
end

----------------------------------------------------------------
-- Import / export
----------------------------------------------------------------

function PROG.export_json()
	local st = PROG.state()
	return JSON.encode({
		run = st.run,
		cards = st.cards,
		jokers = st.jokers,
		vouchers = st.vouchers,
		decks = st.decks,
		bonus_dollars = st.bonus_dollars,
	})
end

function PROG.import_json(str)
	if type(str) ~= 'string' or str == '' then return false, 'Nothing to import. Clipboard is empty.' end
	local ok, data = pcall(JSON.decode, str)
	if not ok or type(data) ~= 'table' then return false, 'Import failed. That is not valid JSON.' end
	local st = default_state()
	if type(data.run) == 'number' and data.run >= 1 then st.run = math.floor(data.run) end
	if type(data.bonus_dollars) == 'number' then st.bonus_dollars = math.floor(data.bonus_dollars) end
	if type(data.cards) == 'table' then
		for _, c in ipairs(data.cards) do
			-- Accept a card that has a full save blob, or friendly rank+suit fields.
			if type(c) == 'table' and (type(c.save) == 'table' or (c.rank and c.suit)) then
				local perma = nil
				if type(c.perma) == 'table' then
					perma = {}
					for k, v in pairs(c.perma) do
						if type(k) == 'string' then perma[k] = v end
					end
					if not next(perma) then perma = nil end
				end
				local base = type(c.save) == 'table' and c.save.base or nil
				st.cards[#st.cards + 1] = {
					rank = (c.rank and tostring(c.rank)) or (base and base.value),
					suit = (c.suit and tostring(c.suit)) or (base and base.suit),
					enhancement = c.enhancement, edition = c.edition, seal = c.seal,
					perma = perma,
					save = type(c.save) == 'table' and c.save or nil,
				}
			end
		end
	end
	if type(data.jokers) == 'table' then
		for _, j in ipairs(data.jokers) do
			if type(j) == 'table' and (type(j.save) == 'table' or type(j.key) == 'string') then
				st.jokers[#st.jokers + 1] = {
					key = type(j.key) == 'string' and j.key or nil,
					edition = j.edition,
					sell_cost = type(j.sell_cost) == 'number' and j.sell_cost or nil,
					save = type(j.save) == 'table' and j.save or nil,
				}
			elseif type(j) == 'string' then
				st.jokers[#st.jokers + 1] = { key = j }
			end
		end
	end
	if type(data.vouchers) == 'table' then
		for _, v in ipairs(data.vouchers) do
			if type(v) == 'string' then st.vouchers[#st.vouchers + 1] = v end
		end
	end
	if type(data.decks) == 'table' then
		for _, d in ipairs(data.decks) do
			if type(d) == 'string' then st.decks[#st.decks + 1] = d end
		end
	end
	mod.config.state = st
	PROG.save()
	PROG.refresh_ui_strings()
	return true, string.format('Imported: run %d, %dc %dj %dv %dd.',
		st.run, #st.cards, #st.jokers, #st.vouchers, #st.decks)
end

----------------------------------------------------------------
-- The deck
----------------------------------------------------------------

SMODS.Atlas({ key = 'decks', path = 'prog_decks.png', px = 71, py = 95 })

local back_obj = SMODS.Back({
	key = 'progression',
	atlas = 'decks',
	pos = { x = 0, y = 0 },
	config = {},
	unlocked = true,
	discovered = true,
	loc_txt = {
		name = 'Progression Deck',
		text = {
			'{C:attention}Win Ante 8{} to keep a reward forever.',
			'Each run the blinds scale {C:red}one level faster{}.',
			'Reward cycle: card, Joker, Voucher, deck effect.',
		},
	},
	apply = function(self, back)
		back = back or G.GAME.selected_back
		local st = PROG.state()
		local run = st.run or 1
		G.GAME.prog_run = run
		G.GAME.prog_reward_claimed = false

		-- Blind scaling: level 1 to 3 are the vanilla White/Green/Purple stake tables,
		-- level 4 and up use the Steamodded extended scaling formula automatically.
		G.GAME.modifiers.scaling = math.max(G.GAME.modifiers.scaling or 1, run)

		-- Kept deck effects, merged Cocktail-style
		G.GAME.prog_decks = {}
		for _, dk in ipairs(st.decks) do
			local center = G.P_CENTERS[dk]
			if center then
				G.GAME.prog_decks[#G.GAME.prog_decks + 1] = dk
				back.effect.config = PROG.merge(back.effect.config, center.config)
				if back.effect.config.voucher then
					back.effect.config.vouchers = back.effect.config.vouchers or {}
					back.effect.config.vouchers[#back.effect.config.vouchers + 1] = back.effect.config.voucher
					back.effect.config.voucher = nil
				end
				if center.apply and type(center.apply) == 'function' then center:apply(back) end
				if dk == 'b_checkered' then
					G.E_MANAGER:add_event(Event({
						func = function()
							for _, v in pairs(G.playing_cards) do
								if v.base.suit == 'Clubs' then v:change_suit('Spades') end
								if v.base.suit == 'Diamonds' then v:change_suit('Hearts') end
							end
							return true
						end,
					}))
				end
			end
		end
		if back.effect.config.akyrs_starting_letters then
			G.GAME.starting_params.akyrs_starting_letters = back.effect.config.akyrs_starting_letters
		end
		if back.effect.config.akyrs_letters_no_uppercase then
			G.GAME.starting_params.akyrs_letters_no_uppercase = back.effect.config.akyrs_letters_no_uppercase
		end
		back.effect.prog_merged = true

		-- Kept playing cards. Spawned in a deferred event so G.deck exists and so we
		-- can restore permanent bonuses (the extra_cards proto path can't carry those).
		-- Tag each with its stored index so re-picking it at a reward updates it in place.
		if #st.cards > 0 then
			G.E_MANAGER:add_event(Event({
				func = function()
					if G.deck then
						for i, c in ipairs(st.cards) do
							local card = PROG.spawn_kept_card(c)
							if card and card.ability then card.ability.prog_kept_card = i end
						end
						G.GAME.starting_deck_size = #G.playing_cards
					end
					return true
				end,
			}))
		end

		-- Kept Jokers. Prefer a full-fidelity restore (stickers, modded editions, ability
		-- state); fall back to key + edition when there's no save blob or the mod is absent.
		if #st.jokers > 0 then
			G.E_MANAGER:add_event(Event({
				func = function()
					for k, j in ipairs(st.jokers) do
						local card = j.save and PROG.load_card_from_save(j.save)
						if card then
							card:add_to_deck()
							G.jokers:emplace(card)
							card:start_materialize(nil, k ~= 1)
						elseif j.key and G.P_CENTERS[j.key] then
							card = add_joker(j.key, nil, k ~= 1)
							if card and j.edition and G.P_CENTERS[j.edition] then
								card:set_edition(j.edition, true, true)
							end
							-- Pin sell value. sell_cost is always recomputed as floor(cost/2) +
							-- ability.extra_value, so we bump extra_value by the shortfall (that's
							-- the same field the game uses to make sell value stick) and recompute.
							if card and type(j.sell_cost) == 'number' and card.set_cost then
								card:set_cost() -- fold the edition's cost bump in before measuring
								local shortfall = j.sell_cost - (card.sell_cost or 0)
								if shortfall ~= 0 then
									card.ability.extra_value = (card.ability.extra_value or 0) + shortfall
									card:set_cost()
								end
							end
						end
						-- Tag so re-picking this Joker at a reward updates it in place.
						if card and card.ability then card.ability.prog_kept_joker = k end
					end
					return true
				end,
			}))
		end

		-- Kept Vouchers
		G.GAME.prog_start_vouchers = {}
		for _, v in ipairs(st.vouchers) do
			if G.P_CENTERS[v] and not G.GAME.used_vouchers[v] then
				G.GAME.used_vouchers[v] = true
				G.GAME.prog_start_vouchers[v] = true
				G.GAME.starting_voucher_count = (G.GAME.starting_voucher_count or 0) + 1
				G.E_MANAGER:add_event(Event({
					func = function()
						Card.apply_to_run(nil, G.P_CENTERS[v])
						return true
					end,
				}))
			end
		end

		-- Comeback bonus: extra starting dollars (e.g. $25 for the match loser). Set per
		-- machine via the deck panel or the JSON; applied every run until you turn it off.
		if (st.bonus_dollars or 0) ~= 0 then
			G.GAME.starting_params.dollars = (G.GAME.starting_params.dollars or 0) + st.bonus_dollars
		end
	end,
	calculate = function(self, back, context)
		-- Fan out trigger effects (Anaglyph tags, Plasma balancing) to kept deck effects
		if not (G.GAME and G.GAME.prog_decks) then return end
		for i = 1, #G.GAME.prog_decks do
			local center = G.P_CENTERS[G.GAME.prog_decks[i]]
			if center then
				back:change_to(center)
				local r1, r2 = back:trigger_effect(context)
				back:change_to(G.P_CENTERS[PROG.DECK_KEY])
				if r1 or r2 then return r1, r2 end
			end
		end
	end,
})

PROG.DECK_KEY = (back_obj and back_obj.key) or 'b_prog_progression'

function PROG.in_run()
	if not G.GAME then return false end
	-- Primary signal: apply() sets prog_run, and it persists in the save. Fall back
	-- to matching the selected back's key in case apply() didn't run for some reason.
	if G.GAME.prog_run then return true end
	return (G.GAME.selected_back and G.GAME.selected_back.effect
		and G.GAME.selected_back.effect.center
		and G.GAME.selected_back.effect.center.key == PROG.DECK_KEY) or false
end

-- Is a multiplayer match currently underway?
function PROG.in_mp()
	return (MP and MP.LOBBY and MP.LOBBY.code) and true or false
end

-- True when you still owe yourself a reward this run and haven't claimed it.
function PROG.reward_pending()
	if not PROG.in_run() or (G.GAME and G.GAME.prog_reward_claimed) then return false end
	return true
end

-- Preserve the merged config when calculate() swaps the back around (same trick as Cocktail)
local change_to_ref = Back.change_to
function Back:change_to(new_back)
	if self.effect and self.effect.prog_merged then
		local saved = copy_table(self.effect.config)
		local ret = change_to_ref(self, new_back)
		self.effect.config = saved
		self.effect.prog_merged = true
		return ret
	end
	return change_to_ref(self, new_back)
end

-- Reassert scaling after everything else has applied
local start_run_ref = Game.start_run
function Game:start_run(args)
	PROG.reset_armed = nil
	start_run_ref(self, args)
	if PROG.in_run() then
		G.GAME.modifiers.scaling = math.max(G.GAME.modifiers.scaling or 1, G.GAME.prog_run or PROG.state().run)
	end
end

----------------------------------------------------------------
-- Win: reward selection
----------------------------------------------------------------

-- Open the reward picker over an end-game screen. Uses the REAL timer so it fires even
-- though the win / game-over screen pauses the game.
function PROG.open_reward_on_end_screen()
	G.E_MANAGER:add_event(Event({
		trigger = 'after',
		delay = 0.8,
		timer = 'REAL',
		blocking = false,
		func = function()
			if PROG.reward_pending() then
				local ok, err = pcall(PROG.open_reward_menu)
				if not ok then
					sendWarnMessage('Progression reward menu failed to open: ' .. tostring(err), 'Progression')
				end
			end
			return true
		end,
	}))
end

-- Win screen (single-player Ante 8, or the multiplayer match winner).
local win_game_ref = win_game
function win_game()
	win_game_ref()
	if PROG.in_run() then
		G.GAME.prog_won = true
		if not G.GAME.prog_reward_claimed then PROG.open_reward_on_end_screen() end
	end
end

-- Game-over screen. In a multiplayer match the loser never triggers win_game, so this
-- is where the losing player gets to pick their carry-forward reward. (In single-player
-- a loss just means you retry the same run level, so no reward there.)
local cubgo_ref = create_UIBox_game_over
function create_UIBox_game_over()
	local ret = cubgo_ref()
	if PROG.in_mp() and PROG.reward_pending() then
		PROG.open_reward_on_end_screen()
	end
	return ret
end

-- How many of each type you may keep after winning `run`. Each win unlocks one more
-- slot, cycling card -> Joker -> Voucher -> deck effect. You re-select your whole
-- loadout every run, so kept items are always re-captured at their current state.
PROG.CATS = { 'card', 'joker', 'voucher', 'deck' }
PROG.CAT_PLURAL = { card = 'cards', joker = 'Jokers', voucher = 'Vouchers', deck = 'deck effects' }

function PROG.slot_counts(run)
	run = run or (G.GAME and G.GAME.prog_run) or PROG.state().run
	return {
		card = math.floor((run + 3) / 4),
		joker = math.floor((run + 2) / 4),
		voucher = math.floor((run + 1) / 4),
		deck = math.floor(run / 4),
	}
end

-- The selectable items in the current run for one category, with `preselect` set on the
-- items you're already keeping so they come pre-checked.
function PROG.category_options(cat)
	local opts = {}
	if cat == 'card' then
		for _, card in ipairs(G.playing_cards or {}) do
			if card.base and card.base.value and card.base.suit then
				local entry = PROG.capture_playing_card(card)
				opts[#opts + 1] = {
					label = PROG.describe_card_entry(entry), card = card, entry = entry,
					preselect = card.ability and card.ability.prog_kept_card and true or false,
				}
			end
		end
		table.sort(opts, function(a, b) return a.label < b.label end)
	elseif cat == 'joker' then
		for _, card in ipairs((G.jokers and G.jokers.cards) or {}) do
			if card.ability and card.ability.set == 'Joker' and card.config.center then
				local entry = PROG.capture_joker(card)
				local label = center_name(entry.key, 'Joker')
				if entry.edition and G.P_CENTERS[entry.edition] then
					label = label .. ' (' .. center_name(entry.edition, 'Edition') .. ')'
				end
				if card.sell_cost then label = label .. ' [sell $' .. tostring(card.sell_cost) .. ']' end
				opts[#opts + 1] = {
					label = label, card = card, entry = entry,
					preselect = card.ability.prog_kept_joker and true or false,
				}
			end
		end
	elseif cat == 'voucher' then
		local kept = G.GAME.prog_start_vouchers or {}
		for k, v in pairs(G.GAME.used_vouchers or {}) do
			if v and G.P_CENTERS[k] then
				opts[#opts + 1] = { label = center_name(k, 'Voucher'), key = k, preselect = kept[k] and true or false }
			end
		end
		table.sort(opts, function(a, b) return a.label < b.label end)
	elseif cat == 'deck' then
		local st = PROG.state()
		local keptset = {}
		for _, d in ipairs(st.decks) do keptset[d] = true end
		local excluded = {
			b_challenge = true, b_mp_cocktail = true, b_cry_antimatter = true,
			b_akyrs_hardcore_challenges = true, [PROG.DECK_KEY] = true,
		}
		for _, center in ipairs(G.P_CENTER_POOLS.Back or {}) do
			if center.unlocked and not center.omit and not excluded[center.key] then
				opts[#opts + 1] = { label = center_name(center.key, 'Back'), key = center.key, preselect = keptset[center.key] and true or false }
			end
		end
		table.sort(opts, function(a, b) return a.label < b.label end)
	end
	return opts
end

PROG.reward_page = 1

function PROG.begin_reward()
	PROG.counts = PROG.slot_counts()
	PROG.cat_queue = {}
	for _, c in ipairs(PROG.CATS) do
		if (PROG.counts[c] or 0) > 0 then PROG.cat_queue[#PROG.cat_queue + 1] = c end
	end
	PROG.cat_i = 1
	PROG.cat_opts = {}
	PROG.sel = { card = {}, joker = {}, voucher = {}, deck = {} }
	PROG.reward_page = 1
	PROG.show_reward_step()
end

-- Backwards-compatible entry point used by the end-screen hooks.
function PROG.open_reward_menu()
	PROG.begin_reward()
end

local function sel_count(set)
	local n = 0
	for _ in pairs(set) do n = n + 1 end
	return n
end

function PROG.show_reward_step()
	local cat = PROG.cat_queue and PROG.cat_queue[PROG.cat_i]
	if not cat then return PROG.finalize_reward() end
	if not PROG.cat_opts[cat] then
		PROG.cat_opts[cat] = PROG.category_options(cat)
		-- Pre-check the items you're already keeping, up to this category's limit.
		local lim, n = PROG.counts[cat], 0
		for i, o in ipairs(PROG.cat_opts[cat]) do
			if o.preselect and n < lim then PROG.sel[cat][i] = true; n = n + 1 end
		end
	end
	G.FUNCS.overlay_menu({ definition = PROG.reward_step_def(cat), config = { no_esc = true } })
end

function PROG.reward_step_def(cat)
	local opts = PROG.cat_opts[cat] or {}
	local lim = PROG.counts[cat] or 0
	local sel = PROG.sel[cat]
	local seln = sel_count(sel)
	local pages = math.max(1, math.ceil(#opts / PAGE_SIZE))
	if PROG.reward_page > pages then PROG.reward_page = pages end
	if PROG.reward_page < 1 then PROG.reward_page = 1 end
	local start_i = (PROG.reward_page - 1) * PAGE_SIZE

	local function T(text, scale, colour) return { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
		{ n = G.UIT.T, config = { text = text, scale = scale, colour = colour } },
	} } end

	local rows = {}
	rows[#rows + 1] = T('Run ' .. tostring(G.GAME.prog_run or PROG.state().run) .. ' complete', 0.55, G.C.GREEN)
	rows[#rows + 1] = T('Keep up to ' .. lim .. ' ' .. PROG.CAT_PLURAL[cat] .. '   (' .. seln .. '/' .. lim .. ' chosen)', 0.4, G.C.WHITE)
	if #opts == 0 then
		rows[#rows + 1] = T('None available this run.', 0.35, G.C.UI.TEXT_INACTIVE)
	end
	for i = start_i + 1, math.min(start_i + PAGE_SIZE, #opts) do
		local o = opts[i]
		local on = sel[i]
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.025 }, nodes = {
			UIBox_button({ id = 'prog_sel_' .. i, button = 'prog_toggle', label = { (on and 'KEEP  ' or '') .. o.label }, minw = 5.6, minh = 0.48, scale = 0.32, colour = on and G.C.GREEN or G.C.BLUE }),
		} }
	end
	if pages > 1 then
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
			UIBox_button({ button = 'prog_page_prev', label = { '<' }, minw = 0.7, minh = 0.5, scale = 0.35, colour = G.C.ORANGE, col = true }),
			{ n = G.UIT.C, config = { align = 'cm', minw = 1.6 }, nodes = {
				{ n = G.UIT.T, config = { text = ' ' .. PROG.reward_page .. ' / ' .. pages .. ' ', scale = 0.35, colour = G.C.WHITE } },
			} },
			UIBox_button({ button = 'prog_page_next', label = { '>' }, minw = 0.7, minh = 0.5, scale = 0.35, colour = G.C.ORANGE, col = true }),
		} }
	end
	local nav = {}
	if PROG.cat_i > 1 then
		nav[#nav + 1] = UIBox_button({ button = 'prog_step_back', label = { 'Back' }, minw = 1.6, minh = 0.5, scale = 0.32, colour = G.C.ORANGE, col = true })
	end
	local last = PROG.cat_i >= #PROG.cat_queue
	nav[#nav + 1] = UIBox_button({ button = 'prog_step_next', label = { last and 'Confirm loadout' or 'Next' }, minw = 2.2, minh = 0.5, scale = 0.32, colour = G.C.GREEN, col = true })
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = nav }
	return create_UIBox_generic_options({ no_back = true, contents = rows })
end

G.FUNCS.prog_toggle = function(e)
	local id = e and e.config and e.config.id
	local i = id and tonumber(string.match(tostring(id), '(%d+)$'))
	if not i then return end
	local cat = PROG.cat_queue[PROG.cat_i]
	local sel = PROG.sel[cat]
	if sel[i] then
		sel[i] = nil
	elseif sel_count(sel) < (PROG.counts[cat] or 0) then
		sel[i] = true
	else
		play_sound('cancel')
		return
	end
	G.FUNCS.overlay_menu({ definition = PROG.reward_step_def(cat), config = { no_esc = true } })
end

G.FUNCS.prog_step_next = function()
	PROG.cat_i = PROG.cat_i + 1
	PROG.reward_page = 1
	PROG.show_reward_step()
end

G.FUNCS.prog_step_back = function()
	PROG.cat_i = math.max(1, PROG.cat_i - 1)
	PROG.reward_page = 1
	PROG.show_reward_step()
end

G.FUNCS.prog_page_prev = function()
	PROG.reward_page = PROG.reward_page - 1
	G.FUNCS.overlay_menu({ definition = PROG.reward_step_def(PROG.cat_queue[PROG.cat_i]), config = { no_esc = true } })
end

G.FUNCS.prog_page_next = function()
	PROG.reward_page = PROG.reward_page + 1
	G.FUNCS.overlay_menu({ definition = PROG.reward_step_def(PROG.cat_queue[PROG.cat_i]), config = { no_esc = true } })
end

-- Write the full re-selected loadout to the saved state, capturing each card/Joker fresh.
function PROG.finalize_reward()
	local st = PROG.state()
	local new = { cards = {}, jokers = {}, vouchers = {}, decks = {} }
	for i in pairs(PROG.sel.card or {}) do
		local o = PROG.cat_opts.card and PROG.cat_opts.card[i]
		if o then o.entry.save = PROG.capture_full(o.card); new.cards[#new.cards + 1] = o.entry end
	end
	for i in pairs(PROG.sel.joker or {}) do
		local o = PROG.cat_opts.joker and PROG.cat_opts.joker[i]
		if o then o.entry.save = PROG.capture_full(o.card); new.jokers[#new.jokers + 1] = o.entry end
	end
	for i in pairs(PROG.sel.voucher or {}) do
		local o = PROG.cat_opts.voucher and PROG.cat_opts.voucher[i]
		if o then new.vouchers[#new.vouchers + 1] = o.key end
	end
	for i in pairs(PROG.sel.deck or {}) do
		local o = PROG.cat_opts.deck and PROG.cat_opts.deck[i]
		if o then new.decks[#new.decks + 1] = o.key end
	end
	st.cards, st.jokers, st.vouchers, st.decks = new.cards, new.jokers, new.vouchers, new.decks
	st.run = (G.GAME.prog_run or st.run) + 1
	G.GAME.prog_reward_claimed = true
	PROG.save()
	PROG.refresh_ui_strings()
	PROG.show_reward_summary()
end

function PROG.show_reward_summary()
	local st = PROG.state()
	local rows = {}
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
		{ n = G.UIT.T, config = { text = 'Loadout saved', scale = 0.5, colour = G.C.GREEN, shadow = true } },
	} }
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
		{ n = G.UIT.T, config = { text = string.format('Keeping %d cards, %d Jokers, %d Vouchers, %d deck effects.', #st.cards, #st.jokers, #st.vouchers, #st.decks), scale = 0.35, colour = G.C.WHITE } },
	} }
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
		{ n = G.UIT.T, config = { text = 'Next run is level ' .. st.run .. '. Blinds scale faster.', scale = 0.35, colour = G.C.WHITE } },
	} }
	if PROG.in_mp() then
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
			{ n = G.UIT.T, config = { text = 'Export your run, then set up the next match.', scale = 0.33, colour = G.C.WHITE } },
		} }
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
			UIBox_button({ button = 'prog_export_clipboard', label = { 'Export Progression' }, minw = 4, minh = 0.5, scale = 0.35, colour = G.C.GREEN }),
		} }
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
			UIBox_button({ button = 'go_to_menu', label = { 'Return to Lobby / Menu' }, minw = 4, minh = 0.5, scale = 0.35, colour = G.C.RED }),
		} }
	else
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
			UIBox_button({ button = 'prog_next_run', label = { 'Start Run ' .. st.run }, minw = 4, minh = 0.6, scale = 0.4, colour = G.C.GREEN }),
		} }
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
			UIBox_button({ button = 'prog_close', label = { 'Keep Playing (Endless)' }, minw = 4, minh = 0.5, scale = 0.35, colour = G.C.BLUE }),
		} }
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
			UIBox_button({ button = 'go_to_menu', label = { 'Main Menu' }, minw = 4, minh = 0.5, scale = 0.35, colour = G.C.RED }),
		} }
	end
	G.FUNCS.overlay_menu({ definition = create_UIBox_generic_options({ no_back = true, contents = rows }), config = { no_esc = true } })
end

G.FUNCS.prog_next_run = function()
	local stake = (G.GAME and G.GAME.stake) or 1
	G.FUNCS.exit_overlay_menu()
	G.FUNCS.start_run(nil, { stake = stake })
end

G.FUNCS.prog_close = function()
	G.FUNCS.exit_overlay_menu()
end

----------------------------------------------------------------
-- Deck-select controls (import, export, reset)
--
-- These are injected into the Progression deck's own info panel via generate_UI.
-- That panel is part of the deck-select overlay, so the buttons draw on top of the
-- overlay backdrop (a separate floating UIBox sits behind it and can't be clicked)
-- and the game rebuilds it whenever you cycle to this deck (RUN_SETUP_check_back),
-- so the controls appear only for this deck and update on their own.
----------------------------------------------------------------

function PROG.deck_controls_nodes()
	PROG.refresh_ui_strings()
	local function btn(button, label, colour)
		return UIBox_button({ button = button, label = { label }, colour = colour, minw = 1.15, minh = 0.4, scale = 0.28, col = true })
	end
	-- This sits inside the deck info box, which has a WHITE background, so text must be dark.
	return {
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'run_line', scale = 0.3, colour = G.C.UI.TEXT_DARK } },
			{ n = G.UIT.T, config = { text = '   ', scale = 0.3, colour = G.C.CLEAR } },
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'next_short', scale = 0.3, colour = G.C.UI.TEXT_DARK } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'kept_line', scale = 0.24, colour = G.C.UI.TEXT_DARK } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.04 }, nodes = {
			btn('prog_import_clipboard', 'Import', G.C.BLUE),
			btn('prog_export_clipboard', 'Export', G.C.GREEN),
			btn('prog_reset', 'Reset', G.C.RED),
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'comeback', scale = 0.26, colour = G.C.UI.TEXT_DARK } },
			{ n = G.UIT.T, config = { text = '  ', scale = 0.26, colour = G.C.CLEAR } },
			UIBox_button({ button = 'prog_cycle_comeback', label = { 'change' }, colour = G.C.ORANGE, minw = 1.2, minh = 0.4, scale = 0.26, col = true }),
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'note', scale = 0.24, colour = G.C.UI.TEXT_DARK } },
		} },
	}
end

-- The comeback bonus (extra starting dollars, e.g. for the match loser) cycles 0/25/50.
PROG.COMEBACK_STEPS = { 0, 25, 50 }

G.FUNCS.prog_cycle_comeback = function()
	local st = PROG.state()
	local cur = st.bonus_dollars or 0
	local idx = 1
	for i, v in ipairs(PROG.COMEBACK_STEPS) do if v == cur then idx = i end end
	st.bonus_dollars = PROG.COMEBACK_STEPS[(idx % #PROG.COMEBACK_STEPS) + 1]
	PROG.save()
	PROG.refresh_ui_strings()
	PROG.ui.note = 'Comeback start set to $' .. st.bonus_dollars .. '.'
	play_sound('button', 1, 0.4)
end

local generate_ui_ref = Back.generate_UI
function Back:generate_UI(other, ui_scale, min_dims, challenge)
	local ret = generate_ui_ref(self, other, ui_scale, min_dims, challenge)
	-- Only for the Progression deck as the actively viewed deck in run setup (not the
	-- collection viewer, which passes `other`).
	local center = self.effect and self.effect.center
	if not other and center and center.key == PROG.DECK_KEY
		and G.GAME and G.GAME.viewed_back == self and ret and ret.nodes then
		for _, node in ipairs(PROG.deck_controls_nodes()) do
			ret.nodes[#ret.nodes + 1] = node
		end
	end
	return ret
end

G.FUNCS.prog_import_clipboard = function()
	local ok, msg = PROG.import_json(love.system.getClipboardText())
	PROG.ui.note = msg
	play_sound(ok and 'coin1' or 'cancel')
end

G.FUNCS.prog_export_clipboard = function()
	local payload = PROG.export_json()
	love.system.setClipboardText(payload)
	pcall(love.filesystem.write, 'progression_export.json', payload)
	PROG.ui.note = 'Copied to clipboard + saved file.'
	play_sound('coin1')
end

G.FUNCS.prog_reset = function()
	if PROG.reset_armed then
		PROG.reset()
		PROG.reset_armed = nil
		PROG.refresh_ui_strings()
		PROG.ui.note = 'Reset to run 1.'
		play_sound('tarot1')
	else
		PROG.reset_armed = true
		PROG.ui.note = 'Click Reset again to confirm.'
	end
end

----------------------------------------------------------------
-- Multiplayer lobby panel
--
-- In a BalatroMultiplayer lobby the joiner can only open the deck-select overlay
-- (where the deck panel's Import lives) if the host enabled Different Decks, so
-- without it they have no way to paste their JSON. This puts the same controls on
-- the lobby screen itself, for host and joiner alike, whatever the lobby options.
-- The lobby screen is dark, so text is light here. Installed lazily from
-- Game:main_menu because load order vs the Multiplayer mod isn't guaranteed.
----------------------------------------------------------------

function PROG.lobby_panel_def()
	PROG.refresh_ui_strings()
	local function btn(button, label, colour, minw)
		return UIBox_button({ button = button, label = { label }, colour = colour, minw = minw or 1.4, minh = 0.45, scale = 0.28, col = true })
	end
	return { n = G.UIT.R, config = { align = 'cm', padding = 0.12, r = 0.1, emboss = 0.1, colour = G.C.L_BLACK }, nodes = {
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
			{ n = G.UIT.T, config = { text = 'Progression:  ', scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'run_line', scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
			{ n = G.UIT.T, config = { text = '   ', scale = 0.3, colour = G.C.CLEAR } },
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'kept_line', scale = 0.3, colour = G.C.UI.TEXT_LIGHT } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.04 }, nodes = {
			btn('prog_import_clipboard', 'Import', G.C.BLUE),
			btn('prog_export_clipboard', 'Export', G.C.GREEN),
			btn('prog_cycle_comeback', 'Comeback $', G.C.ORANGE, 1.7),
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'comeback', scale = 0.26, colour = G.C.UI.TEXT_LIGHT } },
			{ n = G.UIT.T, config = { text = '   ', scale = 0.26, colour = G.C.CLEAR } },
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'note', scale = 0.26, colour = G.C.UI.TEXT_LIGHT } },
		} },
	} }
end

local function install_mp_lobby_panel()
	if PROG.mp_lobby_hooked then return end
	if not (MP and G.UIDEF and G.UIDEF.create_UIBox_lobby_menu) then return end
	PROG.mp_lobby_hooked = true
	local lobby_menu_ref = G.UIDEF.create_UIBox_lobby_menu
	G.UIDEF.create_UIBox_lobby_menu = function(...)
		local t = lobby_menu_ref(...)
		-- Append below the lobby's button row; pcall so a Multiplayer layout change
		-- degrades to a panel-less lobby instead of a crash.
		pcall(function()
			local col = t and t.nodes and t.nodes[1]
			if col and col.nodes then col.nodes[#col.nodes + 1] = PROG.lobby_panel_def() end
		end)
		return t
	end
end

local main_menu_ref = Game.main_menu
function Game:main_menu(...)
	install_mp_lobby_panel()
	return main_menu_ref(self, ...)
end

----------------------------------------------------------------
-- JSON file drop
----------------------------------------------------------------

local fd_ref = love.filedropped
function love.filedropped(file)
	if fd_ref then pcall(fd_ref, file) end
	if G.STAGE ~= G.STAGES.MAIN_MENU then return end
	local name = (file.getFilename and file:getFilename()) or ''
	if not string.match(string.lower(name), '%.json$') then return end
	local opened = file:open('r')
	if not opened then return end
	local data = file:read()
	file:close()
	local ok, msg = PROG.import_json(data)
	PROG.ui.note = msg
	play_sound(ok and 'coin1' or 'cancel')
end

----------------------------------------------------------------
-- Options menu: export button during a progression run
----------------------------------------------------------------

local cubo_ref = create_UIBox_options
function create_UIBox_options()
	local ret = cubo_ref()
	if PROG.in_run() then
		local target = ret and ret.nodes and ret.nodes[1] and ret.nodes[1].nodes and ret.nodes[1].nodes[1]
			and ret.nodes[1].nodes[1].nodes and ret.nodes[1].nodes[1].nodes[1] and ret.nodes[1].nodes[1].nodes[1].nodes
		if target then
			-- The reward pick is intentionally NOT here: it's offered only on the end-game
			-- screens (win screen, and the game-over screen in a multiplayer match).
			table.insert(target, { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
				UIBox_button({ button = 'prog_export_clipboard', label = { 'Export Progression' }, minw = 5, colour = G.C.PURPLE }),
			} })
		end
	end
	return ret
end

----------------------------------------------------------------
-- Mods menu config tab
----------------------------------------------------------------

mod.config_tab = function()
	PROG.refresh_ui_strings()
	return { n = G.UIT.ROOT, config = { align = 'cm', padding = 0.1, colour = G.C.CLEAR, minw = 7 }, nodes = {
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'summary', scale = 0.35, colour = G.C.WHITE } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'next', scale = 0.35, colour = G.C.WHITE } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
			UIBox_button({ button = 'prog_import_clipboard', label = { 'Import from Clipboard' }, colour = G.C.BLUE, minw = 2.8, minh = 0.5, scale = 0.3, col = true }),
			UIBox_button({ button = 'prog_export_clipboard', label = { 'Export to Clipboard' }, colour = G.C.GREEN, minw = 2.8, minh = 0.5, scale = 0.3, col = true }),
			UIBox_button({ button = 'prog_reset', label = { 'Reset Progression' }, colour = G.C.RED, minw = 2.8, minh = 0.5, scale = 0.3, col = true }),
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'note', scale = 0.3, colour = G.C.GOLD } },
		} },
	} }
end

PROG.refresh_ui_strings()
