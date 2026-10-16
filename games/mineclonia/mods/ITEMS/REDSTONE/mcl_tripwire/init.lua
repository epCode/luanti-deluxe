-- Port of Minecraft's TripWireHookBlock and TripWireBlock.
--
-- Hooks: mcl_tripwire:hook, hook_attached, hook_powered (attached and
-- powered); 4dir param2 is FACING, pointing away from the wall.
-- Tripwire: mcl_tripwire:tripwire and tripwire_attached; param2 bit 0 is
-- POWERED, bit 1 DISARMED.  Its connections only affect the look and are
-- drawn with connected node boxes.

local S = core.get_translator(core.get_current_modname())

local NORTH, SOUTH, WEST, EAST = mcl_redstone.NORTH, mcl_redstone.SOUTH, mcl_redstone.WEST, mcl_redstone.EAST
local rel = mcl_redstone.rel
local opposite = mcl_redstone.opposite
local get_node = mcl_redstone.get_node
local fourdir_to_dir = mcl_redstone.fourdir_to_dir
local dir_to_fourdir = mcl_redstone.dir_to_fourdir

local HOOK = "mcl_tripwire:hook"
local WIRE = "mcl_tripwire:tripwire"
local WIRE_DIST_MAX = 42

-- Hook state ---------------------------------------------------------------------

local function is_hook(node)
	return mcl_redstone.block_id(node.name) == HOOK
end

local function hook_facing(node)
	return fourdir_to_dir[node.param2 % 4]
end

local function hook_attached(node)
	return node.name == "mcl_tripwire:hook_attached" or node.name == "mcl_tripwire:hook_powered"
end

local function hook_powered(node)
	return node.name == "mcl_tripwire:hook_powered"
end

local function hook_node(attached, powered, facing)
	local name = powered and "mcl_tripwire:hook_powered" or attached and "mcl_tripwire:hook_attached" or HOOK
	return {name = name, param2 = dir_to_fourdir[facing]}
end

-- Wire state ---------------------------------------------------------------------

local function is_wire(node)
	return mcl_redstone.block_id(node.name) == WIRE
end

local function wire_powered(node)
	return node.param2 % 2 == 1
end

local function wire_disarmed(node)
	return math.floor(node.param2 / 2) % 2 == 1
end

local function wire_attached(node)
	return node.name == "mcl_tripwire:tripwire_attached"
end

local function wire_node(attached, powered, disarmed)
	return {
		name = attached and "mcl_tripwire:tripwire_attached" or WIRE,
		param2 = (powered and 1 or 0) + (disarmed and 2 or 0),
	}
end

local function wire_with(node, t)
	local a, p, d = wire_attached(node), wire_powered(node), wire_disarmed(node)
	if t.attached ~= nil then a = t.attached end
	if t.powered ~= nil then p = t.powered end
	if t.disarmed ~= nil then d = t.disarmed end
	return wire_node(a, p, d)
end

-- TripWireHookBlock -------------------------------------------------------------

local function sound(pos, name, pitch)
	core.sound_play(name, {pos = pos, gain = 0.4, pitch = pitch, max_hear_distance = 16}, true)
end

-- TripWireHookBlock.emitState
local function emit_state(pos, attached, powered, was_attached, was_powered)
	local event
	if powered and not was_powered then
		sound(pos, "mesecons_button_push", 0.6)
		event = "block_activate"
	elseif not powered and was_powered then
		sound(pos, "mesecons_button_push", 0.5)
		event = "block_deactivate"
	elseif attached and not was_attached then
		sound(pos, "mesecons_button_push", 0.7)
		event = "block_attach"
	elseif not attached and was_attached then
		sound(pos, "mesecons_button_push", 1.2 / (math.random() * 0.2 + 0.9))
		event = "block_detach"
	end
	if event and mcl_gameevent then
		mcl_gameevent.emit(event, pos, {})
	end
end

local function notify_neighbors(pos, facing)
	mcl_redstone.update_neighbors_at(pos, HOOK)
	mcl_redstone.update_neighbors_at(rel(pos, opposite[facing]), HOOK)
end

local calculate_state

local function on_removed(pos, node)
	local attached, powered = hook_attached(node), hook_powered(node)
	if attached or powered then
		calculate_state(pos, node, true, false, -1, nil)
	end
	if powered then
		notify_neighbors(pos, hook_facing(node))
	end
end

-- TripWireHookBlock.calculateState
function calculate_state(pos, node, being_destroyed, can_update, wire_source, wire_source_node)
	local facing = hook_facing(node)
	local was_attached = hook_attached(node)
	local was_powered = hook_powered(node)
	local attached = not being_destroyed
	local powered = false
	local receiver = 0
	local wires = {}
	for i = 1, WIRE_DIST_MAX - 1 do
		local p = rel(pos, facing, i)
		local w = get_node(p)
		if is_hook(w) then
			if hook_facing(w) == opposite[facing] then
				receiver = i
			end
			break
		end
		if not is_wire(w) and i ~= wire_source then
			wires[i] = nil
			attached = false
		else
			if i == wire_source then
				w = wire_source_node or w
			end
			local armed = not wire_disarmed(w)
			powered = powered or (armed and wire_powered(w))
			wires[i] = w
			if i == wire_source then
				mcl_redstone.schedule_tick(pos, HOOK, 10)
				attached = attached and armed
			end
		end
	end
	attached = attached and receiver > 1
	powered = powered and attached
	if receiver > 0 then
		local p = rel(pos, facing, receiver)
		local o = opposite[facing]
		mcl_redstone.set_block(p, hook_node(attached, powered, o), 3)
		notify_neighbors(p, o)
		if not is_hook(get_node(pos)) then
			on_removed(pos, hook_node(attached, powered, facing))
			return
		end
		emit_state(p, attached, powered, was_attached, was_powered)
	end
	emit_state(pos, attached, powered, was_attached, was_powered)
	if not being_destroyed then
		mcl_redstone.set_block(pos, hook_node(attached, powered, facing), 3)
		if can_update then
			notify_neighbors(pos, facing)
		end
	end
	if was_attached ~= attached then
		for i = 1, receiver - 1 do
			local w = wires[i]
			if w then
				local p = rel(pos, facing, i)
				local now = get_node(p)
				if is_wire(now) then
					mcl_redstone.set_block(p, wire_with(w, {attached = attached}), 3)
				elseif is_hook(now) then
					mcl_redstone.set_block(p, hook_node(attached, hook_powered(now), hook_facing(now)), 3)
				end
			end
		end
	end
end

local function hook_can_survive(pos, node)
	local facing = hook_facing(node)
	local wall = rel(pos, opposite[facing])
	return mcl_redstone.is_face_sturdy(wall, get_node(wall), facing, "full")
end

local hook_behaviour = {
	block = HOOK,
	signal_source = true,
	push_reaction = "destroy",
	own_signal = function(pos, node)
		return hook_powered(node) and 15 or 0
	end,
	get_signal = function(pos, node)
		return hook_powered(node) and 15 or 0
	end,
	get_direct_signal = function(pos, node, d)
		return hook_powered(node) and hook_facing(node) == d and 15 or 0
	end,
	update_shape = function(pos, node, d)
		if opposite[d] == hook_facing(node) and not hook_can_survive(pos, node) then
			return {name = "air"}
		end
	end,
	tick = function(pos, node)
		calculate_state(pos, node, false, true, -1, nil)
	end,
	affect_neighbors_after_removal = function(pos, node, moved)
		if not moved then
			on_removed(pos, node)
		end
	end,
}

-- TripWireHookBlock.getStateForPlacement and setPlacedBy
local function hook_on_place(itemstack, placer, pointed_thing)
	if pointed_thing.type ~= "node" then
		return itemstack
	end
	local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
	if rc then return rc end
	local under = core.get_node(pointed_thing.under)
	local udef = core.registered_nodes[under.name]
	local pos = udef and udef.buildable_to and pointed_thing.under or pointed_thing.above
	-- Horizontal directions ordered by how much the placer looks along them
	local look = placer and placer.get_look_dir and placer:get_look_dir() or vector.new(0, 0, 1)
	local dirs = {NORTH, SOUTH, WEST, EAST}
	table.sort(dirs, function(a, b)
		return vector.dot(mcl_redstone.dirvec[a], look) > vector.dot(mcl_redstone.dirvec[b], look)
	end)
	for _, d in ipairs(dirs) do
		local facing = opposite[d]
		if hook_can_survive(pos, hook_node(false, false, facing)) then
			return core.item_place_node(itemstack, placer, pointed_thing, dir_to_fourdir[facing])
		end
	end
	return itemstack
end

local function hook_after_place_node(pos)
	mcl_redstone._begin()
	calculate_state(pos, get_node(pos), false, false, -1, nil)
	mcl_redstone._end()
end

-- TripWireBlock -------------------------------------------------------------------

-- TripWireBlock.updateSource
local function update_source(pos, node)
	for _, d in ipairs({SOUTH, WEST}) do
		for i = 1, WIRE_DIST_MAX - 1 do
			local p = rel(pos, d, i)
			local n = get_node(p)
			if is_hook(n) then
				if hook_facing(n) == opposite[d] then
					calculate_state(p, n, false, true, i, node)
				end
				break
			end
			if not is_wire(n) then
				break
			end
		end
	end
end

-- Entities in the wire's shape (attached: 1 to 2.5 pixels, else 0 to 8)
local function entities_in(pos, node)
	local y1 = wire_attached(node) and 1/16 or 0
	local y2 = wire_attached(node) and 2.5/16 or 0.5
	local minp = vector.new(pos.x - 0.5, pos.y - 0.5 + y1, pos.z - 0.5)
	local maxp = vector.new(pos.x + 0.5, pos.y - 0.5 + y2, pos.z + 0.5)
	for _, obj in ipairs(core.get_objects_in_area(vector.offset(minp, -2, -2, -2), vector.offset(maxp, 2, 2, 2))) do
		local p = obj:get_pos()
		local props = obj:get_properties()
		local cb = props and props.collisionbox
		local ent = obj:get_luaentity()
		local counts = obj:is_player() or (ent and (props.physical or ent.name == "__builtin:item" or ent._is_arrow or ent.is_mob))
		if p and cb and counts
				and p.x + cb[1] < maxp.x and p.x + cb[4] > minp.x
				and p.y + cb[2] < maxp.y and p.y + cb[5] > minp.y
				and p.z + cb[3] < maxp.z and p.z + cb[6] > minp.z then
			return true
		end
	end
	return false
end

-- TripWireBlock.checkPressed
local function check_pressed(pos, pressed)
	local node = get_node(pos)
	local was = wire_powered(node)
	if pressed == nil then
		pressed = entities_in(pos, node)
	end
	if pressed ~= was then
		node = wire_with(node, {powered = pressed})
		mcl_redstone.set_block(pos, node, 3)
		update_source(pos, node)
	end
	if pressed then
		mcl_redstone.schedule_tick(pos, WIRE, 10)
	elseif was then
		mcl_redstone.schedule_tick(pos, WIRE, 1)
	end
end

local wire_behaviour = {
	block = WIRE,
	push_reaction = "destroy",
	on_place = function(pos, node, oldnode)
		if not is_wire(oldnode) then
			update_source(pos, node)
		end
	end,
	affect_neighbors_after_removal = function(pos, node, moved)
		if not moved then
			update_source(pos, wire_with(node, {powered = true}))
		end
	end,
	tick = function(pos, node)
		if wire_powered(get_node(pos)) then
			check_pressed(pos)
		end
	end,
}

-- TripWireBlock.entityInside
local function wire_on_object_in(pos)
	pos = vector.round(pos)
	local node = core.get_node(pos)
	if not is_wire(node) or wire_powered(node) or mcl_redstone.has_scheduled_tick(pos, WIRE) then
		return
	end
	mcl_redstone._begin()
	if entities_in(pos, node) then
		check_pressed(pos, true)
	end
	mcl_redstone._end()
end

-- TripWireBlock.playerWillDestroy: shears disarm the wire first
local function wire_on_dig(pos, node, digger)
	if digger and digger:is_player() and digger:get_wielded_item():get_name() == "mcl_tools:shears" then
		mcl_redstone._begin()
		mcl_redstone.set_block(pos, wire_with(node, {disarmed = true}), 260)
		mcl_redstone._end()
		if mcl_gameevent then
			mcl_gameevent.emit("shear", pos, {source = digger})
		end
		node = core.get_node(pos)
	end
	return core.node_dig(pos, node, digger)
end

-- Nodes ----------------------------------------------------------------------------

local function px(a) return a / 16 - 0.5 end
-- MC model coordinates (wall at +z / south in the model) to node box
local function box(x1, y1, z1, x2, y2, z2)
	return {px(x1), px(y1), 0.5 - z2 / 16, px(x2), px(y2), 0.5 - z1 / 16}
end

local hook_boxes = {
	box(6, 1, 14, 10, 9, 16), -- plank
	box(7.4, 5.2, 10, 8.8, 6.8, 14), -- stick
	box(6.2, 3.8, 7.9, 9.8, 4.6, 8.7), -- ring
	box(6.2, 3.8, 10.7, 9.8, 4.6, 11.5),
	box(6.2, 3.8, 8.7, 7.0, 4.6, 10.7),
	box(9.0, 3.8, 8.7, 9.8, 4.6, 10.7),
}
local hook_boxes_attached = {
	box(6, 1, 14, 10, 9, 16),
	box(7.4, 5.2, 10, 8.8, 6.8, 14),
	box(6.2, 4.2, 6.7, 9.8, 5, 7.5),
	box(6.2, 4.2, 9.5, 9.8, 5, 10.3),
	box(6.2, 4.2, 7.5, 7.0, 5, 9.5),
	box(9.0, 4.2, 7.5, 9.8, 5, 9.5),
	box(7.75, 1.5, 0, 8.25, 1.6, 6.7), -- string to the wire
}

local hook_common = {
	description = S("Tripwire Hook"),
	_tt_help = S("Provides redstone power when its tripwire is touched"),
	_doc_items_longdesc = S("Tripwire hooks are attached to walls. Two hooks facing each other, with tripwire between them, form a tripwire: when something touches the wire, both hooks emit redstone power."),
	drawtype = "nodebox",
	paramtype = "light",
	paramtype2 = "4dir",
	sunlight_propagates = true,
	walkable = false,
	is_ground_content = false,
	tiles = {"mcl_tripwire_hook.png^[combine:16x16:0,0=default_wood.png^mcl_tripwire_hook.png"},
	inventory_image = "mcl_tripwire_hook.png",
	wield_image = "mcl_tripwire_hook.png",
	use_texture_alpha = "clip",
	groups = {handy = 1, axey = 1, attached_node = 0, dig_by_water = 1, dig_by_piston = 1, tripwire_hook = 1},
	sounds = mcl_sounds.node_sound_wood_defaults(),
	drop = HOOK,
	on_place = hook_on_place,
	after_place_node = hook_after_place_node,
	_mcl_redstone = hook_behaviour,
	_mcl_hardness = 0,
	_mcl_blast_resistance = 0,
}
local hook_tiles = {"default_wood.png", "default_wood.png", "default_wood.png", "default_wood.png", "default_wood.png", "default_wood.png"}

core.register_node(HOOK, table.merge(hook_common, {
	node_box = {type = "fixed", fixed = hook_boxes},
	selection_box = {type = "fixed", fixed = {box(5, 0, 10, 11, 10, 16)}},
	tiles = hook_tiles,
}))
core.register_node("mcl_tripwire:hook_attached", table.merge(hook_common, {
	node_box = {type = "fixed", fixed = hook_boxes_attached},
	selection_box = {type = "fixed", fixed = {box(5, 0, 10, 11, 10, 16)}},
	tiles = hook_tiles,
	groups = table.merge(hook_common.groups, {not_in_creative_inventory = 1}),
	_doc_items_create_entry = false,
}))
core.register_node("mcl_tripwire:hook_powered", table.merge(hook_common, {
	node_box = {type = "fixed", fixed = hook_boxes_attached},
	selection_box = {type = "fixed", fixed = {box(5, 0, 10, 11, 10, 16)}},
	tiles = hook_tiles,
	groups = table.merge(hook_common.groups, {not_in_creative_inventory = 1}),
	_doc_items_create_entry = false,
}))

local h = 1.5 / 16 - 0.5
local wire_common = {
	description = S("Tripwire"),
	drawtype = "nodebox",
	paramtype = "light",
	sunlight_propagates = true,
	walkable = false,
	pointable = true,
	buildable_to = false,
	is_ground_content = false,
	use_texture_alpha = "clip",
	inventory_image = "mcl_mobitems_string.png",
	wield_image = "mcl_mobitems_string.png",
	node_box = {
		type = "connected",
		fixed = {-1/64, h, -1/64, 1/64, h + 1/64, 1/64},
		connect_front = {-1/64, h, -0.5, 1/64, h + 1/64, 0},
		connect_back = {-1/64, h, 0, 1/64, h + 1/64, 0.5},
		connect_left = {-0.5, h, -1/64, 0, h + 1/64, 1/64},
		connect_right = {0, h, -1/64, 0.5, h + 1/64, 1/64},
	},
	connects_to = {"group:tripwire", "group:tripwire_hook"},
	selection_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.5 + 2.5/16, 0.5}},
	groups = {dig_immediate = 3, tripwire = 1, dig_by_water = 1, dig_by_piston = 1, not_in_creative_inventory = 1},
	drop = "mcl_mobitems:string",
	sounds = mcl_sounds.node_sound_defaults(),
	on_dig = wire_on_dig,
	_on_object_in = wire_on_object_in,
	_mcl_redstone = wire_behaviour,
	_doc_items_create_entry = false,
	_mcl_hardness = 0,
}
core.register_node(WIRE, table.merge(wire_common, {
	tiles = {"mcl_tripwire_tripwire.png"},
}))
core.register_node("mcl_tripwire:tripwire_attached", table.merge(wire_common, {
	tiles = {"mcl_tripwire_tripwire.png^[transformFY"},
}))

-- String is the item of the tripwire block
core.override_item("mcl_mobitems:string", {
	on_place = function(itemstack, placer, pointed_thing)
		if pointed_thing.type ~= "node" then
			return itemstack
		end
		local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
		if rc then return rc end
		local fake = ItemStack(itemstack)
		fake:set_name(WIRE)
		local _, pos = core.item_place_node(fake, placer, pointed_thing)
		if pos and not core.is_creative_enabled(placer and placer:get_player_name() or "") then
			itemstack:take_item()
		end
		return itemstack
	end,
})

core.register_craft({
	output = HOOK .. " 2",
	recipe = {
		{"mcl_core:iron_ingot"},
		{"mcl_core:stick"},
		{"group:wood"},
	},
})

core.register_craft({
	type = "fuel",
	recipe = HOOK,
	burntime = 15,
})

doc.add_entry_alias("nodes", HOOK, "nodes", "mcl_tripwire:hook_attached")
doc.add_entry_alias("nodes", HOOK, "nodes", "mcl_tripwire:hook_powered")
