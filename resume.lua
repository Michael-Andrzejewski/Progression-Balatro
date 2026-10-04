----------------------------------------------------------------
-- Resumable Multiplayer matches
--
-- The Multiplayer mod turns saving off for the whole match (G.F_NO_SAVING), so a
-- crash or a dropped connection loses the run. Here each game quietly snapshots
-- its own run whenever it sits in the shop or at blind select, into a per-seat
-- file. After a crash the host opens a new lobby, arms "Resume", and when the
-- match starts every armed game swaps its fresh run for its latest snapshot.
--
-- Files live in the save folder (%AppData%\Balatro\mp_resume\):
--   <seat>_1.jkr (newest) .. <seat>_3.jkr, each a deflated STR_PACK of
--   { run = <save_run table>, meta = { seed, ante, round, state, lives, ... } }
--   <seat>_1.json, a readable copy of the newest meta.
----------------------------------------------------------------

local R = { armed = false, loading = false, last_sig = nil, last_time = 0, status = '' }
PROG.RESUME = R

local DIR = 'mp_resume'
local restore_mp_counters, lives_step -- defined below; used by the update hook
local KEEP = 3

local function seat() return PROG.SEAT or 'default' end
local function path(i, ext) return DIR .. '/' .. seat() .. '_' .. i .. (ext or '.jkr') end

local function in_mp_run()
	return MP and MP.LOBBY and MP.LOBBY.code and G.STAGE == G.STAGES.RUN and G.GAME and G.GAME.pseudorandom
end

local function num(x)
	if to_number then
		local ok, v = pcall(to_number, x)
		if ok and type(v) == 'number' then return v end
	end
	return tonumber(x) or 0
end

local function scalar_copy(t)
	local out = {}
	for k, v in pairs(t or {}) do
		local ty = type(v)
		if ty == 'string' or ty == 'number' or ty == 'boolean' then out[k] = v end
	end
	return out
end

-- A cheap fingerprint of the run, so the shop re-snapshots after purchases but
-- not every frame.
local function signature()
	local g = G.GAME
	return table.concat({
		G.STATE, g.round_resets.ante, g.round, num(g.dollars),
		#(G.jokers and G.jokers.cards or {}), #(G.consumeables and G.consumeables.cards or {}),
		#(G.playing_cards or {}), g.current_round.reroll_cost or 0,
		#(G.shop_jokers and G.shop_jokers.cards or {}),
	}, '|')
end

function R.snapshot(reason)
	if R.loading or not in_mp_run() then return false end
	if G.STATE ~= G.STATES.SHOP and G.STATE ~= G.STATES.BLIND_SELECT then return false end
	if G.pack_cards and G.pack_cards.cards and #G.pack_cards.cards > 0 then return false end
	local was = G.F_NO_SAVING
	G.F_NO_SAVING = false
	local ok, err = pcall(save_run)
	G.F_NO_SAVING = was
	-- save_run queues a write of the shared <profile>/save.jkr; both of our game
	-- copies share a profile, so cancel that and write our own per-seat file.
	if G.FILE_HANDLER then G.FILE_HANDLER.run = nil end
	if not ok or not G.culled_table then
		sendWarnMessage('Resume snapshot failed: ' .. tostring(err), 'Progression')
		return false
	end
	local meta = {
		seat = seat(), seed = G.GAME.pseudorandom.seed, ante = G.GAME.round_resets.ante,
		round = G.GAME.round, state = G.STATE, reason = reason or '',
		lives = MP.GAME and MP.GAME.lives and ((tonumber(MP.GAME.lives) or 0) - (R.lives_debt or 0)), enemy_lives = MP.GAME and MP.GAME.enemy and MP.GAME.enemy.lives,
		furthest_blind = MP.GAME and MP.GAME.furthest_blind, dollars = num(G.GAME.dollars),
		time = os.time(), lobby = scalar_copy(MP.LOBBY.config), is_host = MP.LOBBY.is_host and true or false,
		mp = MP.GAME and {
			comeback_bonus = MP.GAME.comeback_bonus, comeback_bonus_given = MP.GAME.comeback_bonus_given,
			skips = MP.GAME.skips, furthest_blind = MP.GAME.furthest_blind,
			stats = MP.GAME.stats and scalar_copy(MP.GAME.stats) or nil,
		} or nil,
	}
	local ok2, packed = pcall(STR_PACK, { run = G.culled_table, meta = meta })
	if not ok2 then
		sendWarnMessage('Resume snapshot pack failed: ' .. tostring(packed), 'Progression')
		return false
	end
	love.filesystem.createDirectory(DIR)
	for i = KEEP - 1, 1, -1 do
		local data = love.filesystem.read(path(i))
		if data then love.filesystem.write(path(i + 1), data) end
	end
	love.filesystem.write(path(1), love.data.compress('string', 'deflate', packed, 9))
	if JSON then pcall(function() love.filesystem.write(path(1, '.json'), JSON.encode(meta)) end) end
	R.last_sig = signature()
	R.last_time = love.timer.getTime()
	return true
end

function R.read(i)
	local data = love.filesystem.read(path(i or 1))
	if not data then return nil end
	local ok, raw = pcall(love.data.decompress, 'string', 'deflate', data)
	if not ok then return nil end
	local ok2, t = pcall(STR_UNPACK, raw)
	if not ok2 or type(t) ~= 'table' or not t.run then return nil end
	return t
end

function R.meta(i)
	local t = R.read(i)
	return t and t.meta
end

-- Auto-snapshot: whenever the game settles in the shop or at blind select during a
-- Multiplayer match, and again in the shop after anything changes.
local update_ref = Game.update
function Game:update(dt)
	update_ref(self, dt)
	if R.lives_debt and in_mp_run() then lives_step() end
	if R.restore_mp and MP and MP.GAME then
		local rm = R.restore_mp
		if not R.lives_debt then
			restore_mp_counters(rm.mp)
			R.restore_mp = nil
		end
	end
	if R.loading or not in_mp_run() then return end
	if G.STATE ~= G.STATES.SHOP and G.STATE ~= G.STATES.BLIND_SELECT then return end
	if G.CONTROLLER and G.CONTROLLER.locked then return end
	if G.STATE_COMPLETE == false then return end
	local now = love.timer.getTime()
	if now - (R.last_time or 0) < 1.5 then return end
	local sig = signature()
	if sig == R.last_sig then return end
	-- Let the state settle a moment before saving.
	if R.pending_sig ~= sig then R.pending_sig = sig; R.pending_since = now; return end
	if now - (R.pending_since or now) < 0.75 then return end
	R.snapshot('auto')
end

-- Server-side lives start at the lobby's starting_lives; a player who had fewer
-- reports failed rounds until the server count matches the snapshot.
-- The server accepts at most one failed-round report per round, so a gap of more
-- than one life is paid off one life per round. R.lives_debt counts lives still
-- owed; a report goes out only in the shop or at blind select (never inside a
-- blind, so it can't touch a duel), and counts as paid once the server's life
-- count drops.
lives_step = function()
	if not R.lives_debt or R.lives_debt <= 0 or not (MP.GAME and MP.ACTIONS.fail_round) then return end
	local lives = tonumber(MP.GAME.lives) or 0
	local now = love.timer.getTime()
	if R.lives_sent_at then
		-- Only a drop seen shortly after our report, while still outside a blind,
		-- counts as paid; a later drop is a lost duel, not our report.
		if lives < R.lives_sent_at and now - R.lives_sent_time < 6 then
			R.lives_debt = R.lives_debt - 1
			R.lives_sent_at = nil
			if R.lives_debt <= 0 then R.lives_debt = nil end
			return
		end
		if now - R.lives_sent_time < 6 then return end
		R.lives_sent_at = nil -- ignored by the server; retry next round
	end
	if G.STATE ~= G.STATES.SHOP and G.STATE ~= G.STATES.BLIND_SELECT then return end
	if R.lives_round == G.GAME.round or lives <= 1 then return end
	R.lives_round = G.GAME.round
	R.lives_sent_at = lives
	R.lives_sent_time = now
	MP.ACTIONS.fail_round(1)
end

local function sync_lives(target)
	local diff = (tonumber(MP.GAME and MP.GAME.lives) or 0) - (tonumber(target) or 0)
	R.lives_debt = diff > 0 and diff or nil
	R.lives_round, R.lives_sent_at = nil, nil
	lives_step()
end

-- Multiplayer-only counters (comeback bonus, skips, stats) are not part of the
-- saved run. Restore them once the server has confirmed the synced lives, which
-- also undoes the comeback bonus the sync's "failed rounds" would add.
restore_mp_counters = function(mp)
	if not (mp and MP.GAME) then return end
	for _, k in ipairs({ 'comeback_bonus', 'comeback_bonus_given', 'skips', 'furthest_blind' }) do
		if mp[k] ~= nil then MP.GAME[k] = mp[k] end
	end
	if mp.stats and MP.GAME.stats then
		for k, v in pairs(mp.stats) do MP.GAME.stats[k] = v end
	end
end

-- Replace the current (fresh) run with the newest snapshot, staying in the lobby.
function R.resume(i)
	local snap = R.read(i or 1)
	if not snap then R.status = 'No snapshot found'; return false, R.status end
	local meta = snap.meta or {}
	if not in_mp_run() then R.status = 'Start the match first'; return false, R.status end
	R.loading = true
	R.armed = false
	R.pending_meta = meta
	G.F_NO_SAVING = true
	G.FUNCS.wipe_on()
	G.E_MANAGER:add_event(Event({ trigger = 'immediate', no_delete = true, func = function()
		G:delete_run()
		G:start_run({ savetext = snap.run })
		return true
	end }))
	G.FUNCS.wipe_off()
	return true
end

-- Host: copy the snapshot's seed and lobby settings into the new lobby, with
-- starting lives at the higher of the two players' lives at snapshot time.
function R.apply_lobby_from_snapshot()
	local meta = R.meta(1)
	if not meta then return false, 'No snapshot found' end
	if not (MP and MP.LOBBY and MP.LOBBY.code and MP.LOBBY.is_host) then return false, 'Only the host sets the lobby' end
	local cfg = MP.LOBBY.config
	for _, k in ipairs({ 'back', 'stake', 'ruleset', 'pvp_start_round', 'timer', 'timer_base_seconds',
		'timer_increment_seconds', 'death_on_round_loss', 'gold_on_life_loss', 'no_gold_on_round_loss',
		'different_seeds', 'multiplayer_jokers', 'the_order', 'sleeve' }) do
		if meta.lobby and meta.lobby[k] ~= nil then cfg[k] = meta.lobby[k] end
	end
	local seed = tostring(meta.seed or ''):gsub('^%*', '')
	if seed ~= '' then cfg.custom_seed = seed end
	cfg.starting_lives = math.max(tonumber(meta.lives) or 0, tonumber(meta.enemy_lives) or 0, 1)
	MP.ACTIONS.lobby_options()
	return true
end

-- When a match starts with Resume armed, swap in the snapshot once the fresh run
-- has finished setting up (only if its seed matches the snapshot's).
-- Runs right after the snapshot has loaded. start_run clears the event queue, so
-- this has to run from the start_run hook, not from an event queued before it.
local function after_resume(meta)
	G.F_NO_SAVING = true
	if MP.ACTIONS.set_ante and meta.ante then MP.ACTIONS.set_ante(meta.ante) end
	if MP.ACTIONS.set_furthest_blind and meta.furthest_blind then
		MP.GAME.furthest_blind = meta.furthest_blind
		MP.ACTIONS.set_furthest_blind(meta.furthest_blind)
	end
	sync_lives(meta.lives)
	R.restore_mp = { target = tonumber(meta.lives), mp = meta.mp, since = love.timer.getTime() }
	R.loading = false
	R.last_sig = signature()
	R.last_time = love.timer.getTime()
	R.status = string.format('Resumed: ante %s, $%s', tostring(meta.ante), tostring(num(G.GAME.dollars)))
	PROG.ui.resume = R.status
	sendInfoMessage(R.status, 'Progression')
end

local start_run_ref = Game.start_run
function Game:start_run(args)
	start_run_ref(self, args)
	if args and args.savetext and R.pending_meta then
		local meta = R.pending_meta
		R.pending_meta = nil
		local ok, err = pcall(after_resume, meta)
		if not ok then R.loading = false; sendWarnMessage('Resume sync failed: ' .. tostring(err), 'Progression') end
		return
	end
	if not (R.armed and not (args and args.savetext) and in_mp_run()) then return end
	local meta = R.meta(1)
	local cur = tostring(G.GAME.pseudorandom.seed or ''):gsub('^%*', '')
	local want = meta and tostring(meta.seed or ''):gsub('^%*', '')
	if not meta or cur ~= want then
		R.armed = false
		R.status = 'Snapshot seed ' .. tostring(want) .. ' does not match ' .. cur
		sendWarnMessage(R.status, 'Progression')
		return
	end
	G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 1.0, blockable = false, func = function()
		R.resume(1)
		return true
	end }))
end

-- Lobby panel button: arm/disarm Resume (the host also copies the lobby settings).
G.FUNCS.prog_resume_toggle = function(e)
	if R.armed then
		R.armed = false
		R.status = 'Resume off'
	else
		local meta = R.meta(1)
		if not meta then
			R.status = 'No snapshot to resume'
		else
			R.armed = true
			if MP and MP.LOBBY and MP.LOBBY.is_host then R.apply_lobby_from_snapshot() end
			R.status = string.format('Resume ON: ante %s, %s lives, seed %s', tostring(meta.ante), tostring(meta.lives), tostring(meta.seed))
		end
	end
	PROG.ui.resume = R.status
	play_sound('generic1')
end

PROG.ui.resume = ''
