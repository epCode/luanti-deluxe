-- Redstone dust: port of Minecraft's RedstoneWireBlock with the default
-- (non experimental) wire evaluator.
--
-- The connection of each horizontal side (none, side or up) is stored in the
-- node name ("wireflags", see below), the power level in param2.

local S = core.get_translator(core.get_current_modname())

local bit = bit
local band, bor, bnot, lshift = bit.band, bit.bor, bit.bnot, bit.lshift

local DOWN, UP, NORTH, SOUTH, WEST, EAST = 0, 1, 2, 3, 4, 5
local NONE, SIDE, UPSIDE = 0, 1, 2
local HORIZONTAL = mcl_redstone.HORIZONTAL
local opposite = mcl_redstone.opposite
local rel = mcl_redstone.rel
local get_node = mcl_redstone.get_node
local is_conductor = mcl_redstone.is_conductor

local WIRE = "mcl_redstone:redstone"

--- Wireflags are numbers with binary representation YYYYXXXX where XXXX
--- tells which of the four sides are connected and YYYY which of those also
--- go up the neighbouring block.  Bits (right to left): -Z, -X, +Z, +X.
local wireflag_tab = {}
mcl_redstone._wireflag_tab = wireflag_tab

local side_bit = {[SOUTH] = 0x1, [WEST] = 0x2, [NORTH] = 0x4, [EAST] = 0x8}

local function get_side(flags, d)
	local m = side_bit[d]
	if band(flags, lshift(m, 4)) ~= 0 then
		return UPSIDE
	elseif band(flags, m) ~= 0 then
		return SIDE
	end
	return NONE
end

local function set_side(flags, d, v)
	local m = side_bit[d]
	flags = band(flags, bnot(bor(m, lshift(m, 4))))
	if v == SIDE then
		flags = bor(flags, m)
	elseif v == UPSIDE then
		flags = bor(flags, m, lshift(m, 4))
	end
	return flags
end

local function is_connected(flags, d)
	return band(flags, side_bit[d]) ~= 0
end

local function is_dot(flags)
	return band(flags, 0xF) == 0
end

local function is_cross(flags)
	return band(flags, 0xF) == 0xF
end

local CROSS = 0x0F

local function wireflags_to_name(flags)
	return flags == 0 and WIRE or "mcl_redstone:wire_" .. bit.tohex(flags, 2)
end

local function make_node(flags, power)
	return {name = wireflags_to_name(flags), param2 = power}
end

local function node_flags(node)
	return wireflag_tab[node.name]
end

local function node_power(node)
	return band(node.param2, 0xF)
end

local function is_wire(node)
	return wireflag_tab[node.name] ~= nil
end

local function wire_power(node)
	return wireflag_tab[node.name] and band(node.param2, 0xF) or 0
end

-- RedstoneWireBlock.shouldConnectTo(state, level, pos, direction)
local function should_connect_to(pos, node, d)
	local b = mcl_redstone.get_block(node.name)
	local f = b.wire_connects
	if f ~= nil then
		if type(f) == "function" then
			return f(pos, node, d)
		end
		return f
	end
	return mcl_redstone.is_signal_source(node) and d ~= nil
end

local function should_connect_to_pos(pos)
	return should_connect_to(pos, get_node(pos), nil)
end

local function is_hopper(node)
	return node.name:sub(1, 18) == "mcl_hoppers:hopper"
end

-- RedstoneWireBlock.canSurviveOn
local function can_survive_on(pos, node)
	return mcl_redstone.is_face_sturdy(pos, node, UP, "full") or is_hopper(node)
end

local function can_survive(pos)
	local below = rel(pos, DOWN)
	return can_survive_on(below, get_node(below))
end

-- RedstoneWireBlock.getConnectingSide
local function get_connecting_side(pos, d, can_connect_up)
	if can_connect_up == nil then
		local above = rel(pos, UP)
		can_connect_up = not is_conductor(above, get_node(above))
	end
	local rpos = rel(pos, d)
	local rnode = get_node(rpos)
	if can_connect_up then
		local placeable_above = core.get_item_group(rnode.name, "trapdoor") ~= 0 or can_survive_on(rpos, rnode)
		if placeable_above and should_connect_to_pos(rel(rpos, UP)) then
			if mcl_redstone.is_face_sturdy(rpos, rnode, opposite[d], "full") then
				return UPSIDE
			end
			return SIDE
		end
	end
	if not should_connect_to(rpos, rnode, d)
			and (is_conductor(rpos, rnode) or not should_connect_to_pos(rel(rpos, DOWN))) then
		return NONE
	end
	return SIDE
end

-- RedstoneWireBlock.getMissingConnections (from a state with all sides NONE)
local function get_missing_connections(pos, flags)
	local above = rel(pos, UP)
	local can_connect_up = not is_conductor(above, get_node(above))
	for _, d in ipairs(HORIZONTAL) do
		if not is_connected(flags, d) then
			flags = set_side(flags, d, get_connecting_side(pos, d, can_connect_up))
		end
	end
	return flags
end

-- RedstoneWireBlock.getConnectionState
local function get_connection_state(pos, flags)
	local was_dot = is_dot(flags)
	flags = get_missing_connections(pos, 0)
	if was_dot and is_dot(flags) then
		return flags
	end
	local north = is_connected(flags, NORTH)
	local south = is_connected(flags, SOUTH)
	local east = is_connected(flags, EAST)
	local west = is_connected(flags, WEST)
	local north_south_empty = not north and not south
	local east_west_empty = not east and not west
	if not west and north_south_empty then flags = set_side(flags, WEST, SIDE) end
	if not east and north_south_empty then flags = set_side(flags, EAST, SIDE) end
	if not north and east_west_empty then flags = set_side(flags, NORTH, SIDE) end
	if not south and east_west_empty then flags = set_side(flags, SOUTH, SIDE) end
	return flags
end

-- Turned off while a wire measures the signal of its neighbours.
local should_signal = true

-- RedstoneWireBlock.getBlockSignal
local function get_block_signal(pos)
	should_signal = false
	local ok, s = pcall(mcl_redstone.get_best_neighbor_signal, pos)
	should_signal = true
	if not ok then
		error(s, 0)
	end
	return s
end

-- RedstoneWireEvaluator.getIncomingWireSignal
local function get_incoming_wire_signal(pos)
	local signal = 0
	local above = rel(pos, UP)
	local above_conductor = is_conductor(above, get_node(above))
	for _, d in ipairs(HORIZONTAL) do
		local npos = rel(pos, d)
		local nnode = get_node(npos)
		signal = math.max(signal, wire_power(nnode))
		local conductor = is_conductor(npos, nnode)
		if conductor and not above_conductor then
			signal = math.max(signal, wire_power(get_node(rel(npos, UP))))
		elseif not conductor then
			signal = math.max(signal, wire_power(get_node(rel(npos, DOWN))))
		end
	end
	return math.max(0, signal - 1)
end

-- DefaultRedstoneWireEvaluator.calculateTargetStrength
local function calculate_target_strength(pos)
	local block_signal = get_block_signal(pos)
	if block_signal == 15 then
		return 15
	end
	return math.max(block_signal, get_incoming_wire_signal(pos))
end

-- DefaultRedstoneWireEvaluator.updatePowerStrength
local function update_power_strength(pos, node)
	local target = calculate_target_strength(pos)
	if node_power(node) == target then
		return
	end
	if mcl_redstone.same_node(get_node(pos), node) then
		mcl_redstone.set_block(pos, {name = node.name, param2 = target}, 2)
	end
	local list = {pos}
	for d = 0, 5 do
		list[#list + 1] = rel(pos, d)
	end
	for _, p in ipairs(mcl_redstone.java_hash_order(list)) do
		mcl_redstone.update_neighbors_at(p, WIRE)
	end
end

-- RedstoneWireBlock.checkCornerChangeAt
local function check_corner_change_at(pos)
	if is_wire(get_node(pos)) then
		mcl_redstone.update_neighbors_at(pos, WIRE)
		for d = 0, 5 do
			mcl_redstone.update_neighbors_at(rel(pos, d), WIRE)
		end
	end
end

-- RedstoneWireBlock.updateNeighborsOfNeighboringWires
local function update_neighbors_of_neighboring_wires(pos)
	for _, d in ipairs(HORIZONTAL) do
		check_corner_change_at(rel(pos, d))
	end
	for _, d in ipairs(HORIZONTAL) do
		local target = rel(pos, d)
		if is_conductor(target, get_node(target)) then
			check_corner_change_at(rel(target, UP))
		else
			check_corner_change_at(rel(target, DOWN))
		end
	end
end

-- RedstoneWireBlock.updatesOnShapeChange
local function updates_on_shape_change(pos, oldflags, newflags)
	for _, d in ipairs(HORIZONTAL) do
		local rpos = rel(pos, d)
		if is_connected(oldflags, d) ~= is_connected(newflags, d) and is_conductor(rpos, get_node(rpos)) then
			mcl_redstone.update_neighbors_at_except(rpos, WIRE, opposite[d])
		end
	end
end

local behaviour = {
	block = WIRE,
	wire_connects = true,
	signal_source = function()
		return should_signal
	end,
	get_signal = function(pos, node, d)
		if not should_signal or d == DOWN then
			return 0
		end
		local power = node_power(node)
		if power == 0 then
			return 0
		end
		if d ~= UP and not is_connected(get_connection_state(pos, node_flags(node)), opposite[d]) then
			return 0
		end
		return power
	end,
	own_signal = function(pos, node)
		return node_power(node)
	end,
	placement = function(pos, node, oldnode)
		if is_wire(oldnode) then
			return
		end
		-- getStateForPlacement starts from the cross shape
		return make_node(get_connection_state(pos, CROSS), node_power(node))
	end,
	update_shape = function(pos, node, d, npos, nnode)
		local flags = node_flags(node)
		local power = node_power(node)
		if d == DOWN then
			if not can_survive_on(npos, nnode) then
				return {name = "air"}
			end
			return nil
		elseif d == UP then
			return make_node(get_connection_state(pos, flags), power)
		end
		local side = get_connecting_side(pos, d)
		if (side ~= NONE) == is_connected(flags, d) and not is_cross(flags) then
			return make_node(set_side(flags, d, side), power)
		end
		return make_node(get_connection_state(pos, set_side(CROSS, d, side)), power)
	end,
	update_indirect_neighbour_shapes = function(pos, node, flags, limit)
		local wflags = node_flags(node)
		for _, d in ipairs(HORIZONTAL) do
			if get_side(wflags, d) ~= NONE and not is_wire(get_node(rel(pos, d))) then
				local below = rel(rel(pos, d), DOWN)
				if is_wire(get_node(below)) then
					local npos = rel(below, opposite[d])
					mcl_redstone.neighbor_shape_changed(opposite[d], below, npos, get_node(npos), flags, limit)
				end
				local above = rel(rel(pos, d), UP)
				if is_wire(get_node(above)) then
					local npos = rel(above, opposite[d])
					mcl_redstone.neighbor_shape_changed(opposite[d], above, npos, get_node(npos), flags, limit)
				end
			end
		end
	end,
	on_place = function(pos, node, oldnode)
		if mcl_redstone.block_id(oldnode.name) == WIRE then
			return
		end
		update_power_strength(pos, node)
		for _, d in ipairs(mcl_redstone.VERTICAL) do
			mcl_redstone.update_neighbors_at(rel(pos, d), WIRE)
		end
		update_neighbors_of_neighboring_wires(pos)
	end,
	affect_neighbors_after_removal = function(pos, oldnode, moved)
		if moved then
			return
		end
		for d = 0, 5 do
			mcl_redstone.update_neighbors_at(rel(pos, d), WIRE)
		end
		update_power_strength(pos, oldnode)
		update_neighbors_of_neighboring_wires(pos)
	end,
	neighbor_changed = function(pos, node)
		if can_survive(pos) then
			update_power_strength(pos, node)
		else
			mcl_redstone.drop_resources(pos, node)
			mcl_redstone.remove_block(pos, false)
		end
	end,
	push_reaction = "destroy",
}
-- RedstoneWireBlock.spawnParticlesAlongLine
local function particles_along_line(name, pos, color, side, along, from, to)
	local span = to - from
	if math.random() >= 0.2 * span then
		return
	end
	local s, a = mcl_redstone.dirvec[side], mcl_redstone.dirvec[along]
	local t = from + span * math.random()
	mcl_redstone.dust_particle(name, vector.new(
		pos.x + 0.4375 * s.x + t * a.x,
		pos.y + 0.4375 * s.y + t * a.y,
		pos.z + 0.4375 * s.z + t * a.z), color)
end

-- RedstoneWireBlock.animateTick
behaviour.animate = function(pos, node, name)
	local power = node_power(node)
	if power == 0 then
		return
	end
	local flags = node_flags(node)
	local color = mcl_redstone.wire_colors[power]
	for _, d in ipairs(HORIZONTAL) do
		local c = get_side(flags, d)
		if c == UPSIDE then
			particles_along_line(name, pos, color, d, UP, -0.5, 0.5)
		end
		if c == UPSIDE or c == SIDE then
			particles_along_line(name, pos, color, DOWN, d, 0, 0.5)
		else
			particles_along_line(name, pos, color, DOWN, d, 0, 0.3)
		end
	end
end

behaviour.get_direct_signal = function(pos, node, d)
	if not should_signal then
		return 0
	end
	return behaviour.get_signal(pos, node, d)
end

-- RedstoneWireBlock.useWithoutItem: toggle between dot and cross
local function on_rightclick(pos, node, clicker, itemstack)
	if clicker and clicker:is_player() then
		local pname = clicker:get_player_name()
		if core.is_protected(pos, pname) then
			core.record_protection_violation(pos, pname)
			return itemstack
		end
	end
	local flags = node_flags(node)
	if is_cross(flags) or is_dot(flags) then
		mcl_redstone._begin()
		local newflags = get_connection_state(pos, is_cross(flags) and 0 or CROSS)
		if newflags ~= flags then
			mcl_redstone.set_block(pos, make_node(newflags, node_power(node)), 3)
			updates_on_shape_change(pos, flags, newflags)
		end
		mcl_redstone._end()
	end
	return itemstack
end

-- BlockItem.place checks canSurvive
local function on_place(itemstack, placer, pointed_thing)
	if pointed_thing.type ~= "node" then
		return itemstack
	end
	local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
	if rc then return rc end
	local under = core.get_node(pointed_thing.under)
	local udef = core.registered_nodes[under.name]
	local pos = udef and udef.buildable_to and pointed_thing.under or pointed_thing.above
	if not can_survive(pos) then
		return itemstack
	end
	return core.item_place_node(itemstack, placer, pointed_thing)
end

-- Node registration -------------------------------------------------------------

local nodebox_wire = {
	{-1/16, -.5, -8/16, 1/16, -.5+1/64, -1/16}, -- z negative
	{-8/16, -.5, -1/16, -1/16, -.5+1/64, 1/16}, -- x negative
	{-1/16, -.5, 1/16, 1/16, -.5+1/64, 8/16}, -- z positive
	{1/16, -.5, -1/16, 8/16, -.5+1/64, 1/16}, -- x positive
}

local connected_nodebox_wire = {
	{name = "connect_front", nodebox = {-1/16, -.5+1/16, -.5, 1/16, .4999+1/64, -.5+1/16}}, -- z negative up
	{name = "connect_left", nodebox = {-.5, -.5+1/16, -1/16, -.5+1/16, .4999+1/64, 1/16}}, -- x negative up
	{name = "connect_back", nodebox = {-1/16, -.5+1/16, .5-1/16, 1/16, .4999+1/64, .5}}, -- z positive up
	{name = "connect_right", nodebox = {.5-1/16, -.5+1/16, -1/16, .5, .4999+1/64, 1/16}}, -- x positive up
}
local box_center = {-1/16, -.5, -1/16, 1/16, -.5+1/64, 1/16}
local box_bump = {-2/16, -8/16, -2/16, 2/16, -.5+1/64, 2/16}

local selectionbox = {
	type = "fixed",
	fixed = {-.5, -.5, -.5, .5, -.5+1/16, .5}
}

local cross_tile = "redstone_redstone_dust_dot.png^redstone_redstone_dust_line0.png^(redstone_redstone_dust_line1.png^[transformR90)"
local line_tile = "redstone_redstone_dust_line0.png"
local dot_tile = "redstone_redstone_dust_dot.png"

-- Wireflags that Minecraft can produce: a single connection always extends
-- to the opposite side, and only connected sides can go up.
local function is_legal(flags)
	local sides = band(flags, 0xF)
	if band(flags, bnot(lshift(sides, 4) + 0xF)) ~= 0 then
		return false
	end
	return sides ~= 0x1 and sides ~= 0x2 and sides ~= 0x4 and sides ~= 0x8
end

for flags = 0, 255 do
	if is_legal(flags) then
		local tt, longdesc, usagehelp, nodebox, tiles
		if flags == 0 then
			tt = S("Transmits redstone power, powers mechanisms")
			longdesc = S("Redstone is a versatile conductive mineral which transmits redstone power. It can be placed on the ground as a trail.").."\n"..
				S("A redstone trail can be in two states: Powered or not powered. A powered redstone trail will power (and thus activate) adjacent redstone components.").."\n"..
				S("Redstone power can be received from various redstone components, such as a block of redstone or a button. Redstone power is used to activate numerous mechanisms, such as redstone lamps or pistons.")
			usagehelp = S("Place redstone on the ground to build a redstone trail. The trails will connect to each other automatically and it can also go over hills.").."\n\n"..
				S("Read the help entries on the other redstone components to learn how redstone components interact.")
			tiles = {dot_tile, dot_tile, "blank.png", "blank.png", "blank.png", "blank.png"}
			nodebox = {type = "fixed", fixed = {-8/16, -.5, -8/16, 8/16, -.5+1/64, 8/16}}
		else
			tiles = {cross_tile, cross_tile, line_tile, line_tile, line_tile, line_tile}
			nodebox = {type = "connected", fixed = {box_center}}
			for i = 0, 3 do
				if band(flags, lshift(1, i)) ~= 0 then
					table.insert(nodebox.fixed, nodebox_wire[i + 1])
				end
			end
			for i = 4, 7 do
				if band(flags, lshift(1, i)) ~= 0 then
					nodebox[connected_nodebox_wire[i - 3].name] = connected_nodebox_wire[i - 3].nodebox
				end
			end
			if band(flags, 0xA) ~= 0 and band(flags, 0x5) ~= 0 then
				table.insert(nodebox.fixed, box_bump)
			end
			doc.add_entry_alias("nodes", WIRE, "nodes", wireflags_to_name(flags))
		end

		local name = wireflags_to_name(flags)
		core.register_node(name, {
			drawtype = "nodebox",
			connects_to = {"group:solid"},
			paramtype = "light",
			paramtype2 = "color",
			palette = "mcl_redstone_palette_power.png",
			use_texture_alpha = "clip",
			sunlight_propagates = true,
			selection_box = selectionbox,
			node_box = nodebox,
			tiles = tiles,
			walkable = false,
			drop = WIRE,
			sounds = mcl_sounds.node_sound_defaults(),
			is_ground_content = false,
			groups = {redstone_wire = 1, dig_immediate = 3, attached_node = 1, dig_by_water = 1,
				destroy_by_lava_flow = 1, dig_by_piston = 1, unsticky = 1, craftitem = 1,
				not_in_creative_inventory = flags ~= 0 and 1 or 0},
			description = S("Redstone Dust"),
			_tt_help = tt,
			_doc_items_create_entry = longdesc and true or false,
			_doc_items_longdesc = longdesc,
			_doc_items_usagehelp = usagehelp,
			wield_image = flags == 0 and "redstone_redstone_dust.png" or nil,
			inventory_image = flags == 0 and "redstone_redstone_dust.png" or nil,
			on_rightclick = on_rightclick,
			on_place = flags == 0 and on_place or nil,
			_mcl_redstone = behaviour,
			_mcl_armor_trim_color = flags == 0 and "#e80202" or nil,
			_mcl_armor_trim_desc = flags == 0 and S("Redstone Material") or nil,
		})
		wireflag_tab[name] = flags
	end
end
