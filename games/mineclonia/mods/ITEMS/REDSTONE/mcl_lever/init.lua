local S = core.get_translator(core.get_current_modname())

local function on_rotate(pos, node, user, mode)
	if mode == screwdriver.ROTATE_FACE then
		if node.param2 == 10 then
			node.param2 = 13
			core.swap_node(pos, node)
			return true
		elseif node.param2 == 13 then
			node.param2 = 10
			core.swap_node(pos, node)
			return true
		elseif node.param2 == 8 then
			node.param2 = 15
			core.swap_node(pos, node)
			return true
		elseif node.param2 == 15 then
			node.param2 = 8
			core.swap_node(pos, node)
			return true
		end
	end
	-- TODO: Rotate axis
	return false
end

-- Port of Minecraft's LeverBlock. The facedir of param2 points to the block
-- the lever is attached to.

local BLOCK = "mcl_lever:lever"
local rel = mcl_redstone.rel
local opposite = mcl_redstone.opposite

local function attached_dir(node)
	return mcl_redstone.dir_index(core.facedir_to_dir(node.param2)) or mcl_redstone.DOWN
end

-- FaceAttachedHorizontalDirectionalBlock.canAttach
local function can_attach(pos, a)
	local spos = rel(pos, a)
	return mcl_redstone.is_face_sturdy(spos, mcl_redstone.get_node(spos), opposite[a], "full")
end

local function is_powered(node)
	return node.name == "mcl_lever:lever_on"
end

-- LeverBlock.updateNeighbours
local function update_neighbours(pos, node)
	mcl_redstone.update_neighbors_at(pos, BLOCK)
	mcl_redstone.update_neighbors_at(rel(pos, attached_dir(node)), BLOCK)
end

-- LeverBlock.pull
local function pull(pos, node)
	mcl_redstone._begin()
	local new = {name = is_powered(node) and "mcl_lever:lever_off" or "mcl_lever:lever_on", param2 = node.param2}
	mcl_redstone.set_block(pos, new, 3)
	update_neighbours(pos, new)
	mcl_redstone._end()
	core.sound_play("mesecons_button_push", {pos = pos, gain = 0.3, max_hear_distance = 16,
		pitch = is_powered(new) and 1.0 or 0.9}, true)
	-- Minecraft pulls levers with a null player (useWithoutItem too)
	if mcl_gameevent then
		mcl_gameevent.emit(is_powered(new) and "block_activate" or "block_deactivate", pos, {})
	end
end

local behaviour = {
	block = BLOCK,
	signal_source = true,
	push_reaction = "destroy",
	own_signal = function(pos, node)
		return is_powered(node) and 15 or 0
	end,
	get_signal = function(pos, node)
		return is_powered(node) and 15 or 0
	end,
	get_direct_signal = function(pos, node, d)
		return is_powered(node) and d == opposite[attached_dir(node)] and 15 or 0
	end,
	affect_neighbors_after_removal = function(pos, node, moved)
		if not moved and is_powered(node) then
			update_neighbours(pos, node)
		end
	end,
	-- LeverBlock.animateTick / makeParticle
	animate = function(pos, node, name)
		if is_powered(node) and math.random() < 0.25 then
			local v = mcl_redstone.dirvec[attached_dir(node)]
			mcl_redstone.dust_particle(name, vector.offset(pos, 0.2 * v.x, 0.2 * v.y, 0.2 * v.z),
				mcl_redstone.REDSTONE_DUST, 0.5)
		end
	end,
	update_shape = function(pos, node, d)
		local a = attached_dir(node)
		if d == a and not can_attach(pos, a) then
			return {name = "air"}
		end
	end,
}

local commdef = {
	drawtype = "mesh",
	tiles = {"default_cobble.png^mesecons_walllever_lever.png"},
	paramtype = "light",
	paramtype2 = "facedir",
	sunlight_propagates = true,
	walkable = false,
	selection_box = {
		type = "fixed",
		fixed = { -3/16, -4/16, 2/16, 3/16, 4/16, 8/16 },
	},
	groups = {
		handy = 1,
		dig_by_water = 1,
		destroy_by_lava_flow = 1,
		dig_by_piston = 1,
		attached_node_facedir = 1,
		unsticky = 1
	},
	is_ground_content = false,
	drop = "mcl_lever:lever_off",
	description=S("Lever"),
	node_placement_prediction = "",
	sounds = mcl_sounds.node_sound_stone_defaults(),
	on_rotate = on_rotate,
	_mcl_hardness = 0.5,
	_mcl_redstone = behaviour,
	on_rightclick = function(pos, node)
		pull(pos, node)
	end,
}

-- LEVER
core.register_node("mcl_lever:lever_off", table.merge(commdef, {
	inventory_image = "mesecons_walllever_lever_inv.png",
	wield_image = "mesecons_walllever_lever_inv.png",
	mesh = "mesecons_walllever_lever_off.obj",
	_tt_help = S("Provides redstone power while it's turned on"),
	_doc_items_longdesc = S("A lever is a redstone component which can be flipped on and off. It supplies redstone power to adjacent blocks while it is in the “on” state."),
	_doc_items_usagehelp = S("Use the lever to flip it on or off."),
	on_place = function(itemstack, placer, pointed_thing)
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
			groups = def and def.groups
		end

		-- FaceAttachedHorizontalDirectionalBlock.canSurvive: the face of the
		-- block it attaches to must be sturdy
		local support = def.buildable_to and vector.subtract(under, vector.subtract(pointed_thing.above, under)) or under
		if type(def and def.placement_prevented) == "function" then
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

		local above = pointed_thing.above
		local dir = vector.subtract(under, above)
		local tau = math.pi*2
		local wdir = core.dir_to_facedir(dir, true)
		if dir.y ~= 0 then
			local yaw = placer:get_look_horizontal()
			if (yaw > tau/8 and yaw < (tau/8)*3) or (yaw < (tau/8)*7 and yaw > (tau/8)*5) then
				if dir.y == -1 then
					wdir = 13
				else
					wdir = 15
				end
			else
				if dir.y == -1 then
					wdir = 10
				else
					wdir = 8
				end
			end
		end

		local idef = itemstack:get_definition()
		local itemstack, success = core.item_place_node(itemstack, placer, pointed_thing, wdir)

		if success then
			if idef.sounds and idef.sounds.place then
				core.sound_play(idef.sounds.place, {pos=above, gain=1}, true)
			end
		end
		return itemstack
	end,
}))

core.register_node("mcl_lever:lever_on", table.merge(commdef, {
	drawtype = "mesh",
	mesh = "mesecons_walllever_lever_on.obj",
	groups = table.merge(commdef.groups, {not_in_creative_inventory = 1}),
	_doc_items_create_entry = false,
}))

core.register_craft({
	output = "mcl_lever:lever_off",
	recipe = {
		{"mcl_core:stick"},
		{"mcl_core:cobble"},
	}
})

doc.add_entry_alias("nodes", "mcl_lever:lever_off", "nodes", "mcl_lever:lever_on")
