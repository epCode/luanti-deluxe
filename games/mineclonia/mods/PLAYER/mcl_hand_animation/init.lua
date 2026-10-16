-- Keeps each player's first-person hand animation parameters
-- (ObjectRef:set_hand_animation) in line with Minecraft:
-- * Haste and Conduit Power shorten swings by (1 + amplifier) ticks, Mining
--   Fatigue lengthens them by (1 + amplifier) * 2 ticks
--   (LivingEntity.getModifiedSwingDuration).
-- * Items are not used up in creative mode, so right-clicks that swing the
--   hand also lower the item (Player.hasInfiniteMaterials).

local TICK = 0.05
local UPDATE_INTERVAL = 0.25

local current = {}

local function effect_level(player, name)
	if not mcl_potions or not mcl_potions.get_effect_level then
		return 0
	end
	return mcl_potions.get_effect_level(player, name) or 0
end

local function wanted_params(player)
	-- Effect levels are 1-based, Minecraft's amplifiers 0-based
	local dig_speed = math.max(effect_level(player, "haste"),
		effect_level(player, "conduit_power"))
	local fatigue = effect_level(player, "fatigue")
	local offset = 0
	if dig_speed > 0 then
		offset = -dig_speed * TICK
	elseif fatigue > 0 then
		offset = fatigue * 2 * TICK
	end
	return {
		swing_duration_offset = offset,
		infinite_items = core.is_creative_enabled(player:get_player_name()),
	}
end

local function update(player)
	if not player.set_hand_animation then
		return
	end
	local params = wanted_params(player)
	local old = current[player]
	if old and old.swing_duration_offset == params.swing_duration_offset
			and old.infinite_items == params.infinite_items then
		return
	end
	current[player] = params
	player:set_hand_animation(params)
end

core.register_on_joinplayer(update)

core.register_on_leaveplayer(function(player)
	current[player] = nil
end)

mcl_gamemode.register_on_gamemode_change(function(player)
	update(player)
end)

-- Effects have no reliable end callbacks, so they are checked regularly
local timer = 0
core.register_globalstep(function(dtime)
	timer = timer + dtime
	if timer < UPDATE_INTERVAL then
		return
	end
	timer = 0
	for _, player in ipairs(core.get_connected_players()) do
		update(player)
	end
end)
