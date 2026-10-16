local S = core.get_translator(core.get_current_modname())

-- Port of Minecraft's DoorBlock.
--
-- A door is two nodes, a lower (_b_) and an upper (_t_) half, both of the
-- same redstone block.  The state Minecraft keeps in the block state of each
-- half is spread over the node and its metadata:
--   * FACING: param2 of the closed door,
--   * HINGE: meta "is_mirrored" (1 = right hinge),
--   * OPEN: meta "is_open"; opening turns the node (_1 <-> _2 and param2),
--   * POWERED: meta "powered" ("redstone_power" in older worlds).
-- Like in Minecraft, a change to one half reaches the other through a shape
-- update, which copies the state.

local DOWN, UP = mcl_redstone.DOWN, mcl_redstone.UP
local rel = mcl_redstone.rel

-- Level.gameEvent(source, BLOCK_OPEN / BLOCK_CLOSE, pos); `source` is a
-- player, a mob (its luaentity) or nil
local function door_event(pos, open, source)
	if not mcl_gameevent then
		return
	end
	if type(source) == "table" and not core.is_player(source) then
		source = source.object
	end
	if source and not core.is_player(source) and not (source.get_luaentity and source:get_luaentity()) then
		source = nil
	end
	mcl_gameevent.emit(open and "block_open" or "block_close", pos, {source = source})
end
mcl_doors.door_event = door_event

function mcl_doors.is_open(pos)
	local meta = core.get_meta(pos)
	return meta:get_int("is_open") == 1
end

local function is_door(node)
	return core.get_item_group(node.name, "door") ~= 0
end

local function is_top(node)
	return core.get_item_group(node.name, "door_top") ~= 0
end

local function other_half_name(name)
	if name:find("_t_%d$") then
		return (name:gsub("_t_(%d)$", "_b_%1"))
	end
	return (name:gsub("_b_(%d)$", "_t_%1"))
end

local function is_powered(meta)
	local p = meta:get_string("powered")
	if p == "" then
		return meta:get_int("redstone_power") ~= 0
	end
	return p == "1"
end

-- The node of the door after OPEN is cycled.  _1 is a closed door with a
-- left hinge or an open one with a right hinge.
local function cycled_open(node)
	local p2 = node.param2 or 0
	local rot = p2 % 4
	local base = node.name:sub(1, -2)
	if node.name:sub(-1) == "1" then
		return {name = base .. "2", param2 = p2 - rot + (rot + 1) % 4}
	end
	return {name = base .. "1", param2 = p2 - rot + (rot + 3) % 4}
end

local STATE_FIELDS = {"is_open", "is_mirrored", "powered", "doors_owner"}

-- Copies the door state of the half at `from` to the half at `to`.  Returns
-- true if it changed.
local function copy_state(from, to)
	local m1, m2 = core.get_meta(from), core.get_meta(to)
	local changed = false
	for _, f in ipairs(STATE_FIELDS) do
		local v = m1:get_string(f)
		if f == "powered" then
			v = is_powered(m1) and "1" or "0"
		end
		if m2:get_string(f) ~= v then
			m2:set_string(f, v)
			changed = true
		end
	end
	if m2:get_string("redstone_power") ~= "" then
		m2:set_string("redstone_power", "")
	end
	return changed
end

-- level.setBlock(pos, state.setValue(OPEN, open).setValue(POWERED, powered), flags)
local function set_door_state(pos, node, open, powered, flags)
	local meta = core.get_meta(pos)
	local was_open = meta:get_int("is_open") == 1
	meta:set_int("is_open", open and 1 or 0)
	meta:set_string("powered", powered and "1" or "0")
	meta:set_string("redstone_power", "")
	if open ~= was_open then
		mcl_redstone.set_block(pos, cycled_open(node), flags)
	else
		-- Only POWERED changed: the node stays, but it is still a new
		-- state for Minecraft (the shape updates copy it to the other half).
		mcl_redstone.node_changed(pos, node, node, flags)
	end
end

-- DoorBlock.canSurvive
local function can_survive(pos, node)
	local below = rel(pos, DOWN)
	local bnode = mcl_redstone.get_node(below)
	if is_top(node) then
		return mcl_redstone.is_block(bnode, mcl_redstone.block_id(node.name))
	end
	return mcl_redstone.is_face_sturdy(below, bnode, UP)
end

-- DoorBlock.getHinge: true for the right hinge (a mirrored door).
local function get_hinge_right(pos, d, placer, pointed_thing)
	local above = rel(pos, UP)
	local get_node = core.get_node
	local full = mcl_redstone.is_collision_full_block
	local left_d, right_d = mcl_redstone.counter_clockwise[d], mcl_redstone.clockwise[d]
	local left, left_above = rel(pos, left_d), rel(above, left_d)
	local right, right_above = rel(pos, right_d), rel(above, right_d)
	local lnode, rnode = get_node(left), get_node(right)
	local balance = (full(left, lnode) and -1 or 0)
		+ (full(left_above, get_node(left_above)) and -1 or 0)
		+ (full(right, rnode) and 1 or 0)
		+ (full(right_above, get_node(right_above)) and 1 or 0)
	local door_left = core.get_item_group(lnode.name, "door_bottom") ~= 0
	local door_right = core.get_item_group(rnode.name, "door_bottom") ~= 0
	if (door_left and not door_right) or balance > 0 then
		return true
	elseif (door_right and not door_left) or balance < 0 then
		return false
	end
	-- Which half of the block was clicked, in Minecraft's coordinates
	-- (its z axis points the other way).
	local click = core.pointed_thing_to_face_pos(placer, pointed_thing)
	local click_x = click.x - (pos.x - 0.5)
	local click_z = 1 - (click.z - (pos.z - 0.5))
	local v = mcl_redstone.dirvec[d]
	local step_x, step_z = v.x, -v.z
	local left_hinge = (step_x >= 0 or not (click_z < 0.5)) and (step_x <= 0 or not (click_z > 0.5))
		and (step_z >= 0 or not (click_x > 0.5)) and (step_z <= 0 or not (click_x < 0.5))
	return not left_hinge
end

-- This helper function calls on_place_node callbacks.
local function on_place_node(place_defs, placer, itemstack)
	-- Run script hook
	for _, callback in pairs(core.registered_on_placenodes) do
		-- Deep-copy pos, node and pointed_thing because callback can modify them
		local place_to_copy = vector.copy(place_defs.place_to)
		local newnode_copy = table.copy(place_defs.newnode)
		local oldnode_copy = table.copy(place_defs.oldnode)
		local pointed_thing_copy = table.copy(place_defs.pointed_thing)

		callback(place_to_copy, newnode_copy, placer, oldnode_copy, itemstack, pointed_thing_copy)
	end
end

function mcl_doors:register_door(name, def)
	def.groups.not_in_creative_inventory = 1
	def.groups.dig_by_piston = 1
	def.groups.unsticky = 1
	def.groups.door = 1

	if not def.sound_open then def.sound_open = "doors_door_open" end
	if not def.sound_close then def.sound_close = "doors_door_close" end

	local box = {{-0.5, -0.5, -0.5, 0.5, 0.5, -0.3125}}

	if not def.node_box_bottom then def.node_box_bottom = box end
	if not def.node_box_top then def.node_box_top = box end
	if not def.selection_box_bottom then def.selection_box_bottom= box end
	if not def.selection_box_top then def.selection_box_top = box end

	local longdesc, usagehelp, tt_help
	tt_help = def._tt_help
	longdesc = def._doc_items_longdesc
	usagehelp = def._doc_items_usagehelp

	if not longdesc then
		if def.only_redstone_can_open then
			longdesc = S("This door is a 2-block high barrier which can be opened or closed by hand or by redstone power.")
		else
			longdesc = S("This door is a 2-block high barrier which can only be opened by redstone power, not by hand.")
		end
	end

	if not usagehelp then
		if def.only_redstone_can_open then
			usagehelp = S("To open or close this door, send a redstone signal to its bottom half.")
		else
			usagehelp = S("To open or close this door, rightclick it or send a redstone signal to its bottom half.")
		end
	end

	if not tt_help then
		if def.only_redstone_can_open then
			tt_help = S("Openable by redstone power")
		else
			tt_help = S("Openable by players and redstone power")
		end
	end

	local craftitem_groups = {deco_block = 1}
	if def.groups and def.groups.flammable then
		craftitem_groups.flammable = def.groups.flammable
	end

	local function check_player_priv(pos, player)
		if not def.only_placer_can_open then return true end

		local meta = core.get_meta(pos)
		local pn = player:get_player_name()

		return meta:get_string("doors_owner") == pn
	end

	local BLOCK = name

	local function play_sound(pos, open)
		core.sound_play(open and def.sound_open or def.sound_close, {pos = pos, gain = 0.5,
			max_hear_distance = 16, pitch = math.random() * 0.1 + 0.9}, true)
	end

	-- DoorBlock.setOpen
	local function set_open(pos, should_open)
		local node = core.get_node(pos)
		if mcl_redstone.is_block(node, BLOCK) and mcl_doors.is_open(pos) ~= should_open then
			set_door_state(pos, node, should_open, is_powered(core.get_meta(pos)), 10)
			play_sound(pos, should_open)
			door_event(pos, should_open, nil)
		end
	end

	-- DoorBlock.useWithoutItem
	local rightclick = function(pos, node, clicker)
		if check_player_priv(pos, clicker) then
			node = core.get_node(pos)
			local meta = core.get_meta(pos)
			local open = meta:get_int("is_open") ~= 1
			set_door_state(pos, node, open, is_powered(meta), 10)
			play_sound(pos, open)
			door_event(pos, open, clicker)
		end
	end

	-- DoorBlock.onExplosionHit (wind charges); only the lower half reacts
	local function on_wind_charge_hit(pos)
		if not def.only_redstone_can_open and not is_powered(core.get_meta(pos)) then
			set_open(pos, not mcl_doors.is_open(pos))
		end
		return true
	end

	-- DoublePlantBlock.preventDropFromBottomPart: an upper half broken in
	-- creative mode or without the right tool takes the lower half with it
	-- without drops.
	local function on_dig_top(pos, node, digger)
		local below = vector.offset(pos, 0, -1, 0)
		local bnode = core.get_node(below)
		if digger and digger:is_player() and mcl_redstone.is_block(bnode, BLOCK) and not is_top(bnode)
				and not core.is_protected(pos, digger:get_player_name())
				and check_player_priv(pos, digger) then
			local pname = digger:get_player_name()
			local tool = digger:get_wielded_item():get_name()
			if core.is_creative_enabled(pname)
					or (mcl_autogroup and not mcl_autogroup.can_harvest(bnode.name, tool, digger)) then
				mcl_redstone.set_block(below, {name = "air"}, 35)
			end
		end
		return core.node_dig(pos, node, digger)
	end

	local behaviour = {
		block = BLOCK,
		push_reaction = "destroy",
		-- DoorBlock.neighborChanged
		neighbor_changed = function(pos, node, from_block)
			if from_block == BLOCK then
				return
			end
			local signal = mcl_redstone.has_neighbor_signal(pos)
				or mcl_redstone.has_neighbor_signal(rel(pos, is_top(node) and DOWN or UP))
			local meta = core.get_meta(pos)
			if signal ~= is_powered(meta) then
				if signal ~= (meta:get_int("is_open") == 1) then
					play_sound(pos, signal)
					door_event(pos, signal, nil)
				end
				set_door_state(pos, node, signal, signal, 2)
			end
		end,
		-- DoorBlock.updateShape
		update_shape = function(pos, node, d, npos, nnode)
			local top = is_top(node)
			if d ~= (top and DOWN or UP) then
				if not top and d == DOWN and not can_survive(pos, node) then
					return {name = "air"}
				end
				return
			end
			if is_door(nnode) and is_top(nnode) ~= top then
				-- neighbourState.setValue(HALF, half)
				local new = {name = other_half_name(nnode.name), param2 = nnode.param2}
				local changed = copy_state(npos, pos)
				if mcl_redstone.same_node(new, node) then
					if changed then
						mcl_redstone.node_changed(pos, node, node, 2)
					end
					return
				end
				return new
			end
			return {name = "air"}
		end,
		-- The metadata goes away when the block changes (a copper door
		-- weathering): take the state of the other half.
		on_place = function(pos, node, oldnode)
			if mcl_redstone.block_id(oldnode.name) == BLOCK then
				return
			end
			local opos = rel(pos, is_top(node) and DOWN or UP)
			local onode = mcl_redstone.get_node(opos)
			if is_door(onode) and is_top(onode) ~= is_top(node) then
				copy_state(opos, pos)
			end
		end,
	}

	local tpl_doors = {
		_mcl_baseitem = name,
		_mcl_blast_resistance = def._mcl_blast_resistance,
		_mcl_hardness = def._mcl_hardness,
		_mcl_redstone = behaviour,
		can_dig = check_player_priv,
		drawtype = "nodebox",
		drop = "",
		groups = def.groups,
		is_ground_content = false,
		on_rightclick = not def.only_redstone_can_open and rightclick or nil,
		on_rotate = function(pos, node, _, mode, _)
			if mode == screwdriver.ROTATE_FACE then
				-- The other half follows through the shape update
				node.param2 = screwdriver.rotate.facedir(pos, node, mode)
				core.swap_node(pos, node)
				return true
			end
			return false
		end,
		paramtype = "light",
		paramtype2 = "facedir",
		sounds = def.sounds,
		sunlight_propagates = true,
		use_texture_alpha = "clip"
	}

	local groups_bottom = table.update(table.copy(def.groups), { door_bottom = 1 })
	local groups_top = table.update(table.copy(def.groups), { door_top = 1 })

	local tpl_bottom = {
		-- Like Minecraft's loot table, only the lower half drops the door
		drop = name,
		_on_wind_charge_hit = on_wind_charge_hit,
		groups = groups_bottom,
		node_box = {
			fixed = def.node_box_bottom,
			type = "fixed"
		},
		selection_box = {
			fixed = def.selection_box_bottom,
			type = "fixed"
		}
	}

	local tpl_top = {
		_on_wind_charge_hit = function(pos)
			return on_wind_charge_hit(vector.offset(pos, 0, -1, 0))
		end,
		on_dig = on_dig_top,
		groups = groups_top,
		node_box = {
			fixed = def.node_box_top,
			type = "fixed"
		},
		selection_box = {
			fixed = def.selection_box_top,
			type = "fixed"
		}
	}

	core.register_node(":"..name, {
		description = def.description,
		_tt_help = tt_help,
		_doc_items_longdesc = longdesc,
		_doc_items_usagehelp = usagehelp,
		_mcl_burntime = def._mcl_burntime,
		tiles = {"blank.png"},
		wield_image = def.inventory_image,
		inventory_image = def.inventory_image,
		groups = craftitem_groups,
		on_place = function(itemstack, placer, pointed_thing)
			if pointed_thing.type ~= "node" or not placer or not placer:is_player() then
				return itemstack
			end

			local name = itemstack:get_name()
			local pn = placer:get_player_name()
			local pt = pointed_thing.above
			local ptu = pointed_thing.under

			if core.is_protected(pt, pn) and core.is_protected(ptu, pn) then return itemstack end

			local ptunode = core.get_node(ptu)
			local ptudefs = core.registered_nodes[ptunode.name]
			local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)

			if rc then return rc end

			if ptudefs and ptudefs.buildable_to then pt = pointed_thing.under end

			local pt2 = vector.offset(pt, 0, 1, 0)
			local ptname = core.get_node(pt).name
			local pt2name = core.get_node(pt2).name
			local ptdefs = core.registered_nodes[ptname]
			local pt2defs = core.registered_nodes[pt2name]

			if (ptdefs and not ptdefs.buildable_to) or (pt2defs and not pt2defs.buildable_to) then
				return itemstack
			end

			-- DoorBlock.getStateForPlacement
			local d = mcl_redstone.horizontal_looking_direction(placer)
			local p2 = mcl_redstone.dir_to_fourdir[d]
			local mirrored = get_hinge_right(pt, d, placer, pointed_thing)
			local lower = {name = name.."_b_"..(mirrored and 2 or 1), param2 = p2}
			if not can_survive(pt, lower) then
				return itemstack
			end
			local powered = mcl_redstone.has_neighbor_signal(pt) or mcl_redstone.has_neighbor_signal(pt2)
			if powered then
				lower = cycled_open(lower)
			end

			-- Set door nodes; the upper half takes the state of the lower one
			-- (DoorBlock.setPlacedBy)
			core.set_node(pt, lower)
			local meta1 = core.get_meta(pt)
			-- save mirror state for the correct door
			if mirrored then
				meta1:set_int("is_mirrored", 1)
			end
			if def.only_placer_can_open then
				meta1:set_string("doors_owner", "")
			end
			-- Save open state. 1 = open. 0 = closed
			meta1:set_int("is_open", powered and 1 or 0)
			meta1:set_string("powered", powered and "1" or "0")
			core.set_node(pt2, {name = other_half_name(lower.name), param2 = lower.param2})

			if def.sounds and def.sounds.place then
				core.sound_play(def.sounds.place, {pos = pt}, true)
			end

			if not core.is_creative_enabled(pn) then itemstack:take_item() end

			local place_defs_pt = {
				newnode = core.get_node(pt),
				oldnode = ptunode,
				place_to = pt,
				pointed_thing = pointed_thing
			}

			local place_defs_pt2 = {
				newnode = core.get_node(pt2),
				oldnode = core.get_node(vector.offset(ptu, 0, 1, 0)),
				place_to = pt2,
				pointed_thing = pointed_thing
			}

			on_place_node(place_defs_pt, placer, itemstack)
			on_place_node(place_defs_pt2, placer, itemstack)

			return itemstack
		end,
	})

	local tt = def.tiles_top
	local tb = def.tiles_bottom

	core.register_node(":"..name.."_b_1", table.merge({
		tiles = {
			"blank.png", tt[2].."^[transformFXR90", tb[2],
			tb[2].."^[transformFX", tb[1], tb[1].."^[transformFX"
		}
	}, tpl_doors, tpl_bottom))

	core.register_node(":"..name.."_t_1", table.merge({
		tiles = {
			tt[2].."^[transformR90", "blank.png", tt[2],
			tt[2].."^[transformFX", tt[1], tt[1].."^[transformFX"
		}
	}, tpl_doors, tpl_top))

	core.register_node(":"..name.."_b_2", table.merge({
		tiles = {
			"blank.png", tt[2].."^[transformFXR90", tb[2].."^[transformI",
			tb[2].."^[transformFX", tb[1].."^[transformFX", tb[1]
		}
	}, tpl_doors, tpl_bottom))

	core.register_node(":"..name.."_t_2", table.merge({
		tiles = {
			tt[2].."^[transformR90", "blank.png", tt[2].."^[transformI",
			tt[2].."^[transformFX", tt[1].."^[transformFX", tt[1]
		}
	}, tpl_doors, tpl_top))
	doc.add_entry_alias("craftitems", name, "nodes", name.."_b_1")
	doc.add_entry_alias("craftitems", name, "nodes", name.."_b_2")
	doc.add_entry_alias("craftitems", name, "nodes", name.."_t_1")
	doc.add_entry_alias("craftitems", name, "nodes", name.."_t_2")
end
