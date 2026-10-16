-- Items in both hands and first-person hand animations (Minecraft's swing and
-- item use animations), using the engine's hand animation API when it exists.

local item_use = {}

-- Returns the item in a hand: "main" (the wielded item) or "offhand".
function mcl_util.get_hand_item(player, hand)
	if hand == "offhand" then
		return player:get_inventory():get_stack("offhand", 1)
	end
	return player:get_wielded_item()
end

-- Replaces the item in a hand. With skip_anim the first-person view replaces
-- the item at once instead of lowering it (e.g. for the drawing stages of a bow).
function mcl_util.set_hand_item(player, hand, stack, skip_anim)
	if hand == "offhand" then
		player:get_inventory():set_stack("offhand", 1, stack)
		if skip_anim then
			-- Sends the inventory, with the change above, right away without
			-- the swap animation
			player:set_wielded_item(player:get_wielded_item(), true)
		end
	else
		player:set_wielded_item(stack, skip_anim)
	end
end

local function is_default_callback(def, field)
	local f = def[field]
	return f == nil or f == core.nodedef_default[field]
		or f == core.craftitemdef_default[field]
		or f == core.tooldef_default[field]
		or f == core.noneitemdef_default[field]
end

-- Whether a right-click does nothing with the item in the main hand, so that
-- the item in the other hand is used instead (Minecraft tries the main hand
-- first, then the other hand).
-- Items can set `_mcl_main_hand_passive` to a boolean or a function
-- (player, itemstack, pointed_thing) to decide this themselves.
function mcl_util.main_hand_passive(player, pointed_thing)
	local stack = player:get_wielded_item()
	if stack:is_empty() then
		return true
	end
	local def = stack:get_definition()
	local passive = def._mcl_main_hand_passive
	if type(passive) == "function" then
		return passive(player, stack, pointed_thing)
	elseif passive ~= nil then
		return passive
	end
	if def.type == "node" then
		-- Nodes are placed on nodes
		return not (pointed_thing and pointed_thing.type == "node")
	end
	if core.get_item_group(stack:get_name(), "food") ~= 0 then
		-- Food is eaten, unless the player is too full for it
		local hunger = rawget(_G, "mcl_hunger")
		return hunger ~= nil and hunger.is_player_full(player)
			and not hunger.can_eat_when_full(player, stack)
	end
	return is_default_callback(def, "on_place")
		and is_default_callback(def, "on_secondary_use")
end

-- Returns the hand ("main" or "offhand") and its item that a held right-click
-- uses, for items that `predicate(itemstack)` accepts, or nil.
function mcl_util.get_use_hand(player, predicate, pointed_thing)
	local main = player:get_wielded_item()
	if predicate(main) then
		return "main", main
	end
	local offhand = mcl_util.get_hand_item(player, "offhand")
	if not offhand:is_empty() and predicate(offhand)
			and mcl_util.main_hand_passive(player, pointed_thing) then
		return "offhand", offhand
	end
end

-- Shows the item in a hand being used in first person. `def` is as for
-- ObjectRef:start_item_use. A use that is already shown is not restarted
-- unless `restart` is set.
function mcl_util.start_item_use(player, def, restart)
	if not player.start_item_use then
		return
	end
	local hand = def.hand or "main"
	local current = item_use[player]
	if current and current.animation == def.animation and current.hand == hand
			and not restart then
		return
	end
	item_use[player] = {animation = def.animation, hand = hand}
	player:start_item_use(def)
end

-- Ends the use shown by start_item_use. With `animation`, only a use with
-- that animation is ended.
function mcl_util.stop_item_use(player, animation)
	local current = item_use[player]
	if not current or (animation and current.animation ~= animation) then
		return
	end
	item_use[player] = nil
	if player.stop_item_use then
		player:stop_item_use()
	end
end

-- Returns {animation = ..., hand = ...} of the use being shown, or nil.
function mcl_util.get_item_use(player)
	return item_use[player]
end

-- Swings the hand in first person (and the arm as others see it).
-- `def` is as for ObjectRef:swing_hand.
function mcl_util.swing_hand(player, def)
	if player.swing_hand then
		player:swing_hand(def)
	end
end

core.register_on_leaveplayer(function(player)
	item_use[player] = nil
end)

core.register_on_dieplayer(function(player)
	mcl_util.stop_item_use(player)
end)
