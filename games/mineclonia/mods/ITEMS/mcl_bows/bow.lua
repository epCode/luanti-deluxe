local S = core.get_translator(core.get_current_modname())

-- local arrows = {
-- 	["mcl_bows:arrow"] = "mcl_bows:arrow_entity",
-- }

-- AbstractArrow: default gravity 0.05 blocks/tick^2.
local GRAVITY = 20
local BOW_DURABILITY = 385

-- Charging time in microseconds
local BOW_CHARGE_TIME_HALF = 200000 -- bow level 1
local BOW_CHARGE_TIME_FULL = 500000 -- bow level 2 (full charge)
mcl_bows.BOW_CHARGE_TIME_HALF = 200000 / 1.0e6
mcl_bows.BOW_CHARGE_TIME_FULL = 500000 / 1.0e6

-- Factor to multiply with player speed while player uses bow
-- This emulates the sneak speed.
-- Minecraft multiplies the movement input by 0.2 while an item is in use.
local PLAYER_USE_BOW_SPEED = 0.2

local BOW_MAX_SPEED = 3.0 * 20

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

-- The hand ("main" or "offhand") that draws the bow
local bow_hand = {}

local function is_bow(name)
	return name == "mcl_bows:bow" or name == "mcl_bows:bow_enchanted"
end

-- bow_0, bow_1, bow_2 and their enchanted variants
local function is_drawn_bow(name)
	return core.get_item_group(name, "bow") == 1 and not is_bow(name)
end

function mcl_bows.shoot_arrow(arrow_item, pos, dir, yaw, shooter, power, damage, is_critical, bow_stack, collectable)
	local obj = core.add_entity({x=pos.x,y=pos.y,z=pos.z}, ItemStack(arrow_item):get_name().."_entity")
	if not obj or not obj:get_pos() then return end
	if power == nil then
		power = 1.0
	end
	local inaccuracy = nil
	if type(shooter) == "string" then -- Assume to be dispenser.
		inaccuracy = 6
		shooter = nil
	end
	local speed = power * BOW_MAX_SPEED
	local mob_shooter = shooter and not shooter:is_player ()
	local player_shooter = shooter and shooter:is_player ()

	if damage == nil then
		if mob_shooter then
			-- Randomize arrow damage by difficulty.
			damage = 2.0
			local bonus
				= mcl_util.dist_triangular (mcl_vars.difficulty * 0.11,
								0.57425)
			damage = damage + bonus
		else
			damage = 2.0
		end
	end
	local knockback = 0
	if bow_stack then
		local enchantments = mcl_enchanting.get_enchantments(bow_stack)
		if enchantments.power then
			damage = damage + (enchantments.power / 2) + 0.5
		end
		if enchantments.punch then
			knockback = knockback + enchantments.punch
		end
		if enchantments.flame then
			mcl_burning.set_on_fire(obj, math.huge)
		end
	end
	dir = mcl_bows.add_inaccuracy(dir, player_shooter and 1 or inaccuracy)
	obj:set_velocity({x=dir.x*speed, y=dir.y*speed, z=dir.z*speed})
	obj:set_acceleration({x=0, y=-GRAVITY, z=0})
	obj:set_yaw(yaw-math.pi/2)
	local le = obj:get_luaentity()
	le._shooter = shooter
	le._source_object = shooter
	le._damage = damage
	le._is_critical = is_critical
	le._startpos = pos
	le._knockback = knockback
	le._collectable = collectable
	le._itemstring = arrow_item
	local soundparam = {object=shooter, pos=not shooter and pos or nil, max_hear_distance=32}
	core.sound_play("mcl_bows_bow_shoot", soundparam, true)
	if shooter and shooter:is_player() then
		if le.player == "" then
			le.player = shooter
		end
		le.node = shooter:get_inventory():get_stack("main", 1):get_name()
	end
	return obj
end

-- Returns the arrow stack, its index and its inventory list. Like Minecraft,
-- arrows in the other hand are used first, then in the main hand, then the
-- first ones in the inventory.
local function get_arrow(player)
	local inv = player:get_inventory()
	local function is_arrow(stack)
		return not stack:is_empty() and core.get_item_group(stack:get_name(), "ammo_bow") ~= 0
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

function mcl_bows.get_arrow_stack_for_bow (player)
	return get_arrow (player)
end

local function player_shoot_arrow (player, power, is_critical, bow_stack)
	local arrow_stack, arrow_stack_id, arrow_list = get_arrow(player)
	local arrow_itemstring
	local has_infinity_enchantment = mcl_enchanting.has_enchantment(bow_stack, "infinity")

	if core.is_creative_enabled(player:get_player_name()) then
		if arrow_stack then
			arrow_itemstring = arrow_stack:to_string()
		else
			arrow_itemstring = "mcl_bows:arrow"
		end
	else
		if not arrow_stack then
			return false
		end
		arrow_itemstring = arrow_stack:to_string()
		if not (has_infinity_enchantment and core.get_item_group(arrow_stack:get_name(), "ammo_bow_regular") > 0) then
			arrow_stack:take_item()
		end
		local inv = player:get_inventory()
		inv:set_stack(arrow_list, arrow_stack_id, arrow_stack)
	end
	if not arrow_itemstring then
		return false
	end
	local playerpos = mcl_util.target_eye_pos (player)
	playerpos.y = playerpos.y - 0.1
	local dir = player:get_look_dir()
	local yaw = player:get_look_horizontal()

	arrow_itemstring = ItemStack(arrow_itemstring)
	arrow_itemstring:set_count(1)
	arrow_itemstring = arrow_itemstring:to_string()

	mcl_bows.shoot_arrow (arrow_itemstring, playerpos, dir, yaw, player,
			      power, nil, is_critical, bow_stack,
			      not has_infinity_enchantment)
	return true
end

-- Bow item, uncharged state
core.register_tool("mcl_bows:bow", {
	description = S("Bow"),
	_tt_help = S("Launches arrows"),
	_doc_items_longdesc = S("Bows are ranged weapons to shoot arrows at your foes.").."\n"..
S("The speed and damage of the arrow increases the longer you charge. The regular damage of the arrow is between 1 and 9. At full charge, there's also a 20% of a critical hit, dealing 10 damage instead."),
	_doc_items_usagehelp = S("To use the bow, you first need to have at least one arrow anywhere in your inventory (unless in Creative Mode). Hold down the right mouse button (or the zoom key) to charge, release to shoot."),
	_doc_items_durability = BOW_DURABILITY,
	inventory_image = "mcl_bows_bow.png",
	wield_scale = mcl_vars.tool_wield_scale,
	stack_max = 1,
	-- Trick to disable digging as well
	on_use = function() end,
	on_place = function(itemstack, player, pointed_thing)
		local rc = mcl_util.call_on_rightclick(itemstack, player, pointed_thing)
		if rc then return rc end

		itemstack:get_meta():set_string("active", "true")
		return itemstack
	end,
	on_secondary_use = function(itemstack, player, pointed_thing)
		local rc = mcl_util.call_on_rightclick(itemstack, player, pointed_thing)
		if rc then return rc end

		itemstack:get_meta():set_string("active", "true")
		return itemstack
	end,
	touch_interaction = "short_dig_long_place",
	groups = {weapon = 2, weapon_ranged = 1, bow = 1, enchantability = 1, offhand_item = 1},
	_mcl_uses = 385,
	_mcl_burntime = 15
})

-- Iterates through player inventory and resets all the bows in "charging" state back to their original stage
local function reset_bows(player)
	local inv = player:get_inventory()
	for _, listname in ipairs({"main", "offhand"}) do
	local list = inv:get_list(listname) or {}
	for place, stack in pairs(list) do
		if stack:get_name() == "mcl_bows:bow" or stack:get_name() == "mcl_bows:bow_enchanted" then
			stack:get_meta():set_string("active", "")
		elseif stack:get_name()=="mcl_bows:bow_0" or stack:get_name()=="mcl_bows:bow_1" or stack:get_name()=="mcl_bows:bow_2" then
			stack:set_name("mcl_bows:bow")
			stack:get_meta():set_string("active", "")
			list[place] = stack
		elseif stack:get_name()=="mcl_bows:bow_0_enchanted" or stack:get_name()=="mcl_bows:bow_1_enchanted" or stack:get_name()=="mcl_bows:bow_2_enchanted" then
			stack:set_name("mcl_bows:bow_enchanted")
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
	playerphysics.set_fov_bow_start(player, nil)
	-- LivingEntity.stopUsingItem (ItemStack.causeUseVibration)
	if bow_load[player:get_player_name()] ~= nil and mcl_gameevent then
		mcl_gameevent.emit_entity(player, "item_interact_finish")
	end
	bow_load[player:get_player_name()] = nil
	bow_index[player:get_player_name()] = nil
	bow_hand[player:get_player_name()] = nil
	mcl_util.stop_item_use(player, "bow")
	playerphysics.remove_physics_factor(player, "speed", "mcl_bows:use_bow")
	if also_reset_bows then
		reset_bows(player)
	end
end

-- Bow in charging state
for level=0, 2 do
	core.register_tool("mcl_bows:bow_"..level, {
		description = S("Bow"),
		_doc_items_create_entry = false,
		inventory_image = "mcl_bows_bow_"..level..".png",
		wield_scale = mcl_vars.tool_wield_scale,
		stack_max = 1,
		range = 0, -- Pointing range to 0 to prevent punching with bow :D
		groups = {not_in_creative_inventory=1, not_in_craft_guide=1, bow=1, enchantability=1},
		-- The drawing stages replace each other without lowering the bow
		hand_animation_on_swap = false,
		-- Trick to disable digging as well
		on_use = function() end,
		on_drop = function(itemstack, dropper, pos)
			reset_bow_state(dropper)
			itemstack:get_meta():set_string("active", "")
			if mcl_enchanting.is_enchanted(itemstack:get_name()) then
				itemstack:set_name("mcl_bows:bow_enchanted")
			else
				itemstack:set_name("mcl_bows:bow")
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

function mcl_bows.player_shoot (player, wielditem, usetime_us, hand)
	local enchanted = mcl_enchanting.is_enchanted(wielditem:get_name())
	local charge = math.max(math.min(usetime_us, BOW_CHARGE_TIME_FULL), 0)
	local charge_ratio = charge / BOW_CHARGE_TIME_FULL
	charge_ratio = math.max(math.min(charge_ratio, 1), 0)

	-- Calculate damage and power.
	local is_critical = false
	if charge >= BOW_CHARGE_TIME_FULL then
		is_critical = true
	end

	local has_shot = player_shoot_arrow (player, charge_ratio, is_critical, wielditem)

	if enchanted then
		wielditem:set_name("mcl_bows:bow_enchanted")
	else
		wielditem:set_name("mcl_bows:bow")
	end

	if has_shot and not core.is_creative_enabled(player:get_player_name()) then
		local durability = BOW_DURABILITY
		local unbreaking = mcl_enchanting.get_enchantment(wielditem, "unbreaking")
		if unbreaking > 0 then
			durability = durability * (unbreaking + 1)
		end
		wielditem:add_wear(65535/durability)
	end
	mcl_util.set_hand_item (player, hand or "main", wielditem, true)
end

controls.register_on_release(function(player, key)
	if mcl_serverplayer.is_csm_capable (player) then
		return
	end
	if key~="RMB" and key~="zoom" then return end
	local name = player:get_player_name()
	local hand = bow_hand[name] or "main"
	local wielditem = mcl_util.get_hand_item(player, hand)
	if is_drawn_bow(wielditem:get_name()) then
		local p_load = bow_load[name]
		local charge
		-- Type sanity check
		if type(p_load) == "number" then
			charge = core.get_us_time() - p_load
		else
			-- In case something goes wrong ...
			-- Just assume minimum charge.
			charge = 0
			core.log("warning", "[mcl_bows] Player "..name.." fires arrow with non-numeric bow_load!")
		end
		mcl_bows.player_shoot (player, wielditem, charge, hand)
		reset_bow_state(player, true)
	end
end)

-- Whether the bow in a hand is still the one being drawn
local function still_drawing(player, name)
	local hand = bow_hand[name]
	if not hand then
		return false
	end
	if hand == "main" and player:get_wield_index() ~= bow_index[name] then
		return false
	end
	return is_drawn_bow(mcl_util.get_hand_item(player, hand):get_name())
end

controls.register_on_hold(function(player, key)
	if mcl_serverplayer.is_csm_capable (player) then
		return
	end
	local name = player:get_player_name()
	local creative = core.is_creative_enabled(name)
	if (key ~= "RMB" and key ~= "zoom") or not (creative or get_arrow(player)) then
		return
	end
	if bow_load[name] == nil then
		local hand, wielditem = mcl_util.get_use_hand(player, function(stack)
			return is_bow(stack:get_name())
				and (stack:get_meta():get("active") or key == "zoom")
		end)
		if not hand then
			return
		end
		local enchanted = mcl_enchanting.is_enchanted(wielditem:get_name())
		if enchanted then
			wielditem:set_name("mcl_bows:bow_0_enchanted")
		else
			wielditem:set_name("mcl_bows:bow_0")
		end
		mcl_util.set_hand_item(player, hand, wielditem, true)
		-- Slow player down when using bow
		playerphysics.add_physics_factor(player, "speed", "mcl_bows:use_bow", PLAYER_USE_BOW_SPEED)
		bow_load[name] = core.get_us_time()
		bow_index[name] = player:get_wield_index()
		bow_hand[name] = hand
		-- LivingEntity.startUsingItem (ItemStack.causeUseVibration)
		if mcl_gameevent then
			mcl_gameevent.emit_entity(player, "item_interact_start")
		end
		playerphysics.set_fov_bow_start(player, bow_load[name])
		mcl_util.start_item_use(player, {
			animation = "bow",
			charge_time = BOW_CHARGE_TIME_FULL / 1.0e6,
			hand = hand,
		})
	elseif still_drawing(player, name) then
		local hand = bow_hand[name]
		local wielditem = mcl_util.get_hand_item(player, hand)
		local item_name = wielditem:get_name()
		local suffix = mcl_enchanting.is_enchanted(item_name) and "_enchanted" or ""
		local held = core.get_us_time() - bow_load[name]
		if item_name == "mcl_bows:bow_0" .. suffix and held >= BOW_CHARGE_TIME_HALF then
			wielditem:set_name("mcl_bows:bow_1" .. suffix)
		elseif item_name == "mcl_bows:bow_1" .. suffix and held >= BOW_CHARGE_TIME_FULL then
			wielditem:set_name("mcl_bows:bow_2" .. suffix)
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
	output = "mcl_bows:bow",
	recipe = {
		{"", "mcl_core:stick", "mcl_mobitems:string"},
		{"mcl_core:stick", "", "mcl_mobitems:string"},
		{"", "mcl_core:stick", "mcl_mobitems:string"},
	}
})

core.register_craft({
	output = "mcl_bows:bow",
	recipe = {
		{"mcl_mobitems:string", "mcl_core:stick", ""},
		{"mcl_mobitems:string", "", "mcl_core:stick"},
		{"mcl_mobitems:string", "mcl_core:stick", ""},
	}
})

doc.add_entry_alias("tools", "mcl_bows:bow", "tools", "mcl_bows:bow_0")
doc.add_entry_alias("tools", "mcl_bows:bow", "tools", "mcl_bows:bow_1")
doc.add_entry_alias("tools", "mcl_bows:bow", "tools", "mcl_bows:bow_2")
