local S = core.get_translator(core.get_current_modname())

local boxes = {
	{
		{ -8/16, -8/16, -8/16, 8/16, -6/16, 8/16 }, -- the main slab
		{ -1/16, -6/16, 6/16, 1/16, -1/16, 4/16}, -- still torch
		{ -1/16, -6/16, 0/16, 1/16, -1/16, 2/16}, -- moved torch
	},
	{
		{ -8/16, -8/16, -8/16, 8/16, -6/16, 8/16 }, -- the main slab
		{ -1/16, -6/16, 6/16, 1/16, -1/16, 4/16}, -- still torch
		{ -1/16, -6/16, -2/16, 1/16, -1/16, 0/16}, -- moved torch
	},
	{
		{ -8/16, -8/16, -8/16, 8/16, -6/16, 8/16 }, -- the main slab
		{ -1/16, -6/16, 6/16, 1/16, -1/16, 4/16}, -- still torch
		{ -1/16, -6/16, -4/16, 1/16, -1/16, -2/16}, -- moved torch
	},
	{
		{ -8/16, -8/16, -8/16, 8/16, -6/16, 8/16 }, -- the main slab
		{ -1/16, -6/16, 6/16, 1/16, -1/16, 4/16}, -- still torch
		{ -1/16, -6/16, -6/16, 1/16, -1/16, -4/16}, -- moved torch
	},
}

-- Port of Minecraft's RepeaterBlock (see mcl_redstone/diode.lua).
-- param2 % 4 is the output direction (4dir); locked repeaters keep their
-- delay in param2 / 4.

local BLOCK = "mcl_repeaters:repeater"
local opposite = mcl_redstone.opposite
local fourdir_to_dir = mcl_redstone.fourdir_to_dir

local function get_delay(node)
	local g = core.get_item_group(node.name, "redstone_repeater")
	if g == 5 then
		return math.min(4, math.max(1, math.floor(node.param2 / 4)))
	end
	return g
end

local function is_powered(node)
	return core.get_item_group(node.name, "redstone_repeater_on") ~= 0
end

local function is_locked_state(node)
	return core.get_item_group(node.name, "redstone_repeater") == 5
end

local function make_node(delay, locked, powered, dir4)
	if locked then
		return {name = "mcl_repeaters:repeater_" .. (powered and "on" or "off") .. "_locked", param2 = delay * 4 + dir4}
	end
	return {name = "mcl_repeaters:repeater_" .. (powered and "on" or "off") .. "_" .. delay, param2 = dir4}
end

local function with(node, t)
	local delay, locked, powered = get_delay(node), is_locked_state(node), is_powered(node)
	if t.delay ~= nil then delay = t.delay end
	if t.locked ~= nil then locked = t.locked end
	if t.powered ~= nil then powered = t.powered end
	return make_node(delay, locked, powered, node.param2 % 4)
end

-- FACING points to the input, opposite of the output direction
local function facing(node)
	return opposite[fourdir_to_dir[node.param2 % 4]]
end

local diode
local diode_def = mcl_redstone.diode_behaviour({
	block = BLOCK,
	facing = facing,
	powered = is_powered,
	set_powered = function(node, powered)
		return with(node, {powered = powered})
	end,
	delay = function(node)
		return get_delay(node) * 2
	end,
	side_input_diodes_only = true,
	-- RepeaterBlock.isLocked
	is_locked = function(pos, node)
		return diode.get_alternate_signal(pos, node) > 0
	end,
})
diode = diode_def.diode

local function can_survive_below(npos, nnode)
	return mcl_redstone.diode_can_survive_on(npos, nnode)
end

local behaviour = table.merge(diode_def, {
	wire_connects = function(pos, node, d)
		local f = facing(node)
		return d == f or d == opposite[f]
	end,
	update_shape = function(pos, node, d, npos, nnode)
		if d == mcl_redstone.DOWN and not can_survive_below(npos, nnode) then
			return {name = "air"}
		end
		if mcl_redstone.axis[d] ~= mcl_redstone.axis[facing(node)] then
			return with(node, {locked = diode.is_locked(pos, node)})
		end
	end,
	-- RepeaterBlock.animateTick
	animate = function(pos, node, name)
		if not is_powered(node) then
			return
		end
		local f = mcl_redstone.dirvec[facing(node)]
		local offset = math.random() < 0.5 and (get_delay(node) * 2 - 1) or -5
		offset = offset / 16
		mcl_redstone.dust_particle(name, vector.new(
			pos.x + (math.random() - 0.5) * 0.2 + offset * f.x,
			pos.y - 0.1 + (math.random() - 0.5) * 0.2,
			pos.z + (math.random() - 0.5) * 0.2 + offset * f.z), mcl_redstone.REDSTONE_DUST)
	end,
	-- RepeaterBlock.getStateForPlacement
	placement = function(pos, node, oldnode)
		if mcl_redstone.block_id(oldnode.name) == BLOCK then
			return
		end
		return with(node, {locked = diode.is_locked(pos, node)})
	end,
})

local commdef = {
	drawtype = "nodebox",
	walkable = false, -- Workaround until https://github.com/luanti-org/luanti/issues/16432 is resolved
	selection_box = {
		type = "fixed",
		fixed = { -8/16, -8/16, -8/16, 8/16, -6/16, 8/16 },
	},
	collision_box = {
		type = "fixed",
		fixed = { -8/16, -8/16, -8/16, 8/16, -6/16, 8/16 },
	},
	groups = {dig_immediate = 3, dig_by_water = 1, destroy_by_lava_flow = 1, dig_by_piston = 1, unsticky = 1, attached_node = 1},
	paramtype = "light",
	paramtype2 = "4dir",
	sunlight_propagates = false,
	is_ground_content = false,
	drop = "mcl_repeaters:repeater_off_1",
	sounds = mcl_sounds.node_sound_stone_defaults(),
	on_rotate = screwdriver.disallow,
	_mcl_redstone = behaviour,
	after_place_node = mcl_redstone.diode_after_place_node,
	on_place = mcl_redstone.diode_on_place,
}

for delay = 1, 4 do
	local normaldef = table.merge(commdef, {
		node_box = {
			type = "fixed",
			fixed = boxes[delay]
		},
		groups = table.merge(commdef.groups, {redstone_repeater = delay}),
		on_rightclick = function(pos, node, clicker)
			local protname = clicker:get_player_name()
			if core.is_protected(pos, protname) then
				core.record_protection_violation(pos, protname)
				return
			end
			-- RepeaterBlock.useWithoutItem: state.cycle(DELAY)
			mcl_redstone.set_block(pos, with(node, {delay = get_delay(node) % 4 + 1}), 3)
		end,
	})

	core.register_node("mcl_repeaters:repeater_off_"..delay, table.merge(normaldef, {
		description = delay == 1 and S("Redstone Repeater") or S("Redstone Repeater (Delay @1)", delay),
		inventory_image = delay == 1 and "mesecons_delayer_item.png" or nil,
		wield_image = delay == 1 and "mesecons_delayer_item.png" or nil,
		_tt_help = delay == 1 and (
			S("Transmits redstone power only in one direction").."\n"..
			S("Delays signal").."\n"..
			S("Output locks when getting active redstone repeater signal from the side")
		) or nil,
		_doc_items_usagehelp = delay == 1 and (
			S("To power a redstone repeater, send a signal in “arrow” direction (the input). The signal goes out on the opposite side (the output) with a delay. To change the delay, use the redstone repeater. The delay is between 0.1 and 0.4 seconds long and can be changed in steps of 0.1 seconds. It is indicated by the position of the moving redstone torch.").."\n"..
			S("To lock a repeater, send a signal from an adjacent repeater into one of its sides. While locked, the moving redstone torch disappears, the output doesn't change and the input signal is ignored.")
		) or nil,
		_doc_items_longdesc = delay == 1 and S("Redstone repeaters are versatile redstone components with multiple purposes: 1. They only allow signals to travel in one direction. 2. They delay the signal. 3. Optionally, they can lock their output in one state.") or nil,
		_doc_items_create_entry = delay == 1,
		tiles = {
			"mesecons_delayer_off.png",
			"mcl_stairs_stone_slab_top.png",
			"mesecons_delayer_sides_off.png",
			"mesecons_delayer_sides_off.png",
			"mesecons_delayer_ends_off.png",
			"mesecons_delayer_ends_off.png",
		},
		groups = table.merge(normaldef.groups, {not_in_creative_inventory = delay ~= 1 and 1 or 0}),
	}))

	core.register_node("mcl_repeaters:repeater_on_"..delay, table.merge(normaldef, {
		description = S("Redstone Repeater (Delay @1, Powered)", delay),
		_doc_items_create_entry = false,
		tiles = {
			"mesecons_delayer_on.png",
			"mcl_stairs_stone_slab_top.png",
			"mesecons_delayer_sides_on.png",
			"mesecons_delayer_sides_on.png",
			"mesecons_delayer_ends_on.png",
			"mesecons_delayer_ends_on.png",
		},
		groups = table.merge(normaldef.groups, {redstone_repeater_on = 1, not_in_creative_inventory = 1}),
	}))

	if delay ~= 1 then
		doc.add_entry_alias("nodes", "mcl_repeaters:repeater_off_1", "nodes", "mcl_repeaters:repeater_off_"..delay)
	end
	doc.add_entry_alias("nodes", "mcl_repeaters:repeater_off_1", "nodes", "mcl_repeaters:repeater_on_"..delay)
end

local lockeddef = table.merge(commdef, {
	_doc_items_create_entry = false,
	node_box = {
		type = "fixed",
		fixed = {
			{ -8/16, -8/16, -8/16, 8/16, -6/16, 8/16 }, -- the main slab
			{ -1/16, -6/16, 6/16, 1/16, -1/16, 4/16}, -- still torch
			{ -6/16, -6/16, -1/16, 6/16, -4/16, 1/16}, -- lock
		}
	},
	groups = table.merge(commdef.groups, {redstone_repeater = 5, not_in_creative_inventory = 1}),
})

core.register_node("mcl_repeaters:repeater_off_locked", table.merge(lockeddef, {
	description = S("Redstone Repeater (Locked)"),
	tiles = {
		"mesecons_delayer_locked_off.png",
		"mcl_stairs_stone_slab_top.png",
		"mesecons_delayer_sides_locked_off.png",
		"mesecons_delayer_sides_locked_off.png",
		"mesecons_delayer_front_locked_off.png",
		"mesecons_delayer_end_locked_off.png",
	},
}))

core.register_node("mcl_repeaters:repeater_on_locked", table.merge(lockeddef, {
	description = S("Redstone Repeater (Locked, Powered)"),
	tiles = {
		"mesecons_delayer_locked_on.png",
		"mcl_stairs_stone_slab_top.png",
		"mesecons_delayer_sides_locked_on.png",
		"mesecons_delayer_sides_locked_on.png",
		"mesecons_delayer_front_locked_on.png",
		"mesecons_delayer_end_locked_on.png",
	},
	groups = table.merge(lockeddef.groups, {redstone_repeater_on = 1}),
}))

core.register_craft({
	output = "mcl_repeaters:repeater_off_1",
	recipe = {
		{ "",      "", ""      },
		{ "mcl_redstone_torch:redstone_torch_on", "mcl_redstone:redstone",  "mcl_redstone_torch:redstone_torch_on" },
		{ "mcl_core:stone",   "mcl_core:stone",   "mcl_core:stone"   },
	}
})

doc.add_entry_alias("nodes", "mcl_repeaters:repeater_off_1", "nodes", "mcl_repeaters:repeater_off_locked")
doc.add_entry_alias("nodes", "mcl_repeaters:repeater_off_1", "nodes", "mcl_repeaters:repeater_on_locked")
