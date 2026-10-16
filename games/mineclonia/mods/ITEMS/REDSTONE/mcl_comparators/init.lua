local S = core.get_translator(core.get_current_modname())

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

-- Adds the fullness of the lists `lists` of the inventory at pos to
-- `total` (a float), like the loop of
-- AbstractContainerMenu.getRedstoneSignalFromContainer.  Returns the new
-- total and the number of slots.
local function get_inventory_data(pos, lists, total)
	local inv = core.get_inventory({type="node", pos=pos})
	if not inv then
		return total, 0
	end
	local slots = 0
	for _, listname in ipairs(lists) do
		local list = inv:get_list(listname)
		if list then
			slots = slots + #list
			for _, stack in ipairs(list) do
				if not stack:is_empty() then
					-- Container.getMaxStackSize(stack): the container allows 99
					local max = math.min(99, stack:get_stack_max())
					total = fround(total + fround(stack:get_count() / max))
				end
			end
		end
	end
	return total, slots
end

-- Mth.lerpDiscrete(total / slots, 0, 15)
local function container_signal(total, slots)
	if slots == 0 then
		return 0
	end
	local percent = fround(total / slots)
	return math.floor(fround(percent * 14)) + (percent > 0 and 1 or 0)
end

local MAIN = {"main"}

-- AbstractContainerMenu.getRedstoneSignalFromContainer of the node at pos
-- (the lists in Minecraft's slot order)
local function measure_inventory(pos, _, _, lists)
	return container_signal(get_inventory_data(pos, lists or MAIN, 0))
end

--- wrap measure_inventory to measure non main invs
local function measure_complex_inventory(lists)
	return function(pos)
		return measure_inventory(pos, nil, nil, lists)
	end
end

-- ChestBlock.isChestBlockedAt: a conductor or a sitting cat above
local function chest_blocked(pos)
	local above = vector.offset(pos, 0, 1, 0)
	if mcl_redstone.is_conductor(above, mcl_redstone.get_node(above)) then
		return true
	end
	-- Cats whose box intersects the block space above
	for obj in core.objects_inside_radius(above, 2) do
		local ent = obj:get_luaentity()
		if ent and ent.name == "mobs_mc:cat" and ent._pose == "sit" then
			local p = obj:get_pos()
			local cb = obj:get_properties().collisionbox
			if p.x + cb[1] < above.x + 0.5 and p.x + cb[4] > above.x - 0.5
					and p.y + cb[2] < above.y + 0.5 and p.y + cb[5] > above.y - 0.5
					and p.z + cb[3] < above.z + 0.5 and p.z + cb[6] > above.z - 0.5 then
				return true
			end
		end
	end
	return false
end

-- ChestBlock.getAnalogOutputSignal: the signal of the whole (double) chest,
-- 0 if it is blocked.  `side` is the half at pos ("left" is the first
-- container of the CompoundContainer) or nil for a single chest.
local function measure_chest(side)
	return function(pos, node)
		local other_pos = side and mcl_util.get_double_container_neighbor_pos(pos, node.param2, side)
		local other = other_pos and mcl_redstone.get_node(other_pos)
		if other and core.get_item_group(other.name, "double_chest") == 0 then
			other_pos = nil
		end
		if chest_blocked(pos) or other_pos and chest_blocked(other_pos) then
			return 0
		end
		if not other_pos then
			return measure_inventory(pos)
		end
		local first, second = pos, other_pos
		if side == "right" then
			first, second = other_pos, pos
		end
		local total, slots1 = get_inventory_data(first, MAIN, 0)
		local total2, slots2 = get_inventory_data(second, MAIN, total)
		return container_signal(total2, slots1 + slots2)
	end
end

local function measure_constant(power_level)
	return function()
		return power_level
	end
end

local function measure_item_frames(pos)
	local meta = core.get_meta(pos)
	if meta:get_inventory():get_stack("main", 1):get_name() ~= "" then
		return meta:get_int("mcl_item_rotation") + 1
	end
	return 0
end

local measure_chest_small = measure_chest(nil)
local measure_double_chest_left = measure_chest("left")
local measure_double_chest_right = measure_chest("right")
-- AbstractFurnaceBlockEntity slots: input, fuel, result
local measure_furnace = measure_complex_inventory({"src", "fuel", "dst"})
-- BrewingStandBlockEntity slots: 3 bottles, ingredient, fuel
local measure_brewing_stand = measure_complex_inventory({"stand", "input", "fuel"})

-- measurable nodes mapped to their measuring function
local measure_tab = {
	["mcl_barrels:barrel_closed"] = measure_inventory,
	["mcl_barrels:barrel_open"] = measure_inventory,
	["mcl_chests:chest_small"] = measure_chest_small,
	["mcl_chests:chest_left"] = measure_double_chest_left,
	["mcl_chests:chest_right"] = measure_double_chest_right,
	["mcl_chests:trapped_chest_small"] = measure_chest_small,
	["mcl_chests:trapped_chest_left"] = measure_double_chest_left,
	["mcl_chests:trapped_chest_right"] = measure_double_chest_right,
	["mcl_chests:trapped_chest_on_small"] = measure_chest_small,
	["mcl_chests:trapped_chest_on_left"] = measure_double_chest_left,
	["mcl_chests:trapped_chest_on_right"] = measure_double_chest_right,
	["mcl_dispensers:dispenser"] = measure_inventory,
	["mcl_dispensers:dispenser_down"] = measure_inventory,
	["mcl_dispensers:dispenser_up"] = measure_inventory,
	["mcl_dispensers:dropper"] = measure_inventory,
	["mcl_dispensers:dropper_down"] = measure_inventory,
	["mcl_dispensers:dropper_up"] = measure_inventory,
	["mcl_hoppers:hopper"] = measure_inventory,
	["mcl_hoppers:hopper_disabled"] = measure_inventory,
	["mcl_hoppers:hopper_side"] = measure_inventory,
	["mcl_hoppers:hopper_side_disabled"] = measure_inventory,
	["mcl_furnaces:furnace"] = measure_furnace,
	["mcl_blast_furnace:blast_furnace"] = measure_furnace,
	["mcl_smoker:smoker"] = measure_furnace,
	["mcl_itemframes:frame"] = measure_item_frames,
	["mcl_itemframes:glow_frame"] = measure_item_frames,
	["mcl_itemframes:invisible_frame"] = measure_item_frames,
	["mcl_itemframes:invisible_glow_frame"] = measure_item_frames,
	-- Shulker boxes, brewing stands and nodes in the comparator_signal group
	-- are added on mods loaded; other blocks define analog_output themselves.
}

-- Port of Minecraft's ComparatorBlock (see mcl_redstone/diode.lua).
-- The output signal (ComparatorBlockEntity) is kept in the node metadata.

local BLOCK = "mcl_comparators:comparator"
local opposite = mcl_redstone.opposite
local rel = mcl_redstone.rel
local fourdir_to_dir = mcl_redstone.fourdir_to_dir
local get_node = mcl_redstone.get_node

local item_frames = {
	["mcl_itemframes:frame"] = true,
	["mcl_itemframes:glow_frame"] = true,
	["mcl_itemframes:invisible_frame"] = true,
	["mcl_itemframes:invisible_glow_frame"] = true,
}

local function get_output(pos)
	local meta = core.get_meta(pos)
	if meta:contains("output") then
		return meta:get_int("output")
	end
	-- Older worlds kept the output in param2
	return math.floor(get_node(pos).param2 / 4)
end

local function set_output(pos, value)
	core.get_meta(pos):set_int("output", value)
end

local function is_subtract(node)
	return node.name:sub(-4) == "_sub"
end

local function is_powered(node)
	return node.name:find("_on_", 1, true) ~= nil
end

local function facing(node)
	return opposite[fourdir_to_dir[node.param2 % 4]]
end

local function make_node(node, powered, subtract)
	return {
		name = "mcl_comparators:comparator_" .. (powered and "on" or "off") .. "_" .. (subtract and "sub" or "comp"),
		param2 = node.param2 % 4,
	}
end

-- The item frame on the far side of the block behind the comparator,
-- hanging on that block (ComparatorBlock.getItemFrame).
local function item_frame_signal(fpos, d)
	local fnode = get_node(fpos)
	if not item_frames[fnode.name] then
		return nil
	end
	local wall = mcl_redstone.dir_index(core.wallmounted_to_dir(fnode.param2))
	if wall ~= opposite[d] then
		return nil
	end
	return measure_item_frames(fpos)
end

local diode
local diode_def = mcl_redstone.diode_behaviour({
	block = BLOCK,
	facing = facing,
	powered = is_powered,
	set_powered = function(node, powered)
		return make_node(node, powered, is_subtract(node))
	end,
	delay = function()
		return 2
	end,
	output = function(pos)
		return get_output(pos)
	end,
	-- ComparatorBlock.getInputSignal
	get_input_signal = function(pos, node, dio)
		local result = dio.base_get_input_signal(pos, node)
		local d = facing(node)
		local tpos = rel(pos, d)
		local tnode = get_node(tpos)
		if mcl_redstone.has_analog_output(tnode) then
			result = mcl_redstone.get_analog_output(tpos, tnode, opposite[d])
		elseif result < 15 and mcl_redstone.is_conductor(tpos, tnode) then
			tpos = rel(tpos, d)
			tnode = get_node(tpos)
			local frame = item_frame_signal(tpos, d)
			local block_signal = mcl_redstone.has_analog_output(tnode)
				and mcl_redstone.get_analog_output(tpos, tnode, opposite[d]) or nil
			if frame or block_signal then
				result = math.max(frame or -1, block_signal or -1)
			end
		end
		return result
	end,
	-- ComparatorBlock.shouldTurnOn
	should_turn_on = function(pos, node, dio)
		local input = dio.get_input_signal(pos, node)
		if input == 0 then
			return false
		end
		local side = dio.get_alternate_signal(pos, node)
		return input > side or (input == side and not is_subtract(node))
	end,
	check_tick_on_neighbor = function(pos, node, dio)
		if mcl_redstone.will_tick_this_tick(pos, BLOCK) then
			return
		end
		local output = mcl_redstone.comparator_calculate_output(pos, node)
		if output ~= get_output(pos) or is_powered(node) ~= dio.should_turn_on(pos, node) then
			local priority = dio.should_prioritize(pos, node) and mcl_redstone.PRIORITY_HIGH or mcl_redstone.PRIORITY_NORMAL
			mcl_redstone.schedule_tick(pos, BLOCK, 2, priority)
		end
	end,
	tick = function(pos, node)
		mcl_redstone.comparator_refresh_output_state(pos, node)
	end,
})
diode = diode_def.diode

-- ComparatorBlock.calculateOutputSignal
function mcl_redstone.comparator_calculate_output(pos, node)
	local input = diode.get_input_signal(pos, node)
	if input == 0 then
		return 0
	end
	local side = diode.get_alternate_signal(pos, node)
	if side > input then
		return 0
	end
	return is_subtract(node) and input - side or input
end

-- ComparatorBlock.refreshOutputState
function mcl_redstone.comparator_refresh_output_state(pos, node)
	local output = mcl_redstone.comparator_calculate_output(pos, node)
	local old = get_output(pos)
	set_output(pos, output)
	if old ~= output or not is_subtract(node) then
		local source_on = diode.should_turn_on(pos, node)
		local is_on = is_powered(node)
		if is_on and not source_on then
			mcl_redstone.set_block(pos, make_node(node, false, is_subtract(node)), 2)
		elseif not is_on and source_on then
			mcl_redstone.set_block(pos, make_node(node, true, is_subtract(node)), 2)
		end
		diode.update_neighbors_in_front(pos, node)
	end
end

local behaviour = table.merge(diode_def, {
	update_shape = function(pos, node, d, npos, nnode)
		if d == mcl_redstone.DOWN and not mcl_redstone.diode_can_survive_on(npos, nnode) then
			return {name = "air"}
		end
	end,
})

-- ComparatorBlock.useWithoutItem: cycle the mode
local function on_rightclick(pos, node, clicker)
	local protname = clicker:get_player_name()
	if core.is_protected(pos, protname) then
		core.record_protection_violation(pos, protname)
		return
	end
	mcl_redstone._begin()
	local new = make_node(node, is_powered(node), not is_subtract(node))
	core.sound_play("mesecons_button_push", {pos = pos, gain = 0.3, pitch = is_subtract(new) and 1.1 or 1.0}, true)
	mcl_redstone.set_block(pos, new, 2)
	local now = get_node(pos)
	if mcl_redstone.block_id(now.name) == BLOCK then
		mcl_redstone.comparator_refresh_output_state(pos, now)
	end
	mcl_redstone._end()
end

-- compute tile depending on state and mode
local function get_tiles(state, mode)
	local top = "mcl_comparators_"..state..".png^"..
		"mcl_comparators_"..mode..".png"
	local sides = "mcl_comparators_sides_"..state..".png^"..
		"mcl_comparators_sides_"..mode..".png"
	local ends = "mcl_comparators_ends_"..state..".png^"..
		"mcl_comparators_ends_"..mode..".png"
	return {
		top, "mcl_stairs_stone_slab_top.png",
		sides, sides.."^[transformFX",
		ends, ends,
	}
end

local node_boxes = {
	comp = {
		{ -8/16, -8/16, -8/16,
		   8/16, -6/16,  8/16 },	-- the main slab
		{ -1/16, -6/16,  6/16,
		   1/16, -4/16,  4/16 },	-- front torch
		{ -4/16, -6/16, -5/16,
		  -2/16, -1/16, -3/16 },	-- left back torch
		{  2/16, -6/16, -5/16,
		   4/16, -1/16, -3/16 },	-- right back torch
	},
	sub = {
		{ -8/16, -8/16, -8/16,
		   8/16, -6/16,  8/16 },	-- the main slab
		{ -1/16, -6/16,  6/16,
		   1/16, -3/16,  4/16 },	-- front torch (active)
		{ -4/16, -6/16, -5/16,
		  -2/16, -1/16, -3/16 },	-- left back torch
		{  2/16, -6/16, -5/16,
		   4/16, -1/16, -3/16 },	-- right back torch
	},
}

local collision_box = {
	type = "fixed",
	fixed = { -8/16, -8/16, -8/16, 8/16, -6/16, 8/16 },
}

local groups = {
	dig_immediate = 3,
	dig_by_water  = 1,
	destroy_by_lava_flow = 1,
	dig_by_piston = 1,
	unsticky = 1,
	attached_node = 1,
	redstone_comparator = 1,
}

for _, mode in pairs{"comp", "sub"} do
	for _, state in pairs{"on", "off"} do
		local nodename = "mcl_comparators:comparator_"..state.."_"..mode

		local longdesc, usagehelp, use_help
		if state == "off" and mode == "comp" then
			longdesc = S("Redstone comparators are multi-purpose redstone components.").."\n"..
			S("They can transmit a redstone signal, detect whether a block contains any items and compare multiple signals.")

			usagehelp = S("A redstone comparator has 1 main input, 2 side inputs and 1 output. The output is in arrow direction, the main input is in the opposite direction. The other 2 sides are the side inputs.").."\n"..
				S("The main input can powered in 2 ways: First, it can be powered directly by redstone power like any other component. Second, it is powered if, and only if a container (like a chest) is placed in front of it and the container contains at least one item.").."\n"..
				S("The side inputs are only powered by normal redstone power. The redstone comparator can operate in two modes: Transmission mode and subtraction mode. It starts in transmission mode and the mode can be changed by using the block.").."\n\n"..
				S("Transmission mode:\nThe front torch is unlit and lowered. The output is powered if, and only if the main input is powered. The two side inputs are ignored.").."\n"..
				S("Subtraction mode:\nThe front torch is lit. The output is powered if, and only if the main input is powered and none of the side inputs is powered.")
		else
			use_help = false
		end

		local nodedef = {
			description = S("Redstone Comparator"),
			_doc_items_create_entry = use_help,
			_doc_items_longdesc = longdesc,
			_doc_items_usagehelp = usagehelp,
			drawtype = "nodebox",
			tiles = get_tiles(state, mode),
			walkable = false, -- Workaround until https://github.com/luanti-org/luanti/issues/16432 is resolved
			selection_box = collision_box,
			collision_box = collision_box,
			node_box = {
				type = "fixed",
				fixed = node_boxes[mode],
			},
			groups = groups,
			paramtype = "light",
			paramtype2 = "4dir",
			sunlight_propagates = false,
			is_ground_content = false,
			drop = "mcl_comparators:comparator_off_comp",
			on_rightclick = on_rightclick,
			sounds = mcl_sounds.node_sound_stone_defaults(),
			on_rotate = screwdriver.disallow,
			_mcl_redstone = behaviour,
			after_place_node = mcl_redstone.diode_after_place_node,
			on_place = mcl_redstone.diode_on_place,
		}

		if mode == "comp" and state == "off" then
			nodedef._doc_items_create_entry = true
			nodedef.inventory_image = "mcl_comparators_item.png"
			nodedef.wield_image = "mcl_comparators_item.png"
		else
			nodedef.groups = table.copy(nodedef.groups)
			nodedef.groups.not_in_creative_inventory = 1
			if mode == "sub" or state == "on" then
				nodedef.inventory_image = nil
			end
			local desc = nodedef.description
			if mode ~= "sub" and state == "on" then
				desc = S("Redstone Comparator (Powered)")
			elseif mode == "sub" and state ~= "on" then
				desc = S("Redstone Comparator (Subtract)")
			elseif mode == "sub" and state == "on" then
				desc = S("Redstone Comparator (Subtract, Powered)")
			end
			nodedef.description = desc

			doc.add_entry_alias("nodes", "mcl_comparators:comparator_"..state.."_"..mode, "nodes", nodename)
		end

		core.register_node(nodename, nodedef)
	end
end

core.register_craft({
	output = "mcl_comparators:comparator_off_comp",
	recipe = {
		{ "",      "mcl_redstone_torch:redstone_torch_on", ""      },
		{ "mcl_redstone_torch:redstone_torch_on", "mcl_nether:quartz",  "mcl_redstone_torch:redstone_torch_on" },
		{ "mcl_core:stone",   "mcl_core:stone",   "mcl_core:stone"   },
	}
})

core.register_on_mods_loaded(function()
	for name, def in pairs(core.registered_nodes) do
		if core.get_item_group(name, "shulker_box") ~= 0 then
			measure_tab[name] = measure_inventory
		elseif core.get_item_group(name, "brewing_stand") ~= 0 then
			measure_tab[name] = measure_brewing_stand
		elseif  -- comparator_signal == 0 still marks the node as comparator measurable
			def.groups and def.groups.comparator_signal then
			measure_tab[name] = measure_constant(def.groups.comparator_signal)
		end
	end
	-- Item frames are read only through a block (see item_frame_signal)
	for name in pairs(item_frames) do
		measure_tab[name] = nil
	end
	-- BlockBehaviour.getAnalogOutputSignal of measurable nodes
	for name, measure in pairs(measure_tab) do
		local b = mcl_redstone._blocks[name]
		if b and not b.analog_output then
			b.analog_output = function(pos, node)
				return math.max(0, math.min(15, measure(pos, node, core.registered_nodes[node.name])))
			end
		end
	end
end)
