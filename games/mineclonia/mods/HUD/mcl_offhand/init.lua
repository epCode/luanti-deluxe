mcl_offhand = {}

local max_offhand_px = 128
-- only supports up to 128px textures

function mcl_offhand.get_offhand(player)
	return player:get_inventory():get_stack("offhand", 1)
end

function mcl_offhand.set_offhand(player, itemstack)
	return player:get_inventory():set_stack("offhand", 1, itemstack)
end

-- Whether a node placed from `stack` at `pointed_thing` would be inside the
-- player. The client refuses this for the main hand (it predicts placement),
-- but the other hand is only placed by the server.
local function would_place_inside(player, stack, pointed_thing)
	local def = stack:get_definition()
	local name = def.node_placement_prediction
	if name == nil and def.type == "node" then
		name = stack:get_name()
	end
	local ndef = name and core.registered_nodes[name]
	if not ndef or not ndef.walkable then
		return false
	end

	-- Where core.item_place_node puts it
	local under_def = core.registered_nodes[core.get_node(pointed_thing.under).name]
	local pos = under_def and under_def.buildable_to and pointed_thing.under
		or pointed_thing.above

	local ppos = player:get_pos()
	local cb = player:get_properties().collisionbox
	local eps = 0.001
	for _, b in ipairs(core.get_node_boxes("collision_box", pos, {name = name, param2 = 0})) do
		if pos.x + b[1] < ppos.x + cb[4] - eps and pos.x + b[4] > ppos.x + cb[1] + eps
				and pos.y + b[2] < ppos.y + cb[5] - eps and pos.y + b[5] > ppos.y + cb[2] + eps
				and pos.z + b[3] < ppos.z + cb[6] - eps and pos.z + b[6] > ppos.z + cb[3] + eps then
			return true
		end
	end
	return false
end

-- Uses the item in the other hand for a right-click that does nothing with
-- the item in the main hand (Minecraft tries the main hand first, then the
-- other hand): places it on a node, or uses it (e.g. throws it).
-- Returns true if the other hand was used.
-- The callbacks that offhand_fallback (below) replaced: the item in the other
-- hand is used with its own callback, not the fallback to the other hand
-- (wrapper -> original callback, or false if there was none)
local fallback_originals = {}

local function own_callback(func)
	local original = fallback_originals[func]
	if original == nil then
		return func
	end
	return original or nil
end

local using_offhand = {}

function mcl_offhand.place(placer, pointed_thing)
	if not placer or not placer:is_player() then
		return false
	end
	local name = placer:get_player_name()
	if using_offhand[name] then
		return false
	end
	using_offhand[name] = true
	local ok, used = pcall(mcl_offhand.use_offhand, placer, pointed_thing)
	using_offhand[name] = nil
	if not ok then
		error(used, 0)
	end
	return used
end

function mcl_offhand.use_offhand(placer, pointed_thing)
	local offhand = mcl_offhand.get_offhand(placer)
	if offhand:is_empty() then
		return false
	end
	local odef = offhand:get_definition()
	local new_stack
	if pointed_thing and pointed_thing.type == "node" then
		if would_place_inside(placer, offhand, pointed_thing) then
			-- Nothing happens, like a failed placement with the main hand
			return true
		end
		local on_place = own_callback(odef.on_place)
		if on_place then
			new_stack = on_place(offhand, placer, pointed_thing)
		else
			new_stack = core.item_place(offhand, placer, pointed_thing)
		end
	else
		local on_secondary_use = own_callback(odef.on_secondary_use)
		if not on_secondary_use then
			return false
		end
		new_stack = on_secondary_use(offhand, placer, pointed_thing)
	end
	if new_stack then
		mcl_offhand.set_offhand(placer, new_stack)
	end
	-- The client swings the other hand by itself when its item is used up;
	-- items in creative mode are not
	if core.is_creative_enabled(placer:get_player_name()) and odef.type == "node"
			and pointed_thing and pointed_thing.type == "node" then
		mcl_util.swing_hand(placer, {hand = "offhand", item_used = true})
	end
	return true
end

-- A right-click with an item that has no use of its own (or the empty hand)
-- uses the item in the other hand
local function is_default_callback(def, field)
	local f = def[field]
	return f == nil or f == core.nodedef_default[field]
		or f == core.craftitemdef_default[field]
		or f == core.tooldef_default[field]
		or f == core.noneitemdef_default[field]
end

local function offhand_fallback(old_func, on_node_only)
	local function fallback(itemstack, user, pointed_thing)
		if user and user:is_player()
				and (not on_node_only or (pointed_thing and pointed_thing.type == "node")) then
			-- Nodes that can be right-clicked come first
			local rc = mcl_util.call_on_rightclick(itemstack, user, pointed_thing)
			if rc then
				return rc
			end
			if mcl_util.main_hand_passive(user, pointed_thing)
					and mcl_offhand.place(user, pointed_thing) then
				return
			end
		end
		if old_func then
			return old_func(itemstack, user, pointed_thing)
		end
	end
	fallback_originals[fallback] = old_func or false
	return fallback
end

-- Items that swing the hand when used (thrown, cast, ...). Survival clients
-- swing by themselves when the item is used up, but not in creative mode or
-- when the item stays (fishing rods).
local swing_on_use = {
	"^mcl_throwing:", "^mcl_fireworks:rocket", "^mcl_end:ender_eye$",
	"^mcl_fishing:fishing_rod", "^mcl_experience:bottle$",
	"^mcl_potions:.*_splash$", "^mcl_potions:.*_lingering$",
}

local function swings_on_use(name)
	for _, pattern in ipairs(swing_on_use) do
		if name:find(pattern) then
			return true
		end
	end
	return false
end

local function swing_after_use(old_func)
	return function(itemstack, user, pointed_thing)
		local name = itemstack:get_name()
		local result = old_func(itemstack, user, pointed_thing)
		if result ~= nil and user and user:is_player() then
			local hand = "main"
			if user:get_wielded_item():get_name() ~= name
					and mcl_offhand.get_offhand(user):get_name() == name then
				hand = "offhand"
			end
			mcl_util.swing_hand(user, {hand = hand})
		end
		return result
	end
end

core.register_on_mods_loaded(function()
	for name, def in pairs(core.registered_items) do
		local override = {}
		if swings_on_use(name) then
			if not is_default_callback(def, "on_place") then
				override.on_place = swing_after_use(def.on_place)
			end
			if not is_default_callback(def, "on_secondary_use") then
				override.on_secondary_use = swing_after_use(def.on_secondary_use)
			end
		end
		if name == "" then
			override.on_place = offhand_fallback(def.on_place)
			override.on_secondary_use = offhand_fallback(def.on_secondary_use)
		elseif def._mcl_main_hand_passive ~= false
				and core.get_item_group(name, "food") == 0 then
			-- Nodes are placed instead
			if def.type ~= "node" and is_default_callback(def, "on_place") then
				override.on_place = offhand_fallback(def.on_place, true)
			end
			if is_default_callback(def, "on_secondary_use") then
				override.on_secondary_use = offhand_fallback(def.on_secondary_use)
			end
		end
		if next(override) then
			core.override_item(name, override)
		end
	end
end)

-- The swap hands key (F) swaps the items in the main hand and the other hand
controls.register_on_press(function(player, key)
	if key ~= "swap_hands" or mcl_gamemode.is_spectator(player) then
		return
	end
	local inv = player:get_inventory()
	if inv:get_size("offhand") < 1 then
		return
	end
	local main = player:get_wielded_item()
	local offhand = mcl_offhand.get_offhand(player)
	mcl_offhand.set_offhand(player, main)
	player:set_wielded_item(offhand)
end)

local function offhand_get_wear(player)
	return mcl_offhand.get_offhand(player):get_wear()
end

local function offhand_get_count(player)
	return mcl_offhand.get_offhand(player):get_count()
end

local function remove_hud(player, hud)
	local offhand_hud = mcl_offhand[player].hud[hud]
	if offhand_hud then
		player:hud_remove(offhand_hud)
		mcl_offhand[player].hud[hud] = nil
	end
end

local function rgb_to_hex(r, g, b)
	return string.format("%02x%02x%02x", r, g, b)
end

local function update_wear_bar(player, itemstack)
	local wear_bar_percent = (65535 - offhand_get_wear(player)) / 65535

	local color
	local wear = itemstack:get_wear() / 65535;
	local wear_i = math.min(math.floor(wear * 600), 511);
	wear_i = math.min(wear_i + 10, 511);
	if wear_i <= 255 then
		color = {wear_i, 255, 0}
	else
		color = {255, 511 - wear_i, 0}
	end
	local wear_bar = mcl_offhand[player].hud.wear_bar
	player:hud_change(wear_bar, "text", "mcl_wear_bar.png^[colorize:#" .. rgb_to_hex(color[1], color[2], color[3]))
	player:hud_change(wear_bar, "scale", {x = 40 * wear_bar_percent, y = 3})
	player:hud_change(wear_bar, "offset", {x = -320 - (20 - player:hud_get(wear_bar).scale.x / 2), y = -13})
end

mcl_player.register_globalstep(function(player)
	if not mcl_offhand[player] then
		mcl_offhand[player] = {
			hud = {},
			last_wear = offhand_get_wear(player),
			last_count = offhand_get_count(player),
		}
	end

	local itemstack = mcl_offhand.get_offhand(player)
	local offhand_item = itemstack:get_name()
	local offhand = mcl_offhand[player]
	local offhand_hud = offhand.hud
	local item = core.registered_items[offhand_item]
	if offhand_item ~= "" and item and not mcl_gamemode.is_spectator(player) then
		local meta_texture = itemstack:get_meta():get_string("inventory_overlay")
		if not meta_texture or meta_texture == "" then meta_texture = item.inventory_image end
		if (not meta_texture or meta_texture == "") and item.tiles then
			-- Nodes without an inventory image are drawn as a cube
			local function tile(i)
				local t = item.tiles[i] or item.tiles[#item.tiles]
				t = type(t) == "table" and (t.name or t.image) or t
				return t or "blank.png"
			end
			meta_texture = core.inventorycube(tile(1), tile(6), tile(3))
		end
		local item_texture = meta_texture .. "^[resize:" .. max_offhand_px .. "x" .. max_offhand_px
		local position = {x = 0.5, y = 1}
		local offset = {x = -320, y = -32}

		if not offhand_hud.slot then
			offhand_hud.slot = player:hud_add({
				type = "image",
				position = position,
				offset = offset,
				scale = {x = 0.46875, y = 0.46875},
				text = "mcl_offhand_slot.png" .. "^[resize:" .. max_offhand_px .. "x" .. max_offhand_px,
				z_index = 0,
			})
		end
		if not offhand_hud.item then
			offhand_hud.item = player:hud_add({
				type = "image",
				position = position,
				offset = offset,
				scale = {x = 0.375, y = 0.375},
				text = item_texture,
				z_index = 1,
			})
		else
			local item_hud = player:hud_get(offhand_hud.item)
			if item_hud and item_hud.text ~= item_texture then
				player:hud_change(offhand_hud.item, "text", item_texture)
			elseif not item_hud then
				offhand_hud.item = nil
			end
		end
		if not offhand_hud.wear_bar_bg and core.registered_tools[offhand_item] then
			if offhand_get_wear(player) > 0 then
				local texture = "mcl_wear_bar.png^[colorize:#000000"
				offhand_hud.wear_bar_bg = player:hud_add({
					type = "image",
					position = {x = 0.5, y = 1},
					offset = {x = -320, y = -13},
					scale = {x = 40, y = 3},
					text = texture,
					z_index = 2,
				})
				offhand_hud.wear_bar = player:hud_add({
					type = "image",
					position = {x = 0.5, y = 1},
					offset = {x = -320, y = -13},
					scale = {x = 10, y = 3},
					text = texture,
					z_index = 3,
				})
				update_wear_bar(player, itemstack)
			end
		end

		if not offhand_hud.item_count and offhand_get_count(player) > 1 then
			offhand_hud.item_count = player:hud_add({
				type = "text",
				position = {x = 0.5, y = 1},
				offset = {x = -298, y = -18},
				scale = {x = 1, y = 1},
				alignment = {x = -1, y = 0},
				text = offhand_get_count(player),
				z_index = 4,
				number = 0xFFFFFF,
			})
		end

		if offhand_hud.wear_bar then
			if offhand.last_wear ~= offhand_get_wear(player) then
				update_wear_bar(player, itemstack)
				offhand.last_wear = offhand_get_wear(player)
			end
			if offhand_get_wear(player) <= 0 or not core.registered_tools[offhand_item] then
				remove_hud(player, "wear_bar_bg")
				remove_hud(player, "wear_bar")
			end
		end

		if offhand_hud.item_count then
			if offhand.last_count ~= offhand_get_count(player) then
				player:hud_change(offhand_hud.item_count, "text", offhand_get_count(player))
				offhand.last_count = offhand_get_count(player)
			end
			if offhand_get_count(player) <= 1 then
				remove_hud(player, "item_count")
			end
		end

	elseif offhand_hud.slot then
		for index, _ in pairs(mcl_offhand[player].hud) do
			remove_hud(player, index)
		end
	end
end)

core.register_on_player_inventory_action(function(player, action, _, inventory_info)
	local from_offhand = inventory_info.from_list == "offhand"
	local to_offhand = inventory_info.to_list == "offhand"
	if action == "move" and from_offhand or to_offhand then
		mcl_inventory.update_inventory_formspec(player)
	end
end)
