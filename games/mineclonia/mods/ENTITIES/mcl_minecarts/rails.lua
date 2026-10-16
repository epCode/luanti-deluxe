local S = core.get_translator(core.get_current_modname())

-- Redstone behaviour of the rails: a port of Minecraft's BaseRailBlock,
-- RailBlock, PoweredRailBlock (powered and activator rails) and
-- DetectorRailBlock.
--
-- Minecraft stores the shape of a rail in its block state.  Luanti's raillike
-- drawtype works the shape out from the neighbouring rails when it draws them
-- (and minecarts follow the same connections), so the shape used here is the
-- one the engine draws, given as a Minecraft RailShape.

local rel = mcl_redstone.rel
local get_node = mcl_redstone.get_node
local block_id = mcl_redstone.block_id
local UP = mcl_redstone.UP
local NORTH, SOUTH, WEST, EAST = mcl_redstone.NORTH, mcl_redstone.SOUTH, mcl_redstone.WEST, mcl_redstone.EAST

-- RailShape
local NORTH_SOUTH, EAST_WEST = 1, 2
local ASCENDING_EAST, ASCENDING_WEST, ASCENDING_NORTH, ASCENDING_SOUTH = 3, 4, 5, 6
local SOUTH_EAST, SOUTH_WEST, NORTH_WEST, NORTH_EAST = 7, 8, 9, 10

local ascending = {
	[NORTH] = ASCENDING_NORTH, [SOUTH] = ASCENDING_SOUTH,
	[WEST] = ASCENDING_WEST, [EAST] = ASCENDING_EAST,
}

-- RailShape.isSlope
local function is_slope(shape)
	return shape >= ASCENDING_EAST and shape <= ASCENDING_SOUTH
end

local RAIL_GROUP = core.raillike_group("rail")

-- Nodes the engine connects rails to (raillike nodes of the rail group), and
-- {block, straight} of the rails with Minecraft behaviour.
local rail_names = {}
local rail_blocks = {}

core.register_on_mods_loaded(function()
	for name, ndef in pairs(core.registered_nodes) do
		if ndef.drawtype == "raillike" and core.get_item_group(name, "connect_to_raillike") == RAIL_GROUP then
			rail_names[name] = true
		end
	end
end)

-- BaseRailBlock.isRail
local function is_rail(pos)
	return rail_names[get_node(pos).name] or false
end

local function up(pos) return vector.offset(pos, 0, 1, 0) end
local function down(pos) return vector.offset(pos, 0, -1, 0) end

-- Order of rail_direction in MapblockMeshGenerator (+Z, -Z, -X, +X)
local DRAW_DIRS = {NORTH, SOUTH, WEST, EAST}

-- The shape the engine draws the rail at pos with (drawRaillikeNode).  If
-- `opos` is given, the node there counts as a rail if `orail` is true.
-- Rails that cannot curve (`straight`) get one of the straight shapes: a
-- junction the straight track through it, a curve or crossing NORTH_SOUTH.
local function get_shape(pos, straight, opos, orail)
	local function rail_at(p)
		if opos and p.x == opos.x and p.y == opos.y and p.z == opos.z then
			return orail
		end
		return is_rail(p)
	end
	local conn = {}
	local slope
	for _, d in ipairs(DRAW_DIRS) do
		local p = rel(pos, d)
		if rail_at(up(p)) then
			slope = d
			conn[d] = true
		elseif rail_at(p) or rail_at(down(p)) then
			conn[d] = true
		end
	end
	if slope then
		return ascending[slope]
	end
	local n, s, w, e = conn[NORTH], conn[SOUTH], conn[WEST], conn[EAST]
	local ns, we = n or s, w or e
	if we and not ns then
		return EAST_WEST
	elseif not we then
		return NORTH_SOUTH
	end
	if not straight then
		if s and e and not n and not w then return SOUTH_EAST end
		if s and w and not n and not e then return SOUTH_WEST end
		if n and w and not s and not e then return NORTH_WEST end
		if n and e and not s and not w then return NORTH_EAST end
	end
	if w and e and not (n and s) then
		return EAST_WEST
	end
	return NORTH_SOUTH
end

-- RailState.updateConnections
local function get_connections(pos, shape)
	if shape == NORTH_SOUTH then
		return {rel(pos, NORTH), rel(pos, SOUTH)}
	elseif shape == EAST_WEST then
		return {rel(pos, WEST), rel(pos, EAST)}
	elseif shape == ASCENDING_EAST then
		return {rel(pos, WEST), up(rel(pos, EAST))}
	elseif shape == ASCENDING_WEST then
		return {up(rel(pos, WEST)), rel(pos, EAST)}
	elseif shape == ASCENDING_NORTH then
		return {up(rel(pos, NORTH)), rel(pos, SOUTH)}
	elseif shape == ASCENDING_SOUTH then
		return {rel(pos, NORTH), up(rel(pos, SOUTH))}
	elseif shape == SOUTH_EAST then
		return {rel(pos, EAST), rel(pos, SOUTH)}
	elseif shape == SOUTH_WEST then
		return {rel(pos, WEST), rel(pos, SOUTH)}
	elseif shape == NORTH_WEST then
		return {rel(pos, WEST), rel(pos, NORTH)}
	end
	return {rel(pos, EAST), rel(pos, NORTH)}
end

-- Block.canSupportRigidBlock (unloaded nodes keep the rail)
local function supports(pos)
	local node = get_node(pos)
	return node.name == "ignore" or mcl_redstone.can_support_rigid_block(pos, node)
end

-- BaseRailBlock.canSurvive
local function can_survive(pos)
	return supports(down(pos))
end

-- BaseRailBlock.shouldBeRemoved
local function should_be_removed(pos, shape)
	if not supports(down(pos)) then
		return true
	elseif shape == ASCENDING_EAST then
		return not supports(rel(pos, EAST))
	elseif shape == ASCENDING_WEST then
		return not supports(rel(pos, WEST))
	elseif shape == ASCENDING_NORTH then
		return not supports(rel(pos, NORTH))
	elseif shape == ASCENDING_SOUTH then
		return not supports(rel(pos, SOUTH))
	end
	return false
end

-- BaseRailBlock.affectNeighborsAfterRemoval, for a rail that had `shape`
local function affect_neighbors_after_removal(pos, block, straight, shape, moved)
	if not moved then
		if is_slope(shape) then
			mcl_redstone.update_neighbors_at(up(pos), block)
		end
		if straight then
			mcl_redstone.update_neighbors_at(pos, block)
			mcl_redstone.update_neighbors_at(down(pos), block)
		end
	end
end

-- The updates of Level.setBlockAndUpdate for a rail whose shape changed
-- from `old_shape` (RailState.connectTo).
local function shape_changed(pos, node, old_shape)
	local info = rail_blocks[node.name]
	-- LevelChunk.setBlockState: rails affect their neighbours on every change
	affect_neighbors_after_removal(pos, info.block, info.straight, old_shape, false)
	mcl_redstone.update_neighbors_at(pos, info.block)
	mcl_redstone.update_neighbour_shapes(pos, node, mcl_redstone.UPDATE_CLIENTS)
end

-- The part of RailState.place that changes other rails: in Minecraft the new
-- rail connects the rails next to it to itself.  The engine reshapes all
-- rails that see the node at pos; tell those whose shape changed.
local function update_connected_rails(pos, oldnode)
	local was_rail = rail_names[oldnode.name] or false
	local now_rail = is_rail(pos)
	if was_rail == now_rail then
		return
	end
	for _, d in ipairs(mcl_redstone.HORIZONTAL) do
		local side = rel(pos, d)
		for _, rpos in ipairs({side, up(side), down(side)}) do
			local rnode = get_node(rpos)
			local info = rail_blocks[rnode.name]
			if info then
				local old_shape = get_shape(rpos, info.straight, pos, was_rail)
				if old_shape ~= get_shape(rpos, info.straight) then
					shape_changed(rpos, rnode, old_shape)
				end
			end
		end
	end
end

-- Behaviour shared by all rails (BaseRailBlock).  `spec.update_state` is
-- updateState(state, level, pos, block), `spec.placed` runs at the end of
-- onPlace with the rail placed.
local function rail_behaviour(block, straight, spec)
	spec = spec or {}
	local update_state = spec.update_state
	local b = {
		block = block,
		-- `newBlock instanceof BaseRailBlock` in LevelChunk.setBlockState
		always_affect_after_removal = true,
		-- Rails pop off through neighborChanged, not through shape updates
		update_shape = function() end,
		-- BaseRailBlock.neighborChanged
		neighbor_changed = function(pos, node, from_block, moved)
			if block_id(get_node(pos).name) ~= block then
				return
			end
			if should_be_removed(pos, get_shape(pos, straight)) then
				mcl_redstone.drop_resources(pos, node)
				mcl_redstone.remove_block(pos, moved)
			elseif update_state then
				update_state(pos, node, from_block)
			end
		end,
		-- BaseRailBlock.onPlace
		on_place = function(pos, node, oldnode, moved)
			if block_id(oldnode.name) == block then
				return
			end
			-- BaseRailBlock.updateState(state, level, pos, movedByPiston):
			-- updateDir, then a neighbour update of itself
			update_connected_rails(pos, oldnode)
			if straight then
				mcl_redstone.neighbor_changed_state(node, pos, block, moved)
			end
			if spec.placed then
				spec.placed(pos, node)
			end
		end,
		affect_neighbors_after_removal = function(pos, oldnode, moved)
			affect_neighbors_after_removal(pos, block, straight, get_shape(pos, straight), moved)
			-- The engine reshapes the rails next to a removed rail
			update_connected_rails(pos, oldnode)
		end,
	}
	for k, v in pairs(spec.fields or {}) do
		b[k] = v
	end
	return b
end

local function register_rail_block(block, straight, names)
	for _, name in ipairs(names) do
		rail_blocks[name] = {block = block, straight = straight}
	end
end

-- PoweredRailBlock (powered rail and activator rail)
local function powered_rail_behaviour(block, off, on)
	local function is_powered(node)
		return node.name == on
	end

	local is_same_rail_with_power

	-- PoweredRailBlock.findPoweredRailSignal (Minecraft's +z is south)
	local function find_powered_rail_signal(pos, shape, forward, depth)
		if depth >= 8 then
			return false
		end
		local x, y, z = pos.x, pos.y, pos.z
		local check_below = true
		if shape == NORTH_SOUTH then
			z = forward and z - 1 or z + 1
		elseif shape == EAST_WEST then
			x = forward and x - 1 or x + 1
		elseif shape == ASCENDING_EAST then
			if forward then
				x = x - 1
			else
				x = x + 1
				y = y + 1
				check_below = false
			end
			shape = EAST_WEST
		elseif shape == ASCENDING_WEST then
			if forward then
				x = x - 1
				y = y + 1
				check_below = false
			else
				x = x + 1
			end
			shape = EAST_WEST
		elseif shape == ASCENDING_NORTH then
			if forward then
				z = z - 1
			else
				z = z + 1
				y = y + 1
				check_below = false
			end
			shape = NORTH_SOUTH
		elseif shape == ASCENDING_SOUTH then
			if forward then
				z = z - 1
				y = y + 1
				check_below = false
			else
				z = z + 1
			end
			shape = NORTH_SOUTH
		end
		local p = vector.new(x, y, z)
		return is_same_rail_with_power(p, forward, depth, shape)
			or check_below and is_same_rail_with_power(down(p), forward, depth, shape)
	end

	-- PoweredRailBlock.isSameRailWithPower
	function is_same_rail_with_power(pos, forward, depth, dir)
		local node = get_node(pos)
		if block_id(node.name) ~= block then
			return false
		end
		local my_shape = get_shape(pos, true)
		if dir == EAST_WEST and (my_shape == NORTH_SOUTH or my_shape == ASCENDING_NORTH or my_shape == ASCENDING_SOUTH) then
			return false
		elseif dir == NORTH_SOUTH and (my_shape == EAST_WEST or my_shape == ASCENDING_EAST or my_shape == ASCENDING_WEST) then
			return false
		elseif not is_powered(node) then
			return false
		end
		return mcl_redstone.has_neighbor_signal(pos) or find_powered_rail_signal(pos, my_shape, forward, depth + 1)
	end

	-- PoweredRailBlock.updateState
	local function update_state(pos, node)
		local powered = is_powered(node)
		local shape = get_shape(pos, true)
		local should_power = mcl_redstone.has_neighbor_signal(pos)
			or find_powered_rail_signal(pos, shape, true, 0)
			or find_powered_rail_signal(pos, shape, false, 0)
		if should_power ~= powered then
			mcl_redstone.set_block(pos, {name = should_power and on or off}, mcl_redstone.UPDATE_ALL)
			mcl_redstone.update_neighbors_at(down(pos), block)
			if is_slope(shape) then
				mcl_redstone.update_neighbors_at(up(pos), block)
			end
		end
	end

	register_rail_block(block, true, {off, on})
	return rail_behaviour(block, true, {update_state = update_state})
end

-- DetectorRailBlock
local DETECTOR = "mcl_minecarts:detector_rail"
local DETECTOR_OFF, DETECTOR_ON = "mcl_minecarts:detector_rail", "mcl_minecarts:detector_rail_on"

local function is_minecart(obj)
	local le = obj:get_luaentity()
	return le and le.name:sub(1, 14) == "mcl_minecarts:" and le or nil
end
mcl_minecarts.is_minecart = is_minecart

-- Bounding box of an AbstractMinecart (0.98 x 0.7, standing on the rail)
function mcl_minecarts.get_minecart_box(p)
	return p.x - 0.49, p.y - 0.5, p.z - 0.49, p.x + 0.49, p.y + 0.2, p.z + 0.49
end

-- DetectorRailBlock.getInteractingMinecartOfType with getSearchBB
local function get_interacting_minecarts(pos, filter)
	local x1, y1, z1 = pos.x - 0.3, pos.y - 0.5, pos.z - 0.3
	local x2, y2, z2 = pos.x + 0.3, pos.y + 0.3, pos.z + 0.3
	local list = {}
	for obj in core.objects_in_area(vector.new(x1 - 1, y1 - 1, z1 - 1), vector.new(x2 + 1, y2 + 1, z2 + 1)) do
		local le = is_minecart(obj)
		local p = le and obj:get_pos()
		if p and (not filter or filter(le)) then
			local bx1, by1, bz1, bx2, by2, bz2 = mcl_minecarts.get_minecart_box(p)
			if bx1 < x2 and bx2 > x1 and by1 < y2 and by2 > y1 and bz1 < z2 and bz2 > z1 then
				list[#list + 1] = le
			end
		end
	end
	return list
end

local function detector_powered(node)
	return node.name == DETECTOR_ON
end

-- DetectorRailBlock.updatePowerToConnected
local function update_power_to_connected(pos)
	for _, cpos in ipairs(get_connections(pos, get_shape(pos, true))) do
		local cnode = get_node(cpos)
		mcl_redstone.neighbor_changed_state(cnode, cpos, block_id(cnode.name), false)
	end
end

-- DetectorRailBlock.checkPressed
local function check_pressed(pos, node)
	if not can_survive(pos) or block_id(get_node(pos).name) ~= DETECTOR then
		return
	end
	local was_pressed = detector_powered(node)
	local should_be_pressed = #get_interacting_minecarts(pos) > 0
	if should_be_pressed ~= was_pressed then
		mcl_redstone.set_block(pos, {name = should_be_pressed and DETECTOR_ON or DETECTOR_OFF}, mcl_redstone.UPDATE_ALL)
		update_power_to_connected(pos)
		mcl_redstone.update_neighbors_at(pos, DETECTOR)
		mcl_redstone.update_neighbors_at(down(pos), DETECTOR)
	end
	if should_be_pressed then
		mcl_redstone.schedule_tick(pos, DETECTOR, 20)
	end
	mcl_redstone.update_neighbour_for_output_signal(pos, DETECTOR)
end

-- DetectorRailBlock.entityInside: a minecart is in the node at pos
function mcl_minecarts.detector_rail_entity_inside(pos, node)
	if not detector_powered(node) then
		check_pressed(pos, node)
	end
end

-- Java float arithmetic: rounds a number to the nearest float (ties to even).
local function fround(x)
	if x == 0 then
		return 0
	end
	local m, e = math.frexp(x)
	local s = m * 16777216
	local r = math.floor(s + 0.5)
	if r - s == 0.5 and r % 2 == 1 then
		r = r - 1
	end
	return math.ldexp(r, e - 24)
end

-- AbstractContainerMenu.getRedstoneSignalFromContainer
local function container_signal(le)
	local inv = mcl_entity_invs.load_inv(le, le._inv_size or 27)
	local list = inv and inv:get_list("main")
	if not list or #list == 0 then
		return 0
	end
	local total = 0
	for _, stack in ipairs(list) do
		if not stack:is_empty() then
			-- Container.getMaxStackSize(stack): the container allows 99
			local max = math.min(99, stack:get_stack_max())
			total = fround(total + fround(stack:get_count() / max))
		end
	end
	total = fround(total / #list)
	-- Mth.lerpDiscrete(total, 0, 15)
	return math.floor(fround(total * 14)) + (total > 0 and 1 or 0)
end

register_rail_block(DETECTOR, true, {DETECTOR_OFF, DETECTOR_ON})
local detector_rail_behaviour = rail_behaviour(DETECTOR, true, {
	-- DetectorRailBlock.onPlace: checkPressed after BaseRailBlock.updateState
	placed = check_pressed,
	fields = {
		signal_source = true,
		own_signal = function(pos, node)
			return detector_powered(node) and 15 or 0
		end,
		get_signal = function(pos, node)
			return detector_powered(node) and 15 or 0
		end,
		get_direct_signal = function(pos, node, d)
			return detector_powered(node) and d == UP and 15 or 0
		end,
		tick = function(pos, node)
			if detector_powered(node) then
				check_pressed(pos, node)
			end
		end,
		analog_output = function(pos, node)
			if detector_powered(node) then
				local command_blocks = get_interacting_minecarts(pos, function(le)
					return le.name == "mcl_minecarts:command_block_minecart"
				end)
				if #command_blocks > 0 then
					-- getCommandBlock().getSuccessCount(): these minecarts
					-- don't run commands
					return 0
				end
				local containers = get_interacting_minecarts(pos, function(le)
					return le._inv_size ~= nil
				end)
				if #containers > 0 then
					return container_signal(containers[1])
				end
			end
			return 0
		end,
	},
})

-- RailBlock (normal rails).  Its updateState switches T-junctions powered by
-- a redstone signal source, which the engine's rail shapes can't do.
register_rail_block("mcl_minecarts:rail", false, {"mcl_minecarts:rail"})
local rail_rail_behaviour = rail_behaviour("mcl_minecarts:rail", false)

-- Template rail function
local function register_rail(itemstring, tiles, def_extras, creative)
	local groups = {handy=1,pickaxey=1, attached_node=1,rail=1,connect_to_raillike=core.raillike_group("rail"),transport=1, no_spawning_inside=1}
	if creative == false then
		groups.not_in_creative_inventory = 1
	end
	local ndef = {
		drawtype = "raillike",
		tiles = tiles,
		is_ground_content = false,
		inventory_image = tiles[1],
		wield_image = tiles[1],
		paramtype = "light",
		walkable = false,
		selection_box = {
			type = "fixed",
			fixed = {-1/2, -1/2, -1/2, 1/2, -1/2+1/16, 1/2},
		},
		groups = groups,
		sounds = mcl_sounds.node_sound_metal_defaults(),
		_mcl_hardness = 0.7,
		after_destruct = function(pos)
			-- Scan for minecarts in this pos and force them to execute their "floating" check.
			-- Normally, this will make them drop.
			for obj in core.objects_inside_radius(pos, 1) do
				local le = obj:get_luaentity()
				if le then
					-- All entities in this mod are minecarts, so this works
					if string.sub(le.name, 1, 14) == "mcl_minecarts:" then
						le._last_float_check = mcl_minecarts.check_float_time
					end
				end
			end
		end,
	}
	if def_extras then
		for k,v in pairs(def_extras) do
			ndef[k] = v
		end
	end
	core.register_node(itemstring, ndef)
end

local railuse = S("Place them on the ground to build your railway, the rails will automatically connect to each other and will turn into curves, T-junctions, crossings and slopes as needed.")

-- Normal rail
register_rail("mcl_minecarts:rail",
	{"default_rail.png", "default_rail_curved.png", "default_rail_t_junction.png", "default_rail_crossing.png"},
	{
		description = S("Rail"),
		_tt_help = S("Track for minecarts"),
		_doc_items_longdesc = S("Rails can be used to build transport tracks for minecarts. Normal rails slightly slow down minecarts due to friction."),
		_doc_items_usagehelp = railuse,
		_mcl_redstone = rail_rail_behaviour,
	}
)

local golden_rail_behaviour = powered_rail_behaviour("mcl_minecarts:golden_rail",
	"mcl_minecarts:golden_rail", "mcl_minecarts:golden_rail_on")

-- Powered rail (off = brake mode)
register_rail("mcl_minecarts:golden_rail",
	{"mcl_minecarts_rail_golden.png", "mcl_minecarts_rail_golden_curved.png", "mcl_minecarts_rail_golden_t_junction.png", "mcl_minecarts_rail_golden_crossing.png"},
	{
		description = S("Powered Rail"),
		_tt_help = S("Track for minecarts").."\n"..S("Speed up when powered, slow down when not powered"),
		_doc_items_longdesc = S("Rails can be used to build transport tracks for minecarts. Powered rails are able to accelerate and brake minecarts."),
		_doc_items_usagehelp = railuse .. "\n" .. S("Without redstone power, the rail will brake minecarts. To make this rail accelerate minecarts, power it with redstone power."),
		_rail_acceleration = -3,
		_mcl_redstone = golden_rail_behaviour,
	}
)

-- Powered rail (on = acceleration mode)
register_rail("mcl_minecarts:golden_rail_on",
	{"mcl_minecarts_rail_golden_powered.png", "mcl_minecarts_rail_golden_curved_powered.png", "mcl_minecarts_rail_golden_t_junction_powered.png", "mcl_minecarts_rail_golden_crossing_powered.png"},
	{
		_doc_items_create_entry = false,
		_rail_acceleration = 4,
		_mcl_redstone = golden_rail_behaviour,
		drop = "mcl_minecarts:golden_rail",
	},
	false
)

local activator_rail_behaviour = powered_rail_behaviour("mcl_minecarts:activator_rail",
	"mcl_minecarts:activator_rail", "mcl_minecarts:activator_rail_on")

-- Activator rail (off)
register_rail("mcl_minecarts:activator_rail",
	{"mcl_minecarts_rail_activator.png", "mcl_minecarts_rail_activator_curved.png", "mcl_minecarts_rail_activator_t_junction.png", "mcl_minecarts_rail_activator_crossing.png"},
	{
		description = S("Activator Rail"),
		_tt_help = S("Track for minecarts").."\n"..S("Activates minecarts when powered"),
		_doc_items_longdesc = S("Rails can be used to build transport tracks for minecarts. Activator rails are used to activate special minecarts."),
		_doc_items_usagehelp = railuse .. "\n" .. S("To make this rail activate minecarts, power it with redstone power and send a minecart over this piece of rail."),
		_mcl_redstone = activator_rail_behaviour,
	}
)

-- Activator rail (on)
register_rail("mcl_minecarts:activator_rail_on",
	{"mcl_minecarts_rail_activator_powered.png", "mcl_minecarts_rail_activator_curved_powered.png", "mcl_minecarts_rail_activator_t_junction_powered.png", "mcl_minecarts_rail_activator_crossing_powered.png"},
	{
		_doc_items_create_entry = false,
		_mcl_redstone = activator_rail_behaviour,
		drop = "mcl_minecarts:activator_rail",
	},
	false
)

-- Detector rail (off)
register_rail("mcl_minecarts:detector_rail",
	{"mcl_minecarts_rail_detector.png", "mcl_minecarts_rail_detector_curved.png", "mcl_minecarts_rail_detector_t_junction.png", "mcl_minecarts_rail_detector_crossing.png"},
	{
		description = S("Detector Rail"),
		_tt_help = S("Track for minecarts").."\n"..S("Emits redstone power when a minecart is detected"),
		_doc_items_longdesc = S("Rails can be used to build transport tracks for minecarts. A detector rail is able to detect a minecart above it and powers redstone mechanisms."),
		_doc_items_usagehelp = railuse .. "\n" .. S("To detect a minecart and provide redstone power, connect it to redstone trails or redstone mechanisms and send any minecart over the rail."),
		_mcl_redstone = detector_rail_behaviour,
	}
)

-- Detector rail (on)
register_rail("mcl_minecarts:detector_rail_on",
	{"mcl_minecarts_rail_detector_powered.png", "mcl_minecarts_rail_detector_curved_powered.png", "mcl_minecarts_rail_detector_t_junction_powered.png", "mcl_minecarts_rail_detector_crossing_powered.png"},
	{
		_doc_items_create_entry = false,
		_mcl_redstone = detector_rail_behaviour,
		drop = "mcl_minecarts:detector_rail",
	},
	false
)

-- Detector rails from older worlds were switched off by the minecart leaving
-- them; give them the scheduled check of a pressed detector rail.
core.register_lbm({
	label = "Check pressed detector rails",
	name = "mcl_minecarts:detector_rail_check",
	nodenames = {DETECTOR_ON},
	run_at_every_load = false,
	action = function(pos)
		if not mcl_redstone.has_scheduled_tick(pos, DETECTOR) then
			mcl_redstone.schedule_tick(pos, DETECTOR, 20)
		end
	end,
})

-- Crafting
core.register_craft({
	output = "mcl_minecarts:rail 16",
	recipe = {
		{"mcl_core:iron_ingot", "", "mcl_core:iron_ingot"},
		{"mcl_core:iron_ingot", "mcl_core:stick", "mcl_core:iron_ingot"},
		{"mcl_core:iron_ingot", "", "mcl_core:iron_ingot"},
	}
})

core.register_craft({
	output = "mcl_minecarts:golden_rail 6",
	recipe = {
		{"mcl_core:gold_ingot", "", "mcl_core:gold_ingot"},
		{"mcl_core:gold_ingot", "mcl_core:stick", "mcl_core:gold_ingot"},
		{"mcl_core:gold_ingot", "mcl_redstone:redstone", "mcl_core:gold_ingot"},
	}
})

core.register_craft({
	output = "mcl_minecarts:activator_rail 6",
	recipe = {
		{"mcl_core:iron_ingot", "mcl_core:stick", "mcl_core:iron_ingot"},
		{"mcl_core:iron_ingot", "mcl_redstone_torch:redstone_torch_on", "mcl_core:iron_ingot"},
		{"mcl_core:iron_ingot", "mcl_core:stick", "mcl_core:iron_ingot"},
	}
})

core.register_craft({
	output = "mcl_minecarts:detector_rail 6",
	recipe = {
		{"mcl_core:iron_ingot", "", "mcl_core:iron_ingot"},
		{"mcl_core:iron_ingot", "mcl_pressureplates:pressure_plate_stone_off", "mcl_core:iron_ingot"},
		{"mcl_core:iron_ingot", "mcl_redstone:redstone", "mcl_core:iron_ingot"},
	}
})


doc.add_entry_alias("nodes", "mcl_minecarts:golden_rail", "nodes", "mcl_minecarts:golden_rail_on")

