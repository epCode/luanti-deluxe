local S = core.get_translator(core.get_current_modname())

local spyglass_block = {}
local spyglass_scope = {}

local function spyglass_block_or_unblock (itemstack, player, pointed_thing)
	if spyglass_scope[player] ~= nil then
		return itemstack
	end
	local rc = mcl_util.call_on_rightclick(itemstack, player, pointed_thing)
	if rc then
		spyglass_block[player] = 1
		return rc
	end
	spyglass_block[player] = nil
	return itemstack
end

core.register_tool("mcl_spyglass:spyglass", {
	description = S("Spyglass"),
	_doc_items_longdesc = S("A spyglass is an item that can be used for zooming in on specific locations."),
	inventory_image = "mcl_spyglass.png",
	groups = {tool = 1},
	stack_max = 1,
	_mcl_toollike_wield = true,
	touch_interaction = "short_dig_long_place",
	on_place = spyglass_block_or_unblock,
	on_secondary_use = spyglass_block_or_unblock,
})

core.register_craft({
	output = "mcl_spyglass:spyglass",
	recipe = {
		{"mcl_amethyst:amethyst_shard"},
		{"mcl_copper:copper_ingot"},
		{"mcl_copper:copper_ingot"},
	}
})

local function is_spyglass(stack)
	return stack:get_name() == "mcl_spyglass:spyglass"
end

local function add_scope(player, hand)
	-- LivingEntity.startUsingItem (ItemStack.causeUseVibration)
	if mcl_gameevent then
		mcl_gameevent.emit_entity(player, "item_interact_start")
	end
	spyglass_scope[player] = player:hud_add({
		type = "image",
		position = {x = 0.5, y = 0.5},
		scale = {x = -100, y = -100},
		text = "mcl_spyglass_scope.png",
	})
	if player.start_item_use then
		-- Looking through the spyglass hides both hands
		mcl_util.start_item_use(player, {animation = "spyglass", hand = hand})
	else
		player:hud_set_flags({wielditem = false})
	end
end

local function remove_scope(player)
	if spyglass_scope[player] then
		-- LivingEntity.stopUsingItem (ItemStack.causeUseVibration)
		if mcl_gameevent then
			mcl_gameevent.emit_entity(player, "item_interact_finish")
		end
		player:hud_remove(spyglass_scope[player])
		spyglass_scope[player] = nil
		if player.start_item_use then
			mcl_util.stop_item_use(player, "spyglass")
		else
			player:hud_set_flags({wielditem = true})
		end
		playerphysics.set_fov_scoping(player, false)
	end
end

controls.register_on_release(function(player, key)
	if mcl_serverplayer.is_csm_capable (player) then
		return
	end
	if key ~= "RMB" and key ~= "zoom" then return end
	local ctrl = player:get_player_control()
	if key == "RMB" and ctrl.zoom or key == "zoom" and ctrl.place then return end
	remove_scope(player)
end)

controls.register_on_hold(function(player, key)
	if mcl_serverplayer.is_csm_capable (player) then
		return
	end
	if key ~= "RMB" and key ~= "zoom" then return end
	-- A spyglass in the main hand, or in the other hand if the main hand does
	-- nothing (like Minecraft)
	local hand = mcl_util.get_use_hand(player, is_spyglass)
	if hand and spyglass_block[player] == nil then
		playerphysics.set_fov_scoping(player, true)
		if spyglass_scope[player] == nil then
			add_scope(player, hand)
		end
	else
		remove_scope(player)
	end
end)

core.register_on_dieplayer(function(player)
	remove_scope(player)
end)

core.register_on_leaveplayer(function(player)
	spyglass_scope[player] = nil
end)
