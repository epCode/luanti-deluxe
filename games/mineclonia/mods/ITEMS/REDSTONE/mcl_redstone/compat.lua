-- The previous mcl_redstone API, implemented on top of the Minecraft port.
--
-- Old style `_mcl_redstone` definitions ({get_power, update, init,
-- connects_to, on_observer_neighbor_change}) keep working: `update` runs on
-- neighbour updates and its result is applied after `delay` redstone ticks.

local DOWN, UP = 0, 1
local dirvec = mcl_redstone.dirvec
local opposite = mcl_redstone.opposite
local get_node = mcl_redstone.get_node
local hash = mcl_redstone.hash

-- Pending old style updates by position: {priority, node}
local pending_updates = {}

local function apply_update(pos, ret)
	local delay = ret.delay or 1
	local priority = ret.priority or 1000
	local h = hash(pos)
	local current = pending_updates[h]
	if current and priority >= current.priority then
		return
	end
	local oldnode = get_node(pos)
	local node = {name = ret.name, param2 = ret.param2 or 0}
	if mcl_redstone.same_node(node, oldnode) then
		pending_updates[h] = nil
		return
	end
	local entry = {priority = priority, node = node, oldnode = oldnode}
	pending_updates[h] = entry
	pos = vector.copy(pos)
	mcl_redstone.after_ticks(delay * 2, function()
		if pending_updates[h] ~= entry then
			return
		end
		pending_updates[h] = nil
		if mcl_redstone.same_node(get_node(pos), entry.oldnode) then
			mcl_redstone.set_block(pos, entry.node, 3)
		end
	end)
end

function mcl_redstone._compat_behaviour(name, rs)
	local b = {}
	if rs.get_power then
		b.signal_source = true
		b.get_signal = function(pos, node, d)
			return rs.get_power(node, dirvec[opposite[d]]) or 0
		end
		b.get_direct_signal = function(pos, node, d)
			local p, strong = rs.get_power(node, dirvec[opposite[d]])
			return strong and p or 0
		end
		b.own_signal = function(pos, node)
			local best = 0
			for d = 0, 5 do
				best = math.max(best, rs.get_power(node, dirvec[d]) or 0)
			end
			return best
		end
	end
	if rs.connects_to then
		b.wire_connects = function(pos, node, d)
			return d ~= nil and rs.connects_to(node, dirvec[opposite[d]]) or false
		end
	elseif rs.get_power then
		b.wire_connects = function(pos, node, d)
			return d ~= nil
		end
	end
	local update = rs.update
	if update then
		b.neighbor_changed = function(pos, node)
			local ret = update(pos, node)
			if ret then
				apply_update(pos, ret)
			end
		end
	end
	local init = rs.init or update
	if init then
		b.on_place = function(pos, node, oldnode)
			if mcl_redstone.block_id(oldnode.name) == mcl_redstone.block_id(node.name) then
				return
			end
			local ret = init(pos, node)
			if ret then
				apply_update(pos, ret)
			end
		end
		b._compat_init = init
	end
	if rs.on_observer_neighbor_change then
		b.update_shape = function(pos, node, d, npos)
			rs.on_observer_neighbor_change(pos, node, npos)
		end
	end
	return b
end

-- Old style init callbacks also run when their mapblock is loaded.
core.register_on_mods_loaded(function()
	local names = {}
	for name, b in pairs(mcl_redstone._blocks) do
		if b._compat_init then
			table.insert(names, name)
		end
	end
	if #names > 0 then
		core.register_lbm({
			label = "Initialise old style redstone components",
			name = "mcl_redstone:compat_init",
			nodenames = names,
			run_at_every_load = true,
			action = function(pos, node)
				local b = mcl_redstone._blocks[node.name]
				local ret = b and b._compat_init and b._compat_init(pos, node)
				if ret then
					apply_update(pos, ret)
				end
			end,
		})
	end
end)

-- Power coming into pos from direction dir (relative to pos, so (0, 1, 0)
-- means from above), or the best of all directions.  With option "direct",
-- power through conductive blocks is ignored.
function mcl_redstone.get_power(pos, dir, option)
	mcl_redstone._begin()
	local power
	if dir then
		local d = mcl_redstone.dir_index(dir)
		local p = vector.add(pos, dir)
		if option == "direct" then
			local node = get_node(p)
			local f = mcl_redstone.get_block(node.name).get_signal
			power = f and f(p, node, d) or 0
		else
			power = mcl_redstone.get_signal(p, d)
		end
	elseif option == "direct" then
		power = 0
		for d = 0, 5 do
			local p = mcl_redstone.rel(pos, d)
			local node = get_node(p)
			local f = mcl_redstone.get_block(node.name).get_signal
			power = math.max(power, f and f(p, node, d) or 0)
		end
	else
		power = mcl_redstone.get_best_neighbor_signal(pos)
	end
	mcl_redstone._end()
	return power
end

-- Level.setBlockAndUpdate
function mcl_redstone.swap_node(pos, node)
	return mcl_redstone.set_block(pos, node, 3)
end

-- Runs the neighbour update of the node at pos.
function mcl_redstone.update_node(pos)
	mcl_redstone.neighbor_changed(pos, mcl_redstone.block_id(get_node(pos).name))
end

-- Tells comparators reading the node at pos that its contents changed.
function mcl_redstone.update_comparators(pos)
	mcl_redstone.update_neighbour_for_output_signal(pos, mcl_redstone.block_id(get_node(pos).name))
end

-- Shape updates to the neighbours of pos (observers etc.)
function mcl_redstone._notify_observer_neighbours(pos)
	mcl_redstone.update_neighbour_shapes(pos, get_node(pos), 2)
end

function mcl_redstone._update_neighbours(pos, oldnode, newnode)
	newnode = newnode or get_node(pos)
	mcl_redstone.node_changed(pos, oldnode or {name = "air", param2 = 0}, newnode, 3)
end

-- Nodes that conduct redstone power, by name (values are 0).
mcl_redstone._solid_opaque_tab = setmetatable({}, {
	__index = function(_, name)
		local def = core.registered_nodes[name]
		if not def then
			return nil
		end
		return mcl_redstone.is_conductor(vector.zero(), {name = name, param2 = 0}) and 0 or nil
	end,
})

mcl_redstone._slab_tab = setmetatable({}, {
	__index = function(_, name)
		return core.get_item_group(name, "slab_top") ~= 0 and 0 or nil
	end,
})

function mcl_redstone._update_opaque_connections() end
function mcl_redstone._connect_with_wires() end
function mcl_redstone._update_wire_shape_neighbours(pos)
	mcl_redstone._notify_observer_neighbours(pos)
end
function mcl_redstone._abort_pending_update(pos)
	pending_updates[hash(pos)] = nil
end
