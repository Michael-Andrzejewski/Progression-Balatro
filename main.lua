--- Progression Mod
--- A roguelite deck for Balatro. Each win lets you keep things for all future runs,
--- but every run makes the blinds scale faster. Carry-over modes:
--- Classic (one new keep per win, cycling card / Joker / Voucher / deck effect,
--- one blind level per run), Full Loadout (one of each per win, four levels per run),
--- Versus (head-to-head series pacing), and Unlimited (keep as many cards, Jokers,
--- and Vouchers as you want but no deck effects, blind levels double each run:
--- 1, 5, 10, 20, 40, ...).

local mod = SMODS.current_mod

PROG = PROG or {}
PROG.mod = mod

local PAGE_SIZE = 8

----------------------------------------------------------------
-- State
----------------------------------------------------------------
-- Stored in the mod config (persists across runs and game restarts):
-- state = {
--   run      = 1,        -- current run number (1-based)
--   mode     = 'full',   -- carry-over mode key (see PROG.MODES)
--   cards    = { {rank='King', suit='Hearts', enhancement='m_glass', edition='e_foil', seal='Red'}, ... },
--   jokers   = { {key='j_blueprint', edition='e_negative'}, ... },
--   vouchers = { 'v_overstock_norm', ... },
--   decks    = { 'b_red', ... },
-- }

local function default_state()
	return { run = 1, mode = 'full', cards = {}, jokers = {}, vouchers = {}, decks = {}, bonus_dollars = 0, meta_lives = 4,
		extra_slots = { card = 0, joker = 0, voucher = 0 } }
end

-- Saves and JSON from before modes existed have no mode field; they were built
-- under the classic pacing, so any state with progress stays classic. Fresh
-- states get the new default, Full Loadout.
local function normalize_mode(st)
	if st.mode and PROG.MODES[st.mode] then return end
	if (st.run or 1) > 1 or #st.cards > 0 or #st.jokers > 0 or #st.vouchers > 0 or #st.decks > 0 then
		st.mode = 'classic'
	else
		st.mode = 'full'
	end
end

-- Seats: two game copies on one PC share the save folder, so one mod config
-- file would let each player's carry-overs overwrite the other's. A launcher
-- sets PROGRESSION_SEAT (letters, digits, - and _), and that copy keeps its
-- state in its own file, progression_state_<seat>.json, instead of the mod config.
local function read_seat()
	local ok, raw = pcall(os.getenv, 'PROGRESSION_SEAT')
	if not ok or type(raw) ~= 'string' then return nil end
	local seat = raw:gsub('[^%w_%-]', '')
	if seat == '' then return nil end
	return seat
end
PROG.SEAT = read_seat()

function PROG.seat_file()
	return PROG.SEAT and ('progression_state_' .. PROG.SEAT .. '.json') or nil
end

local function get_raw_state()
	if not PROG.SEAT then return mod.config.state end
	if PROG.seat_state == nil then
		PROG.seat_state = false
		local ok, contents = pcall(love.filesystem.read, PROG.seat_file())
		if ok and type(contents) == 'string' and contents ~= '' then
			local dok, data = pcall(JSON.decode, contents)
			if dok and type(data) == 'table' then PROG.seat_state = data end
		end
	end
	return PROG.seat_state or nil
end

local function set_raw_state(st)
	if PROG.SEAT then PROG.seat_state = st else mod.config.state = st end
end

function PROG.state()
	if not get_raw_state() then set_raw_state(default_state()) end
	local st = get_raw_state()
	st.run = st.run or 1
	st.cards = st.cards or {}
	st.jokers = st.jokers or {}
	st.vouchers = st.vouchers or {}
	st.decks = st.decks or {}
	st.bonus_dollars = st.bonus_dollars or 0
	st.meta_lives = st.meta_lives or 4
	st.extra_slots = type(st.extra_slots) == 'table' and st.extra_slots or {}
	for _, c in ipairs({ 'card', 'joker', 'voucher' }) do
		st.extra_slots[c] = tonumber(st.extra_slots[c]) or 0
	end
	normalize_mode(st)
	return st
end

function PROG.save()
	if PROG.SEAT then
		local ok, enc = pcall(JSON.encode, PROG.state())
		if ok then pcall(love.filesystem.write, PROG.seat_file(), enc) end
		return
	end
	SMODS.save_mod_config(mod)
end

-- Reset clears progress but keeps the chosen mode: it is a setting, not progress.
function PROG.reset()
	local old = get_raw_state()
	local mode = old and old.mode
	local st = default_state()
	if mode and PROG.MODES[mode] then st.mode = mode end
	set_raw_state(st)
	PROG.save()
end

PROG.REWARD_CYCLE = { 'card', 'joker', 'voucher', 'deck' }
PROG.REWARD_NAMES = { card = 'playing card', joker = 'Joker', voucher = 'Voucher', deck = 'deck effect' }

-- Slot count that means "no limit". Big enough that no real run can reach it,
-- small enough that arithmetic and %d formatting stay exact.
PROG.UNLIMITED = 1e9

----------------------------------------------------------------
-- Carry-over modes
--
-- Everything a ruleset decides comes down to three questions about a run
-- number, so each mode answers exactly those:
--   slots(run)  how many keep-slots of each type winning this run grants
--   level(run)  the blind-scaling level this run plays at (feeds
--               G.GAME.modifiers.scaling and the level-6+ blind-step skips)
--   gain(run)   what the next win promises, for UI text
-- A mode may also define deck_pool(run): the set of deck-effect keys offered
-- at that run's reward (nil = every deck).
-- The mode travels with the state (and its JSON), and each run snapshots it
-- into G.GAME.prog_mode / prog_level so switching never warps a run underway.
----------------------------------------------------------------

-- Versus deck-effect tiers, cumulative: round 1 offers tier 1, round 2 adds
-- tier 2, round 3 adds tier 3, round 4 on offers everything.
PROG.VERSUS_DECK_TIERS = {
	{ 'b_red', 'b_blue', 'b_green', 'b_yellow', 'b_magic' },
	{ 'b_ghost', 'b_black', 'b_painted', 'b_anaglyph', 'b_abandoned' },
	{ 'b_plasma', 'b_mp_heidelberg', 'b_mp_echodeck', 'b_aij_fabled' },
}

function PROG.versus_deck_pool(run)
	if run >= 4 then return nil end
	local pool = {}
	for tier = 1, math.min(run, #PROG.VERSUS_DECK_TIERS) do
		for _, k in ipairs(PROG.VERSUS_DECK_TIERS[tier]) do pool[k] = true end
	end
	return pool
end

PROG.MODES = {
	classic = {
		label = 'Classic',
		blurb = 'One new keep per win, cycling card, Joker, Voucher, deck effect. Blinds scale one level per run.',
		slots = function(run)
			return {
				card = math.floor((run + 3) / 4),
				joker = math.floor((run + 2) / 4),
				voucher = math.floor((run + 1) / 4),
				deck = math.floor(run / 4),
			}
		end,
		level = function(run) return run end,
		gain = function(run) return PROG.REWARD_NAMES[PROG.REWARD_CYCLE[(run - 1) % 4 + 1]] end,
	},
	full = {
		label = 'Full Loadout',
		blurb = 'Every win adds one card, one Joker, one Voucher, and one deck effect. Blinds scale four levels per run.',
		slots = function(run)
			return { card = run, joker = run, voucher = run, deck = run }
		end,
		level = function(run) return 4 * (run - 1) + 1 end,
		gain = function() return 'one of each' end,
	},
	versus = {
		label = 'Versus',
		blurb = 'Head-to-head series rules. Every win adds one keep of each type. Blind levels double: 1, 5, 10, 20, 40. Early deck rewards come from limited pools.',
		slots = function(run)
			return { card = run, joker = run, voucher = run, deck = run }
		end,
		level = function(run)
			if run <= 1 then return 1 end
			return 5 * 2 ^ (run - 2)
		end,
		gain = function() return 'one of each' end,
		deck_pool = function(run) return PROG.versus_deck_pool(run) end,
	},
	unlimited = {
		label = 'Unlimited',
		blurb = 'Keep as many cards, Jokers, and Vouchers as you want each win. No deck effects. Blind levels double: 1, 5, 10, 20, 40.',
		slots = function()
			return { card = PROG.UNLIMITED, joker = PROG.UNLIMITED, voucher = PROG.UNLIMITED, deck = 0 }
		end,
		level = function(run)
			if run <= 1 then return 1 end
			return 5 * 2 ^ (run - 2)
		end,
		gain = function() return 'as many cards, Jokers, and Vouchers as you want' end,
	},
	series = {
		label = 'Series',
		blurb = 'Head-to-head series on the Void Deck. Every match, both players keep one more card, Joker, and Voucher (no deck effects). The match loser also gets a permanent extra slot of the type the winner picks. Blind levels double: 1, 5, 10, 20, 40.',
		slots = function(run)
			return { card = run, joker = run, voucher = run, deck = 0 }
		end,
		level = function(run)
			if run <= 1 then return 1 end
			return 5 * 2 ^ (run - 2)
		end,
		gain = function() return 'one card, Joker, and Voucher' end,
		-- Runs on this deck instead of the Progression Deck.
		base_deck = 'b_sonfive_voiddeck',
		-- The loser's extra keep (winner picks its type), stacking permanently.
		loser_extra = true,
		-- No meta-lives or comeback money: the extra keep is the comeback.
		no_meta_lives = true,
	},
}
PROG.MODE_ORDER = { 'classic', 'full', 'versus', 'unlimited', 'series' }

-- The saved mode setting (what the next run will use).
function PROG.mode()
	return PROG.MODES[PROG.state().mode] or PROG.MODES.full
end

-- The mode a question about the current run should be answered with: the run's
-- own snapshot while one is underway, the saved setting otherwise.
function PROG.active_mode()
	if PROG.in_run() and G.GAME.prog_mode and PROG.MODES[G.GAME.prog_mode] then
		return PROG.MODES[G.GAME.prog_mode]
	end
	return PROG.mode()
end

function PROG.scaling_level(run)
	run = run or (G.GAME and G.GAME.prog_run) or PROG.state().run
	return PROG.active_mode().level(run)
end

-- Display name for a deck key, safe to call before localization is ready.
local function center_name_safe(key)
	local ok, res = pcall(function()
		local c = G.P_CENTERS and G.P_CENTERS[key]
		if not c then return key end
		local n = localize({ type = 'name_text', set = 'Back', key = key })
		if type(n) == 'string' and n ~= 'ERROR' then return n end
		return c.name or key
	end)
	return ok and res or key
end

-- Live UI strings (referenced by ref_table text nodes so they update in place)
PROG.ui = { summary = '', next = '', note = '', run_line = '', next_short = '', kept_line = '', comeback = '', mode_line = '', mode_blurb = '', lives = '' }

function PROG.refresh_ui_strings()
	local st = PROG.state()
	local mode = PROG.mode()
	local level = mode.level(st.run)
	PROG.ui.summary = string.format('Run %d, blinds level %d. Kept: %d cards, %d Jokers, %d Vouchers, %d deck effects.',
		st.run, level, #st.cards, #st.jokers, #st.vouchers, #st.decks)
	PROG.ui.next = 'Next reward on win: ' .. mode.gain(st.run)
	PROG.ui.mode_line = 'Mode: ' .. mode.label
	PROG.ui.mode_blurb = mode.blurb
	-- Compact variants for the narrow deck-select panel
	PROG.ui.run_line = (level == st.run) and ('Run ' .. st.run)
		or string.format('Run %d (level %d)', st.run, level)
	PROG.ui.next_short = 'Next win: ' .. mode.gain(st.run)
	PROG.ui.kept_line = string.format('Kept: %dc %dj %dv %dd', #st.cards, #st.jokers, #st.vouchers, #st.decks)
	local ex = st.extra_slots or {}
	if (ex.card or 0) + (ex.joker or 0) + (ex.voucher or 0) > 0 then
		PROG.ui.kept_line = PROG.ui.kept_line .. string.format('  Extra slots: +%dc +%dj +%dv', ex.card or 0, ex.joker or 0, ex.voucher or 0)
	end
	if PROG.SEAT then PROG.ui.kept_line = PROG.ui.kept_line .. '  [seat ' .. PROG.SEAT .. ']' end
	if mode.base_deck then
		PROG.ui.mode_line = PROG.ui.mode_line .. ' (on ' .. center_name_safe(mode.base_deck) .. ')'
	end
	PROG.ui.comeback = 'Comeback start: $' .. (st.bonus_dollars or 0)
	PROG.ui.lives = 'Meta-lives: ' .. (st.meta_lives or 4) .. '/4'
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
		mode = st.mode,
		cards = st.cards,
		jokers = st.jokers,
		vouchers = st.vouchers,
		decks = st.decks,
		bonus_dollars = st.bonus_dollars,
		meta_lives = st.meta_lives,
		extra_slots = st.extra_slots,
	})
end

function PROG.import_json(str)
	if type(str) ~= 'string' or str == '' then return false, 'Nothing to import. Clipboard is empty.' end
	local ok, data = pcall(JSON.decode, str)
	if not ok or type(data) ~= 'table' then return false, 'Import failed. That is not valid JSON.' end
	local st = default_state()
	if type(data.run) == 'number' and data.run >= 1 then st.run = math.floor(data.run) end
	st.mode = (type(data.mode) == 'string' and PROG.MODES[data.mode]) and data.mode or nil
	if type(data.bonus_dollars) == 'number' then st.bonus_dollars = math.floor(data.bonus_dollars) end
	if type(data.meta_lives) == 'number' then st.meta_lives = math.max(1, math.min(4, math.floor(data.meta_lives))) end
	if type(data.extra_slots) == 'table' then
		for _, c in ipairs({ 'card', 'joker', 'voucher' }) do
			local v = tonumber(data.extra_slots[c])
			if v then st.extra_slots[c] = math.max(0, math.floor(v)) end
		end
	end
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
	normalize_mode(st)
	set_raw_state(st)
	PROG.save()
	PROG.refresh_ui_strings()
	return true, string.format('Imported: run %d, %dc %dj %dv %dd, %s.',
		st.run, #st.cards, #st.jokers, #st.vouchers, #st.decks, PROG.MODES[st.mode].label)
end

----------------------------------------------------------------
-- The deck
----------------------------------------------------------------

-- Everything a Progression run sets up at run start: run/level snapshot, blind
-- scaling, kept deck effects, cards, Jokers, Vouchers, comeback money. Called by
-- the Progression Deck's apply, and (with hosted = true) after a mode's base
-- deck applies itself, so Series mode can run on the Void Deck.
function PROG.apply_to_back(back, hosted)
	local st = PROG.state()
	local run = st.run or 1
	G.GAME.prog_run = run
	G.GAME.prog_mode = st.mode
	G.GAME.prog_level = PROG.scaling_level(run)
	G.GAME.prog_reward_claimed = false

	-- Blind scaling: level 1 to 3 are the vanilla White/Green/Purple stake tables,
	-- level 4 and up use the Steamodded extended scaling formula automatically.
	-- The level comes from the mode: Classic plays run N at level N, Full Loadout
	-- at level 4(N-1)+1.
	G.GAME.modifiers.scaling = math.max(G.GAME.modifiers.scaling or 1, G.GAME.prog_level)

	-- Kept deck effects, merged Cocktail-style. Only on the Progression Deck itself:
	-- a hosted base deck (Series mode) keeps its own config and gets no deck effects.
	if not hosted then
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
	end

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
end

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
			'{C:attention}Win Ante 8{} to keep rewards forever.',
			'Full Loadout mode: one of {C:attention}each{} type per win,',
			'blinds scale {C:red}four levels{} per run.',
			'Classic mode: {C:attention}one{} new keep per win (cycling),',
			'blinds scale {C:red}one level{} per run.',
			'Versus mode: one of each per win, blind levels {C:red}double{} each run.',
			'Unlimited mode: keep {C:attention}as much as you want{} (no deck effects), blind levels {C:red}double{}.',
			'Level {C:attention}6{}+: each level adds a {C:red}skipped blind step{} to antes {C:attention}4+{}.',
		},
	},
	apply = function(self, back)
		PROG.apply_to_back(back or G.GAME.selected_back, false)
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

-- The deck a mode runs on instead of the Progression Deck (Series: the Void
-- Deck), or nil. Read from the saved mode, since this is asked at run start.
function PROG.base_deck_key()
	local key = PROG.mode().base_deck
	if key and key ~= PROG.DECK_KEY and G.P_CENTERS[key] then return key end
	return nil
end

-- When the selected deck is the mode's base deck, let it apply itself first,
-- then lay the Progression run on top. Guarded so it runs once per run even
-- if another mod calls apply_to_run again.
local apply_to_run_ref = Back.apply_to_run
function Back:apply_to_run(...)
	local ret = apply_to_run_ref(self, ...)
	local key = self.effect and self.effect.center and self.effect.center.key
	local base = PROG.base_deck_key()
	if base and key == base and G.GAME and not G.GAME.prog_hosted_applied then
		G.GAME.prog_hosted_applied = true
		PROG.apply_to_back(self, true)
	end
	return ret
end

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

-- From level 6 on, each level adds one skipped step to the blind curve. Skips
-- are placed at antes in the cycling order 4, 6, 8, 5, 7 (level 6 puts one at
-- ante 4, level 7 adds one at ante 6, level 8 at ante 8, then ante 5, ante 7,
-- then the cycle repeats and antes gain second skips). A skip at ante X pushes
-- every ante from X onward one extra step up the curve, so the offsets stack:
-- at level 8, ante 8 sits at effective ante 11. Levels 1 to 5 and antes 1 to 3
-- always stay vanilla.
local SKIP_ORDER = { 4, 6, 8, 5, 7 }

function PROG.effective_ante(ante)
	if type(ante) ~= 'number' or not PROG.in_run() then return ante end
	-- prog_level is snapshotted at run start; pre-mode run saves only carry
	-- prog_run, which equalled the level under the classic pacing.
	local level = G.GAME.prog_level or G.GAME.prog_run or PROG.scaling_level()
	local skips = level - 5
	if skips <= 0 or ante <= 3 then return ante end
	local bump = 0
	for i = 1, skips do
		if SKIP_ORDER[(i - 1) % #SKIP_ORDER + 1] <= ante then bump = bump + 1 end
	end
	return ante + bump
end

-- Installed on the first run start rather than at load, so it wraps the final
-- get_blind_amount after every other mod (Talisman replaces it outright) is done.
local function ensure_blind_curve_hook()
	if PROG.blind_curve_hooked then return end
	PROG.blind_curve_hooked = true
	local gba_ref = get_blind_amount
	function get_blind_amount(ante)
		return gba_ref(PROG.effective_ante(ante))
	end
end

-- Steamodded picks the first blinds before start_run builds the new Joker,
-- consumable and Voucher areas, and with object weights on (Pokermon turns them
-- on) that pick scans those areas. On every run after the first in a session the
-- slots still hold removed areas whose card lists are gone, and the scan crashes
-- ("bad argument #1 to 'ipairs'"): every Multiplayer match after the first died
-- on start. A removed area has nothing to score, so leave it out of the list.
if SMODS and SMODS.get_card_areas then
	local get_card_areas_ref = SMODS.get_card_areas
	function SMODS.get_card_areas(_type, ...)
		local t = get_card_areas_ref(_type, ...)
		if (_type == 'jokers' or _type == 'playing_cards') and type(t) == 'table' then
			local live = {}
			for i = 1, table.maxn(t) do
				local area = t[i]
				if area and (type(area) ~= 'table' or area.cards ~= nil) then live[#live + 1] = area end
			end
			return live
		end
		return t
	end
end

-- Reassert scaling after everything else has applied
local start_run_ref = Game.start_run
function Game:start_run(args)
	PROG.reset_armed = nil
	ensure_blind_curve_hook()
	start_run_ref(self, args)
	if PROG.in_run() then
		G.GAME.modifiers.scaling = math.max(G.GAME.modifiers.scaling or 1,
			G.GAME.prog_level or G.GAME.prog_run or PROG.scaling_level())
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

-- A multiplayer match loss costs one meta-life. Losing the fourth ends the
-- series: the loser's comeback money goes up $25 and their lives refill to 4
-- for the next series. The series winner refills their own lives (and the
-- previous loser retires their comeback money) with the panel controls, since
-- nothing is synced between the two clients.
function PROG.on_match_loss()
	if G.GAME.prog_meta_life_lost then return end
	G.GAME.prog_meta_life_lost = true
	G.GAME.prog_lost_match = true
	local st = PROG.state()
	-- Series mode has no meta-lives or comeback money; its comeback is the
	-- loser's extra keep, chosen at the start of the reward picker.
	if PROG.active_mode().no_meta_lives then return end
	st.meta_lives = math.max(0, (st.meta_lives or 4) - 1)
	if st.meta_lives == 0 then
		st.bonus_dollars = (st.bonus_dollars or 0) + 25
		st.meta_lives = 4
		G.GAME.prog_series_lost = true
	end
	PROG.save()
	PROG.refresh_ui_strings()
end

-- Game-over screen. In a multiplayer match the loser never triggers win_game, so this
-- is where the losing player gets to pick their carry-forward reward. (In single-player
-- a loss just means you retry the same run level, so no reward there.)
--
-- NOTE: inside a Multiplayer lobby this vanilla hook is dead code. Multiplayer
-- loads at priority 10000000, so its own create_UIBox_game_over wrapper sits
-- outside ours, and in a lobby it builds MP.UI.create_UIBox_mp_game_end(false)
-- without calling inward. The loser is caught by the MP end-screen hook below
-- instead; this stays for MP versions that do not override the end screens.
local cubgo_ref = create_UIBox_game_over
function create_UIBox_game_over()
	local ret = cubgo_ref()
	if PROG.in_mp() and PROG.in_run() then
		PROG.on_match_loss()
		if PROG.reward_pending() then
			PROG.open_reward_on_end_screen()
		end
	end
	return ret
end

-- The Multiplayer end screen (the Your Nemesis one). Built with won = false for
-- the match loser: that is the loser's only end screen in a lobby, so the
-- meta-life loss and the reward picker hang off it. Winners are already handled
-- by the win_game hook, which MP does call inward. Installed lazily from
-- Game:main_menu because MP loads after us.
local function install_mp_end_screen_hook()
	if PROG.mp_end_hooked then return end
	if not (MP and MP.UI and MP.UI.create_UIBox_mp_game_end) then return end
	PROG.mp_end_hooked = true
	local end_ref = MP.UI.create_UIBox_mp_game_end
	MP.UI.create_UIBox_mp_game_end = function(won, ...)
		local ret = end_ref(won, ...)
		if not won and PROG.in_mp() and PROG.in_run() then
			PROG.on_match_loss()
			if PROG.reward_pending() then
				PROG.open_reward_on_end_screen()
			end
		end
		return ret
	end
end
PROG.install_mp_end_screen_hook = install_mp_end_screen_hook

-- How many of each type you may keep after winning `run`, per the active mode.
-- You re-select your whole loadout every run, so kept items are always
-- re-captured at their current state.
PROG.CATS = { 'card', 'joker', 'voucher', 'deck' }
PROG.CAT_PLURAL = { card = 'cards', joker = 'Jokers', voucher = 'Vouchers', deck = 'deck effects' }

function PROG.slot_counts(run)
	run = run or (G.GAME and G.GAME.prog_run) or PROG.state().run
	local mode = PROG.active_mode()
	local counts = copy_table(mode.slots(run))
	-- Loser extras stack permanently on top of the mode's slots.
	if mode.loser_extra then
		local ex = PROG.state().extra_slots or {}
		for _, c in ipairs({ 'card', 'joker', 'voucher' }) do
			counts[c] = (counts[c] or 0) + (ex[c] or 0)
		end
	end
	return counts
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
		-- Cards with something on them (enhancement, edition, seal, bonuses) first,
		-- then by rank high to low, then suit, so the ones worth keeping are on page 1.
		local function special(o)
			local e = o.entry
			return (e.enhancement or e.edition or e.seal or e.perma) and 1 or 0
		end
		local function rank_id(o) return (o.card.base and o.card.base.id) or 0 end
		table.sort(opts, function(a, b)
			local sa, sb = special(a), special(b)
			if sa ~= sb then return sa > sb end
			local ra, rb = rank_id(a), rank_id(b)
			if ra ~= rb then return ra > rb end
			return a.label < b.label
		end)
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
		-- Versus limits the early deck rewards to fixed pools; pool is nil once
		-- every deck is unlocked (round 4 on) or in the other modes.
		local mode = PROG.active_mode()
		local pool = mode.deck_pool and mode.deck_pool((G.GAME and G.GAME.prog_run) or PROG.state().run) or nil
		for _, center in ipairs(G.P_CENTER_POOLS.Back or {}) do
			if center.unlocked and not center.omit and not excluded[center.key]
				and (not pool or pool[center.key]) then
				opts[#opts + 1] = { label = center_name(center.key, 'Back'), key = center.key, preselect = keptset[center.key] and true or false }
			end
		end
		table.sort(opts, function(a, b) return a.label < b.label end)
	end
	return opts
end

PROG.reward_page = 1

function PROG.begin_reward()
	-- Series loser: first record the extra slot the winner picked for them.
	if PROG.active_mode().loser_extra and G.GAME.prog_lost_match and not G.GAME.prog_extra_type then
		return PROG.show_extra_choice()
	end
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

-- Series mode: the match loser keeps one extra item. The winner decides its
-- type (tell each other out loud or in chat); the loser clicks it here. The slot
-- is permanent and stacks with later losses.
function PROG.show_extra_choice()
	local function T(text, scale, colour) return { n = G.UIT.R, config = { align = 'cm', padding = 0.04 }, nodes = {
		{ n = G.UIT.T, config = { text = text, scale = scale, colour = colour } },
	} } end
	local rows = {
		T('Match lost: you get one extra keep', 0.5, G.C.RED),
		T('Your opponent (the winner) chooses its type.', 0.35, G.C.WHITE),
		T('Click the type they picked. This slot is permanent.', 0.35, G.C.WHITE),
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.1 }, nodes = {
			UIBox_button({ button = 'prog_extra_joker', label = { 'Joker' }, minw = 2, minh = 0.6, scale = 0.4, colour = G.C.RED, col = true }),
			UIBox_button({ button = 'prog_extra_voucher', label = { 'Voucher' }, minw = 2, minh = 0.6, scale = 0.4, colour = G.C.SECONDARY_SET.Voucher, col = true }),
			UIBox_button({ button = 'prog_extra_card', label = { 'Card' }, minw = 2, minh = 0.6, scale = 0.4, colour = G.C.BLUE, col = true }),
		} },
	}
	G.FUNCS.overlay_menu({ definition = create_UIBox_generic_options({ no_back = true, contents = rows }), config = { no_esc = true } })
end

function PROG.choose_extra(cat)
	if G.GAME.prog_extra_type then return PROG.begin_reward() end
	local st = PROG.state()
	st.extra_slots[cat] = (st.extra_slots[cat] or 0) + 1
	G.GAME.prog_extra_type = cat
	PROG.save()
	PROG.refresh_ui_strings()
	play_sound('coin1')
	PROG.begin_reward()
end
G.FUNCS.prog_extra_joker = function() PROG.choose_extra('joker') end
G.FUNCS.prog_extra_voucher = function() PROG.choose_extra('voucher') end
G.FUNCS.prog_extra_card = function() PROG.choose_extra('card') end

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
	if lim >= PROG.UNLIMITED then
		rows[#rows + 1] = T('Keep as many ' .. PROG.CAT_PLURAL[cat] .. ' as you want   (' .. seln .. ' chosen)', 0.4, G.C.WHITE)
	else
		rows[#rows + 1] = T('Keep up to ' .. lim .. ' ' .. PROG.CAT_PLURAL[cat] .. '   (' .. seln .. '/' .. lim .. ' chosen)', 0.4, G.C.WHITE)
	end
	if #opts == 0 then
		rows[#rows + 1] = T('None available this run.', 0.35, G.C.UI.TEXT_INACTIVE)
	end
	if #opts > 1 then
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			UIBox_button({ button = 'prog_select_all', label = { 'Keep all' }, minw = 1.7, minh = 0.4, scale = 0.28, colour = G.C.GREEN, col = true }),
			UIBox_button({ button = 'prog_select_none', label = { 'Keep none' }, minw = 1.7, minh = 0.4, scale = 0.28, colour = G.C.RED, col = true }),
		} }
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

-- Select every option in the current category, up to the mode's limit.
G.FUNCS.prog_select_all = function()
	local cat = PROG.cat_queue[PROG.cat_i]
	if not cat then return end
	local sel = PROG.sel[cat]
	local lim = PROG.counts[cat] or 0
	local n = sel_count(sel)
	for i = 1, #(PROG.cat_opts[cat] or {}) do
		if n >= lim then break end
		if not sel[i] then
			sel[i] = true
			n = n + 1
		end
	end
	G.FUNCS.overlay_menu({ definition = PROG.reward_step_def(cat), config = { no_esc = true } })
end

G.FUNCS.prog_select_none = function()
	local cat = PROG.cat_queue[PROG.cat_i]
	if not cat then return end
	PROG.sel[cat] = {}
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
		{ n = G.UIT.T, config = { text = (PROG.mode().slots(st.run).deck or 0) > 0
			and string.format('Keeping %d cards, %d Jokers, %d Vouchers, %d deck effects.', #st.cards, #st.jokers, #st.vouchers, #st.decks)
			or string.format('Keeping %d cards, %d Jokers, %d Vouchers.', #st.cards, #st.jokers, #st.vouchers), scale = 0.35, colour = G.C.WHITE } },
	} }
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
		{ n = G.UIT.T, config = { text = string.format('Run %d is next. Blinds scale at level %d.', st.run, PROG.mode().level(st.run)), scale = 0.35, colour = G.C.WHITE } },
	} }
	if PROG.in_mp() then
		if PROG.active_mode().loser_extra then
			local ex = st.extra_slots or {}
			local line = G.GAME.prog_lost_match
				and string.format('Extra keep recorded: %s. Your extra slots: +%d cards, +%d Jokers, +%d Vouchers.', PROG.REWARD_NAMES[G.GAME.prog_extra_type] or '?', ex.card or 0, ex.joker or 0, ex.voucher or 0)
				or 'You won. Tell your opponent which type their extra keep is: Joker, Voucher, or card.'
			rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
				{ n = G.UIT.T, config = { text = line, scale = 0.33, colour = G.C.GOLD } },
			} }
		elseif G.GAME.prog_series_lost then
			rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
				{ n = G.UIT.T, config = { text = string.format('Series lost. Comeback money is now $%d and meta-lives refill to 4.', st.bonus_dollars or 0), scale = 0.33, colour = G.C.RED } },
			} }
		else
			rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
				{ n = G.UIT.T, config = { text = string.format('Meta-lives: %d/4', st.meta_lives or 4), scale = 0.33, colour = G.C.WHITE } },
			} }
		end
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
			{ n = G.UIT.T, config = { text = 'Export your run, then set up the next match.', scale = 0.33, colour = G.C.WHITE } },
		} }
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
			UIBox_button({ button = 'prog_export_clipboard', label = { 'Export Progression' }, minw = 4, minh = 0.5, scale = 0.35, colour = G.C.GREEN }),
		} }
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
			UIBox_button({ button = 'prog_return_lobby', label = { 'Return to Lobby / Menu' }, minw = 4, minh = 0.5, scale = 0.35, colour = G.C.RED }),
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

-- Use the Multiplayer mod's own return-to-lobby flow when we replaced its end
-- screen, so the lobby state stays intact; plain menu otherwise.
G.FUNCS.prog_return_lobby = function(e)
	-- The other player already sent the lobby back while we were picking.
	if PROG.deferred_menu then
		PROG.deferred_menu = nil
		return G.FUNCS.go_to_menu(e)
	end
	-- The match is over, so skip Multiplayer's "Are you sure?" (its Back button
	-- would strand you on an empty end screen once this summary is closed).
	if PROG.in_mp() and MP.ACTIONS and MP.ACTIONS.stop_game then
		G.FUNCS.exit_overlay_menu()
		return MP.ACTIONS.stop_game()
	end
	if PROG.in_mp() and G.FUNCS.mp_return_to_lobby then
		return G.FUNCS.mp_return_to_lobby(e)
	end
	return G.FUNCS.go_to_menu(e)
end

-- When one player returns to the lobby, Multiplayer pulls the other one back too
-- (its stopGame handler calls go_to_menu). If that player is still choosing their
-- loadout, the picker would vanish and the picks would be lost. So while a match
-- reward is pending, hold the menu change; the summary's Return button finishes it.
local go_to_menu_ref = G.FUNCS.go_to_menu
G.FUNCS.go_to_menu = function(...)
	if PROG.in_mp() and PROG.reward_pending() and G.GAME and (G.GAME.prog_won or G.GAME.prog_lost_match) then
		PROG.deferred_menu = true
		PROG.ui.note = 'Your opponent returned to the lobby. Finish your loadout first.'
		return
	end
	return go_to_menu_ref(...)
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
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'mode_line', scale = 0.26, colour = G.C.UI.TEXT_DARK } },
			{ n = G.UIT.T, config = { text = '  ', scale = 0.26, colour = G.C.CLEAR } },
			UIBox_button({ button = 'prog_cycle_mode', label = { 'change' }, colour = G.C.PURPLE, minw = 1.2, minh = 0.4, scale = 0.26, col = true }),
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'comeback', scale = 0.26, colour = G.C.UI.TEXT_DARK } },
			{ n = G.UIT.T, config = { text = '  ', scale = 0.26, colour = G.C.CLEAR } },
			UIBox_button({ button = 'prog_cycle_comeback', label = { 'change' }, colour = G.C.ORANGE, minw = 1.2, minh = 0.4, scale = 0.26, col = true }),
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'lives', scale = 0.26, colour = G.C.UI.TEXT_DARK } },
			{ n = G.UIT.T, config = { text = '  ', scale = 0.26, colour = G.C.CLEAR } },
			UIBox_button({ button = 'prog_cycle_lives', label = { 'change' }, colour = G.C.RED, minw = 1.2, minh = 0.4, scale = 0.26, col = true }),
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'note', scale = 0.24, colour = G.C.UI.TEXT_DARK } },
		} },
	}
end

-- Cycle the carry-over mode. Takes effect from the next run; one already
-- underway keeps the mode it started with (snapshotted in apply).
G.FUNCS.prog_cycle_mode = function()
	local st = PROG.state()
	local idx = 1
	for i, k in ipairs(PROG.MODE_ORDER) do if k == st.mode then idx = i end end
	st.mode = PROG.MODE_ORDER[(idx % #PROG.MODE_ORDER) + 1]
	PROG.save()
	PROG.refresh_ui_strings()
	PROG.ui.note = 'Mode set to ' .. PROG.mode().label .. '.'
	play_sound('button', 1, 0.4)
end

-- Manual meta-lives control (for the series winner refilling, or fixing a
-- missed count). Clicking counts down and wraps: 4, 3, 2, 1, back to 4.
G.FUNCS.prog_cycle_lives = function()
	local st = PROG.state()
	local lives = (st.meta_lives or 4) - 1
	if lives < 1 then lives = 4 end
	st.meta_lives = lives
	PROG.save()
	PROG.refresh_ui_strings()
	PROG.ui.note = 'Meta-lives set to ' .. lives .. '.'
	play_sound('button', 1, 0.4)
end

-- The comeback bonus (extra starting dollars, e.g. for the match loser) cycles
-- in $25 steps; series losses can stack it past the top, so the wrap goes back to $0.
PROG.COMEBACK_STEPS = { 0, 25, 50, 75, 100 }

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
			btn('prog_cycle_mode', 'Mode', G.C.PURPLE, 1.1),
			btn('prog_cycle_comeback', 'Comeback $', G.C.ORANGE, 1.7),
			btn('prog_cycle_lives', 'Lives', G.C.RED, 1.0),
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'mode_line', scale = 0.26, colour = G.C.UI.TEXT_LIGHT } },
			{ n = G.UIT.T, config = { text = '   ', scale = 0.26, colour = G.C.CLEAR } },
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'lives', scale = 0.26, colour = G.C.UI.TEXT_LIGHT } },
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
	PROG.install_mp_end_screen_hook()
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
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'mode_line', scale = 0.35, colour = G.C.WHITE } },
			{ n = G.UIT.T, config = { text = '  ', scale = 0.35, colour = G.C.CLEAR } },
			UIBox_button({ button = 'prog_cycle_mode', label = { 'Switch Mode' }, colour = G.C.PURPLE, minw = 2.2, minh = 0.45, scale = 0.28, col = true }),
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'mode_blurb', scale = 0.26, colour = G.C.UI.TEXT_INACTIVE } },
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
