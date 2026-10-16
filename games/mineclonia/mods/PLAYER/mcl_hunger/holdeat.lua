local eat_duration = {}
-- The hand ("main" or "offhand") that holds the food being eaten
local eat_hand = {}
local eat_anim_hud = {}
local eat_anim_block = {}
local last_eat_sound = {} -- effect timer for precise interval

-- Minecraft multiplies the movement input by 0.2 while an item is in use.
local SPEED_WHILE_EAT = 0.2
local EAT_DELAY = 1.61

local function play_eat_anim_sound(user, itemname, hunger_points, item_def, pitch)
	if not (user and itemname and hunger_points and item_def) then
		return false
	end

	local foodtype = core.get_item_group(itemname, "food")
	if foodtype == 3 then
		-- Item is a drink, play drinking sound
		core.sound_play("survival_thirst_drink", {
			max_hear_distance = 6,
			gain = 0.75,
			pitch = mcl_util.float_random(0.95, 1.05),
			object = user,
		}, true)
		return
	end

	core.sound_play("mcl_hunger_bite", {
		max_hear_distance = 6,
		gain = 0.05,
		pitch = mcl_util.float_random(0.95, 1.05),
		object = user,
	}, true)
end

local function is_food(stack)
	return core.get_item_group(stack:get_name(), "food") ~= 0
end

-- Returns the hand with the food that the player is trying to eat, or false
local function is_player_trying_to_eat(player, keypress)
	if mcl_serverplayer.is_csm_at_least (player, 1) then
		return false
	end

	local itemstack = player:get_wielded_item ()
	local offhand = mcl_util.get_hand_item (player, "offhand")
	if not is_food(itemstack) and not is_food(offhand) then
		return false
	end

	local pointed_thing = mcl_util.get_pointed_thing (player, true)
	local pname = player:get_player_name ()
	local pinfo = core.get_player_window_information (pname)

	if pinfo and pinfo.touch_controls and keypress == "LMB" then
		-- Trigger rightclick/formspec on touch controls
		if pointed_thing and pointed_thing.type == "node" then
			local node = core.get_node (pointed_thing.under)
			local meta = core.get_meta (pointed_thing.under)
			local fs = meta:get_string ("formspec")
			if fs ~= "" then
				local pname = player:get_player_name ()
				core.show_formspec(pname, node.name, fs)
			end
		end
		mcl_util.call_on_rightclick (itemstack, player, pointed_thing)
		return false
	end

	if keypress ~= "RMB" then
		return false
	end

	if eat_anim_block[player] then
		return false
	end

	local rc = mcl_util.call_on_rightclick (itemstack, player, pointed_thing)
	if rc then
		player:set_wielded_item(rc)
		return false
	end

	-- Like Minecraft, food in the main hand is eaten first, then food in the
	-- other hand if the main hand does nothing
	return mcl_util.get_use_hand (player, function (stack)
		return is_food (stack) and (not mcl_hunger.is_player_full (player)
			or mcl_hunger.can_eat_when_full (player, stack))
	end, pointed_thing) or false
end

local function get_eat_delay(itemname)
	local def = core.registered_items[itemname]
	return def and def._mcl_eat_delay or EAT_DELAY
end

local function begin_eating_state(player, hand)
	eat_duration[player] = 0
	eat_hand[player] = hand
	playerphysics.add_physics_factor(player, "speed", "mcl_hunger:eat_anim", SPEED_WHILE_EAT)
	local itemname = mcl_util.get_hand_item(player, hand):get_name()
	-- LivingEntity.startUsingItem (ItemStack.causeUseVibration)
	if mcl_gameevent then
		mcl_gameevent.emit_entity(player, "item_interact_start")
	end
	mcl_util.start_item_use(player, {
		animation = core.get_item_group(itemname, "food") == 3 and "drink" or "eat",
		duration = get_eat_delay(itemname),
		hand = hand,
	}, true)
end

local function terminate_eating_state(player)
	if eat_duration[player] then
		mcl_util.stop_item_use(player)
		-- LivingEntity.stopUsingItem (ItemStack.causeUseVibration)
		if mcl_gameevent and player:get_pos() then
			mcl_gameevent.emit_entity(player, "item_interact_finish")
		end
	end
	eat_duration[player] = nil
	eat_hand[player] = nil
	last_eat_sound[player] = nil
	playerphysics.remove_physics_factor(player, "speed", "mcl_hunger:eat_anim")
end

function mcl_hunger.prevent_eating (player)
	eat_anim_block[player] = true
	terminate_eating_state(player)
end

local function check_eat(player, hand)
	local itemstack = mcl_util.get_hand_item (player, hand)
	local itemname = itemstack:get_name ()
	local is_full = mcl_hunger.is_player_full (player)

	if is_full and not mcl_hunger.can_eat_when_full(player, itemstack) then
		return
	end

	-- Prioritize eat over shield block
	mcl_shields.players[player].blocking = 0

	if not eat_duration[player] then
		begin_eating_state(player, hand)
	end

	local def = core.registered_items[itemname]
	local hunger_points = core.get_item_group(itemname, "eatable")

	-- Eat animation sound
	local step = math.floor(eat_duration[player] / 0.2)
	local last_step = last_eat_sound[player] or 0
	if step > last_step then
		last_eat_sound[player] = step
		play_eat_anim_sound(player, itemname, hunger_points, def)
	end
end

local function check_eat_term(player)
	local hand = eat_hand[player]
	if not hand then
		return
	end
	local itemstack = mcl_util.get_hand_item (player, hand)
	local itemname = itemstack:get_name ()
	local pointed_thing = mcl_util.get_pointed_thing (player, true)

	local def = core.registered_items[itemname]
	local hunger_points = core.get_item_group(itemname, "eatable")

	local eat_delay = get_eat_delay(itemname)
	if eat_duration[player] and eat_duration[player] >= eat_delay then
		itemstack = core.do_item_eat(hunger_points, def._mcl_eat_replace_with, itemstack, player, pointed_thing)
		if core.get_item_group(itemname, "food") == 3 then
			mcl_hunger.play_drinking_sound(player)
		else
			mcl_hunger.play_eating_sound(player)
		end

		if itemstack then
			mcl_util.set_hand_item(player, hand, itemstack)
		end
		terminate_eating_state(player)
	end
end

local function get_sprite_pos(time)
	local offset = math.sin(2 * math.pi / 0.8 * time)
	local x = 0.5
	local y = 1 - 1/16 + offset / 64
	return {x = x, y = y}
end

local function get_sprite_scale(player)
	local info = core.get_player_window_information(player:get_player_name())
	local ar = info and info.size.x / info.size.y or 16 / 9
	return {
		x = -25,
		y = -25 * ar,
	}
end

controls.register_on_hold (function (player, key)
	local hand = is_player_trying_to_eat (player, key)
	if not hand or (eat_hand[player] and eat_hand[player] ~= hand) then
		-- special case. can happen when the player switches the wielded item while eating
		if key == "RMB" and eat_duration[player] then
			terminate_eating_state(player)
		end
		if not hand then
			return
		end
	end

	check_eat_term(player)
	check_eat(player, hand)
end)

core.register_globalstep (function (dtime)
	for player, hudid in pairs (eat_anim_hud) do
		if not eat_duration[player] then
			player:hud_set_flags({wielditem = true})
			player:hud_remove(hudid)
			eat_anim_hud[player] = nil
		end
	end
	for player, time in pairs (eat_duration) do
		eat_duration[player] = time + dtime
		-- Engines with first-person item use animations show eating themselves
		if player.start_item_use then
			goto continue
		end
		local wielditem = mcl_util.get_hand_item(player, eat_hand[player])
		local itemstackdef = wielditem:get_definition()
		local wield_image = itemstackdef.wield_image
		if not wield_image or wield_image == "" then
			wield_image = itemstackdef.inventory_image
		end
		local pos = get_sprite_pos(time)

		if not eat_anim_hud[player] then
			eat_anim_hud[player] = player:hud_add({
				type = "image",
				scale = get_sprite_scale(player),
				alignment = {x = 0, y = 0},
				offset = {x = 0, y = -30},
				text = wield_image,
				position = pos,
				z_index = -200,
			})
			player:hud_set_flags({wielditem = false})
		else
			player:hud_change(eat_anim_hud[player], "text", wield_image)
			player:hud_change(eat_anim_hud[player], "position", get_sprite_pos(time))
		end
		::continue::
	end
end)

controls.register_on_release (function (player, key)
	if mcl_serverplayer.is_csm_at_least (player, 1) then
		return
	end
	if key ~= "RMB" then
		return
	end

	mcl_hunger.prevent_eating (player)
	core.after(0, function ()
		eat_anim_block[player] = nil
	end)
end)

core.register_on_leaveplayer (function (player, _)
	terminate_eating_state(player)
end)

core.register_on_dieplayer(function (player)
	mcl_hunger.prevent_eating(player)
end)
