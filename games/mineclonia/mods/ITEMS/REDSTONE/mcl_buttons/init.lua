local S = core.get_translator(core.get_current_modname())

mcl_buttons = {}

-- Port of Minecraft's ButtonBlock. param2 (wallmounted) points to the block
-- the button is attached to.

local rel = mcl_redstone.rel
local opposite = mcl_redstone.opposite

local function attached_dir(node)
	return mcl_redstone.dir_index(core.wallmounted_to_dir(node.param2)) or mcl_redstone.DOWN
end

local function can_attach(pos, a)
	local spos = rel(pos, a)
	return mcl_redstone.is_face_sturdy(spos, mcl_redstone.get_node(spos), opposite[a], "full")
end

local function block_of(def)
	return "mcl_buttons:button_" .. def._mcl_button_basename
end

-- ButtonBlock.updateNeighbours
local function update_neighbours(pos, node, block)
	mcl_redstone.update_neighbors_at(pos, block)
	mcl_redstone.update_neighbors_at(rel(pos, attached_dir(node)), block)
end

local function play_sound(pos, def, pressed)
	core.sound_play(def._mcl_redstone_push_sound, {pos = pos, pitch = pressed and 1.0 or 0.9}, true)
end

-- An arrow stuck in the button (ButtonBlock.checkPressed)
local function has_arrow(pos, node)
	local boxes = core.get_node_boxes("selection_box", pos, node)
	for _, b in ipairs(boxes) do
		-- Stuck arrows have their position at the support's face
		local minp = vector.offset(pos, math.min(b[1], b[4]) - 0.125, math.min(b[2], b[5]) - 0.125, math.min(b[3], b[6]) - 0.125)
		local maxp = vector.offset(pos, math.max(b[1], b[4]) + 0.125, math.max(b[2], b[5]) + 0.125, math.max(b[3], b[6]) + 0.125)
		for _, obj in ipairs(core.get_objects_in_area(minp, maxp)) do
			local ent = obj:get_luaentity()
			if ent and (ent._is_arrow or ent.name == "mcl_tridents:trident_entity") then
				return obj
			end
		end
	end
	return nil
end

local function check_pressed(pos, node)
	local def = core.registered_nodes[node.name]
	local block = block_of(def)
	local first_arrow = def._mcl_button_push_by_arrow and has_arrow(pos, node) or nil
	local should = first_arrow ~= nil
	local was = core.get_item_group(node.name, "button_on") ~= 0
	if should ~= was then
		local new = {name = block .. (should and "_on" or "_off"), param2 = node.param2}
		mcl_redstone.set_block(pos, new, 3)
		update_neighbours(pos, new, block)
		play_sound(pos, def, should)
		if mcl_gameevent then
			mcl_gameevent.emit(should and "block_activate" or "block_deactivate", pos, {source = first_arrow})
		end
	end
	if should then
		mcl_redstone.schedule_tick(pos, block, def._mcl_button_push_duration * 2)
	end
end

-- ButtonBlock.press; `player` is the player pushing it or nil
function mcl_buttons.push_button(pos, node, player)
	local def = core.registered_nodes[node.name]
	if not def or not def._mcl_button_basename or core.get_item_group(node.name, "button_on") ~= 0 then
		return
	end
	local block = block_of(def)
	mcl_redstone._begin()
	local new = {name = block .. "_on", param2 = node.param2}
	mcl_redstone.set_block(pos, new, 3)
	update_neighbours(pos, new, block)
	mcl_redstone.schedule_tick(pos, block, def._mcl_button_push_duration * 2)
	mcl_redstone._end()
	play_sound(pos, def, true)
	if mcl_gameevent then
		mcl_gameevent.emit("block_activate", pos, {source = core.is_player(player) and player or nil})
	end
end

local function make_behaviour(basename, powered)
	local block = "mcl_buttons:button_" .. basename
	return {
		block = block,
		signal_source = true,
		push_reaction = "destroy",
		own_signal = function()
			return powered and 15 or 0
		end,
		get_signal = function()
			return powered and 15 or 0
		end,
		get_direct_signal = function(pos, node, d)
			return powered and d == opposite[attached_dir(node)] and 15 or 0
		end,
		affect_neighbors_after_removal = function(pos, node, moved)
			if not moved and powered then
				update_neighbours(pos, node, block)
			end
		end,
		update_shape = function(pos, node, d)
			local a = attached_dir(node)
			if d == a and not can_attach(pos, a) then
				return {name = "air"}
			end
		end,
		tick = function(pos, node)
			if powered then
				check_pressed(pos, node)
			end
		end,
	}
end

local function on_button_place(itemstack, placer, pointed_thing)
	if pointed_thing.type ~= "node" or not placer or not placer:is_player() then
		-- no interaction possible with entities
		return itemstack
	end

	local under = pointed_thing.under
	local node = core.get_node(under)
	local def = core.registered_nodes[node.name]
	if not def then return end
	local groups = def.groups

	local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
	if rc then return rc end

	-- If the pointed node is buildable, let's look at the node *behind* that node
	if def.buildable_to then
		local dir = vector.subtract(pointed_thing.above, pointed_thing.under)
		local actual = vector.subtract(under, dir)
		local actualnode = core.get_node(actual)
		def = core.registered_nodes[actualnode.name]
		groups = def and def.groups or nil
	end

	if not def then return end

	-- FaceAttachedHorizontalDirectionalBlock.canSurvive
	local support = def.buildable_to and vector.subtract(under, vector.subtract(pointed_thing.above, under)) or under
	if type(def.placement_prevented) == "function" then
		if
			def.placement_prevented({
				itemstack = itemstack,
				placer = placer,
				pointed_thing = pointed_thing,
			})
		then
			return itemstack
		end
	elseif not mcl_redstone.is_face_sturdy(support, core.get_node(support),
			mcl_redstone.dir_index(vector.subtract(pointed_thing.above, pointed_thing.under)), "full") then
		return itemstack
	end

	local idef = itemstack:get_definition()
	local itemstack, success = core.item_place_node(itemstack, placer, pointed_thing)

	if success then
		if idef and idef.sounds and idef.sounds.place then
			core.sound_play(idef.sounds.place, {pos=pointed_thing.above, gain=1}, true)
		end
	end
	return itemstack
end

function mcl_buttons.register_button(basename, def)
	local description = def.description
	local texture = def.texture
	local recipeitem = def.recipeitem
	local groups = def.groups
	local sounds = def.sounds
	local push_by_arrow = def.push_by_arrow
	local longdesc = def.longdesc
	local push_duration = def.push_duration
	local push_sound = def.push_sound
	local burntime = def.burntime

	local push_duration_in_seconds = push_duration * 0.1
	local tt = S("Provides redstone power when pushed")
	tt = tt .. "\n" .. S("Push duration: @1s", string.format("%.1f", push_duration_in_seconds ))
	if push_by_arrow then
		tt = tt .. "\n" .. S("Pushable by arrow")
	end
	local commdef = {
		drawtype = "nodebox",
		tiles = {texture},
		wield_image = "mesecons_button_wield_mask.png^"..texture.."^mesecons_button_wield_mask.png^[makealpha:255,126,126",
		inventory_image = "mesecons_button_wield_mask.png^"..texture.."^mesecons_button_wield_mask.png^[makealpha:255,126,126",
		wield_scale = { x=1, y=1, z=1},
		paramtype = "light",
		paramtype2 = "wallmounted",
		is_ground_content = false,
		walkable = false,
		sunlight_propagates = true,
		groups = table.merge(groups, {attached_node=1, dig_by_water=1, dig_by_piston=1, button=1, attaches_to_base=1, attaches_to_side=1, attaches_to_top=1, button_push_by_arrow = push_by_arrow and 1 or 0}),
		description = description,
		_tt_help = tt,
		_doc_items_longdesc = longdesc,
		_doc_items_usagehelp = S("Use the button to push it."),
		on_place = on_button_place,
		node_placement_prediction = "",
		sounds = sounds,
		_mcl_hardness = 0.5,
		_mcl_button_basename = basename,
		_mcl_burntime = burntime,
		_mcl_redstone_push_sound = push_sound or "mesecons_button_push",
		_mcl_button_push_duration = push_duration,
		_mcl_button_push_by_arrow = push_by_arrow,
	}

	core.register_node(":mcl_buttons:button_"..basename.."_off", table.merge(commdef, {
		node_box = {
			type = "wallmounted",
			wall_side = { -8/16, -2/16, -4/16, -6/16, 2/16, 4/16 },
			wall_bottom = { -4/16, -8/16, -2/16, 4/16, -6/16, 2/16 },
			wall_top = { -4/16, 6/16, -2/16, 4/16, 8/16, 2/16 },
		},
		groups = table.merge(commdef.groups, {button=1}),
		_mcl_redstone = make_behaviour(basename, false),
		on_rightclick = function(pos, node, clicker)
			mcl_buttons.push_button(pos, node, clicker)
		end,
		sounds = sounds,
		-- ButtonBlock.entityInside: an arrow presses a wooden button
		_on_arrow_hit = function(pos, arrowent)
			local node = core.get_node(pos)
			local def = core.registered_nodes[node.name]
			if def._mcl_button_push_by_arrow then
				mcl_redstone._begin()
				check_pressed(pos, node)
				mcl_redstone._end()
				return true
			end
		end,
	}))

	core.register_node(":mcl_buttons:button_"..basename.."_on", table.merge(commdef, {
		node_box = {
			type = "wallmounted",
			wall_side = { -8/16, -2/16, -4/16, -7/16, 2/16, 4/16 },
			wall_bottom = { -4/16, -8/16, -2/16, 4/16, -7/16, 2/16 },
			wall_top = { -4/16, 7/16, -2/16, 4/16, 8/16, 2/16 },
		},
		groups = table.merge(commdef.groups, {button=2, button_on=1, not_in_creative_inventory=1}),
		drop = "mcl_buttons:button_"..basename.."_off",
		_doc_items_create_entry = false,
		_mcl_redstone = make_behaviour(basename, true),
		-- ButtonBlock.entityInside: arrows keep a wooden button pressed
		_on_arrow_hit = function(pos, arrowent)
			return false
		end,
	}))

	core.register_craft({
		output = "mcl_buttons:button_"..basename.."_off",
		recipe = {{ recipeitem }},
	})
end

mcl_buttons.register_button("stone", {
	description = S("Stone Button"),
	texture = "default_stone.png",
	recipeitem = "mcl_core:stone",
	sounds = mcl_sounds.node_sound_stone_defaults(),
	groups = {material_stone=1,handy=1,pickaxey=1},
	push_duration = 10,
	push_by_arrow = false,
	longdesc = S("A stone button is a redstone component made out of stone which can be pushed to provide redstone power. When pushed, it powers adjacent redstone components for 1 second."),
	push_sound = "mesecons_button_push",
})

mcl_buttons.register_button("polished_blackstone", {
	description = S("Polished Blackstone Button"),
	texture = "mcl_blackstone_polished.png",
	recipeitem = "mcl_blackstone:blackstone_polished",
	sounds = mcl_sounds.node_sound_stone_defaults(),
	groups = {material_stone=1,handy=1,pickaxey=1},
	push_duration = 10,
	push_by_arrow = false,
	longdesc = S("A polished blackstone button is a redstone component made out of polished blackstone which can be pushed to provide redstone power. When pushed, it powers adjacent redstone components for 1 second."),
	push_sound = "mesecons_button_push",
})

doc.add_entry_alias("nodes", "mcl_buttons:button_wood_off", "nodes", "mcl_buttons:button_wood_on")
doc.add_entry_alias("nodes", "mcl_buttons:button_stone_off", "nodes", "mcl_buttons:button_stone_on")
