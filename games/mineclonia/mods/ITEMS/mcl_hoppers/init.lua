local S = core.get_translator(core.get_current_modname())
local F = core.formspec_escape
local C = core.colorize

mcl_hoppers = {}

-- Port of Minecraft's HopperBlock and HopperBlockEntity.  Hoppers move items
-- in a block entity ticker (mcl_redstone.add_ticker), after the scheduled
-- ticks and block events of each game tick.  The transfer cooldown
-- (HopperBlockEntity.cooldownTime) is in game ticks.

local BLOCK = "mcl_hoppers:hopper"
local MOVE_ITEM_SPEED = 8
local FOURDIR_OFFSET = 3

local DOWN = mcl_redstone.DOWN
local opposite = mcl_redstone.opposite
local get_node = mcl_redstone.get_node

local hash = core.hash_node_position

local enabled_names = {
	["mcl_hoppers:hopper"] = true,
	["mcl_hoppers:hopper_side"] = true,
}
local toggle_names = {
	["mcl_hoppers:hopper"] = "mcl_hoppers:hopper_disabled",
	["mcl_hoppers:hopper_disabled"] = "mcl_hoppers:hopper",
	["mcl_hoppers:hopper_side"] = "mcl_hoppers:hopper_side_disabled",
	["mcl_hoppers:hopper_side_disabled"] = "mcl_hoppers:hopper_side",
}

-- HopperBlock.FACING
local function hopper_facing(node)
	if core.get_item_group(node.name, "hopper") == 2 then
		local dir = core.fourdir_to_dir((node.param2 + FOURDIR_OFFSET) % 4)
		return mcl_redstone.dir_index(dir)
	end
	return DOWN
end

-- Hopper block entity state ----------------------------------------------------

-- Block entities (tickers) of the hoppers by position
local hoppers = {}

local push_items_tick

-- Creates the block entity (and ticker) of the hopper at pos
local function new_hopper(pos)
	local h = hash(pos)
	local old = hoppers[h]
	if old then
		old.removed = true
	end
	local meta = core.get_meta(pos)
	local cooldown = meta:contains("TransferCooldown") and meta:get_int("TransferCooldown") or -1
	local be = mcl_redstone.add_ticker({
		pos = vector.copy(pos),
		hash = h,
		cooldown = cooldown,
		saved_cooldown = cooldown,
		ticked = 0,
		tick = function(t)
			push_items_tick(t)
		end,
	})
	hoppers[h] = be
	return be
end

-- The block entity of the hopper at pos
local function get_hopper(pos)
	local be = hoppers[hash(pos)]
	if be and not be.removed then
		return be
	end
	return new_hopper(pos)
end
mcl_hoppers.get_hopper = get_hopper

local function remove_hopper(pos)
	local h = hash(pos)
	local be = hoppers[h]
	if be then
		be.removed = true
		hoppers[h] = nil
	end
end

local function set_cooldown(be, time)
	be.cooldown = time
	-- Kept in the node metadata like Minecraft's "TransferCooldown"
	if be.saved_cooldown ~= time and time >= 0 then
		be.saved_cooldown = time
		core.get_meta(be.pos):set_int("TransferCooldown", time)
	end
end

local function is_on_cooldown(be)
	return be.cooldown > 0
end

local function is_on_custom_cooldown(be)
	return be.cooldown > MOVE_ITEM_SPEED
end

-- Containers --------------------------------------------------------------------
--
-- A container is a list of inventory slots like Minecraft's Container.  A
-- container made of several inventories (a large chest) is Minecraft's
-- CompoundContainer.

local Container = {}
Container.__index = Container

-- parts: list of {inv = InvRef, list = listname, pos = node position or nil,
-- entity = luaentity or nil}
local function make_container(parts, props)
	local c = setmetatable(props or {}, Container)
	c.parts = parts
	c.slots = {}
	for _, part in ipairs(parts) do
		for i = 1, part.inv:get_size(part.list) do
			c.slots[#c.slots + 1] = {part, i}
		end
	end
	c.size = #c.slots
	return c
end
mcl_hoppers.make_container = make_container

function Container:get_item(i)
	local s = self.slots[i]
	return s[1].inv:get_stack(s[1].list, s[2])
end

function Container:set_item(i, stack)
	local s = self.slots[i]
	s[1].inv:set_stack(s[1].list, s[2], stack)
end

function Container:is_empty()
	for _, part in ipairs(self.parts) do
		if not part.inv:is_empty(part.list) then
			return false
		end
	end
	return true
end

-- Container.canPlaceItem and WorldlyContainer.canPlaceItemThroughFace
function Container:can_place_item(_, stack, _)
	if self.no_shulker_boxes and core.get_item_group(stack:get_name(), "shulker_box") ~= 0 then
		return false
	end
	return true
end

-- Container.canTakeItem and WorldlyContainer.canTakeItemThroughFace
function Container:can_take_item()
	return true
end

-- Container.setChanged: tells comparators (BlockEntity.setChanged)
function Container:set_changed()
	for _, part in ipairs(self.parts) do
		if part.pos then
			mcl_redstone.update_comparators(part.pos)
		elseif part.entity and rawget(_G, "mcl_entity_invs") then
			mcl_entity_invs.save_inv(part.entity)
		end
	end
end

local function node_inv_part(pos, list)
	local inv = core.get_meta(pos):get_inventory()
	if inv:get_size(list or "main") == 0 then
		return nil
	end
	return {inv = inv, list = list or "main", pos = vector.copy(pos)}
end

-- The container of a node handled by Minecraft's rules (chests, barrels,
-- shulker boxes, hoppers, dispensers and droppers), or nil.
local function generic_container(pos, node, ctype)
	local part = node_inv_part(pos)
	if not part then
		return nil
	end
	if ctype == 5 or ctype == 6 then
		-- ChestBlock.getContainer(..., ignoreBlocked = true): the
		-- CompoundContainer of both halves, the "left" half first
		local other_pos = mcl_util.get_double_container_neighbor_pos(pos, node.param2, ctype == 5 and "left" or "right")
		local other = other_pos and get_node(other_pos)
		local other_part = other and core.get_item_group(other.name, "double_chest") ~= 0 and node_inv_part(other_pos)
		if other_part then
			if ctype == 5 then
				return make_container({part, other_part})
			end
			return make_container({other_part, part})
		end
	end
	local props = {}
	if ctype == 3 then
		props.no_shulker_boxes = true
	end
	if core.get_item_group(node.name, "hopper") ~= 0 then
		props.hopper = get_hopper(pos)
	end
	return make_container({part}, props)
end

-- Nodes with Mineclonia's own hopper handling (furnaces, brewing stands,
-- composters...): {hooked = true, pos = pos, node = node, def = def}
local function block_container(pos, node, mode)
	local def = core.registered_nodes[node.name]
	if not def then
		return nil
	end
	local ctype = core.get_item_group(node.name, "container")
	local hook = mode == "in" and def._on_hopper_in or mode == "out" and def._on_hopper_out
	if hook or ctype == 1 or ctype == 4 or ctype == 7 then
		return {hooked = true, pos = pos, node = node, def = def, ctype = ctype}
	end
	if ctype == 2 or ctype == 3 or ctype == 5 or ctype == 6 then
		return generic_container(pos, node, ctype)
	end
	return nil
end

local container_entities = {
	["mcl_minecarts:chest_minecart"] = true,
	["mcl_minecarts:hopper_minecart"] = true,
	["mcl_boats:chest_boat"] = true,
}

local function box_intersects(obj, min, max)
	local p = obj:get_pos()
	local cb = obj:get_properties().collisionbox
	return p.x + cb[1] < max.x and p.x + cb[4] > min.x
		and p.y + cb[2] < max.y and p.y + cb[5] > min.y
		and p.z + cb[3] < max.z and p.z + cb[6] > min.z
end

-- HopperBlockEntity.getEntityContainer: a random container entity in the
-- block space at pos
local function entity_container(pos)
	if not rawget(_G, "mcl_entity_invs") then
		return nil
	end
	local min, max = vector.offset(pos, -0.5, -0.5, -0.5), vector.offset(pos, 0.5, 0.5, 0.5)
	local found = {}
	for obj in core.objects_inside_radius(pos, 2.5) do
		local ent = obj:get_luaentity()
		if ent and container_entities[ent.name] and (ent._inv_size or 0) > 0 and box_intersects(obj, min, max) then
			found[#found + 1] = ent
		end
	end
	if #found == 0 then
		return nil
	end
	local ent = found[math.random(#found)]
	local inv = mcl_entity_invs.load_inv(ent, ent._inv_size)
	if not inv then
		return nil
	end
	return make_container({{inv = inv, list = "main", entity = ent}})
end

-- HopperBlockEntity.getContainerAt.  `mode` is "in" (items go into the
-- container) or "out".
local function get_container_at(pos, mode)
	local node = get_node(pos)
	return block_container(pos, node, mode) or entity_container(pos)
end
mcl_hoppers.get_container_at = get_container_at

-- Item transfer -------------------------------------------------------------------

local function stack_max(stack)
	return math.min(99, stack:get_stack_max())
end

local function same_item(a, b)
	if a:get_name() ~= b:get_name() then
		return false
	end
	local a1, b1 = ItemStack(a), ItemStack(b)
	a1:set_count(1)
	b1:set_count(1)
	return a1:to_string() == b1:to_string()
end

-- HopperBlockEntity.canMergeItems
local function can_merge_items(a, b)
	return a:get_count() <= a:get_stack_max() and same_item(a, b)
end

-- HopperBlockEntity.tryMoveInItem
local function try_move_in_item(from, container, stack, slot, face)
	if not container:can_place_item(slot, stack, face) then
		return stack
	end
	local current = container:get_item(slot)
	local success = false
	local was_empty = container:is_empty()
	if current:is_empty() then
		container:set_item(slot, stack)
		stack = ItemStack("")
		success = true
	elseif can_merge_items(current, stack) then
		local space = stack:get_stack_max() - current:get_count()
		local count = math.min(stack:get_count(), space)
		if count > 0 then
			stack:take_item(count)
			current:set_count(current:get_count() + count)
			container:set_item(slot, current)
			success = true
		end
	end
	if success then
		local be = container.hopper
		if was_empty and be and not is_on_custom_cooldown(be) then
			local skip = 0
			if from and from.hopper and be.ticked >= from.hopper.ticked then
				skip = 1
			end
			set_cooldown(be, MOVE_ITEM_SPEED - skip)
		end
		container:set_changed()
	end
	return stack
end

-- HopperBlockEntity.addItem(from, container, stack, face): moves as much of
-- stack into the container as fits and returns the rest.
local function add_item(from, container, stack, face)
	stack = ItemStack(stack)
	local slots = face and container.slots_for_face and container:slots_for_face(face)
	if slots then
		for i = 1, #slots do
			if stack:is_empty() then break end
			stack = try_move_in_item(from, container, stack, slots[i], face)
		end
	else
		for i = 1, container.size do
			if stack:is_empty() then break end
			stack = try_move_in_item(from, container, stack, i, face)
		end
	end
	return stack
end
mcl_hoppers.add_item = add_item

-- HopperBlockEntity.isFullContainer
local function is_full_container(container, face)
	local slots = face and container.slots_for_face and container:slots_for_face(face)
	local n = slots and #slots or container.size
	for i = 1, n do
		local stack = container:get_item(slots and slots[i] or i)
		if stack:is_empty() or stack:get_count() < stack_max(stack) then
			return false
		end
	end
	return true
end

-- HopperBlockEntity.inventoryFull
local function inventory_full(container)
	for i = 1, container.size do
		local stack = container:get_item(i)
		if stack:is_empty() or stack:get_count() ~= stack:get_stack_max() then
			return false
		end
	end
	return true
end

local function snapshot(inv)
	local t = {}
	for i, stack in ipairs(inv:get_list("main")) do
		t[i] = stack:to_string()
	end
	return t
end

local function inv_changed(inv, before)
	for i, stack in ipairs(inv:get_list("main")) do
		if before[i] ~= stack:to_string() then
			return true
		end
	end
	return false
end

-- Pushing into a node with Mineclonia's own hopper handling
local function hooked_push(pos, c)
	local inv = core.get_meta(pos):get_inventory()
	local before = snapshot(inv)
	local def = c.def
	local done = false
	if def._mcl_allow_hopper_in and not def._mcl_allow_hopper_in(pos, c.pos) then
		return false
	end
	if def._on_hopper_in then
		done = def._on_hopper_in(pos, c.pos)
	end
	if not done and c.ctype >= 2 and c.ctype <= 6 then
		mcl_util.move_item_container(pos, c.pos)
	end
	local changed = inv_changed(inv, before)
	if changed and def._after_hopper_in then
		def._after_hopper_in(c.pos)
	end
	return changed
end

-- Pulling from a node with Mineclonia's own hopper handling
local function hooked_pull(pos, c)
	local inv = core.get_meta(pos):get_inventory()
	local before = snapshot(inv)
	local def = c.def
	local done = false
	if def._on_hopper_out then
		done = def._on_hopper_out(c.pos, pos)
	end
	if not done then
		mcl_util.move_item_container(c.pos, pos)
	end
	local changed = inv_changed(inv, before)
	if changed and def._after_hopper_out then
		def._after_hopper_out(c.pos)
	end
	return changed
end

-- HopperBlockEntity.ejectItems
local function eject_items(pos, node, self)
	local facing = hopper_facing(node)
	local container = get_container_at(mcl_redstone.rel(pos, facing), "in")
	if not container then
		return false
	end
	if container.hooked then
		return hooked_push(pos, container)
	end
	local face = opposite[facing]
	if is_full_container(container, face) then
		return false
	end
	for slot = 1, self.size do
		local stack = self:get_item(slot)
		if not stack:is_empty() then
			local one = stack:take_item(1)
			local result = add_item(self, container, one, face)
			if result:is_empty() then
				self:set_item(slot, stack)
				container:set_changed()
				return true
			end
		end
	end
	return false
end

-- HopperBlockEntity.tryTakeInItemFromSlot
local function try_take_in_item_from_slot(hopper, container, slot, face)
	local stack = container:get_item(slot)
	if not stack:is_empty() and container:can_take_item(hopper, slot, stack, face) then
		local one = stack:take_item(1)
		container:set_item(slot, stack)
		local result = add_item(container, hopper, one, nil)
		if result:is_empty() then
			container:set_changed()
			return true
		end
		stack:add_item(one)
		container:set_item(slot, stack)
	end
	return false
end

-- HopperBlockEntity.addItem(container, itemEntity)
local function add_item_entity(container, obj, ent)
	local stack = ItemStack(ent.itemstring)
	local result = add_item(nil, container, stack, nil)
	if result:is_empty() then
		ent.itemstring = ""
		ent._removed = true
		obj:remove()
		return true
	end
	if result:get_count() ~= stack:get_count() then
		if ent.set_item then
			ent:set_item(result:to_string())
		else
			ent.itemstring = result:to_string()
		end
	end
	return false
end

-- HopperBlockEntity.getItemsAtAndAbove: item entities in Hopper.SUCK_AABB
local function get_items_at_and_above(pos)
	local min, max = vector.offset(pos, -0.5, 0.1875, -0.5), vector.offset(pos, 0.5, 1.5, 0.5)
	local list = {}
	for obj in core.objects_inside_radius(vector.offset(pos, 0, 0.75, 0), 2) do
		local ent = obj:get_luaentity()
		if ent and ent.name == "__builtin:item" and not ent._removed and ent.itemstring ~= ""
				and box_intersects(obj, min, max) then
			list[#list + 1] = {obj, ent}
		end
	end
	return list
end

-- HopperBlockEntity.suckInItems
local function suck_in_items(pos, hopper)
	local uppos = vector.offset(pos, 0, 1, 0)
	local upnode = get_node(uppos)
	local container = block_container(uppos, upnode, "out") or entity_container(uppos)
	if container then
		if container.hooked then
			return hooked_pull(pos, container)
		end
		local slots = container.slots_for_face and container:slots_for_face(DOWN)
		for i = 1, slots and #slots or container.size do
			if try_take_in_item_from_slot(hopper, container, slots and slots[i] or i, DOWN) then
				return true
			end
		end
		return false
	end
	if not mcl_redstone.is_collision_full_block(uppos, upnode) then
		for _, e in ipairs(get_items_at_and_above(pos)) do
			if add_item_entity(hopper, e[1], e[2]) then
				return true
			end
		end
	end
	return false
end

-- HopperBlockEntity.tryMoveItems
local function try_move_items(pos, node, be, action)
	if is_on_cooldown(be) or not enabled_names[node.name] then
		return false
	end
	local self = make_container({node_inv_part(pos)}, {hopper = be})
	local changed = false
	if not self:is_empty() then
		changed = eject_items(pos, node, self)
	end
	if not inventory_full(self) then
		changed = action(self) or changed
	end
	if changed then
		set_cooldown(be, MOVE_ITEM_SPEED)
		mcl_redstone.update_comparators(pos)
		return true
	end
	return false
end

-- HopperBlockEntity.pushItemsTick
function push_items_tick(be)
	local pos = be.pos
	local node = get_node(pos)
	if mcl_redstone.block_id(node.name) ~= BLOCK then
		be.removed = true
		if hoppers[be.hash] == be then
			hoppers[be.hash] = nil
		end
		return
	end
	be.cooldown = be.cooldown - 1
	be.ticked = mcl_redstone.get_game_time()
	if not is_on_cooldown(be) then
		set_cooldown(be, 0)
		if not node_inv_part(pos) then
			return
		end
		try_move_items(pos, node, be, function(self)
			return suck_in_items(pos, self)
		end)
	end
end

-- HopperBlock.checkPoweredState
local function check_powered_state(pos, node)
	local should_be_on = not mcl_redstone.has_neighbor_signal(pos)
	if should_be_on ~= (enabled_names[node.name] or false) then
		mcl_redstone.set_block(pos, {name = toggle_names[node.name], param2 = node.param2}, 2)
	end
end

local redstone = {
	block = BLOCK,
	-- HopperBlock.onPlace
	on_place = function(pos, node, oldnode)
		if mcl_redstone.block_id(oldnode.name) ~= BLOCK then
			check_powered_state(pos, node)
		end
	end,
	neighbor_changed = function(pos, node)
		check_powered_state(pos, node)
	end,
	-- Containers.updateNeighboursAfterDestroy
	affect_neighbors_after_removal = function(pos)
		mcl_redstone.update_neighbour_for_output_signal(pos, BLOCK)
	end,
}

--[[ BEGIN OF NODE DEFINITIONS ]]

local mcl_hoppers_formspec = table.concat({
	"formspec_version[4]",
	"size[11.75,8.175]",

	"label[0.375,0.375;" .. F(C(mcl_formspec.label_color, S("Hopper"))) .. "]",

	mcl_formspec.get_itemslot_bg_v4(2.875, 0.75, 5, 1),
	"list[context;main;2.875,0.75;5,1;]",

	"label[0.375,2.45;" .. F(C(mcl_formspec.label_color, S("Inventory"))) .. "]",

	mcl_formspec.get_itemslot_bg_v4(0.375, 2.85, 9, 3),
	"list[current_player;main;0.375,2.85;9,3;9]",

	mcl_formspec.get_itemslot_bg_v4(0.375, 6.8, 9, 1),
	"list[current_player;main;0.375,6.8;9,1;]",

	"listring[context;main]",
	"listring[current_player;main]",
})

-- Downwards hopper (base definition)
local def_hopper = {
	inventory_image = "mcl_hoppers_item.png",
	wield_image = "mcl_hoppers_item.png",
	groups = { pickaxey = 1, container = 2, deco_block = 1, hopper = 1, pathfinder_partial = 2, },
	drawtype = "nodebox",
	paramtype = "light",
	-- FIXME: mcl_hoppers_hopper_inside.png is unused by hoppers.
	tiles = {"mcl_hoppers_hopper_inside.png^mcl_hoppers_hopper_top.png", "mcl_hoppers_hopper_outside.png", "mcl_hoppers_hopper_outside.png", "mcl_hoppers_hopper_outside.png", "mcl_hoppers_hopper_outside.png", "mcl_hoppers_hopper_outside.png"},
	node_box = {
		type = "fixed",
		fixed = {
			--funnel walls
			{ -0.5, 0.0, 0.4, 0.5, 0.5, 0.5 },
			{ 0.4, 0.0, -0.5, 0.5, 0.5, 0.5 },
			{ -0.5, 0.0, -0.5, -0.4, 0.5, 0.5 },
			{ -0.5, 0.0, -0.5, 0.5, 0.5, -0.4 },
			--funnel base
			{ -0.5, 0.0, -0.5, 0.5, 0.1, 0.5 },
			--spout
			{ -0.3, -0.3, -0.3, 0.3, 0.0, 0.3 },
			{ -0.1, -0.3, -0.1, 0.1, -0.5, 0.1 },
		},
	},
	selection_box = {
		type = "fixed",
		fixed = {
			--funnel
			{ -0.5, 0.0, -0.5, 0.5, 0.5, 0.5 },
			--spout
			{ -0.3, -0.3, -0.3, 0.3, 0.0, 0.3 },
			{ -0.1, -0.3, -0.1, 0.1, -0.5, 0.1 },
		},
	},
	is_ground_content = false,

	on_construct = function(pos)
		local meta = core.get_meta(pos)
		meta:set_string("formspec", mcl_hoppers_formspec)
		local inv = meta:get_inventory()
		inv:set_size("main", 5)
		new_hopper(pos)
	end,
	on_destruct = function(pos)
		remove_hopper(pos)
	end,
	after_dig_node = mcl_util.drop_items_from_meta_container({"main"}),

	allow_metadata_inventory_move = function(pos, _, _, _, _, count, player)
		local name = player:get_player_name()
		if core.is_protected(pos, name) then
			core.record_protection_violation(pos, name)
			return 0
		else
			return count
		end
	end,
	allow_metadata_inventory_take = function(pos, _, _, stack, player)
		local name = player:get_player_name()
		if core.is_protected(pos, name) then
			core.record_protection_violation(pos, name)
			return 0
		else
			return stack:get_count()
		end
	end,
	allow_metadata_inventory_put = function(pos, _, _, stack, player)
		local name = player:get_player_name()
		if core.is_protected(pos, name) then
			core.record_protection_violation(pos, name)
			return 0
		else
			return stack:get_count()
		end
	end,
	on_metadata_inventory_move = function(pos, _, _, _, _, _, player)
		core.log("action", player:get_player_name()..
				" moves stuff in mcl_hoppers at "..core.pos_to_string(pos))
		mcl_redstone.update_comparators(pos)
	end,
	on_metadata_inventory_put = function(pos, _, _, _, player)
		core.log("action", player:get_player_name()..
				" moves stuff to mcl_hoppers at "..core.pos_to_string(pos))
		mcl_redstone.update_comparators(pos)
	end,
	on_metadata_inventory_take = function(pos, _, _, _, player)
		core.log("action", player:get_player_name()..
				" takes stuff from mcl_hoppers at "..core.pos_to_string(pos))
		mcl_redstone.update_comparators(pos)
	end,
	sounds = mcl_sounds.node_sound_metal_defaults(),

	_mcl_blast_resistance = 4.8,
	_mcl_hardness = 3,

	_mcl_redstone = redstone,
}

-- Redstone variants (on/off) of downwards hopper.
-- Note a hopper is enabled when it is *not* supplied with redstone power and disabled when it is supplied with redstone power.

-- Enabled downwards hopper
local def_hopper_enabled = table.copy(def_hopper)
def_hopper_enabled.description = S("Hopper")
def_hopper_enabled._tt_help = S("5 inventory slots").."\n"..S("Collects items from above, moves items to container below").."\n"..S("Can be disabled with redstone power")
def_hopper_enabled._doc_items_longdesc = S("Hoppers are containers with 5 inventory slots. They collect dropped items from above, take items from a container above and attempt to put its items it into an adjacent container. Hoppers can go either downwards or sideways. Hoppers interact with chests, droppers, dispensers, shulker boxes, furnaces and hoppers.").."\n\n"..

S("Hoppers interact with containers the following way:").."\n"..
S("• Furnaces: Hoppers from above will put items into the source slot. Hoppers from below take items from the output slot. They also take items from the fuel slot when they can't be used as a fuel. Sideway hoppers that point to the furnace put items into the fuel slot").."\n"..
S("• Ender chests: No interaction.").."\n"..
S("• Other containers: Normal interaction.").."\n\n"..

S("Hoppers can be disabled when supplied with redstone power. Disabled hoppers don't move items.")
def_hopper_enabled._doc_items_usagehelp = S("To place a hopper vertically, place it on the floor or a ceiling. To place it sideways, place it at the side of a block. Use the hopper to access its inventory.")
def_hopper_enabled.on_place = function(itemstack, placer, pointed_thing)
	local uposnode = core.get_node(pointed_thing.under)
	local uposnodedef = core.registered_nodes[uposnode.name]
	if not uposnodedef then return itemstack end

	local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
	if rc then return rc end

	local dir = vector.direction(pointed_thing.under, pointed_thing.above)
	local fake_itemstack = ItemStack(itemstack)
	local param2
	if dir.y == 0 then
		fake_itemstack:set_name("mcl_hoppers:hopper_side")
		param2 = (core.dir_to_fourdir(dir) + FOURDIR_OFFSET ) % 4
	end

	local itemstack,_ = core.item_place_node(fake_itemstack, placer, pointed_thing, param2)
	itemstack:set_name("mcl_hoppers:hopper")
	return itemstack
end

core.register_node("mcl_hoppers:hopper", def_hopper_enabled)

-- Disabled downwards hopper
local def_hopper_disabled = table.copy(def_hopper)
def_hopper_disabled.description = S("Disabled Hopper")
def_hopper_disabled.inventory_image = nil
def_hopper_disabled._doc_items_create_entry = false
def_hopper_disabled.groups.not_in_creative_inventory = 1
def_hopper_disabled.drop = "mcl_hoppers:hopper"

core.register_node("mcl_hoppers:hopper_disabled", def_hopper_disabled)

-- Sidewars hopper (base definition)
local def_hopper_side = table.merge(def_hopper, {
	_doc_items_create_entry = false,
	drop = "mcl_hoppers:hopper",
	groups = { pickaxey = 1, container = 2, not_in_creative_inventory = 1, hopper = 2, pathfinder_partial = 2 },
	paramtype2 = "facedir",
	tiles = {"mcl_hoppers_hopper_inside.png^mcl_hoppers_hopper_top.png", "mcl_hoppers_hopper_outside.png", "mcl_hoppers_hopper_outside.png", "mcl_hoppers_hopper_outside.png", "mcl_hoppers_hopper_outside.png", "mcl_hoppers_hopper_outside.png"},
	node_box = {
		type = "fixed",
		fixed = {
			--funnel walls
			{ -0.5, 0.0, 0.4, 0.5, 0.5, 0.5 },
			{ 0.4, 0.0, -0.5, 0.5, 0.5, 0.5 },
			{ -0.5, 0.0, -0.5, -0.4, 0.5, 0.5 },
			{ -0.5, 0.0, -0.5, 0.5, 0.5, -0.4 },
			--funnel base
			{ -0.5, 0.0, -0.5, 0.5, 0.1, 0.5 },
			--spout
			{ -0.3, -0.3, -0.3, 0.3, 0.0, 0.3 },
			{ -0.5, -0.3, -0.1, 0.1, -0.1, 0.1 },
		},
	},
	selection_box = {
		type = "fixed",
		fixed = {
			--funnel
			{ -0.5, 0.0, -0.5, 0.5, 0.5, 0.5 },
			--spout
			{ -0.3, -0.3, -0.3, 0.3, 0.0, 0.3 },
			{ -0.5, -0.3, -0.1, 0.1, -0.1, 0.1 },
		},
	},

	on_rotate = screwdriver.rotate_simple,
})

local def_hopper_side_enabled = table.copy(def_hopper_side)
def_hopper_side_enabled.description = S("Side Hopper")

core.register_node("mcl_hoppers:hopper_side", def_hopper_side_enabled)

local def_hopper_side_disabled = table.copy(def_hopper_side)
def_hopper_side_disabled.description = S("Disabled Side Hopper")

core.register_node("mcl_hoppers:hopper_side_disabled", def_hopper_side_disabled)

--[[ END OF NODE DEFINITIONS ]]

core.register_craft({
	output = "mcl_hoppers:hopper",
	recipe = {
		{"mcl_core:iron_ingot","","mcl_core:iron_ingot"},
		{"mcl_core:iron_ingot","mcl_chests:chest","mcl_core:iron_ingot"},
		{"","mcl_core:iron_ingot",""},
	}
})

-- Add entry aliases for the Help
doc.add_entry_alias("nodes", "mcl_hoppers:hopper", "nodes", "mcl_hoppers:hopper_side")

-- Legacy

core.register_lbm({
	label = "Update hopper formspecs (0.60.0",
	name = "mcl_hoppers:update_formspec_0_60_0",
	nodenames = { "group:hopper" },
	run_at_every_load = false,
	action = function(pos)
		local meta = core.get_meta(pos)
		meta:set_string("formspec", mcl_hoppers_formspec)
	end,
})

core.register_lbm({
	label = "Tick hoppers",
	name = "mcl_hoppers:ticker",
	nodenames = { "group:hopper" },
	run_at_every_load = true,
	action = function(pos)
		-- Older hoppers were driven by node timers
		core.get_node_timer(pos):stop()
		get_hopper(pos)
	end,
})

dofile(core.get_modpath(core.get_current_modname()).."/compat.lua")
