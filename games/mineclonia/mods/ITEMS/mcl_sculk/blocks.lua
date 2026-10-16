------------------------------------------------------------------------
-- Sculk, sculk veins and the sculk catalyst
------------------------------------------------------------------------

local S = mcl_sculk.S
local R = mcl_redstone
local G = mcl_gameevent
local ALL = mcl_sculk.DIRECTIONS
local has_face, with_face, without_face = mcl_sculk.has_face, mcl_sculk.with_face, mcl_sculk.without_face

------------------------------------------------------------------------
-- Block entities: per position state with a game tick ticker and game
-- event listeners, created when the node is placed or loaded and removed
-- with it (Minecraft's block entities of the same block survive state
-- changes; the node metadata holds their saved data).
------------------------------------------------------------------------

local entities = {}

local function hash(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

-- def: {block = block id, create = function(pos) -> be table,
--       tick = function(be), remove = function(be)}
function mcl_sculk.register_block_entity(nodenames, def)
	local names = {}
	for _, n in ipairs(nodenames) do
		names[n] = true
	end
	local function get(pos)
		local h = hash(pos)
		local be = entities[h]
		if be and not be.removed and be.def == def then
			return be
		end
		be = def.create(vector.copy(pos))
		be.pos = vector.copy(pos)
		be.def = def
		entities[h] = be
		be.ticker = R.add_ticker({
			pos = be.pos,
			tick = function(t)
				local node = R.get_node(t.pos)
				if not names[node.name] then
					t.removed = true
					mcl_sculk.remove_block_entity(t.pos)
					return
				end
				if def.tick then
					def.tick(be, node)
				end
			end,
		})
		return be
	end
	def.get = get
	core.register_lbm({
		label = "Sculk block entities of " .. nodenames[1],
		name = "mcl_sculk:block_entity_" .. nodenames[1]:gsub(":", "_"),
		nodenames = nodenames,
		run_at_every_load = true,
		action = function(pos)
			get(pos)
		end,
	})
	for _, n in ipairs(nodenames) do
		local ndef = core.registered_nodes[n]
		local old_construct, old_destruct = ndef.on_construct, ndef.on_destruct
		core.override_item(n, {
			on_construct = function(pos)
				if old_construct then
					old_construct(pos)
				end
				get(pos)
			end,
			on_destruct = function(pos)
				if old_destruct then
					old_destruct(pos)
				end
				local be = entities[hash(pos)]
				-- The ticker removes the block entity once the node is
				-- another block; a state change of the same block keeps it
				if be and be.def == def and def.keep_on_destruct then
					return
				end
				mcl_sculk.remove_block_entity(pos)
			end,
		})
	end
	return get
end

function mcl_sculk.get_block_entity(pos)
	local be = entities[hash(pos)]
	if be and not be.removed then
		return be
	end
	return nil
end

function mcl_sculk.remove_block_entity(pos)
	local h = hash(pos)
	local be = entities[h]
	if be then
		be.removed = true
		if be.ticker then
			be.ticker.removed = true
		end
		G.remove_block_listener(pos)
		if be.def.remove then
			be.def.remove(be)
		end
		entities[h] = nil
	end
end

------------------------------------------------------------------------
-- Sculk
------------------------------------------------------------------------

local function sculk_tile(name, length)
	return {name = name, animation = {type = "vertical_frames", aspect_w = 16, aspect_h = 16, length = length}}
end

core.register_node("mcl_sculk:sculk", {
	description = S("Sculk"),
	_doc_items_longdesc = S("Sculk is a block found in the deep dark. It spreads from sculk catalysts when mobs die nearby, and drops experience when mined without Silk Touch."),
	tiles = {sculk_tile("mcl_sculk_sculk.png", 4.0)},
	groups = {handy = 1, hoey = 1, building_block = 1, sculk = 1},
	sounds = mcl_sculk.sounds.sculk,
	is_ground_content = false,
	drop = "",
	_mcl_silk_touch_drop = true,
	after_dig_node = function(pos, _, _, digger)
		-- DropExperienceBlock(ConstantInt.of(1))
		mcl_sculk.drop_experience(pos, digger, 1)
	end,
	_mcl_hardness = 0.2,
	_mcl_blast_resistance = 0.2,
})

------------------------------------------------------------------------
-- Sculk veins (SculkVeinBlock, a MultifaceSpreadeableBlock)
------------------------------------------------------------------------

local vein_mask, vein_node, is_vein = mcl_sculk.vein_mask, mcl_sculk.vein_node, mcl_sculk.is_vein

-- MultifaceBlock shapes: a 1/16 thick plate on each face (Block.boxZ(16, 0, 1))
local PLATE = {
	[R.NORTH] = {-0.5, -0.5, 0.4375, 0.5, 0.5, 0.5},
	[R.SOUTH] = {-0.5, -0.5, -0.5, 0.5, 0.5, -0.4375},
	[R.WEST] = {-0.5, -0.5, -0.5, -0.4375, 0.5, 0.5},
	[R.EAST] = {0.4375, -0.5, -0.5, 0.5, 0.5, 0.5},
	[R.UP] = {-0.5, 0.4375, -0.5, 0.5, 0.5, 0.5},
	[R.DOWN] = {-0.5, -0.5, -0.5, 0.5, -0.4375, 0.5},
}
-- The model: a plane 0.1/16 off the face (models/block/sculk_vein.json)
local OFF = 0.1 / 16
local MODEL = {
	[R.NORTH] = {-0.5, -0.5, 0.5 - OFF, 0.5, 0.5, 0.5 - OFF},
	[R.SOUTH] = {-0.5, -0.5, -0.5 + OFF, 0.5, 0.5, -0.5 + OFF},
	[R.WEST] = {-0.5 + OFF, -0.5, -0.5, -0.5 + OFF, 0.5, 0.5},
	[R.EAST] = {0.5 - OFF, -0.5, -0.5, 0.5 - OFF, 0.5, 0.5},
	[R.UP] = {-0.5, 0.5 - OFF, -0.5, 0.5, 0.5 - OFF, 0.5},
	[R.DOWN] = {-0.5, -0.5 + OFF, -0.5, 0.5, -0.5 + OFF, 0.5},
}

-- Direction.orderedByNearest(entity): the directions sorted by how close
-- they are to the look direction
local function nearest_looking_directions(placer)
	local dir = placer and placer.get_look_dir and placer:get_look_dir() or vector.new(0, -1, 0)
	local list = {}
	for _, d in ipairs(ALL) do
		table.insert(list, {d = d, dot = vector.dot(dir, R.dirvec[d])})
	end
	table.sort(list, function(a, b)
		if a.dot ~= b.dot then
			return a.dot > b.dot
		end
		return a.d < b.d
	end)
	local out = {}
	for i, v in ipairs(list) do
		out[i] = v.d
	end
	return out
end

-- MultifaceBlock.getStateForPlacement(BlockPlaceContext)
local function vein_on_place(itemstack, placer, pointed_thing)
	if pointed_thing.type ~= "node" then
		return itemstack
	end
	local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
	if rc then
		return rc
	end
	local under = pointed_thing.under
	local unode = core.get_node(under)
	local pos
	-- MultifaceBlock.canBeReplaced: a vein with a vacant face
	if is_vein(unode) and vein_mask(unode) ~= 63 then
		pos = under
	else
		local udef = core.registered_nodes[unode.name]
		if udef and udef.buildable_to then
			pos = under
		else
			pos = pointed_thing.above
		end
	end
	local old = core.get_node(pos)
	local odef = core.registered_nodes[old.name]
	if not is_vein(old) and not (odef and odef.buildable_to) then
		return itemstack
	end
	local name = placer and placer:get_player_name() or ""
	if core.is_protected(pos, name) then
		core.record_protection_violation(pos, name)
		return itemstack
	end
	for _, d in ipairs(nearest_looking_directions(placer)) do
		local new = mcl_sculk.vein_state_for_placement(old, pos, d)
		if new then
			core.set_node(pos, new)
			local def = core.registered_nodes[new.name]
			if def.sounds and def.sounds.place then
				core.sound_play(def.sounds.place, {pos = pos}, true)
			end
			for _, cb in ipairs(core.registered_on_placenodes) do
				cb(vector.copy(pos), new, placer, old, itemstack, pointed_thing)
			end
			if not core.is_creative_enabled(name) then
				itemstack:take_item()
			end
			return itemstack
		end
	end
	return itemstack
end

local vein_groups = {
	handy = 1, hoey = 1, deco_block = 1, sculk = 1, sculk_vein = 1,
	dig_by_piston = 1, destroy_by_lava_flow = 1, dig_by_water = 1,
	not_solid = 1,
}

local function vein_def(mask)
	local boxes, model = {}, {}
	local n = 0
	for _, d in ipairs(ALL) do
		if has_face(mask, d) then
			table.insert(boxes, PLATE[d])
			table.insert(model, MODEL[d])
			n = n + 1
		end
	end
	return {
		description = S("Sculk Vein"),
		_doc_items_longdesc = S("Sculk veins cover the faces of the blocks around them in the deep dark."),
		drawtype = "nodebox",
		tiles = {sculk_tile("mcl_sculk_vein.png", 4.0)},
		use_texture_alpha = "clip",
		inventory_image = "mcl_sculk_vein.png^[verticalframe:80:0",
		wield_image = "mcl_sculk_vein.png^[verticalframe:80:0",
		paramtype = "light",
		sunlight_propagates = true,
		walkable = false,
		buildable_to = true,
		node_box = {type = "fixed", fixed = model},
		selection_box = {type = "fixed", fixed = boxes},
		groups = table.copy(vein_groups),
		sounds = mcl_sculk.sounds.vein,
		drop = "",
		-- loot_table/blocks/sculk_vein: one per face, with silk touch
		_mcl_silk_touch_drop = {"mcl_sculk:vein " .. n},
		node_placement_prediction = "",
		on_place = vein_on_place,
		on_rotate = false,
		_mcl_hardness = 0.2,
		_mcl_blast_resistance = 0.2,
		_mcl_redstone = {
			block = "mcl_sculk:vein",
			push_reaction = "destroy",
			-- MultifaceBlock.updateShape
			update_shape = function(pos, node, d, npos, nnode)
				local m = vein_mask(node)
				if m == 0 then
					return {name = "air"}
				end
				if has_face(m, d) and not R.is_face_sturdy(npos, nnode, R.opposite[d], "full") then
					return vein_node(without_face(m, d)) or {name = "air"}
				end
				return nil
			end,
		},
	}
end

-- One face: wallmounted, like glow lichen
do
	local def = vein_def(bit.lshift(1, R.DOWN))
	def.paramtype2 = "wallmounted"
	def.node_box = {type = "fixed", fixed = MODEL[R.DOWN]}
	def.selection_box = {type = "fixed", fixed = PLATE[R.DOWN]}
	def._mcl_silk_touch_drop = true
	core.register_node("mcl_sculk:vein", def)
end

for mask = 1, 63 do
	if mcl_sculk.popcount(mask) > 1 then
		local name = mcl_sculk.vein_name(mask)
		local def = vein_def(mask)
		def.groups.not_in_creative_inventory = 1
		core.register_node(name, def)
		mcl_sculk._vein_mask_by_name[name] = mask
	end
end

-- MultifaceBlock.canSurvive for veins placed by other mods (e.g. a
-- schematic): faces without support fall off on the next neighbour update.

------------------------------------------------------------------------
-- Sculk catalyst (SculkCatalystBlock + SculkCatalystBlockEntity)
------------------------------------------------------------------------

local PULSE_TICKS = 8

local function catalyst_bloom(be, pos)
	-- CatalystListener.bloom
	local node = core.get_node(pos)
	R.set_block(pos, {name = "mcl_sculk:catalyst_bloom", param2 = node.param2}, 3)
	R.schedule_tick(pos, "mcl_sculk:catalyst", PULSE_TICKS)
	mcl_sculk.soul_particles(vector.offset(pos, 0, 0.65, 0), 2, vector.new(0.2, 0, 0.2))
	mcl_sculk.play("block.sculk_catalyst.bloom", pos, 2.0, 0.6 + math.random() * 0.4)
end

local function save_cursors(be)
	local s = be.spreader:serialize()
	if s ~= be.saved then
		be.saved = s
		core.get_meta(be.pos):set_string("cursors", s)
	end
end

local catalyst_be = {
	keep_on_destruct = true,
	create = function(pos)
		local be = {spreader = mcl_sculk.new_level_spreader()}
		be.saved = core.get_meta(pos):get_string("cursors")
		be.spreader:deserialize(be.saved)
		-- CatalystListener: radius 8, BY_DISTANCE
		local listener = {
			radius = 8,
			delivery_mode = "by_distance",
			node_check = function(node)
				return node.name == "mcl_sculk:catalyst" or node.name == "mcl_sculk:catalyst_bloom"
			end,
		}
		function listener:get_position()
			return self.pos
		end
		function listener:handle_game_event(event, ctx, source_pos)
			if event ~= "entity_die" or not ctx.source then
				return false
			end
			if not ctx.experience_consumed then
				local xp = ctx.experience or 0
				if xp > 0 then
					be.spreader:add_cursors(vector.round(vector.offset(source_pos, 0, 0.5, 0)), xp)
					save_cursors(be)
					-- tryAwardItSpreadsAdvancement: the mob was last hurt by a player
					local le = ctx.source:get_luaentity()
					local killer = le and le.last_player_hit_name
					if killer and le.last_player_hit_time
							and core.get_gametime() - le.last_player_hit_time <= 5
							and awards and awards.unlock then
						awards.unlock(killer, "mcl:kill_mob_near_sculk_catalyst")
					end
				end
				-- LivingEntity.skipDropExperience
				ctx.experience_consumed = true
				catalyst_bloom(be, self.pos)
			end
			return true
		end
		G.add_block_listener(pos, listener)
		return be
	end,
	-- SculkCatalystBlockEntity.serverTick
	tick = function(be)
		if #be.spreader.cursors > 0 then
			be.spreader:update_cursors(be.pos, true)
			save_cursors(be)
		end
	end,
}

local function catalyst_def(bloom)
	local top = bloom and sculk_tile("mcl_sculk_catalyst_top_bloom.png", 0.4) or "mcl_sculk_catalyst_top.png"
	local side = bloom and sculk_tile("mcl_sculk_catalyst_side_bloom.png", 0.4) or "mcl_sculk_catalyst_side.png"
	return {
		description = S("Sculk Catalyst"),
		_doc_items_longdesc = S("When a mob dies near a sculk catalyst, the experience it would drop spreads sculk around it."),
		tiles = {top, "mcl_sculk_catalyst_bottom.png", side},
		groups = {handy = 1, hoey = 1, building_block = 1, sculk = 1, sculk_catalyst = 1,
			not_in_creative_inventory = bloom and 1 or 0},
		sounds = mcl_sculk.sounds.catalyst,
		is_ground_content = false,
		light_source = 6,
		drop = "",
		_mcl_silk_touch_drop = {"mcl_sculk:catalyst"},
		after_dig_node = function(pos, _, _, digger)
			mcl_sculk.drop_experience(pos, digger, 5)
		end,
		_mcl_hardness = 3.0,
		_mcl_blast_resistance = 3.0,
		_mcl_redstone = {
			block = "mcl_sculk:catalyst",
			-- SculkCatalystBlock.tick
			tick = function(pos, node)
				if node.name == "mcl_sculk:catalyst_bloom" then
					R.set_block(pos, {name = "mcl_sculk:catalyst", param2 = node.param2}, 3)
				end
			end,
		},
	}
end

core.register_node("mcl_sculk:catalyst", catalyst_def(false))
core.register_node("mcl_sculk:catalyst_bloom", catalyst_def(true))
mcl_sculk.register_block_entity({"mcl_sculk:catalyst", "mcl_sculk:catalyst_bloom"}, catalyst_be)
