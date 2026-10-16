local S = core.get_translator(core.get_current_modname())

mcl_observers = {}

-- Port of Minecraft's ObserverBlock. FACING (the observed side) is the
-- facedir direction of horizontal observers, up or down for the vertical ones.

local BLOCK = "mcl_observers:observer"
local rel = mcl_redstone.rel
local opposite = mcl_redstone.opposite

local function get_front_dir(node)
	if node.name == "mcl_observers:observer_up_off" or node.name == "mcl_observers:observer_up_on" then
		return {x=0, y=1, z=0}
	elseif node.name == "mcl_observers:observer_down_off" or node.name == "mcl_observers:observer_down_on" then
		return {x=0, y=-1, z=0}
	else
		return core.facedir_to_dir(node.param2)
	end
end

function mcl_observers.get_front_pos(pos, node)
	return vector.add(pos, get_front_dir(node))
end

local function facing(node)
	return mcl_redstone.dir_index(get_front_dir(node))
end

local function is_powered(node)
	return core.get_item_group(node.name, "observer") == 2
end

local function with_powered(node, powered)
	local ndef = core.registered_nodes[node.name]
	return {name = powered and ndef._mcl_observer_on or ndef._mcl_observer_off, param2 = node.param2}
end

-- ObserverBlock.updateNeighborsInFront (the output is at the back)
local function update_neighbors_in_front(pos, node)
	local d = facing(node)
	local back = rel(pos, opposite[d])
	mcl_redstone.neighbor_changed(back, BLOCK, pos)
	mcl_redstone.update_neighbors_at_except(back, BLOCK, d)
end

local function own_signal(pos, node)
	return is_powered(node) and 15 or 0
end

local function get_signal(pos, node, d)
	return facing(node) == d and own_signal(pos, node) or 0
end

local behaviour = {
	block = BLOCK,
	signal_source = true,
	conductor = false,
	own_signal = own_signal,
	get_signal = get_signal,
	get_direct_signal = get_signal,
	wire_connects = function(pos, node, d)
		return d == facing(node)
	end,
	tick = function(pos, node)
		if is_powered(node) then
			mcl_redstone.set_block(pos, with_powered(node, false), 2)
		else
			mcl_redstone.set_block(pos, with_powered(node, true), 2)
			mcl_redstone.schedule_tick(pos, BLOCK, 2)
		end
		update_neighbors_in_front(pos, node)
	end,
	update_shape = function(pos, node, d)
		if facing(node) == d and not is_powered(node) then
			-- ObserverBlock.startSignal
			if not mcl_redstone.has_scheduled_tick(pos, BLOCK) then
				mcl_redstone.schedule_tick(pos, BLOCK, 2)
			end
		end
	end,
	on_place = function(pos, node, oldnode)
		if mcl_redstone.block_id(oldnode.name) == BLOCK then
			return
		end
		if is_powered(node) and not mcl_redstone.has_scheduled_tick(pos, BLOCK) then
			local new = with_powered(node, false)
			mcl_redstone.set_block(pos, new, 18)
			update_neighbors_in_front(pos, new)
		end
	end,
	affect_neighbors_after_removal = function(pos, node)
		if is_powered(node) and mcl_redstone.has_scheduled_tick(pos, BLOCK) then
			update_neighbors_in_front(pos, with_powered(node, false))
		end
	end,
}

-- ObserverBlock.getStateForPlacement: it observes what the placer looks at
local function on_place(itemstack, placer, pointed_thing)
	if pointed_thing.type ~= "node" then
		return itemstack
	end
	local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
	if rc then return rc end
	local d = mcl_redstone.nearest_looking_direction(placer)
	local name, param2 = "mcl_observers:observer_off", 0
	if d == mcl_redstone.UP then
		name = "mcl_observers:observer_up_off"
	elseif d == mcl_redstone.DOWN then
		name = "mcl_observers:observer_down_off"
	else
		param2 = core.dir_to_facedir(mcl_redstone.dirvec[d])
	end
	local fake = ItemStack(itemstack)
	fake:set_name(name)
	local ret, pos = core.item_place_node(fake, placer, pointed_thing, param2)
	if pos then
		itemstack:take_item()
	end
	return itemstack
end

local commdef = {
	is_ground_content = false,
	sounds = mcl_sounds.node_sound_stone_defaults(),
	on_rotate = false,
	groups = {pickaxey=1, material_stone=1, redstone_not_conductive=1, },
	_mcl_hardness = 3.5,
	drop = "mcl_observers:observer_off",

	_mcl_redstone = behaviour,
}
local commdef_off = table.merge(commdef, {
	groups = table.merge(commdef.groups, {observer=1}),
})
local commdef_on = table.merge(commdef, {
	_doc_items_create_entry = false,
	groups = table.merge(commdef.groups, {observer=2}),
})

core.register_node("mcl_observers:observer_off", table.merge(commdef_off, {
	paramtype2 = "facedir",
	description = S("Observer"),
	groups = table.merge(commdef_off.groups),
	_tt_help = S("Emits redstone pulse when block in front changes"),
	_doc_items_longdesc = S("An observer is a redstone component which observes the block in front of it and sends a very short redstone pulse whenever this block changes."),
	_doc_items_usagehelp = S("Place the observer directly in front of the block you want to observe with the “face” looking at the block. The arrow points to the side of the output, which is at the opposite side of the “face”. You can place your redstone dust or any other component here."),

	tiles = {
		"mcl_observers_observer_top.png^[transformR180", "default_furnace_bottom.png",
		"mcl_observers_observer_side.png", "mcl_observers_observer_side.png",
		"mcl_observers_observer_front.png", "mcl_observers_observer_back.png",
	},
	on_place = on_place,
	_mcl_observer_on = "mcl_observers:observer_on",
	_mcl_observer_off = "mcl_observers:observer_off",
}))

core.register_node("mcl_observers:observer_on", table.merge(commdef_on, {
	paramtype2 = "facedir",
	groups = table.merge(commdef_on.groups, {not_in_creative_inventory=1}),
	tiles = {
		"mcl_observers_observer_top.png^[transformR180", "default_furnace_bottom.png",
		"mcl_observers_observer_side.png", "mcl_observers_observer_side.png",
		"mcl_observers_observer_front.png", "mcl_observers_observer_back_lit.png",
	},
	_mcl_observer_on = "mcl_observers:observer_on",
	_mcl_observer_off = "mcl_observers:observer_off",
}))

core.register_node("mcl_observers:observer_down_off", table.merge(commdef_off, {
	_doc_items_create_entry = false,
	groups = table.merge(commdef_off.groups, {not_in_creative_inventory=1}),
	tiles = {
		"mcl_observers_observer_back.png", "mcl_observers_observer_front.png",
		"mcl_observers_observer_side.png^[transformR90", "mcl_observers_observer_side.png^[transformR90",
		"mcl_observers_observer_top.png", "mcl_observers_observer_top.png",
	},
	_mcl_observer_on = "mcl_observers:observer_down_on",
	_mcl_observer_off = "mcl_observers:observer_down_off",
}))
core.register_node("mcl_observers:observer_down_on", table.merge(commdef_on, {
	groups = table.merge(commdef_on.groups, {not_in_creative_inventory=1}),
	tiles = {
		"mcl_observers_observer_back_lit.png", "mcl_observers_observer_front.png",
		"mcl_observers_observer_side.png^[transformR90", "mcl_observers_observer_side.png^[transformR90",
		"mcl_observers_observer_top.png", "mcl_observers_observer_top.png",
	},
	_mcl_observer_on = "mcl_observers:observer_down_on",
	_mcl_observer_off = "mcl_observers:observer_down_off",
}))

core.register_node("mcl_observers:observer_up_off", table.merge(commdef_off, {
	_doc_items_create_entry = false,
	groups = table.merge(commdef_off.groups, {not_in_creative_inventory=1}),
	tiles = {
		"mcl_observers_observer_front.png", "mcl_observers_observer_back.png",
		"mcl_observers_observer_side.png^[transformR270", "mcl_observers_observer_side.png^[transformR270",
		"mcl_observers_observer_top.png^[transformR180", "mcl_observers_observer_top.png^[transformR180",
	},
	_mcl_observer_on = "mcl_observers:observer_up_on",
	_mcl_observer_off = "mcl_observers:observer_up_off",
}))
core.register_node("mcl_observers:observer_up_on", table.merge(commdef_on, {
	groups = table.merge(commdef_on.groups, {not_in_creative_inventory=1}),
	tiles = {
		"mcl_observers_observer_front.png", "mcl_observers_observer_back_lit.png",
		"mcl_observers_observer_side.png^[transformR270", "mcl_observers_observer_side.png^[transformR270",
		"mcl_observers_observer_top.png^[transformR180", "mcl_observers_observer_top.png^[transformR180",
	},
	_mcl_observer_on = "mcl_observers:observer_up_on",
	_mcl_observer_off = "mcl_observers:observer_up_off",
}))

core.register_craft({
	output = "mcl_observers:observer_off",
	recipe = {
		{ "mcl_core:cobble", "mcl_core:cobble", "mcl_core:cobble" },
		{ "mcl_nether:quartz", "mcl_redstone:redstone", "mcl_redstone:redstone" },
		{ "mcl_core:cobble", "mcl_core:cobble", "mcl_core:cobble" },
	},
})
core.register_craft({
	output = "mcl_observers:observer_off",
	recipe = {
		{ "mcl_core:cobble", "mcl_core:cobble", "mcl_core:cobble" },
		{ "mcl_redstone:redstone", "mcl_redstone:redstone", "mcl_nether:quartz" },
		{ "mcl_core:cobble", "mcl_core:cobble", "mcl_core:cobble" },
	},
})

doc.add_entry_alias("nodes", "mcl_observers:observer_off", "nodes", "mcl_observers:observer_on")
doc.add_entry_alias("nodes", "mcl_observers:observer_off", "nodes", "mcl_observers:observer_down_on")
doc.add_entry_alias("nodes", "mcl_observers:observer_off", "nodes", "mcl_observers:observer_up_on")
doc.add_entry_alias("nodes", "mcl_observers:observer_off", "nodes", "mcl_observers:observer_off")
doc.add_entry_alias("nodes", "mcl_observers:observer_off", "nodes", "mcl_observers:observer_down_off")
doc.add_entry_alias("nodes", "mcl_observers:observer_off", "nodes", "mcl_observers:observer_up_off")
