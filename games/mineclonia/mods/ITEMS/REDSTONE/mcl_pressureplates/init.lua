local S = core.get_translator(core.get_current_modname())

local pp_box_off = {
	type = "fixed",
	fixed = { -7/16, -8/16, -7/16, 7/16, -7/16, 7/16 },
}
local pp_box_on = {
	type = "fixed",
	fixed = { -7/16, -8/16, -7/16, 7/16, -7.5/16, 7/16 },
}

mcl_pressureplates = {}

-- Port of Minecraft's BasePressurePlateBlock, PressurePlateBlock and
-- WeightedPressurePlateBlock.

local rel = mcl_redstone.rel
local DOWN, UP = mcl_redstone.DOWN, mcl_redstone.UP

local function obj_does_activate(obj, activated_by)
	if activated_by.any then
		return true
	end
	local ent = obj:get_luaentity()
	if activated_by.mob and ent and ent.is_mob then
		return true
	end
	return activated_by.player and obj:is_player() or false
end

-- Entities that take part in block triggers
local function is_trigger_entity(obj)
	if obj:is_player() then
		return true
	end
	local props = obj:get_properties()
	local ent = obj:get_luaentity()
	if not props or not ent then
		return false
	end
	return props.physical or ent.name == "__builtin:item" or ent._is_arrow or ent.is_mob or false
end

-- BasePressurePlateBlock.TOUCH_AABB
local function count_entities(pos, activated_by)
	local x1, y1, z1 = pos.x - 7/16, pos.y - 0.5, pos.z - 7/16
	local x2, y2, z2 = pos.x + 7/16, pos.y - 0.25, pos.z + 7/16
	local n = 0
	for obj in core.objects_inside_radius(pos, 3) do
		local p = obj:get_pos()
		local props = obj:get_properties()
		local cb = props and props.collisionbox
		if p and cb and is_trigger_entity(obj) and obj_does_activate(obj, activated_by) then
			if p.x + cb[1] < x2 and p.x + cb[4] > x1
					and p.y + cb[2] < y2 and p.y + cb[5] > y1
					and p.z + cb[3] < z2 and p.z + cb[6] > z1 then
				n = n + 1
			end
		end
	end
	return n
end

local function get_signal_for_state(node)
	if core.get_item_group(node.name, "pressure_plate") ~= 2 then
		return 0
	end
	local def = core.registered_nodes[node.name]
	return def._mcl_pressureplate_weighted and node.param2 or 15
end

local function set_signal_for_state(node, signal)
	local def = core.registered_nodes[node.name]
	local basename = def._mcl_pressureplate_basename
	if signal == 0 then
		return {name = basename .. "_off", param2 = 0}
	end
	return {name = basename .. "_on", param2 = def._mcl_pressureplate_weighted and signal or 0}
end

local function get_signal_strength(pos, node)
	local def = core.registered_nodes[node.name]
	local weighted = def._mcl_pressureplate_weighted
	local count = count_entities(pos, def._mcl_pressureplate_activated_by)
	if weighted then
		-- WeightedPressurePlateBlock: maxWeight 15 (light) or 150 (heavy)
		local max = weighted * 15
		count = math.min(count, max)
		if count > 0 then
			return math.ceil(math.min(max, count) / max * 15)
		end
		return 0
	end
	return count > 0 and 15 or 0
end

local function update_neighbours(pos, block)
	mcl_redstone.update_neighbors_at(pos, block)
	mcl_redstone.update_neighbors_at(rel(pos, DOWN), block)
end

-- BasePressurePlateBlock.checkPressed; `source` is the entity that stepped
-- on it (entityInside) or nil (tick)
local function check_pressed(pos, node, old, source)
	local def = core.registered_nodes[node.name]
	local block = def._mcl_pressureplate_basename
	local signal = get_signal_strength(pos, node)
	local was, is = old > 0, signal > 0
	if old ~= signal then
		mcl_redstone.set_block(pos, set_signal_for_state(node, signal), 2)
		update_neighbours(pos, block)
	end
	if not is and was then
		core.sound_play("mesecons_button_push", {pos = pos, gain = 0.3, pitch = 0.8}, true)
		if mcl_gameevent then
			mcl_gameevent.emit("block_deactivate", pos, {source = source})
		end
	elseif is and not was then
		core.sound_play("mesecons_button_push", {pos = pos, gain = 0.3, pitch = 0.9}, true)
		if mcl_gameevent then
			mcl_gameevent.emit("block_activate", pos, {source = source})
		end
	end
	if is then
		mcl_redstone.schedule_tick(pos, block, def._mcl_pressureplate_weighted and 10 or 20)
	end
end

local function can_survive(pos)
	local below = rel(pos, DOWN)
	local node = mcl_redstone.get_node(below)
	return mcl_redstone.can_support_rigid_block(below, node) or mcl_redstone.can_support_center(below, node, UP)
end

local function make_behaviour(basename)
	return {
		block = basename,
		signal_source = true,
		push_reaction = "destroy",
		own_signal = function(pos, node)
			return get_signal_for_state(node)
		end,
		get_signal = function(pos, node)
			return get_signal_for_state(node)
		end,
		get_direct_signal = function(pos, node, d)
			return d == UP and get_signal_for_state(node) or 0
		end,
		tick = function(pos, node)
			local signal = get_signal_for_state(node)
			if signal > 0 then
				check_pressed(pos, node, signal)
			end
		end,
		affect_neighbors_after_removal = function(pos, node, moved)
			if not moved and get_signal_for_state(node) > 0 then
				update_neighbours(pos, basename)
			end
		end,
		update_shape = function(pos, node, d)
			if d == DOWN and not can_survive(pos) then
				return {name = "air"}
			end
		end,
	}
end

-- BasePressurePlateBlock.entityInside
local function on_object_in(pos, _, obj)
	pos = vector.round(pos)
	local node = core.get_node(pos)
	if core.get_item_group(node.name, "pressure_plate") == 0 then
		return
	end
	if get_signal_for_state(node) == 0 then
		mcl_redstone._begin()
		check_pressed(pos, node, 0, type(obj) == "userdata" and obj or nil)
		mcl_redstone._end()
	end
end

function mcl_pressureplates.register_pressure_plate(basename, def)
	local groups_off = table.copy(def.groups)
	groups_off.attached_node = 1
	groups_off.dig_by_piston = 1
	groups_off.unsticky = 1
	groups_off.pressure_plate = 1
	local groups_on = table.copy(groups_off)
	groups_on.not_in_creative_inventory = 1
	groups_on.dig_by_piston = 1
	groups_on.unsticky = 1
	groups_on.pressure_plate = 2

	local tt = S("Provides redstone power when pushed")
	if not def.activated_by then
		tt = tt .. "\n" .. S("Pushable by players, mobs and objects")
	elseif def.activated_by.mob and def.activated_by.player then
		tt = tt .. "\n" .. S("Pushable by players and mobs")
	elseif def.activated_by.mob then
		tt = tt .. "\n" .. S("Pushable by mobs")
	elseif def.activated_by.player then
		tt = tt .. "\n" .. S("Pushable by players")
	end

	local basename = "mcl_pressureplates:pressure_plate_"..basename
	local commdef = {
		drawtype = "nodebox",
		wield_image = def.texture,
		paramtype = "light",
		walkable = false,
		description = def.description,
		tiles = { def.texture },
		drop = basename.."_off",
		_on_object_in = on_object_in,
		sounds = def.sounds,
		is_ground_content = false,
		_mcl_pressureplate_basename = basename,
		_mcl_pressureplate_activated_by = def.activated_by or { any = true },
		_mcl_pressureplate_weighted = def.weighted,
		_mcl_burntime = def.burntime,
		_mcl_hardness = 0.5,
		_mcl_redstone = make_behaviour(basename),
	}

	core.register_node(":"..basename.."_off", table.merge(commdef, {
		node_box = pp_box_off,
		selection_box = pp_box_off,
		groups = groups_off,
		_doc_items_longdesc = def.longdesc,
		_tt_help = tt,
	}))
	core.register_node(":"..basename.."_on", table.merge(commdef, {
		node_box = pp_box_on,
		selection_box = pp_box_on,
		groups = groups_on,
		description = "",
		_doc_items_create_entry = false,
	}))
	core.register_craft({
		output = basename.."_off",
		recipe = {{def.recipeitem, def.recipeitem}},
	})

	doc.add_entry_alias("nodes", basename .. "_off", "nodes", basename .. "_on")
end

mcl_pressureplates.register_pressure_plate("stone", {
	description = S("Stone Pressure Plate"),
	texture = "default_stone.png",
	recipeitem = "mcl_core:stone",
	sounds = mcl_sounds.node_sound_stone_defaults(),
	groups = {pickaxey=1, material_stone=1},
	activated_by = { player = true, mob = true },
	longdesc = S("A stone pressure plate is a redstone component which supplies its surrounding blocks with redstone power while a player or mob stands on top of it. It is not triggered by anything else."),
})

mcl_pressureplates.register_pressure_plate("polished_blackstone", {
	description = S("Polished Blackstone Pressure Plate"),
	texture = "mcl_blackstone_polished.png",
	recipeitem = "mcl_blackstone:blackstone_polished",
	sounds = mcl_sounds.node_sound_stone_defaults(),
	groups = {pickaxey=1, material_stone=1},
	activated_by = { player = true, mob = true },
	longdesc = S("A polished blackstone pressure plate is a redstone component which supplies its surrounding blocks with redstone power while a player or mob stands on top of it. It is not triggered by anything else."),
})

mcl_pressureplates.register_pressure_plate("light", {
	description = S("Light Weighted Pressure Plate"),
	texture = "default_gold_block.png",
	recipeitem = "mcl_core:gold_ingot",
	sounds = mcl_sounds.node_sound_stone_defaults(),
	groups = {pickaxey=1},
	weighted = 1,
	longdesc = S("A heavy weighted pressure plate is a redstone component which supplies its surrounding blocks with one redstone power for every movable object (including dropped items, players and mobs) that rests on top of it."),
})

mcl_pressureplates.register_pressure_plate("heavy", {
	description = S("Heavy Weighted Pressure Plate"),
	texture = "default_steel_block.png",
	recipeitem = "mcl_core:iron_ingot",
	sounds = mcl_sounds.node_sound_stone_defaults(),
	groups = {pickaxey=1},
	weighted = 10,
	longdesc = S("A heavy weighted pressure plate is a redstone component which supplies its surrounding blocks with one redstone power for every 10 movable objects (including dropped items, players and mobs) that rest on top of it."),
})
