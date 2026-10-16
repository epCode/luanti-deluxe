-- Port of Minecraft's PistonBaseBlock, PistonHeadBlock and MovingPistonBlock.
--
-- Pistons, heads and moving blocks use facedir; the piston pushes towards
-- -facedir_to_dir(param2) (FACING).

local S = core.get_translator(core.get_current_modname())

local DOWN, UP = mcl_redstone.DOWN, mcl_redstone.UP
local dirvec = mcl_redstone.dirvec
local opposite = mcl_redstone.opposite
local rel = mcl_redstone.rel
local get_node = mcl_redstone.get_node

local MOVING_PISTON = mcl_pistons.MOVING_PISTON
local PISTON_HEAD = mcl_pistons.PISTON_HEAD

local TRIGGER_EXTEND = 0
local TRIGGER_CONTRACT = 1
local TRIGGER_DROP = 2

local function facing(node)
	return mcl_redstone.dir_index(vector.multiply(core.facedir_to_dir(node.param2), -1)) or UP
end

local function facedir_for(d)
	return core.dir_to_facedir(vector.multiply(dirvec[d], -1), true)
end

local function is_sticky_piston(node)
	return core.get_item_group(node.name, "piston") == 2
end

local function is_extended(node)
	return core.get_item_group(node.name, "piston_extended") ~= 0
end

local function spec(node)
	return core.registered_nodes[node.name]._piston_spec
end

-- PistonBaseBlock.getNeighborSignal (with quasi-connectivity)
local function get_neighbor_signal(pos, push_d)
	for d = 0, 5 do
		if d ~= push_d and mcl_redstone.has_signal(rel(pos, d), d) then
			return true
		end
	end
	if mcl_redstone.has_signal(pos, DOWN) then
		return true
	end
	local above = rel(pos, UP)
	for d = 0, 5 do
		if d ~= DOWN and mcl_redstone.has_signal(rel(above, d), d) then
			return true
		end
	end
	return false
end

local function block_of(node)
	return is_sticky_piston(node) and "mcl_pistons:piston_sticky" or "mcl_pistons:piston"
end

-- PistonBaseBlock.checkIfExtend
local function check_if_extend(pos, node)
	local d = facing(node)
	local extend = get_neighbor_signal(pos, d)
	if extend and not is_extended(node) then
		if mcl_pistons.new_resolver(pos, d, true):resolve() then
			mcl_redstone.block_event(pos, block_of(node), TRIGGER_EXTEND, d)
		end
	elseif not extend and is_extended(node) then
		local pushed = rel(pos, d, 2)
		local event = TRIGGER_CONTRACT
		local be = mcl_pistons.get_moving_entity(pushed)
		if mcl_pistons.is_moving_piston(get_node(pushed)) and be and be.direction == d and be.extending
				and (be.progress_o < 0.5 or mcl_redstone.get_game_time() == be.last_ticked
					or mcl_redstone.is_handling_tick()) then
			event = TRIGGER_DROP
		end
		mcl_redstone.block_event(pos, block_of(node), event, d)
	end
end

local function play(pos, name, pitch)
	core.sound_play(name, {pos = pos, gain = 0.5, max_hear_distance = 16, pitch = pitch}, true)
end

local function moving_piston_node(d, sticky)
	return {name = "mcl_pistons:moving_piston_end", param2 = facedir_for(d)}
end

-- PistonBaseBlock.moveBlocks
local function move_blocks(pos, d, extending, node)
	local sp = spec(node)
	local arm = rel(pos, d)
	if not extending and mcl_redstone.block_id(get_node(arm).name) == PISTON_HEAD then
		mcl_redstone.set_block(arm, {name = "air"}, 276)
	end
	local resolver = mcl_pistons.new_resolver(pos, d, extending)
	if not resolver:resolve() then
		return false
	end
	local to_push = resolver.to_push
	local to_destroy = resolver.to_destroy
	-- deleteAfterMove: a HashMap, iterated in Java's order further down
	local delete_after_move = {}
	local to_push_shapes = {}
	local data = {}
	for i, p in ipairs(to_push) do
		local n = get_node(p)
		to_push_shapes[i] = n
		delete_after_move[mcl_redstone.hash(p)] = {pos = p, node = n}
		-- Data Minecraft would not move but Mineclonia nodes keep
		local meta = core.get_meta(p):to_table()
		local timer = core.get_node_timer(p)
		data[i] = {
			meta = (next(meta.fields) or next(meta.inventory)) and meta or nil,
			timer = timer:is_started() and {timer:get_timeout(), timer:get_elapsed()} or nil,
		}
	end
	local to_update = {}
	local push_d = extending and d or opposite[d]

	for i = #to_destroy, 1, -1 do
		local p = to_destroy[i]
		local n = get_node(p)
		mcl_redstone.drop_resources(p, n)
		mcl_redstone.set_block(p, {name = "air"}, 18)
		if mcl_gameevent then
			mcl_gameevent.emit("block_destroy", p, {node = n})
		end
		to_update[#to_update + 1] = n
	end

	for i = #to_push, 1, -1 do
		local p = to_push[i]
		local n = get_node(p)
		local np = rel(p, push_d)
		delete_after_move[mcl_redstone.hash(np)] = nil
		mcl_redstone.set_block(np, moving_piston_node(d), 324)
		mcl_pistons.new_moving_entity(np, to_push_shapes[i], d, extending, false,
			{meta = data[i].meta, timer = data[i].timer, old_pos = p})
		to_update[#to_update + 1] = n
	end

	if extending then
		local head = {name = sp.pusher, param2 = facedir_for(d)}
		delete_after_move[mcl_redstone.hash(arm)] = nil
		mcl_redstone.set_block(arm, moving_piston_node(d, sp.sticky), 324)
		mcl_pistons.new_moving_entity(arm, head, d, true, true, {sticky = sp.sticky})
	end

	local remaining = {}
	for _, p in ipairs(to_push) do
		if delete_after_move[mcl_redstone.hash(p)] then
			remaining[#remaining + 1] = p
		end
	end
	remaining = mcl_redstone.java_hash_order(remaining)
	for _, p in ipairs(remaining) do
		mcl_redstone.set_block(p, {name = "air"}, 82)
	end
	local air = {name = "air", param2 = 0}
	for _, p in ipairs(remaining) do
		local old = delete_after_move[mcl_redstone.hash(p)].node
		local ob = mcl_redstone.get_block(old.name)
		if ob.update_indirect_neighbour_shapes then
			ob.update_indirect_neighbour_shapes(p, old, 2, 511)
		end
		mcl_redstone.update_neighbour_shapes(p, air, 2)
	end

	local k = 1
	for i = #to_destroy, 1, -1 do
		local n = to_update[k]
		k = k + 1
		local p = to_destroy[i]
		local b = mcl_redstone.get_block(n.name)
		if b.affect_neighbors_after_removal then
			b.affect_neighbors_after_removal(p, n, false)
		end
		if b.update_indirect_neighbour_shapes then
			b.update_indirect_neighbour_shapes(p, n, 2, 511)
		end
		mcl_redstone.update_neighbors_at(p, mcl_redstone.block_id(n.name))
	end
	for i = #to_push, 1, -1 do
		mcl_redstone.update_neighbors_at(to_push[i], mcl_redstone.block_id(to_update[k].name))
		k = k + 1
	end
	if extending then
		mcl_redstone.update_neighbors_at(arm, PISTON_HEAD)
	end
	return true
end

-- PistonBaseBlock.triggerEvent
local function trigger_event(pos, node, b0, b1)
	local d = facing(node)
	local sp = spec(node)
	local extended_node = {name = sp.onname, param2 = node.param2}
	local extend = get_neighbor_signal(pos, d)
	if extend and (b0 == TRIGGER_CONTRACT or b0 == TRIGGER_DROP) then
		mcl_redstone.set_block(pos, extended_node, 2)
		return false
	end
	if not extend and b0 == TRIGGER_EXTEND then
		return false
	end

	if b0 == TRIGGER_EXTEND then
		if not move_blocks(pos, d, true, node) then
			return false
		end
		mcl_redstone.set_block(pos, extended_node, 67)
		play(pos, "piston_extend", math.random() * 0.25 + 0.6)
		if mcl_gameevent then
			mcl_gameevent.emit("block_activate", pos, {node = extended_node})
		end
		local below = rel(rel(pos, d), DOWN)
		local bnode = get_node(below)
		if bnode.name == "mcl_farming:soil" or bnode.name == "mcl_farming:soil_wet" then
			core.set_node(below, {name = "mcl_core:dirt"})
		end
	else
		local arm = rel(pos, d)
		local be = mcl_pistons.get_moving_entity(arm)
		if be then
			mcl_pistons.final_tick(be)
		end
		local moving = moving_piston_node(d, sp.sticky)
		mcl_redstone.set_block(pos, moving, 276)
		mcl_pistons.new_moving_entity(pos, {name = sp.offname, param2 = facedir_for(b1 % 8)}, d, false, true,
			{sticky = sp.sticky})
		mcl_redstone.update_neighbors_at(pos, MOVING_PISTON)
		mcl_redstone.update_neighbour_shapes(pos, moving, 2)
		if sp.sticky then
			local two = rel(pos, d, 2)
			local mnode = get_node(two)
			local piece = false
			local mbe = mcl_pistons.get_moving_entity(two)
			if mcl_pistons.is_moving_piston(mnode) and mbe and mbe.direction == d and mbe.extending then
				mcl_pistons.final_tick(mbe)
				piece = true
			end
			if not piece then
				if b0 ~= TRIGGER_CONTRACT or mnode.name == "air"
						or not mcl_pistons.is_pushable(mnode, two, opposite[d], false, d)
						or (mcl_pistons.get_push_reaction(mnode) ~= "normal" and core.get_item_group(mnode.name, "piston") == 0) then
					mcl_redstone.remove_block(arm, false)
				else
					move_blocks(pos, d, false, node)
				end
			end
		else
			mcl_redstone.remove_block(arm, false)
		end
		play(pos, "piston_retract", math.random() * 0.15 + 0.6)
		if mcl_gameevent then
			mcl_gameevent.emit("block_deactivate", pos, {node = moving})
		end
	end
	return true
end

local function base_behaviour(block)
	return {
		block = block,
		conductor = false,
		neighbor_changed = function(pos, node)
			check_if_extend(pos, node)
		end,
		on_place = function(pos, node, oldnode)
			if mcl_redstone.block_id(oldnode.name) ~= block and not mcl_pistons.get_moving_entity(pos) then
				check_if_extend(pos, node)
			end
		end,
		trigger_event = trigger_event,
	}
end

-- PistonBaseBlock.getStateForPlacement and setPlacedBy
local function piston_on_place(itemstack, placer, pointed_thing)
	if pointed_thing.type ~= "node" then
		return itemstack
	end
	local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
	if rc then return rc end
	local d = opposite[mcl_redstone.nearest_looking_direction(placer)]
	return core.item_place_node(itemstack, placer, pointed_thing, facedir_for(d))
end

local function piston_after_place_node(pos, placer)
	local meta = core.get_meta(pos)
	local owner = placer and placer.get_player_name and placer:get_player_name()
	meta:set_string("owner", owner and owner ~= "" and owner or "$unknown")
	mcl_redstone._begin()
	check_if_extend(pos, get_node(pos))
	mcl_redstone._end()
end

-- PistonHeadBlock -------------------------------------------------------------------

local function head_base_pos(pos, node)
	return rel(pos, opposite[facing(node)])
end

local function is_head_sticky(node)
	return node.name == "mcl_pistons:piston_pusher_sticky"
end

-- PistonHeadBlock.isFittingBase
local function is_fitting_base(head, base)
	local want = is_head_sticky(head) and "mcl_pistons:piston_sticky" or "mcl_pistons:piston"
	return mcl_redstone.block_id(base.name) == want and is_extended(base) and facing(base) == facing(head)
end

local function head_can_survive(pos, node)
	local bpos = head_base_pos(pos, node)
	local base = get_node(bpos)
	if is_fitting_base(node, base) then
		return true
	end
	local be = mcl_pistons.get_moving_entity(bpos)
	return mcl_pistons.is_moving_piston(base) and be ~= nil and be.direction == facing(node)
end

local head_behaviour = {
	block = PISTON_HEAD,
	push_reaction = "block",
	affect_neighbors_after_removal = function(pos, node)
		local bpos = head_base_pos(pos, node)
		if is_fitting_base(node, get_node(bpos)) then
			mcl_redstone.destroy_block(bpos, true)
		end
	end,
	update_shape = function(pos, node, d)
		if d == opposite[facing(node)] and not head_can_survive(pos, node) then
			return {name = "air"}
		end
	end,
	neighbor_changed = function(pos, node, from_block)
		if head_can_survive(pos, node) then
			mcl_redstone.neighbor_changed(head_base_pos(pos, node), from_block, pos)
		end
	end,
}

-- Nodes --------------------------------------------------------------------------------

local pt = 4/16 -- pusher thickness

local piston_pusher_box = {
	type = "fixed",
	fixed = {
		{-2/16, -2/16, -.5 + pt, 2/16, 2/16,  .5 + pt},
		{-.5  , -.5  , -.5     , .5  , .5  , -.5 + pt},
	},
}

local piston_on_box = {
	type = "fixed",
	fixed = {
		{-.5, -.5, -.5 + pt, .5, .5, .5}
	},
}

local usagehelp_piston = S("This block can have one of 6 possible orientations.")

local commdef = {
	_doc_items_create_entry = false,
	groups = {handy=1, pickaxey=1, not_opaque=1},
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	sounds = mcl_sounds.node_sound_stone_defaults(),
	_mcl_hardness = 0.5,
	on_rotate = false,
}

local base_tiles = {
	"mesecons_piston_bottom.png^[transformR180",
	"mesecons_piston_bottom.png",
	"mesecons_piston_bottom.png^[transformR90",
	"mesecons_piston_bottom.png^[transformR270",
	"mesecons_piston_back.png",
}

local function register_piston(spec_, desc, tt, longdesc, front_tile, group)
	local behaviour = base_behaviour(spec_.block)
	local def = table.merge(commdef, {
		description = desc,
		groups = table.merge(commdef.groups, {piston = group}),
		_piston_spec = spec_,
		_mcl_redstone = behaviour,
	})
	core.register_node(spec_.offname, table.merge(def, {
		_doc_items_create_entry = true,
		_tt_help = tt,
		_doc_items_longdesc = longdesc,
		_doc_items_usagehelp = usagehelp_piston,
		tiles = table.insert_all(table.copy(base_tiles), {front_tile}),
		on_place = piston_on_place,
		after_place_node = piston_after_place_node,
	}))
	core.register_node(spec_.onname, table.merge(def, {
		drawtype = "nodebox",
		node_box = piston_on_box,
		selection_box = piston_on_box,
		tiles = table.insert_all(table.copy(base_tiles), {"mesecons_piston_on_front.png"}),
		groups = table.merge(def.groups, {not_in_creative_inventory = 1, piston_extended = 1}),
		drop = spec_.offname,
	}))
	core.register_node(spec_.pusher, {
		drawtype = "nodebox",
		paramtype = "light",
		paramtype2 = "facedir",
		is_ground_content = false,
		drop = "",
		selection_box = piston_pusher_box,
		node_box = piston_pusher_box,
		sounds = mcl_sounds.node_sound_wood_defaults(),
		groups = {handy=1, pickaxey=1, not_in_creative_inventory = 1, unmovable_by_piston = 1},
		_mcl_hardness = 0.5,
		on_rotate = false,
		tiles = {
			"mesecons_piston_pusher_top.png",
			"mesecons_piston_pusher_bottom.png",
			"mesecons_piston_pusher_left.png",
			"mesecons_piston_pusher_right.png",
			"mesecons_piston_pusher_back.png",
			front_tile == "mesecons_piston_pusher_front_sticky.png" and front_tile or "mesecons_piston_pusher_front.png",
		},
		corresponding_piston = spec_.onname,
		_mcl_redstone = head_behaviour,
	})
end

register_piston({
	block = "mcl_pistons:piston",
	offname = "mcl_pistons:piston_off",
	onname = "mcl_pistons:piston_on",
	pusher = "mcl_pistons:piston_pusher",
}, S("Piston"), S("Pushes block when powered by redstone power"),
	S("A piston is a redstone component with a pusher which pushes the block or blocks in front of it when it is supplied with redstone power. Not all blocks can be pushed, however."),
	"mesecons_piston_pusher_front.png", 1)

register_piston({
	block = "mcl_pistons:piston_sticky",
	offname = "mcl_pistons:piston_sticky_off",
	onname = "mcl_pistons:piston_sticky_on",
	pusher = "mcl_pistons:piston_pusher_sticky",
	sticky = true,
}, S("Sticky Piston"), S("Pushes or pulls block when powered by redstone power"),
	S("A sticky piston is a redstone component with a sticky pusher which can be extended and retracted. It extends when it is supplied with redstone power. When the pusher extends, it pushes the block or blocks in front of it. When it retracts, it pulls back the single block in front of it. Note that not all blocks can be pushed or pulled."),
	"mesecons_piston_pusher_front_sticky.png", 2)

-- MovingPistonBlock: invisible; its collision box trails the moving block
-- (facedir points along the movement).
local moving_def = {
	drawtype = "airlike",
	paramtype = "light",
	paramtype2 = "facedir",
	sunlight_propagates = true,
	pointable = false,
	diggable = false,
	buildable_to = false,
	walkable = true,
	drop = "",
	is_ground_content = false,
	groups = {not_in_creative_inventory = 1, unmovable_by_piston = 1, moving_piston = 1},
	on_blast = function() end,
	_mcl_hardness = -1,
	_mcl_blast_resistance = 0,
	_mcl_redstone = {
		block = MOVING_PISTON,
		conductor = false,
		push_reaction = "block",
	},
}
for name, behind in pairs({
	["mcl_pistons:moving_piston"] = 1,
	["mcl_pistons:moving_piston_half"] = 0.5,
	["mcl_pistons:moving_piston_end"] = 0,
}) do
	core.register_node(name, table.merge(moving_def, {
		collision_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5 - behind, 0.5, 0.5, 0.5 - behind}},
	}))
end

--craft recipes
core.register_craft({
	output = "mcl_pistons:piston_off",
	recipe = {
		{"group:wood", "group:wood", "group:wood"},
		{"mcl_core:cobble", "mcl_core:iron_ingot", "mcl_core:cobble"},
		{"mcl_core:cobble", "mcl_redstone:redstone", "mcl_core:cobble"},
	},
})

core.register_craft({
	output = "mcl_pistons:piston_sticky_off",
	recipe = {
		{"mcl_mobitems:slimeball"},
		{"mcl_pistons:piston_off"},
	},
})

-- Add entry aliases for the Help
doc.add_entry_alias("nodes", "mcl_pistons:piston_off", "nodes", "mcl_pistons:piston_on")
doc.add_entry_alias("nodes", "mcl_pistons:piston_off", "nodes", "mcl_pistons:piston_pusher")
doc.add_entry_alias("nodes", "mcl_pistons:piston_sticky_off", "nodes", "mcl_pistons:piston_sticky_on")
doc.add_entry_alias("nodes", "mcl_pistons:piston_sticky_off", "nodes", "mcl_pistons:piston_pusher_sticky")
