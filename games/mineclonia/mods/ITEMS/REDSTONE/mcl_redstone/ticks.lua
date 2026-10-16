-- Minecraft's server tick for blocks, at 20 game ticks per second.
--
-- Each game tick runs, like ServerLevel.tick:
--   1. the game time advances
--   2. scheduled block ticks (LevelTicks), ordered by trigger tick,
--      priority and scheduling order, at most one per position and block
--   3. block events (Level.blockEvent, used by pistons)
--   4. block entity tickers (moving piston blocks, ...)
-- Fluid ticks are done by the engine, entities by their own steps.


local TICK_LENGTH = 0.05
local MAX_TICKS_PER_STEP = 10
local MAX_SCHEDULED_PER_TICK = 65536

local storage = core.get_mod_storage()

local game_time = storage:get_int("game_time")
local sub_tick_order = 0

mcl_redstone.tick_rate = 20
mcl_redstone.is_tick_frozen = false

function mcl_redstone.get_game_time()
	return game_time
end

-- Redstone ticks (two game ticks), for older code.
function mcl_redstone.get_current_tick()
	return math.floor(game_time / 2)
end

-- Scheduled ticks ------------------------------------------------------------

-- Binary heap of ticks, ordered by (trigger, priority, sub).
local heap = {}
-- Pending ticks by key "<hash>|<block>" (LevelChunkTicks.ticksPerPosition)
local pending = {}
-- Ticks collected for the current tick that have not run yet
-- (LevelTicks.toRunThisTickSet)
local running_set = {}
-- Ticks whose position is not loaded, retried later
local dormant = {}

local function before(a, b)
	if a.trigger ~= b.trigger then
		return a.trigger < b.trigger
	end
	if a.priority ~= b.priority then
		return a.priority < b.priority
	end
	return a.sub < b.sub
end

local function heap_push(e)
	local i = #heap + 1
	heap[i] = e
	while i > 1 do
		local p = math.floor(i / 2)
		if before(heap[i], heap[p]) then
			heap[i], heap[p] = heap[p], heap[i]
			i = p
		else
			break
		end
	end
end

local function heap_pop()
	local n = #heap
	if n == 0 then
		return nil
	end
	local top = heap[1]
	heap[1] = heap[n]
	heap[n] = nil
	n = n - 1
	local i = 1
	while true do
		local l, r = 2 * i, 2 * i + 1
		local m = i
		if l <= n and before(heap[l], heap[m]) then m = l end
		if r <= n and before(heap[r], heap[m]) then m = r end
		if m == i then break end
		heap[i], heap[m] = heap[m], heap[i]
		i = m
	end
	return top
end

-- Built from the coordinates: tostring() of a position hash keeps only 14
-- significant digits, which is not enough to tell nearby positions apart.
local function pos_key(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

local function tick_key(pos, block)
	return pos_key(pos) .. "|" .. block
end

mcl_redstone.PRIORITY_EXTREMELY_HIGH = -3
mcl_redstone.PRIORITY_VERY_HIGH = -2
mcl_redstone.PRIORITY_HIGH = -1
mcl_redstone.PRIORITY_NORMAL = 0
mcl_redstone.PRIORITY_LOW = 1
mcl_redstone.PRIORITY_VERY_LOW = 2
mcl_redstone.PRIORITY_EXTREMELY_LOW = 3

local function schedule_entry(pos, block, trigger, priority, func)
	local e = {
		pos = vector.copy(pos),
		block = block,
		trigger = trigger,
		priority = priority or 0,
		sub = sub_tick_order,
		func = func,
	}
	sub_tick_order = sub_tick_order + 1
	if block then
		e.key = tick_key(pos, block)
		pending[e.key] = e
	end
	heap_push(e)
	return e
end

-- Level.scheduleTick(pos, block, delay, priority). `block` is a block id
-- (see mcl_redstone.block_id). Delay is in game ticks.
function mcl_redstone.schedule_tick(pos, block, delay, priority)
	local key = tick_key(pos, block)
	if pending[key] then
		return
	end
	schedule_entry(pos, block, game_time + delay, priority)
end

function mcl_redstone.has_scheduled_tick(pos, block)
	return pending[tick_key(pos, block)] ~= nil
end

function mcl_redstone.will_tick_this_tick(pos, block)
	return running_set[tick_key(pos, block)] ~= nil
end

-- Calls func after `delay` game ticks, during the scheduled tick phase.
function mcl_redstone.after_ticks(delay, func)
	schedule_entry(vector.zero(), nil, game_time + delay, 0, func)
end

-- Older API: delay in redstone ticks (two game ticks each).
function mcl_redstone.after(delay, func)
	mcl_redstone.after_ticks(delay * 2, func)
end

local function is_loaded(pos)
	return core.get_node_or_nil(pos) ~= nil
end

local function run_scheduled_ticks()
	local to_run = {}
	while #to_run < MAX_SCHEDULED_PER_TICK and heap[1] and heap[1].trigger <= game_time do
		local e = heap_pop()
		if e.block and not is_loaded(e.pos) then
			dormant[#dormant + 1] = e
		else
			if e.key then
				pending[e.key] = nil
				running_set[e.key] = e
			end
			to_run[#to_run + 1] = e
		end
	end
	for i = 1, #to_run do
		local e = to_run[i]
		if e.key then
			running_set[e.key] = nil
		end
		if e.func then
			e.func()
		else
			mcl_redstone._tick_block(e.pos, e.block)
		end
	end
	running_set = {}
end

local function wake_dormant()
	if #dormant == 0 then
		return
	end
	local still = {}
	for _, e in ipairs(dormant) do
		if is_loaded(e.pos) then
			heap_push(e)
		else
			still[#still + 1] = e
		end
	end
	dormant = still
end

-- Block events -----------------------------------------------------------------

local events = {}
local event_set = {}

-- Level.blockEvent(pos, block, b0, b1)
function mcl_redstone.block_event(pos, block, b0, b1)
	local key = pos_key(pos) .. "|" .. block .. "|" .. b0 .. "|" .. b1
	if event_set[key] then
		return
	end
	event_set[key] = true
	events[#events + 1] = {pos = vector.copy(pos), block = block, b0 = b0, b1 = b1, key = key}
end

-- ServerLevel.runBlockEvents: events added while running run in the same
-- loop.  The list is not shortened while it runs (no holes for #).
local function run_block_events()
	local reschedule = {}
	local i = 1
	while i <= #events do
		local e = events[i]
		i = i + 1
		event_set[e.key] = nil
		if is_loaded(e.pos) then
			mcl_redstone._do_block_event(e.pos, e.block, e.b0, e.b1)
		else
			reschedule[#reschedule + 1] = e
		end
	end
	events = {}
	for _, e in ipairs(reschedule) do
		if not event_set[e.key] then
			event_set[e.key] = true
			events[#events + 1] = e
		end
	end
end

-- Block entity tickers -----------------------------------------------------------

local tickers = {}
local pending_tickers = {}
local ticking_tickers = false

-- Adds a ticker {pos = pos, tick = function(ticker), removed = false}, ticked
-- every game tick after the block events until ticker.removed is set.
function mcl_redstone.add_ticker(ticker)
	if ticking_tickers then
		pending_tickers[#pending_tickers + 1] = ticker
	else
		tickers[#tickers + 1] = ticker
	end
	return ticker
end

local function run_tickers()
	ticking_tickers = true
	for i = 1, #pending_tickers do
		tickers[#tickers + 1] = pending_tickers[i]
	end
	pending_tickers = {}
	local kept = {}
	for i = 1, #tickers do
		local t = tickers[i]
		if not t.removed then
			if is_loaded(t.pos) then
				t.tick(t)
			end
			if not t.removed then
				kept[#kept + 1] = t
			end
		end
	end
	tickers = kept
	ticking_tickers = false
end

function mcl_redstone._get_tickers()
	return tickers, pending_tickers
end

-- The tick -----------------------------------------------------------------------

local on_tick_callbacks = {}

-- Called with the game time after every game tick.
function mcl_redstone.register_on_game_tick(callback)
	table.insert(on_tick_callbacks, callback)
end

local legacy_tick_callbacks = {}

-- Older API: called after every redstone tick (every second game tick).
function mcl_redstone.register_on_tick(callback)
	table.insert(legacy_tick_callbacks, callback)
end

local handling_tick = false

-- ServerLevel.isHandlingTick: true during scheduled ticks and block events
function mcl_redstone.is_handling_tick()
	return handling_tick
end

function mcl_redstone.tick_step()
	game_time = game_time + 1
	mcl_redstone._begin()
	handling_tick = true
	local ok, err = pcall(function()
		run_scheduled_ticks()
		run_block_events()
	end)
	handling_tick = false
	if ok then
		ok, err = pcall(run_tickers)
	end
	mcl_redstone._end()
	if not ok then
		error(err, 0)
	end
	for _, cb in ipairs(on_tick_callbacks) do
		cb(game_time)
	end
	if game_time % 2 == 0 then
		for _, cb in ipairs(legacy_tick_callbacks) do
			cb(mcl_redstone.get_current_tick())
		end
	end
	if #dormant > 0 and (#dormant < 256 or game_time % 20 == 0) then
		wake_dormant()
	end
end

local accumulator = 0
local sprinting = 0
local steps_left = 0

core.register_globalstep(function(dtime)
	if sprinting > 0 then
		local t0 = core.get_us_time()
		while sprinting > 0 and core.get_us_time() - t0 < 50000 do
			mcl_redstone.tick_step()
			sprinting = sprinting - 1
		end
		return
	end
	if mcl_redstone.is_tick_frozen and steps_left <= 0 then
		accumulator = 0
		return
	end
	local length = 1 / mcl_redstone.tick_rate
	accumulator = accumulator + dtime
	local n = 0
	while accumulator >= length do
		accumulator = accumulator - length
		if mcl_redstone.is_tick_frozen then
			if steps_left <= 0 then
				accumulator = 0
				break
			end
			steps_left = steps_left - 1
		end
		mcl_redstone.tick_step()
		n = n + 1
		if n >= MAX_TICKS_PER_STEP then
			-- Can't keep up: skip the backlog like Minecraft does
			accumulator = 0
			break
		end
	end
end)

-- Older API: seconds per redstone tick.
mcl_redstone.tick_speed = TICK_LENGTH * 2

-- /tick, like Minecraft's command (rates in ticks per second).
core.register_chatcommand("tick", {
	description = "Controls the game tick rate (like Minecraft's /tick)",
	params = "query | rate <ticks per second> | freeze | unfreeze | step [<ticks>] | step stop | sprint <ticks> | sprint stop",
	privs = {server = true},
	func = function(name, param)
		local args = param:split(" ")
		local op, arg = args[1], args[2]
		if op == "query" or not op then
			return true, string.format("Target tick rate: %s per second%s. Game time: %d",
				mcl_redstone.tick_rate, mcl_redstone.is_tick_frozen and " (frozen)" or "", game_time)
		elseif op == "rate" then
			local r = tonumber(arg)
			if not r or r < 1 or r > 10000 then
				return false, "Rate must be a number between 1 and 10000"
			end
			mcl_redstone.tick_rate = r
			return true, "Set the target tick rate to " .. r .. " per second"
		elseif op == "freeze" then
			mcl_redstone.is_tick_frozen = true
			return true, "The game is frozen"
		elseif op == "unfreeze" then
			mcl_redstone.is_tick_frozen = false
			steps_left = 0
			return true, "The game is running normally"
		elseif op == "step" then
			if not mcl_redstone.is_tick_frozen then
				return false, "The game must be frozen first"
			end
			if arg == "stop" then
				steps_left = 0
				return true, "Stepping stopped"
			end
			steps_left = tonumber(arg) or 1
			return true, "Stepping " .. steps_left .. " tick(s)"
		elseif op == "sprint" then
			if arg == "stop" then
				sprinting = 0
				return true, "Sprint stopped"
			end
			local n = tonumber(arg)
			if not n then
				return false, "Number of ticks required"
			end
			sprinting = math.floor(n)
			return true, "Sprinting " .. sprinting .. " ticks"
		end
		return false, "Unknown operation"
	end,
})

-- Persistence --------------------------------------------------------------------

local function save()
	storage:set_int("game_time", game_time)
	local list = {}
	local function add(e)
		if e.block and pending[e.key] == e then
			list[#list + 1] = {
				x = e.pos.x, y = e.pos.y, z = e.pos.z,
				b = e.block, d = e.trigger - game_time, p = e.priority, s = e.sub,
			}
		end
	end
	for _, e in ipairs(heap) do add(e) end
	for _, e in ipairs(dormant) do add(e) end
	table.sort(list, function(a, b) return a.s < b.s end)
	local evs = {}
	for i = 1, #events do
		local e = events[i]
		evs[#evs + 1] = {x = e.pos.x, y = e.pos.y, z = e.pos.z, b = e.block, b0 = e.b0, b1 = e.b1}
	end
	storage:set_string("scheduled_ticks", core.write_json(list) or "[]")
	storage:set_string("block_events", core.write_json(evs) or "[]")
end

local function load()
	local s = storage:get_string("scheduled_ticks")
	local list = s ~= "" and core.parse_json(s) or {}
	for _, t in ipairs(list) do
		local pos = vector.new(t.x, t.y, t.z)
		local key = tick_key(pos, t.b)
		if not pending[key] then
			-- Waits in `dormant` until its area is loaded
			local e = {pos = pos, block = t.b, trigger = game_time + t.d,
				priority = t.p, sub = sub_tick_order, key = key}
			sub_tick_order = sub_tick_order + 1
			pending[key] = e
			dormant[#dormant + 1] = e
		end
	end
	s = storage:get_string("block_events")
	local evs = s ~= "" and core.parse_json(s) or {}
	for _, e in ipairs(evs) do
		mcl_redstone.block_event(vector.new(e.x, e.y, e.z), e.b, e.b0, e.b1)
	end
end

load()

local save_timer = 0
core.register_globalstep(function(dtime)
	save_timer = save_timer + dtime
	if save_timer > 60 then
		save_timer = 0
		save()
	end
end)

core.register_on_shutdown(save)
