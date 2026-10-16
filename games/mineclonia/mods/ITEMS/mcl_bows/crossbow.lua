local S = core.get_translator(core.get_current_modname())

-- local arrows = {
-- 	["mcl_bows:arrow"] = "mcl_bows:arrow_entity",
-- }

-- AbstractArrow: default gravity 0.05 blocks/tick^2.
local GRAVITY = 20
local BOW_DURABILITY = 385

-- Charging time in microseconds.  CrossbowItem: MAX_CHARGE_DURATION
-- is 1.25 s (25 ticks), and the second pulling model is displayed from
-- 58% of the charge duration (assets/minecraft/items/crossbow.json).
local _BOW_CHARGE_TIME_HALF = 725000 -- bow level 1
local _BOW_CHARGE_TIME_FULL = 1250000 -- bow level 2 (full charge)
-- quick_charge.json: crossbow_charge_time -0.25 s per level.
local QUICK_CHARGE_REDUCTION = 0.25 * 1.0e+6

local BOW_CHARGE_TIME_HALF = _BOW_CHARGE_TIME_HALF -- bow level 1
local BOW_CHARGE_TIME_FULL = _BOW_CHARGE_TIME_FULL -- bow level 2 (full charge)
mcl_bows.CROSSBOW_CHARGE_TIME_HALF = BOW_CHARGE_TIME_HALF / 1e+6
mcl_bows.CROSSBOW_CHARGE_TIME_FULL = BOW_CHARGE_TIME_FULL / 1e+6

-- Factor to multiply with player speed while player uses bow
-- This emulates the sneak speed.
-- Minecraft multiplies the movement input by 0.2 while an item is in use.
local PLAYER_USE_CROSSBOW_SPEED = 0.2

local BOW_MAX_SPEED = 3.15 * 20

local function play_load_sound(id, object)
	core.sound_play({name = "mcl_bows_crossbow_drawback_"..id, gain=0.3}, {object=object, max_hear_distance=16}, true)
end

--[[ Store the charging state of each player.
keys: player name
value:
nil = not charging or player not existing
number: currently charging, the number is the time from core.get_us_time
             in which the charging has started
]]
local bow_load = {}

-- Another player table, this one stores the wield index of the bow being charged
local bow_index = {}

-- The hand ("main" or "offhand") that draws the crossbow
local bow_hand = {}

local function is_crossbow(name)
	return name == "mcl_bows:crossbow" or name == "mcl_bows:crossbow_enchanted"
end

local function is_loaded_crossbow(name)
	return core.get_item_group(name, "crossbow") == 5
end

-- crossbow_0, crossbow_1, crossbow_2 and their enchanted variants
local function is_drawn_crossbow(name)
	local level = core.get_item_group(name, "crossbow")
	return level >= 2 and level <= 4
end

local function shoot_arrow_crossbow_1(arrow_item, pos, dir, yaw, shooter, speed, damage, is_critical, crossbow_stack, collectable)
	local obj = core.add_entity({x=pos.x,y=pos.y,z=pos.z}, ItemStack(arrow_item):get_name().."_entity")
	if not obj or not obj:get_pos() then return end
	if damage == nil then
		damage = 2
	end
	if crossbow_stack then
		local enchantments = mcl_enchanting.get_enchantments(crossbow_stack)
		if enchantments.piercing then
			obj:get_luaentity()._piercing = 1 * enchantments.piercing
		else
			obj:get_luaentity()._piercing = 0
		end
	end
	obj:set_velocity({x=dir.x*speed, y=dir.y*speed, z=dir.z*speed})
	obj:set_acceleration({x=0, y=-GRAVITY, z=0})
	obj:set_yaw(yaw-math.pi/2)
	local le = obj:get_luaentity()
	le._shooter = shooter
	le._source_object = shooter
	le._damage = damage
	le._is_critical = is_critical
	le._startpos = pos
	le._collectable = collectable
	le._itemstring = arrow_item
	if shooter and shooter:is_player() then
		if le.player == "" then
			le.player = shooter
		end
		le.node = shooter:get_inventory():get_stack("main", 1):get_name()
	end
	return obj
end

local function get_pitch (dir)
	return math.atan2 (-dir.y, math.sqrt (dir.x * dir.x + dir.z * dir.z))
end

function mcl_bows.shoot_arrow_crossbow (arrow_item, pos, dir, yaw, shooter, speed, damage, is_critical, crossbow_stack, collectable)
	local has_multishot_enchantment
		= crossbow_stack and mcl_enchanting.has_enchantment (crossbow_stack, "multishot")
	core.sound_play({name="mcl_bows_crossbow_shoot", gain=0.035}, {pos=pos, max_hear_distance=32}, true)
	local inaccuracy = (shooter and shooter:is_player() and 1) or nil -- No dispenser; that use mcl_bows.shoot_arrow
	dir = mcl_bows.add_inaccuracy(dir, inaccuracy)
	if has_multishot_enchantment then
		-- calculate rotation by 10 degrees 'left' and 'right' of facing direction
		local pitch = get_pitch (dir)
		local pitch_c = math.cos(pitch)
		local pitch_s = math.sin(pitch)
		local yaw_c = math.cos(yaw + math.pi / 2)
		local yaw_s = math.sin(yaw + math.pi / 2)

		local rot_left =  {x =   yaw_c * pitch_s * math.pi / 18, y =   pitch_c * math.pi / 18, z =   yaw_s * pitch_s * math.pi / 18}
		local rot_right = {x = - yaw_c * pitch_s * math.pi / 18, y = - pitch_c * math.pi / 18, z = - yaw_s * pitch_s * math.pi / 18}
		local dir_left = vector.rotate(dir, rot_left)
		local dir_right = vector.rotate(dir, rot_right)

		shoot_arrow_crossbow_1 (arrow_item, pos, {x=dir_left.x, y=dir_left.y, z=dir_left.z}, yaw, shooter, speed, damage, is_critical, crossbow_stack, collectable)
		shoot_arrow_crossbow_1 (arrow_item, pos, {x=dir_right.x, y=dir_right.y, z=dir_right.z}, yaw, shooter, speed, damage, is_critical, crossbow_stack, collectable)
		shoot_arrow_crossbow_1 (arrow_item, pos, dir, yaw, shooter, speed, damage, is_critical, crossbow_stack, collectable)
	else
		shoot_arrow_crossbow_1 (arrow_item, pos, dir, yaw, shooter, speed, damage, is_critical, crossbow_stack, collectable)
	end
end

-- Returns the arrow stack, its index and its inventory list. Like Minecraft,
-- arrows in the other hand are used first, then in the main hand, then the
-- first ones in the inventory.
local function get_arrow(player)
	local inv = player:get_inventory()
	local function is_arrow(stack)
		return not stack:is_empty() and core.get_item_group(stack:get_name(), "ammo_crossbow") ~= 0
	end
	local offhand = inv:get_stack("offhand", 1)
	if is_arrow(offhand) then
		return offhand, 1, "offhand"
	end
	local wield_index = player:get_wield_index()
	local wielded = inv:get_stack("main", wield_index)
	if is_arrow(wielded) then
		return wielded, wield_index, "main"
	end
	for i=1, inv:get_size("main") do
		local it = inv:get_stack("main", i)
		if is_arrow(it) then
			return it, i, "main"
		end
	end
end

function mcl_bows.get_arrow_stack_for_crossbow (player)
	return get_arrow (player)
end

local function player_shoot_arrow(wielditem, player, is_critical)
	local arrow_itemstring = wielditem:get_meta():get("arrow")
	local arrow_item_name = ItemStack(arrow_itemstring):get_name()
	if not arrow_itemstring or core.get_item_group(arrow_item_name, "ammo_crossbow") == 0 then
		return false
	end

	local playerpos = mcl_util.target_eye_pos (player)
	playerpos.y = playerpos.y - 0.1
	local dir = player:get_look_dir()
	local yaw = player:get_look_horizontal()

	mcl_bows.shoot_arrow_crossbow (arrow_itemstring, playerpos, dir, yaw, player, BOW_MAX_SPEED, nil, is_critical, wielditem, true)
	return true
end

-- Minecraft's crossbow model display (models/item/crossbow.json)
local FIRST_PERSON_ROTATION = {x = -90, y = 0, z = -55}
local FIRST_PERSON_ROTATION_OFFHAND = {x = -90, y = 0, z = 35}

-- Bow item, uncharged state
core.register_tool("mcl_bows:crossbow", {
	description = S("Crossbow"),
	_tt_help = S("Launches arrows"),
	_doc_items_longdesc = S("Crossbows are ranged weapons to shoot arrows at your foes.").."\n"..
S("The speed and damage of the arrow increases the longer you charge. The regular damage of the arrow is between 1 and 9. At full charge, there's also a 20% of a critical hit, dealing 10 damage instead."),
	_doc_items_usagehelp = S("To use the crossbow, you first need to have at least one arrow anywhere in your inventory (unless in Creative Mode). Hold down the right mouse button (or zoom key) to charge, release to load an arrow into the chamber, then to shoot press left mouse."),
	_doc_items_durability = BOW_DURABILITY,
	inventory_image = "mcl_bows_crossbow.png",
	wield_scale = mcl_vars.tool_wield_scale,
	first_person_rotation = FIRST_PERSON_ROTATION,
	first_person_rotation_offhand = FIRST_PERSON_ROTATION_OFFHAND,
	stack_max = 1,
	-- Trick to disable digging as well
	on_use = function() end,
	on_place = function(itemstack, player, pointed_thing)
		local rc = mcl_util.call_on_rightclick(itemstack, player, pointed_thing)
		if rc then return rc end

		itemstack:get_meta():set_string("active", "true")
		return itemstack
	end,
	on_secondary_use = function(itemstack)
		itemstack:get_meta():set_string("active", "true")
		return itemstack
	end,
	touch_interaction = "short_dig_long_place",
	groups = {weapon = 1, weapon_ranged = 1, crossbow = 1, enchantability = 1, offhand_item = 1},
	_mcl_uses = 326,
	_mcl_burntime = 15
})

core.register_tool("mcl_bows:crossbow_loaded", {
	description = S("Crossbow"),
	_tt_help = S("Launches arrows"),
	_doc_items_longdesc = S("Crossbows are ranged weapons to shoot arrows at your foes.").."\n"..
S("The speed and damage of the arrow increases the longer you charge. The regular damage of the arrow is between 1 and 9. At full charge, there's also a 20% of a critical hit, dealing 10 damage instead."),
	_doc_items_usagehelp = S("To use the crossbow, you first need to have at least one arrow anywhere in your inventory (unless in Creative Mode). Hold down the right mouse button to charge, release to load an arrow into the chamber, then to shoot press left mouse."),
	_doc_items_durability = BOW_DURABILITY,
	inventory_image = "mcl_bows_crossbow_3.png",
	wield_scale = mcl_vars.tool_wield_scale,
	first_person_rotation = FIRST_PERSON_ROTATION,
	first_person_rotation_offhand = FIRST_PERSON_ROTATION_OFFHAND,
	stack_max = 1,
	-- Trick to disable digging as well
	on_use = function() end,
	on_place = function(itemstack, player, pointed_thing)
		local rc = mcl_util.call_on_rightclick(itemstack, player, pointed_thing)
		if rc then return rc end

		itemstack:get_meta():set_string("active", "true")
		return itemstack
	end,
	on_secondary_use = function(itemstack)
		itemstack:get_meta():set_string("active", "true")
		return itemstack
	end,
	touch_interaction = "short_dig_long_place",
	groups = {weapon = 2, weapon_ranged = 1, crossbow = 5, enchantability = 1, not_in_creative_inventory = 1, offhand_item = 1},
	-- Held up, ready to shoot
	hold_animation = "charged_crossbow",
	-- Loading replaces the crossbow without lowering it
	hand_animation_on_swap = false,
	_mcl_uses = 326,
	_mcl_burntime = 15
})

-- Iterates through player inventory and resets all the bows in "charging" state back to their original stage
local function reset_bows(player)
	local inv = player:get_inventory()
	for _, listname in ipairs({"main", "offhand"}) do
	local list = inv:get_list(listname) or {}
	for place, stack in pairs(list) do
		if stack:get_name() == "mcl_bows:crossbow" or stack:get_name() == "mcl_bows:crossbow_enchanted" then
			stack:get_meta():set_string("active", "")
		elseif stack:get_name()=="mcl_bows:crossbow_0" or stack:get_name()=="mcl_bows:crossbow_1" or stack:get_name()=="mcl_bows:crossbow_2" then
			stack:set_name("mcl_bows:crossbow")
			stack:get_meta():set_string("active", "")
			list[place] = stack
		elseif stack:get_name()=="mcl_bows:crossbow_0_enchanted" or stack:get_name()=="mcl_bows:crossbow_1_enchanted" or stack:get_name()=="mcl_bows:crossbow_2_enchanted" then
			stack:set_name("mcl_bows:crossbow_enchanted")
			stack:get_meta():set_string("active", "")
			list[place] = stack
		end
	end
	if inv:get_size(listname) > 0 then
		inv:set_list(listname, list)
	end
	end
end

-- Resets the bow charging state and player speed. To be used when the player is no longer charging the bow
local function reset_bow_state(player, also_reset_bows)
	-- LivingEntity.stopUsingItem (ItemStack.causeUseVibration)
	if bow_load[player:get_player_name()] ~= nil and mcl_gameevent then
		mcl_gameevent.emit_entity(player, "item_interact_finish")
	end
	bow_load[player:get_player_name()] = nil
	bow_index[player:get_player_name()] = nil
	bow_hand[player:get_player_name()] = nil
	mcl_util.stop_item_use(player, "crossbow")

	playerphysics.remove_physics_factor(player, "speed", "mcl_bows:use_crossbow")
	if also_reset_bows then
		reset_bows(player)
	end
end

-- Bow in charging state
for level=0, 2 do
	core.register_tool("mcl_bows:crossbow_"..level, {
		description = S("Crossbow"),
		_doc_items_create_entry = false,
		inventory_image = "mcl_bows_crossbow_"..level..".png",
		wield_scale = mcl_vars.tool_wield_scale,
		first_person_rotation = FIRST_PERSON_ROTATION,
		first_person_rotation_offhand = FIRST_PERSON_ROTATION_OFFHAND,
		stack_max = 1,
		range = 0, -- Pointing range to 0 to prevent punching with bow :D
		groups = {not_in_creative_inventory=1, not_in_craft_guide=1, enchantability=1, crossbow=2+level},
		-- The drawing stages replace each other without lowering the crossbow
		hand_animation_on_swap = false,
		-- Trick to disable digging as well
		on_use = function() end,
		on_drop = function(itemstack, dropper, pos)
			reset_bow_state(dropper)
			itemstack:get_meta():set_string("active", "")
			if mcl_enchanting.is_enchanted(itemstack:get_name()) then
				itemstack:set_name("mcl_bows:crossbow_enchanted")
			else
				itemstack:set_name("mcl_bows:crossbow")
			end
			core.item_drop(itemstack, dropper, pos)
			itemstack:take_item()
			return itemstack
		end,
		-- Prevent accidental interaction with itemframes and other nodes
		on_place = function(itemstack)
			return itemstack
		end,
		touch_interaction = "short_dig_long_place",
		_mcl_uses = 385,
	})
end

-- CrossbowItem.getChargeDuration: floor (duration * 20) ticks.
local function charge_time_for_level (quick_charge)
	local time = _BOW_CHARGE_TIME_FULL - (quick_charge or 0) * QUICK_CHARGE_REDUCTION
	return math.max (0, math.floor (time / 50000) * 50000)
end

local function get_crossbow_charge_time (wielditem)
	local enchantments = mcl_enchanting.get_enchantments (wielditem)
	return charge_time_for_level (enchantments.quick_charge)
end

function mcl_bows.crossbow_charge_time_multiplier (quick_charge)
	return charge_time_for_level (quick_charge) / _BOW_CHARGE_TIME_FULL
end

-- Return the time in seconds required to charge the crossbow STACK
-- (by players or mobs alike).
function mcl_bows.get_crossbow_charge_time (stack)
	return get_crossbow_charge_time (stack) / 1.0e+6
end

function mcl_bows.load_crossbow (player, wielditem, usetime)
	local arrow_stack, arrow_stack_id, arrow_list = get_arrow(player)
	local arrow_itemstring

	if not arrow_stack or usetime < get_crossbow_charge_time (wielditem) then
		return
	end

	if core.is_creative_enabled(player:get_player_name()) then
		if arrow_stack then
			arrow_itemstring = arrow_stack:get_name()
		else
			arrow_itemstring = "mcl_bows:arrow"
		end
	else
		arrow_itemstring = arrow_stack:get_name()
		arrow_stack:take_item()
		player:get_inventory():set_stack(arrow_list, arrow_stack_id, arrow_stack)
	end

	wielditem:get_meta():set_string("arrow", arrow_itemstring)

	if not mcl_enchanting.is_enchanted (wielditem:get_name ()) then
		wielditem:set_name("mcl_bows:crossbow_loaded")
	else
		wielditem:set_name("mcl_bows:crossbow_loaded_enchanted")
	end
	player:set_wielded_item(wielditem, true)
end

local function fully_drawn(name)
	return core.get_item_group(name, "crossbow") == 4
end

controls.register_on_release(function(player, key)
	if mcl_serverplayer.is_csm_capable (player) then
		return
	end
	if key~="RMB" and key~="zoom" then return end
	local name = player:get_player_name()
	local hand = bow_hand[name] or "main"
	local wielditem = mcl_util.get_hand_item(player, hand)
	local creative = core.is_creative_enabled(name)
	local arrow_stack, arrow_stack_id, arrow_list = get_arrow(player)

	if fully_drawn(wielditem:get_name()) and (creative or arrow_stack) then
		local arrow_itemstring
		if creative then
			if arrow_stack then
				arrow_itemstring = arrow_stack:to_string()
			else
				arrow_itemstring = "mcl_bows:arrow"
			end
		else
			arrow_itemstring = arrow_stack:to_string()
			arrow_stack:take_item()
			player:get_inventory():set_stack(arrow_list, arrow_stack_id, arrow_stack)
		end

		arrow_itemstring = ItemStack(arrow_itemstring)
		arrow_itemstring:set_count(1)
		arrow_itemstring = arrow_itemstring:to_string()

		wielditem:get_meta():set_string("arrow", arrow_itemstring)

		if wielditem:get_name()=="mcl_bows:crossbow_2" then
			wielditem:set_name("mcl_bows:crossbow_loaded")
		else
			wielditem:set_name("mcl_bows:crossbow_loaded_enchanted")
		end
		mcl_util.set_hand_item(player, hand, wielditem, true)
		core.sound_play({name="mcl_bows_crossbow_load", gain=0.3}, {object=player, max_hear_distance=16}, true)
		reset_bow_state(player)
	else
		reset_bow_state(player, true)
	end
end)

local function shoot_loaded(player, hand)
	local wielditem = mcl_util.get_hand_item(player, hand)
	local enchanted = mcl_enchanting.is_enchanted(wielditem:get_name())
	local has_shot = player_shoot_arrow (wielditem, player, true)

	if enchanted then
		wielditem:set_name("mcl_bows:crossbow_enchanted")
	else
		wielditem:set_name("mcl_bows:crossbow")
	end

	if has_shot and not core.is_creative_enabled(player:get_player_name()) then
		local durability = BOW_DURABILITY
		local unbreaking = mcl_enchanting.get_enchantment(wielditem, "unbreaking")
		local multishot = mcl_enchanting.get_enchantment(wielditem, "multishot")
		if unbreaking > 0 then
			durability = durability * (unbreaking + 1)
		end
		if multishot then
			durability = durability / 3
		end
		wielditem:add_wear(65535/durability)
	end
	-- Shooting does not lower the crossbow, it swings
	mcl_util.set_hand_item(player, hand, wielditem, true)
	mcl_util.swing_hand(player, {hand = hand})
	reset_bow_state(player, true)
end

controls.register_on_press(function(player, key)
	if key == "LMB" then
		if is_loaded_crossbow(player:get_wielded_item():get_name()) then
			shoot_loaded(player, "main")
		end
	elseif key == "RMB" and not mcl_serverplayer.is_csm_capable (player) then
		-- Like Minecraft, using a loaded crossbow shoots it
		local hand = mcl_util.get_use_hand(player, function(stack)
			return is_loaded_crossbow(stack:get_name())
		end, mcl_util.get_pointed_thing(player, true))
		if hand then
			shoot_loaded(player, hand)
		end
	end
end)

-- Whether the crossbow in a hand is still the one being drawn
local function still_drawing(player, name)
	local hand = bow_hand[name]
	if not hand then
		return false
	end
	if hand == "main" and player:get_wield_index() ~= bow_index[name] then
		return false
	end
	return is_drawn_crossbow(mcl_util.get_hand_item(player, hand):get_name())
end

local function set_charge_times(wielditem)
	local enchantments = mcl_enchanting.get_enchantments(wielditem)
	if enchantments.quick_charge then
		BOW_CHARGE_TIME_FULL = charge_time_for_level (enchantments.quick_charge)
		BOW_CHARGE_TIME_HALF = BOW_CHARGE_TIME_FULL * 0.58
	else
		BOW_CHARGE_TIME_HALF = _BOW_CHARGE_TIME_HALF
		BOW_CHARGE_TIME_FULL = _BOW_CHARGE_TIME_FULL
	end
end

controls.register_on_hold(function(player, key)
	if mcl_serverplayer.is_csm_capable (player) then
		return
	end
	local name = player:get_player_name()
	local creative = core.is_creative_enabled(name)
	if key ~= "RMB" and key ~= "zoom" then
		return
	end

	if bow_load[name] == nil then
		local hand, wielditem = mcl_util.get_use_hand(player, function(stack)
			return is_crossbow(stack:get_name())
				and (stack:get_meta():get("active") or key == "zoom")
		end)
		if not hand or not (creative or get_arrow(player)) then
			return
		end
		set_charge_times(wielditem)
		if mcl_enchanting.is_enchanted(wielditem:get_name()) then
			wielditem:set_name("mcl_bows:crossbow_0_enchanted")
		else
			wielditem:set_name("mcl_bows:crossbow_0")
		end
		play_load_sound(0, player)
		mcl_util.set_hand_item(player, hand, wielditem, true)
		-- Slow player down when using bow
		playerphysics.add_physics_factor(player, "speed", "mcl_bows:use_crossbow", PLAYER_USE_CROSSBOW_SPEED)
		bow_load[name] = core.get_us_time()
		bow_index[name] = player:get_wield_index()
		bow_hand[name] = hand
		-- LivingEntity.startUsingItem (ItemStack.causeUseVibration)
		if mcl_gameevent then
			mcl_gameevent.emit_entity(player, "item_interact_start")
		end
		mcl_util.start_item_use(player, {
			animation = "crossbow",
			charge_time = BOW_CHARGE_TIME_FULL / 1.0e6,
			hand = hand,
		})
	elseif still_drawing(player, name) then
		local hand = bow_hand[name]
		local wielditem = mcl_util.get_hand_item(player, hand)
		set_charge_times(wielditem)
		local item_name = wielditem:get_name()
		local suffix = mcl_enchanting.is_enchanted(item_name) and "_enchanted" or ""
		local held = core.get_us_time() - bow_load[name]
		if item_name == "mcl_bows:crossbow_0" .. suffix and held >= BOW_CHARGE_TIME_HALF then
			wielditem:set_name("mcl_bows:crossbow_1" .. suffix)
			play_load_sound(1, player)
		elseif item_name == "mcl_bows:crossbow_1" .. suffix and held >= BOW_CHARGE_TIME_FULL then
			wielditem:set_name("mcl_bows:crossbow_2" .. suffix)
			play_load_sound(2, player)
		else
			return
		end
		mcl_util.set_hand_item(player, hand, wielditem, true)
	else
		reset_bow_state(player, true)
	end
end)

mcl_player.register_globalstep(function(player)
	if not mcl_serverplayer.is_csm_capable (player) then
		local name = player:get_player_name()
		if type(bow_load[name]) == "number" and not still_drawing(player, name) then
			reset_bow_state(player, true)
		end
	end
end)

core.register_on_joinplayer(function(player)
	reset_bows(player)
end)

core.register_on_leaveplayer(function(player)
	reset_bow_state(player, true)
end)

core.register_craft({
	output = "mcl_bows:crossbow",
	recipe = {
		{"mcl_core:stick", "mcl_core:iron_ingot", "mcl_core:stick"},
		{"mcl_mobitems:string", "mcl_bows:arrow", "mcl_mobitems:string"},
		{"", "mcl_core:stick", ""},
	}
})

doc.add_entry_alias("tools", "mcl_bows:crossbow", "tools", "mcl_bows:crossbow_0")
doc.add_entry_alias("tools", "mcl_bows:crossbow", "tools", "mcl_bows:crossbow_1")
doc.add_entry_alias("tools", "mcl_bows:crossbow", "tools", "mcl_bows:crossbow_2")
