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
	return { run = 1, cards = {}, jokers = {}, vouchers = {}, decks = {} }
end

function PROG.state()
	mod.config.state = mod.config.state or default_state()
	local st = mod.config.state
	st.run = st.run or 1
	st.cards = st.cards or {}
	st.jokers = st.jokers or {}
	st.vouchers = st.vouchers or {}
	st.decks = st.decks or {}
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
PROG.ui = { summary = '', next = '', note = '' }

function PROG.refresh_ui_strings()
	local st = PROG.state()
	PROG.ui.summary = string.format('Run %d. Kept: %d cards, %d Jokers, %d Vouchers, %d deck effects.',
		st.run, #st.cards, #st.jokers, #st.vouchers, #st.decks)
	PROG.ui.next = 'Next reward on win: ' .. PROG.REWARD_NAMES[PROG.reward_type()]
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

-- Spawn a kept playing card straight into the deck, restoring enhancement,
-- edition, seal, and any captured permanent bonuses. Modeled on card_from_control.
function PROG.spawn_kept_card(entry)
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
	})
end

function PROG.import_json(str)
	if type(str) ~= 'string' or str == '' then return false, 'Nothing to import. Clipboard is empty.' end
	local ok, data = pcall(JSON.decode, str)
	if not ok or type(data) ~= 'table' then return false, 'Import failed. That is not valid JSON.' end
	local st = default_state()
	if type(data.run) == 'number' and data.run >= 1 then st.run = math.floor(data.run) end
	if type(data.cards) == 'table' then
		for _, c in ipairs(data.cards) do
			if type(c) == 'table' and c.rank and c.suit then
				local perma = nil
				if type(c.perma) == 'table' then
					perma = {}
					for k, v in pairs(c.perma) do
						if type(k) == 'string' then perma[k] = v end
					end
					if not next(perma) then perma = nil end
				end
				st.cards[#st.cards + 1] = {
					rank = tostring(c.rank), suit = tostring(c.suit),
					enhancement = c.enhancement, edition = c.edition, seal = c.seal,
					perma = perma,
				}
			end
		end
	end
	if type(data.jokers) == 'table' then
		for _, j in ipairs(data.jokers) do
			if type(j) == 'table' and type(j.key) == 'string' then
				st.jokers[#st.jokers + 1] = { key = j.key, edition = j.edition }
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
	return true, string.format('Imported run %d with %d cards, %d Jokers, %d Vouchers, %d deck effects.',
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
			'{C:attention}Run #1#{}: blinds scale at {C:red}level #1#{}',
			'Carrying over {C:attention}#2#{} cards, {C:attention}#3#{} Jokers,',
			'{C:attention}#4#{} Vouchers, {C:attention}#5#{} deck effects',
			'Win Ante 8 to keep a {C:green}#6#{}',
		},
	},
	loc_vars = function(self)
		local st = PROG.state()
		return { vars = { st.run, #st.cards, #st.jokers, #st.vouchers, #st.decks, PROG.REWARD_NAMES[PROG.reward_type()] } }
	end,
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
		if #st.cards > 0 then
			G.E_MANAGER:add_event(Event({
				func = function()
					if G.deck then
						for _, c in ipairs(st.cards) do PROG.spawn_kept_card(c) end
						G.GAME.starting_deck_size = #G.playing_cards
					end
					return true
				end,
			}))
		end

		-- Kept Jokers
		if #st.jokers > 0 then
			G.E_MANAGER:add_event(Event({
				func = function()
					for k, j in ipairs(st.jokers) do
						if G.P_CENTERS[j.key] then
							local card = add_joker(j.key, nil, k ~= 1)
							if card and j.edition and G.P_CENTERS[j.edition] then
								card:set_edition(j.edition, true, true)
							end
						end
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

-- True once you've beaten Ante 8 this run and still owe yourself a reward.
function PROG.reward_pending()
	if not PROG.in_run() or G.GAME.prog_reward_claimed then return false end
	if G.GAME.prog_won then return true end
	local ante = (G.GAME.round_resets and G.GAME.round_resets.ante) or G.GAME.ante or 1
	return ante > 8
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

-- Reassert scaling after everything else has applied, and clean up the menu panel
local start_run_ref = Game.start_run
function Game:start_run(args)
	PROG.remove_deck_panel()
	start_run_ref(self, args)
	if PROG.in_run() then
		G.GAME.modifiers.scaling = math.max(G.GAME.modifiers.scaling or 1, G.GAME.prog_run or PROG.state().run)
	end
end

----------------------------------------------------------------
-- Win: reward selection
----------------------------------------------------------------

local win_game_ref = win_game
function win_game()
	win_game_ref()
	if PROG.in_run() then
		G.GAME.prog_won = true
		if not G.GAME.prog_reward_claimed then
			-- Best-effort auto-open. If it fails for any reason, the reward is still
			-- reachable from the pause/Options menu via reward_pending().
			G.E_MANAGER:add_event(Event({
				trigger = 'after',
				delay = 0.8,
				func = function()
					local ok, err = pcall(PROG.open_reward_menu)
					if not ok then
						sendWarnMessage('Progression reward menu failed to open: ' .. tostring(err), 'Progression')
					end
					return true
				end,
			}))
		end
	end
end

function PROG.reward_options()
	local rtype = PROG.reward_type(G.GAME.prog_run)
	local opts = {}
	if rtype == 'card' then
		for _, card in ipairs(G.playing_cards or {}) do
			if card.base and card.base.value and card.base.suit then
				local entry = PROG.capture_playing_card(card)
				opts[#opts + 1] = { label = PROG.describe_card_entry(entry), entry = entry }
			end
		end
		table.sort(opts, function(a, b) return a.label < b.label end)
	elseif rtype == 'joker' then
		for _, card in ipairs((G.jokers and G.jokers.cards) or {}) do
			if card.ability and card.ability.set == 'Joker' and card.config.center then
				local entry = PROG.capture_joker(card)
				local label = center_name(entry.key, 'Joker')
				if entry.edition and G.P_CENTERS[entry.edition] then
					label = label .. ' (' .. center_name(entry.edition, 'Edition') .. ')'
				end
				opts[#opts + 1] = { label = label, entry = entry }
			end
		end
	elseif rtype == 'voucher' then
		local skip = G.GAME.prog_start_vouchers or {}
		for k, v in pairs(G.GAME.used_vouchers or {}) do
			if v and not skip[k] and G.P_CENTERS[k] then
				opts[#opts + 1] = { label = center_name(k, 'Voucher'), entry = k }
			end
		end
		table.sort(opts, function(a, b) return a.label < b.label end)
	elseif rtype == 'deck' then
		local st = PROG.state()
		-- b_cry_antimatter and b_akyrs_hardcore_challenges misbehave outside their own
		-- context (the Cocktail deck blacklists them for the same reason)
		local excluded = {
			b_challenge = true,
			b_mp_cocktail = true,
			b_cry_antimatter = true,
			b_akyrs_hardcore_challenges = true,
			[PROG.DECK_KEY] = true,
		}
		for _, d in ipairs(st.decks) do excluded[d] = true end
		for _, center in ipairs(G.P_CENTER_POOLS.Back or {}) do
			if center.unlocked and not center.omit and not excluded[center.key] then
				opts[#opts + 1] = { label = center_name(center.key, 'Back'), entry = center.key }
			end
		end
	end
	return opts, rtype
end

PROG.reward_page = 1

function PROG.reward_menu_def()
	local opts, rtype = PROG.reward_options()
	PROG.current_opts = opts
	PROG.current_reward_type = rtype
	local pages = math.max(1, math.ceil(#opts / PAGE_SIZE))
	if PROG.reward_page > pages then PROG.reward_page = pages end
	if PROG.reward_page < 1 then PROG.reward_page = 1 end
	local start_i = (PROG.reward_page - 1) * PAGE_SIZE

	local rows = {}
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
		{ n = G.UIT.T, config = { text = 'Run ' .. tostring(G.GAME.prog_run or PROG.state().run) .. ' complete!', scale = 0.6, colour = G.C.GREEN, shadow = true } },
	} }
	local prompt
	if #opts > 0 then
		prompt = 'Choose a ' .. PROG.REWARD_NAMES[rtype] .. ' to keep for all future runs:'
	else
		prompt = 'No ' .. PROG.REWARD_NAMES[rtype] .. ' available to keep this time.'
	end
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
		{ n = G.UIT.T, config = { text = prompt, scale = 0.4, colour = G.C.WHITE } },
	} }
	for i = start_i + 1, math.min(start_i + PAGE_SIZE, #opts) do
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.03 }, nodes = {
			UIBox_button({ id = 'prog_opt_' .. i, button = 'prog_pick', label = { opts[i].label }, minw = 5.5, minh = 0.5, scale = 0.35, colour = G.C.BLUE }),
		} }
	end
	if pages > 1 then
		rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
			UIBox_button({ id = 'prog_prev', button = 'prog_page_prev', label = { '<' }, minw = 0.7, minh = 0.5, scale = 0.35, colour = G.C.ORANGE, col = true }),
			{ n = G.UIT.C, config = { align = 'cm', minw = 1.6 }, nodes = {
				{ n = G.UIT.T, config = { text = ' ' .. PROG.reward_page .. ' / ' .. pages .. ' ', scale = 0.35, colour = G.C.WHITE } },
			} },
			UIBox_button({ id = 'prog_next', button = 'prog_page_next', label = { '>' }, minw = 0.7, minh = 0.5, scale = 0.35, colour = G.C.ORANGE, col = true }),
		} }
	end
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
		UIBox_button({ button = 'prog_skip', label = { (#opts > 0) and 'Skip reward' or 'Continue' }, minw = 3, minh = 0.5, scale = 0.35, colour = G.C.GREY }),
	} }
	return create_UIBox_generic_options({ no_back = true, contents = rows })
end

function PROG.open_reward_menu()
	PROG.reward_page = 1
	G.FUNCS.overlay_menu({ definition = PROG.reward_menu_def(), config = { no_esc = true } })
end

function PROG.claim(opt)
	local st = PROG.state()
	local rtype = PROG.current_reward_type
	local kept_label = nil
	if opt then
		if rtype == 'card' then st.cards[#st.cards + 1] = opt.entry
		elseif rtype == 'joker' then st.jokers[#st.jokers + 1] = opt.entry
		elseif rtype == 'voucher' then st.vouchers[#st.vouchers + 1] = opt.entry
		elseif rtype == 'deck' then st.decks[#st.decks + 1] = opt.entry
		end
		kept_label = opt.label
	end
	st.run = (G.GAME.prog_run or st.run) + 1
	G.GAME.prog_reward_claimed = true
	PROG.save()
	PROG.refresh_ui_strings()

	local rows = {}
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
		{ n = G.UIT.T, config = { text = kept_label and ('Kept: ' .. kept_label) or 'No reward kept.', scale = 0.5, colour = G.C.GREEN, shadow = true } },
	} }
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
		{ n = G.UIT.T, config = { text = 'Next run is level ' .. st.run .. '. Blinds will scale faster.', scale = 0.4, colour = G.C.WHITE } },
	} }
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
		UIBox_button({ button = 'prog_next_run', label = { 'Start Run ' .. st.run }, minw = 4, minh = 0.6, scale = 0.4, colour = G.C.GREEN }),
	} }
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
		UIBox_button({ button = 'prog_close', label = { 'Keep Playing (Endless)' }, minw = 4, minh = 0.5, scale = 0.35, colour = G.C.BLUE }),
	} }
	rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
		UIBox_button({ button = 'go_to_menu', label = { 'Main Menu' }, minw = 4, minh = 0.5, scale = 0.35, colour = G.C.RED }),
	} }
	G.FUNCS.overlay_menu({ definition = create_UIBox_generic_options({ no_back = true, contents = rows }), config = { no_esc = true } })
end

G.FUNCS.prog_pick = function(e)
	local id = e and e.config and e.config.id
	local i = id and tonumber(string.match(tostring(id), '(%d+)$'))
	local opt = i and PROG.current_opts and PROG.current_opts[i]
	if opt then PROG.claim(opt) end
end

G.FUNCS.prog_skip = function()
	PROG.claim(nil)
end

G.FUNCS.prog_page_prev = function()
	PROG.reward_page = PROG.reward_page - 1
	G.FUNCS.overlay_menu({ definition = PROG.reward_menu_def(), config = { no_esc = true } })
end

G.FUNCS.prog_page_next = function()
	PROG.reward_page = PROG.reward_page + 1
	G.FUNCS.overlay_menu({ definition = PROG.reward_menu_def(), config = { no_esc = true } })
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
-- Deck select panel (import, export, reset)
----------------------------------------------------------------

function PROG.remove_deck_panel()
	if PROG.deck_panel then
		PROG.deck_panel:remove()
		PROG.deck_panel = nil
	end
	PROG.reset_armed = nil
end

function PROG.create_deck_panel()
	PROG.remove_deck_panel()
	PROG.refresh_ui_strings()
	local rows = {
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
			{ n = G.UIT.T, config = { text = 'Progression', scale = 0.45, colour = G.C.WHITE, shadow = true } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'summary', scale = 0.28, colour = G.C.WHITE } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'next', scale = 0.28, colour = G.C.WHITE } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
			{ n = G.UIT.T, config = { text = 'Drop a .json file on the window to import a run', scale = 0.25, colour = G.C.UI.TEXT_INACTIVE } },
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
			UIBox_button({ button = 'prog_import_clipboard', label = { 'Paste Import' }, colour = G.C.BLUE, minw = 1.9, minh = 0.45, scale = 0.28, col = true }),
			UIBox_button({ button = 'prog_export_clipboard', label = { 'Export' }, colour = G.C.GREEN, minw = 1.4, minh = 0.45, scale = 0.28, col = true }),
			UIBox_button({ button = 'prog_reset', label = { 'Reset' }, colour = G.C.RED, minw = 1.4, minh = 0.45, scale = 0.28, col = true }),
		} },
		{ n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
			{ n = G.UIT.T, config = { ref_table = PROG.ui, ref_value = 'note', scale = 0.25, colour = G.C.GOLD } },
		} },
	}
	PROG.deck_panel = UIBox({
		definition = { n = G.UIT.ROOT, config = { align = 'cm', padding = 0.15, r = 0.1, colour = { 0, 0, 0, 0.8 } }, nodes = rows },
		config = { align = 'cm', offset = { x = -7.2, y = -3.2 }, major = G.ROOM_ATTACH, bond = 'Weak' },
	})
end

function PROG.refresh_deck_panel()
	local viewing = G.GAME and G.GAME.viewed_back and G.GAME.viewed_back.effect
		and G.GAME.viewed_back.effect.center
		and G.GAME.viewed_back.effect.center.key == PROG.DECK_KEY
	if viewing and G.STAGE == G.STAGES.MAIN_MENU then
		PROG.create_deck_panel()
	else
		PROG.remove_deck_panel()
	end
end

local cvb_ref = G.FUNCS.change_viewed_back
G.FUNCS.change_viewed_back = function(args)
	cvb_ref(args)
	PROG.refresh_deck_panel()
end

local rso_ref = G.UIDEF.run_setup_option
function G.UIDEF.run_setup_option(_type)
	local ret = rso_ref(_type)
	G.E_MANAGER:add_event(Event({
		func = function()
			PROG.refresh_deck_panel()
			return true
		end,
	}))
	return ret
end

local eom_ref = G.FUNCS.exit_overlay_menu
G.FUNCS.exit_overlay_menu = function(e)
	PROG.remove_deck_panel()
	if eom_ref then return eom_ref(e) end
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
	PROG.ui.note = 'Exported to clipboard and progression_export.json in the save folder.'
	play_sound('coin1')
end

G.FUNCS.prog_reset = function()
	if PROG.reset_armed then
		PROG.reset()
		PROG.reset_armed = nil
		PROG.refresh_ui_strings()
		PROG.ui.note = 'Progression reset to run 1.'
		play_sound('tarot1')
	else
		PROG.reset_armed = true
		PROG.ui.note = 'Click Reset again to confirm. This wipes all kept items.'
	end
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
			-- If you've won this run but haven't picked your reward yet, surface it here.
			-- This is the reliable path if the auto-popup on the win screen was missed.
			if PROG.reward_pending() then
				table.insert(target, 1, { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
					UIBox_button({ button = 'prog_open_reward', label = { 'Choose Progression Reward' }, minw = 5, colour = G.C.GREEN }),
				} })
			end
			table.insert(target, { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
				UIBox_button({ button = 'prog_export_clipboard', label = { 'Export Progression' }, minw = 5, colour = G.C.PURPLE }),
			} })
		end
	end
	return ret
end

G.FUNCS.prog_open_reward = function()
	local ok, err = pcall(PROG.open_reward_menu)
	if not ok then
		sendWarnMessage('Progression reward menu failed to open: ' .. tostring(err), 'Progression')
	end
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
