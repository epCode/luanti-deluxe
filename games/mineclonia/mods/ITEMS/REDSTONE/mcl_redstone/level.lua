-- Port of the parts of Minecraft's Level that redstone depends on:
-- Level.setBlock with its update flags, neighbour updates through the
-- CollectingNeighborUpdater, shape updates, and the SignalGetter queries.
--
-- Nodes take part through the `_mcl_redstone` field of their definition (see
-- API.md).  Every node also gets the default behaviour, so changes made by
-- any mod (reported by core.register_on_node_change) update their neighbours
-- like Level.setBlock(pos, state, UPDATE_ALL) does in Minecraft.

local bit = bit
local band, bor, bnot = bit.band, bit.bor, bit.bnot

local DOWN, UP, NORTH, SOUTH, WEST, EAST = 0, 1, 2, 3, 4, 5
local dirvec = mcl_redstone.dirvec
local opposite = mcl_redstone.opposite
local ALL = mcl_redstone.ALL
local UPDATE_ORDER = mcl_redstone.UPDATE_ORDER
local UPDATE_SHAPE_ORDER = mcl_redstone.UPDATE_SHAPE_ORDER
local hash = mcl_redstone.hash

-- Block.UpdateFlags
mcl_redstone.UPDATE_NEIGHBORS = 1
mcl_redstone.UPDATE_CLIENTS = 2
mcl_redstone.UPDATE_INVISIBLE = 4
mcl_redstone.UPDATE_IMMEDIATE = 8
mcl_redstone.UPDATE_KNOWN_SHAPE = 16
mcl_redstone.UPDATE_SUPPRESS_DROPS = 32
mcl_redstone.UPDATE_MOVE_BY_PISTON = 64
mcl_redstone.UPDATE_SKIP_SHAPE_UPDATE_ON_WIRE = 128
mcl_redstone.UPDATE_SKIP_BLOCK_ENTITY_SIDEEFFECTS = 256
mcl_redstone.UPDATE_SKIP_ON_PLACE = 512
mcl_redstone.UPDATE_ALL = 3
mcl_redstone.UPDATE_ALL_IMMEDIATE = 11

local MAX_CHAINED_NEIGHBOR_UPDATES = 1000000
local UPDATE_LIMIT = 512

local raw_swap_node = core.swap_node
local raw_set_node = core.set_node

-- Behaviour of every node by name, completed on mods loaded.
local blocks = {}
mcl_redstone._blocks = blocks

local DEFAULT = {}
mcl_redstone._default_block = DEFAULT

local function B(name)
	return blocks[name] or DEFAULT
end
mcl_redstone.get_block = B

-- Node cache ---------------------------------------------------------------------
--
-- Reads are cached while redstone code runs (between _begin and _end).  All
-- writes through core.set_node/swap_node/remove_node update the cache via the
-- node change hook.

local depth = 0
local nodecache = {}

function mcl_redstone._begin()
	if depth == 0 then
		nodecache = {}
	end
	depth = depth + 1
end

function mcl_redstone._end()
	depth = depth - 1
end

local function get_node(pos)
	if depth == 0 then
		return core.get_node(pos)
	end
	local h = hash(pos)
	local n = nodecache[h]
	if not n then
		n = core.get_node(pos)
		nodecache[h] = n
	end
	return n
end
mcl_redstone.get_node = get_node

local function same_node(a, b)
	return a.name == b.name and (a.param2 or 0) == (b.param2 or 0)
end
mcl_redstone.same_node = same_node

-- The Minecraft block a node belongs to; states of the same block share it.
local function block_id(name)
	local b = blocks[name]
	return b and b.block or name
end
mcl_redstone.block_id = block_id

function mcl_redstone.is_block(node, id)
	return block_id(node.name) == id
end

-- Writing nodes --------------------------------------------------------------------

-- Positions currently written by set_block; their change reports are ours.
local suppress = {}

local function write(pos, node, block_changed)
	local h = hash(pos)
	suppress[h] = (suppress[h] or 0) + 1
	local ok, err = pcall(function()
		if block_changed then
			raw_set_node(pos, node)
		else
			raw_swap_node(pos, node)
		end
	end)
	suppress[h] = suppress[h] - 1
	if suppress[h] == 0 then
		suppress[h] = nil
	end
	nodecache[h] = nil
	if not ok then
		error(err, 0)
	end
end

-- Writes a node without any updates (a change Minecraft keeps in a block
-- entity, not in the block state).
function mcl_redstone._raw_write(pos, node, block_changed)
	write(pos, node, block_changed)
end

local update_neighbors_at, update_neighbour_for_output_signal, update_neighbour_shapes
local action_tab = {}
mcl_redstone._action_tab = action_tab

function mcl_redstone.register_action(func, node_names)
	for _, name in pairs(node_names) do
		action_tab[name] = action_tab[name] or {}
		table.insert(action_tab[name], func)
	end
end

local function run_actions(pos, oldnode, newnode)
	local a, b = action_tab[oldnode.name], action_tab[newnode.name]
	if not a and not b then
		return
	end
	local seen = {}
	for _, list in pairs({a or {}, b or {}}) do
		for _, f in ipairs(list) do
			if not seen[f] then
				seen[f] = true
				f(pos, oldnode, newnode)
			end
		end
	end
end

local function has_analog_output(node)
	local b = B(node.name)
	local h = b.has_analog_output
	if h ~= nil then
		if type(h) == "function" then
			return h(node)
		end
		return h
	end
	return b.analog_output ~= nil
end
mcl_redstone.has_analog_output = has_analog_output

function mcl_redstone.get_analog_output(pos, node, d)
	local b = B(node.name)
	return b.analog_output and b.analog_output(pos, node, d) or 0
end

-- Everything Level.setBlock and LevelChunk.setBlockState do after the node
-- itself has been written.  Returns false if the node changed meanwhile.
local function after_write(pos, oldnode, node, flags, limit)
	local oldb, newb = B(oldnode.name), B(node.name)
	local block_changed = block_id(oldnode.name) ~= block_id(node.name)
	local moved = band(flags, 64) ~= 0

	if (block_changed or newb.always_affect_after_removal)
			and (band(flags, 1) ~= 0 or moved) and oldb.affect_neighbors_after_removal then
		oldb.affect_neighbors_after_removal(pos, oldnode, moved)
	end
	if not same_node(get_node(pos), node) then
		return false
	end
	if band(flags, 512) == 0 and newb.on_place then
		newb.on_place(pos, node, oldnode, moved)
	end
	if not same_node(get_node(pos), node) then
		return true
	end

	if band(flags, 1) ~= 0 then
		update_neighbors_at(pos, block_id(oldnode.name))
		if has_analog_output(node) then
			update_neighbour_for_output_signal(pos, block_id(node.name))
		end
	end
	if band(flags, 16) == 0 and limit > 0 then
		local f2 = band(flags, bnot(33))
		if oldb.update_indirect_neighbour_shapes then
			oldb.update_indirect_neighbour_shapes(pos, oldnode, f2, limit - 1)
		end
		update_neighbour_shapes(pos, node, f2, limit - 1)
		if newb.update_indirect_neighbour_shapes then
			newb.update_indirect_neighbour_shapes(pos, node, f2, limit - 1)
		end
	end
	run_actions(pos, oldnode, node)
	return true
end

-- Level.setBlock(pos, node, flags, limit)
function mcl_redstone.set_block(pos, node, flags, limit)
	flags = flags or 3
	limit = limit or UPDATE_LIMIT
	local oldnode = get_node(pos)
	if oldnode.name == "ignore" then
		return false
	end
	node = {name = node.name, param2 = node.param2 or 0}
	if same_node(oldnode, node) then
		return false
	end
	mcl_redstone._begin()
	local block_changed = block_id(oldnode.name) ~= block_id(node.name)
	-- Minecraft keeps the block entity (node metadata) while the block stays
	-- the same.
	write(pos, node, block_changed)
	local ok, ret = pcall(after_write, pos, oldnode, node, flags, limit)
	mcl_redstone._end()
	if not ok then
		error(ret, 0)
	end
	return ret
end

-- Like set_block, but for a change that was already made (the node at pos
-- is `node` now and was `oldnode`).
function mcl_redstone.node_changed(pos, oldnode, node, flags, limit)
	mcl_redstone._begin()
	nodecache[hash(pos)] = nil
	local ok, ret = pcall(after_write, pos, oldnode, node, flags or 3, limit or UPDATE_LIMIT)
	mcl_redstone._end()
	if not ok then
		error(ret, 0)
	end
	return ret
end

-- Drops of a node like Block.dropResources.
function mcl_redstone.drop_resources(pos, node)
	local drops = core.get_node_drops(node, "")
	for _, item in ipairs(drops) do
		local p = vector.offset(pos,
			math.random() * 0.5 - 0.25, math.random() * 0.5 - 0.25, math.random() * 0.5 - 0.25)
		core.add_item(p, item)
	end
end

-- Level.destroyBlock(pos, drop, limit)
function mcl_redstone.destroy_block(pos, drop, limit)
	local node = get_node(pos)
	if node.name == "air" or node.name == "ignore" then
		return false
	end
	if drop then
		mcl_redstone.drop_resources(pos, node)
	end
	local def = core.registered_nodes[node.name]
	if def and def.sounds and def.sounds.dug then
		core.sound_play(def.sounds.dug, {pos = pos}, true)
	end
	local destroyed = mcl_redstone.set_block(pos, {name = "air"}, 3, limit)
	if destroyed and mcl_gameevent then
		mcl_gameevent.emit("block_destroy", pos, {node = node})
	end
	return destroyed
end

-- Level.removeBlock(pos, moved_by_piston)
function mcl_redstone.remove_block(pos, moved)
	return mcl_redstone.set_block(pos, {name = "air"}, moved and 67 or 3)
end

-- Neighbour updates (CollectingNeighborUpdater) ------------------------------------

local stack = {}
local added = {}
local count = 0

local function run_update(u)
	local kind = u.kind
	if kind == "multi" then
		local d = UPDATE_ORDER[u.idx]
		u.idx = u.idx + 1
		local npos = mcl_redstone.rel(u.pos, d)
		local node = get_node(npos)
		local b = B(node.name)
		if b.neighbor_changed then
			b.neighbor_changed(npos, node, u.block, false, u.pos)
		end
		if u.idx <= 6 and UPDATE_ORDER[u.idx] == u.skip then
			u.idx = u.idx + 1
		end
		return u.idx <= 6
	elseif kind == "simple" then
		local node = get_node(u.pos)
		local b = B(node.name)
		if b.neighbor_changed then
			b.neighbor_changed(u.pos, node, u.block, false, u.from)
		end
		return false
	elseif kind == "full" then
		local b = B(u.node.name)
		if b.neighbor_changed then
			b.neighbor_changed(u.pos, u.node, u.block, u.moved, u.from)
		end
		return false
	else -- shape
		local current = get_node(u.pos)
		if band(u.flags, 128) == 0 or block_id(current.name) ~= "mcl_redstone:redstone" then
			local b = B(current.name)
			if b.update_shape then
				local new = b.update_shape(u.pos, current, u.dir, u.npos, u.nnode)
				if new and not same_node(new, current) then
					if new.name == "air" then
						mcl_redstone.destroy_block(u.pos, band(u.flags, 32) == 0, u.limit)
					else
						mcl_redstone.set_block(u.pos, new, band(u.flags, bnot(32)), u.limit)
					end
				end
			end
		end
		return false
	end
end

local function run_updates()
	while #stack > 0 or #added > 0 do
		for i = #added, 1, -1 do
			stack[#stack + 1] = added[i]
		end
		added = {}
		local nxt = stack[#stack]
		while #added == 0 do
			if not run_update(nxt) then
				-- `nxt` is still the top: added updates are not on the stack yet
				stack[#stack] = nil
				break
			end
		end
	end
end

local function add_and_run(u)
	local running = count > 0
	local too_many = count >= MAX_CHAINED_NEIGHBOR_UPDATES
	count = count + 1
	if not too_many then
		if running then
			added[#added + 1] = u
		else
			stack[#stack + 1] = u
		end
	elseif count - 1 == MAX_CHAINED_NEIGHBOR_UPDATES then
		core.log("error", "[mcl_redstone] Too many chained neighbor updates. Skipping the rest. First skipped position: "
			.. core.pos_to_string(u.pos))
	end
	if not running then
		mcl_redstone._begin()
		local ok, err = pcall(run_updates)
		stack = {}
		added = {}
		count = 0
		mcl_redstone._end()
		if not ok then
			error(err, 0)
		end
	end
end

-- Level.updateNeighborsAtExceptFromFacing
local function update_neighbors_at_except(pos, block, skip)
	local idx = 1
	if UPDATE_ORDER[1] == skip then
		idx = 2
	end
	add_and_run({kind = "multi", pos = vector.copy(pos), block = block, skip = skip, idx = idx})
end
mcl_redstone.update_neighbors_at_except = update_neighbors_at_except

-- Level.updateNeighborsAt
function update_neighbors_at(pos, block)
	update_neighbors_at_except(pos, block, nil)
end
mcl_redstone.update_neighbors_at = update_neighbors_at

-- Level.neighborChanged(pos, block)
function mcl_redstone.neighbor_changed(pos, block, from)
	add_and_run({kind = "simple", pos = vector.copy(pos), block = block, from = from})
end

-- Level.neighborChanged(state, pos, block, orientation, movedByPiston)
function mcl_redstone.neighbor_changed_state(node, pos, block, moved, from)
	add_and_run({kind = "full", node = node, pos = vector.copy(pos), block = block, moved = moved, from = from})
end

-- Level.neighborShapeChanged(dir, pos, npos, nnode, flags, limit): the node at
-- npos, seen from pos in direction dir, changed to nnode.
function mcl_redstone.neighbor_shape_changed(dir, pos, npos, nnode, flags, limit)
	add_and_run({kind = "shape", dir = dir, pos = vector.copy(pos), npos = vector.copy(npos),
		nnode = nnode, flags = flags, limit = limit})
end

-- BlockState.updateNeighbourShapes
function update_neighbour_shapes(pos, node, flags, limit)
	for i = 1, 6 do
		local d = UPDATE_SHAPE_ORDER[i]
		mcl_redstone.neighbor_shape_changed(opposite[d], mcl_redstone.rel(pos, d), pos, node, flags, limit or UPDATE_LIMIT)
	end
end
mcl_redstone.update_neighbour_shapes = update_neighbour_shapes

-- Level.updateNeighbourForOutputSignal: tells comparators reading this node.
function update_neighbour_for_output_signal(pos, block)
	for _, d in ipairs(mcl_redstone.HORIZONTAL) do
		local p = mcl_redstone.rel(pos, d)
		local node = get_node(p)
		if node.name ~= "ignore" then
			if block_id(node.name) == "mcl_comparators:comparator" then
				mcl_redstone.neighbor_changed_state(node, p, block, false, pos)
			elseif mcl_redstone.is_conductor(p, node) then
				p = mcl_redstone.rel(p, d)
				node = get_node(p)
				if block_id(node.name) == "mcl_comparators:comparator" then
					mcl_redstone.neighbor_changed_state(node, p, block, false, pos)
				end
			end
		end
	end
end
mcl_redstone.update_neighbour_for_output_signal = update_neighbour_for_output_signal

-- Block.updateFromNeighbourShapes: the node as it would be after shape
-- updates from all its neighbours.
function mcl_redstone.update_from_neighbour_shapes(node, pos)
	local b = B(node.name)
	if not b.update_shape then
		return node
	end
	local state = node
	for _, d in ipairs(UPDATE_SHAPE_ORDER) do
		local npos = mcl_redstone.rel(pos, d)
		local new = b.update_shape(pos, state, d, npos, get_node(npos))
		if new then
			if new.name == "air" then
				return new
			end
			state = new
			b = B(state.name)
			if not b.update_shape then
				break
			end
		end
	end
	return state
end

-- Signals (SignalGetter) -------------------------------------------------------------
--
-- `d` is the direction from the node asking towards the signal source, as in
-- Minecraft: get_signal(pos, d) is the signal of the node at pos going into
-- the node at pos - d.

local function is_signal_source(node)
	local s = B(node.name).signal_source
	if type(s) == "function" then
		return s(node)
	end
	return s or false
end
mcl_redstone.is_signal_source = is_signal_source

local function get_direct_signal(pos, d)
	local node = get_node(pos)
	local f = B(node.name).get_direct_signal
	return f and f(pos, node, d) or 0
end
mcl_redstone.get_direct_signal = get_direct_signal

-- SignalGetter.getDirectSignalTo
local function get_direct_signal_to(pos)
	local r = 0
	local x, y, z = pos.x, pos.y, pos.z
	r = math.max(r, get_direct_signal({x = x, y = y - 1, z = z}, DOWN))
	if r >= 15 then return r end
	r = math.max(r, get_direct_signal({x = x, y = y + 1, z = z}, UP))
	if r >= 15 then return r end
	r = math.max(r, get_direct_signal({x = x, y = y, z = z + 1}, NORTH))
	if r >= 15 then return r end
	r = math.max(r, get_direct_signal({x = x, y = y, z = z - 1}, SOUTH))
	if r >= 15 then return r end
	r = math.max(r, get_direct_signal({x = x - 1, y = y, z = z}, WEST))
	if r >= 15 then return r end
	return math.max(r, get_direct_signal({x = x + 1, y = y, z = z}, EAST))
end
mcl_redstone.get_direct_signal_to = get_direct_signal_to

-- SignalGetter.getSignal
local function get_signal(pos, d)
	local node = get_node(pos)
	local f = B(node.name).get_signal
	local s = f and f(pos, node, d) or 0
	if mcl_redstone.is_conductor(pos, node) then
		return math.max(s, get_direct_signal_to(pos))
	end
	return s
end
mcl_redstone.get_signal = get_signal

function mcl_redstone.has_signal(pos, d)
	return get_signal(pos, d) > 0
end

-- SignalGetter.hasNeighborSignal
function mcl_redstone.has_neighbor_signal(pos)
	local x, y, z = pos.x, pos.y, pos.z
	return get_signal({x = x, y = y - 1, z = z}, DOWN) > 0
		or get_signal({x = x, y = y + 1, z = z}, UP) > 0
		or get_signal({x = x, y = y, z = z + 1}, NORTH) > 0
		or get_signal({x = x, y = y, z = z - 1}, SOUTH) > 0
		or get_signal({x = x - 1, y = y, z = z}, WEST) > 0
		or get_signal({x = x + 1, y = y, z = z}, EAST) > 0
end

-- SignalGetter.getBestNeighborSignal
function mcl_redstone.get_best_neighbor_signal(pos)
	local best = 0
	for i = 1, 6 do
		local d = ALL[i]
		local s = get_signal(mcl_redstone.rel(pos, d), d)
		if s >= 15 then
			return 15
		end
		if s > best then
			best = s
		end
	end
	return best
end

-- SignalGetter.getControlInputSignal
function mcl_redstone.get_control_input_signal(pos, d, only_diodes)
	local node = get_node(pos)
	local b = B(node.name)
	if only_diodes then
		return b.is_diode and get_direct_signal(pos, d) or 0
	end
	local id = block_id(node.name)
	if id == "mcl_redstone_torch:redstoneblock" then
		return 15
	elseif id == "mcl_redstone:redstone" then
		return band(node.param2, 15)
	end
	return is_signal_source(node) and get_direct_signal(pos, d) or 0
end

-- SignalGetter.getBestOwnOrNeighbourSignal
function mcl_redstone.get_best_own_or_neighbour_signal(pos)
	local node = get_node(pos)
	local b = B(node.name)
	local own = is_signal_source(node) and b.own_signal and b.own_signal(pos, node) or 0
	return math.max(mcl_redstone.get_best_neighbor_signal(pos), own)
end

-- Scheduled ticks and block events -----------------------------------------------------

function mcl_redstone._tick_block(pos, block)
	local node = get_node(pos)
	if block_id(node.name) == block then
		local b = B(node.name)
		if b.tick then
			b.tick(pos, node)
		end
	end
end

function mcl_redstone._do_block_event(pos, block, b0, b1)
	local node = get_node(pos)
	if block_id(node.name) == block then
		local b = B(node.name)
		if b.trigger_event then
			b.trigger_event(pos, node, b0, b1)
		end
	end
end

-- Changes made by other code ------------------------------------------------------------

local function external_change(pos, oldnode, newnode)
	local b = B(newnode.name)
	if b.placement then
		local adjusted = b.placement(pos, newnode, oldnode)
		if adjusted and not same_node(adjusted, newnode) then
			write(pos, adjusted, block_id(adjusted.name) ~= block_id(newnode.name))
			newnode = get_node(pos)
		end
	end
	mcl_redstone.node_changed(pos, oldnode, newnode, 3)
end

-- World generation does not cause block updates in Minecraft: changes made
-- by on_generated callbacks are not processed.
local generating = 0
core.register_on_mods_loaded(function()
	local list = core.registered_on_generateds
	for i, func in ipairs(list) do
		list[i] = function(...)
			generating = generating + 1
			local ok, err = pcall(func, ...)
			generating = generating - 1
			if not ok then
				error(err, 0)
			end
		end
	end
end)

core.register_on_node_change(function(pos, oldnode, newnode)
	local h = hash(pos)
	nodecache[h] = nil
	if suppress[h] or generating > 0 or same_node(oldnode, newnode) then
		return
	end
	external_change(pos, oldnode, newnode)
end)

-- Liquids flowing (from the engine's liquid ticker)
core.register_on_liquid_transformed(function(pos_list, node_list)
	for i, pos in ipairs(pos_list) do
		local newnode = core.get_node(pos)
		local oldnode = node_list[i]
		if not same_node(oldnode, newnode) then
			nodecache[hash(pos)] = nil
			mcl_redstone.node_changed(pos, oldnode, newnode, 3)
		end
	end
end)
