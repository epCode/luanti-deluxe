------------------------------------------------------------------------
-- Field of view.
--
-- Reproduces Minecraft's dynamic FOV (AbstractClientPlayer
-- .getFieldOfViewModifier and GameRenderer.tickFov/getFov):
--
--   * Creative/fly-mode flight multiplies the modifier by 1.1.
--   * The modifier is then multiplied by (s + 1) / 2, where s is the
--     player's movement speed attribute relative to its base value of
--     0.1.  The attribute is affected by sprinting (+30%), Speed
--     (+20%/level), Slowness (-15%/level), Soul Speed on soul blocks
--     and freezing in powder snow.  Movement penalties that are not
--     attribute modifiers in Minecraft (sneaking, using items, soul
--     sand, cobwebs, etc.) do not affect the FOV.
--   * Drawing a bow multiplies it by 1 - 0.15 * min(t / 20, 1)^2,
--     where t is the number of ticks the bow has been drawn.
--   * Looking through a spyglass replaces it with 0.1.
--   * The result (spyglass excepted) is scaled towards 1 by the "FOV
--     Effects" player setting.
--   * Every tick the displayed modifier moves halfway towards the
--     result and is clamped to [0.1, 1.5].
--   * Having one's eyes in water or lava immediately multiplies the
--     FOV by 6/7 (also scaled by "FOV Effects"), and dying narrows the
--     FOV over 20 ticks.
------------------------------------------------------------------------

local S = core.get_translator(core.get_current_modname())

local TICK = 0.05
local BASE_MOVEMENT_SPEED = 0.1
local FLYING_FOV = 1.1
local SPRINT_SPEED_MODIFIER = 0.3
local BOW_FOV_REDUCTION = 0.15
local SCOPING_FOV = 0.1
local MIN_FOV_MODIFIER = 0.1
local MAX_FOV_MODIFIER = 1.5
local FLUID_FOV = 6 / 7
local FREEZE_SPEED_MODIFIER = -0.05
local FREEZE_MAX_TIME = 7 -- `time_in_snow' of mcl_powder_snow at full freeze.
local DEATH_FOV_TICKS = 20

-- Previously these mods each set an FOV factor of their own, which
-- may linger in the metadata of players who left with them active.
local obsolete_fov_factors = {
	"mcl_sprint:sprint",
	"mcl_potions:swiftness",
	"mcl_potions:slowness",
	"mcl_bows:bow_zoom",
}

mcl_player.register_player_setting("playerphysics:fov_effects", {
	type = "slider",
	options = {
		{ min = 0, max = 100, step = 5 },
	},
	section = "Graphics",
	short_desc = S("FOV Effects (%)"),
	long_desc = S("How much the field of view changes with speed effects, sprinting, flying, drawing a bow, and being underwater or in lava."),
	ui_default = "100",
})

local function get_fov_effect_scale(player)
	local value = tonumber(mcl_player.get_player_setting(player, "playerphysics:fov_effects", "100"))
	return value and math.max(0, math.min(1, value / 100)) or 1
end

local function lerp(t, a, b)
	return a + (b - a) * t
end

local states = {}

core.register_on_joinplayer(function(player)
	for _, id in ipairs(obsolete_fov_factors) do
		playerphysics.remove_physics_factor(player, "fov", id)
	end
	-- Absolute FOVs (e.g. the spyglass) never outlive a session.
	playerphysics.set_absolute_fov(player, 0)
	states[player] = {
		fov_modifier = 1,
		death_ticks = 0,
		sent = nil,
		flying = false,
		steady_time = 0,
		falling_time = 0,
	}
	player:set_fov(0, false, 0)
end)

core.register_on_leaveplayer(function(player)
	states[player] = nil
end)

------------------------------------------------------------------------
-- Item use.
------------------------------------------------------------------------

-- Set START_US to the core.get_us_time() at which PLAYER began to draw
-- a bow, or nil once the bow is released.
function playerphysics.set_fov_bow_start(player, start_us)
	local state = states[player]
	if state then
		state.bow_start = start_us
	end
end

-- Set whether PLAYER is looking through a spyglass.
function playerphysics.set_fov_scoping(player, scoping)
	local state = states[player]
	if state then
		state.scoping = scoping or nil
	end
end

------------------------------------------------------------------------
-- Flight detection.
--
-- Recent engines report fly mode.  Older ones do not tell the server
-- whether a client is in fly mode, so it is inferred: a player with the `fly' privilege who is off the ground and
-- whose vertical velocity holds steady (rather than accelerating under
-- gravity) is flying.  As in Minecraft, touching the ground ends
-- flight.
------------------------------------------------------------------------

local SAMPLE_INTERVAL = 0.1
local STEADY_ACCELERATION = 1.5
local FALLING_ACCELERATION = -6.0
local TIME_TO_START_FLYING = 0.15
local TIME_TO_STOP_FLYING = 0.3

local function is_walkable(pos)
	local node = core.get_node_or_nil(pos)
	if not node then
		return true
	end
	local def = core.registered_nodes[node.name]
	return not def or def.walkable
end

local function on_ground(pos, cbox)
	local y = pos.y + cbox[2] - 0.05
	for _, x in ipairs({ cbox[1], cbox[4] }) do
		for _, z in ipairs({ cbox[3], cbox[6] }) do
			if is_walkable(vector.new(pos.x + x, y, pos.z + z)) then
				return true
			end
		end
	end
	return false
end

-- Whether a node at POS might hold a player aloft or slow its descent
-- without it flying.
local function is_supporting(pos)
	local node = core.get_node_or_nil(pos)
	local def = node and core.registered_nodes[node.name]
	return def and (def.climbable
			or (def.liquidtype and def.liquidtype ~= "none")
			or (def.move_resistance or 0) > 0
			or def.liquid_move_physics) or false
end

local function update_flying(player, state, pos, cbox, now)
	if core.features.speed_fly then
		-- The engine reports fly mode.
		local mcl_movement = rawget(_G, "mcl_movement")
		state.flying = mcl_movement and mcl_movement.is_flying(player)
			or false
		return
	end
	local playerinfo = mcl_player.players[player]
	if player:get_hp() <= 0
		or player:get_attach()
		or (playerinfo and playerinfo.elytra and playerinfo.elytra.active)
		or not core.check_player_privs(player, "fly")
		or on_ground(pos, cbox) then
		state.flying = false
		state.steady_time = 0
		state.falling_time = 0
		state.sample_time = nil
		return
	end

	if is_supporting(vector.offset(pos, 0, 0.1, 0))
		or is_supporting(vector.offset(pos, 0, cbox[5] * 0.5, 0)) then
		-- Leave the state alone: flight persists through water and
		-- the like, but nothing can be inferred from motion here.
		state.sample_time = nil
		return
	end

	local vy = player:get_velocity().y
	if not state.sample_time then
		state.sample_time, state.sample_vy = now, vy
		return
	end
	local elapsed = now - state.sample_time
	if elapsed < SAMPLE_INTERVAL then
		return
	end
	local acceleration = (vy - state.sample_vy) / elapsed
	state.sample_time, state.sample_vy = now, vy

	if math.abs(acceleration) < STEADY_ACCELERATION
		and player:get_physics_override().gravity >= 0.5 then
		state.steady_time = state.steady_time + elapsed
		state.falling_time = 0
	elseif acceleration < FALLING_ACCELERATION
		and not player:get_player_control().sneak then
		-- Accelerating downwards without descending deliberately:
		-- this is gravity.
		state.falling_time = state.falling_time + elapsed
		state.steady_time = 0
	else
		state.steady_time = 0
		state.falling_time = 0
	end

	if state.steady_time >= TIME_TO_START_FLYING then
		state.flying = true
	elseif state.falling_time >= TIME_TO_STOP_FLYING then
		state.flying = false
	end
end

------------------------------------------------------------------------
-- Movement speed attribute.
------------------------------------------------------------------------

local function get_soul_speed_level(player)
	if not core.global_exists("mcl_enchanting") then
		return 0
	end
	local boots = player:get_inventory():get_stack("armor", 5)
	return mcl_enchanting.get_enchantment(boots, "soul_speed")
end

-- Return the player's movement speed attribute divided by its base
-- value, applying modifiers in Minecraft's order: additions to the
-- base value, then each total multiplier.  As in Minecraft, Soul Speed
-- and freezing only apply while the block underfoot is not air.
local function get_movement_speed_ratio(player, physics)
	local value = BASE_MOVEMENT_SPEED
	local playerinfo = mcl_player.players[player]
	local stand = playerinfo and playerinfo.nodes.stand

	if stand and stand ~= "air" then
		if core.get_item_group(stand, "soul_block") > 0 then
			local level = get_soul_speed_level(player)
			if level > 0 then
				value = value + 0.03 * (1 + level * 0.35)
			end
		end

		local time_in_snow = tonumber(player:get_meta():get("time_in_snow"))
		if time_in_snow and time_in_snow > 0 then
			local frozen = math.min(time_in_snow, FREEZE_MAX_TIME) / FREEZE_MAX_TIME
			value = value + FREEZE_SPEED_MODIFIER * frozen
		end
	end

	if core.global_exists("mcl_sprint")
		and mcl_sprint.is_sprinting(player:get_player_name()) then
		value = value * (1 + SPRINT_SPEED_MODIFIER)
	end

	local speed = physics and physics.speed
	if speed then
		-- mcl_potions stores these as (1 + factor) and (1 - factor),
		-- i.e. exactly Minecraft's total multipliers.
		value = value * (speed["mcl_potions:swiftness"] or 1)
		value = value * (speed["mcl_potions:slowness"] or 1)
	end

	return math.max(0, math.min(1024, value)) / BASE_MOVEMENT_SPEED
end

------------------------------------------------------------------------
-- FOV controller.
------------------------------------------------------------------------

local function get_target_fov_modifier(player, state, physics, scale)
	if state.scoping then
		return SCOPING_FOV
	end

	local f = 1
	if state.flying then
		f = f * FLYING_FOV
	end
	if not (state.flying and core.features.speed_fly) then
		-- (Flight has one speed; see mcl_movement.)
		f = f * (get_movement_speed_ratio(player, physics) + 1) / 2
	end
	if f ~= f or f == math.huge or f == -math.huge then
		f = 1
	end

	if state.bow_start then
		local ticks = math.floor((core.get_us_time() - state.bow_start) / (TICK * 1e6))
		local t = math.min(ticks / 20, 1)
		f = f * (1 - t * t * BOW_FOV_REDUCTION)
	end

	f = lerp(scale, 1, f)

	-- FOV factors added by other mods.
	if physics and type(physics.fov) == "table" then
		for _, factor in pairs(physics.fov) do
			f = f * factor
		end
	end
	return f
end

local function eyes_in_fluid(player, pos, props)
	local node = core.get_node_or_nil(vector.offset(pos, 0, props.eye_height or 1.62, 0))
	if not node then
		return false
	end
	return core.get_item_group(node.name, "water") ~= 0
		or core.get_item_group(node.name, "lava") ~= 0
end

local function send_fov(player, state, fov, is_multiplier, transition)
	local sent = state.sent
	if sent and sent.is_multiplier == is_multiplier
		and math.abs(sent.fov - fov) < 1e-4 then
		return
	end
	if is_multiplier and math.abs(fov - 1) < 1e-4 then
		-- Clear the override so the client's own FOV (and zoom) apply.
		player:set_fov(0, false, transition)
	else
		player:set_fov(fov, is_multiplier, transition)
	end
	state.sent = { fov = fov, is_multiplier = is_multiplier, }
end

mcl_player.register_globalstep(function(player, dtime)
	local state = states[player]
	if not state then
		return
	end
	local physics = playerphysics.get_physics_data(player)

	if physics and physics.fov_absolute then
		send_fov(player, state, physics.fov_absolute, false, 0.1)
		return
	end

	local now = core.get_us_time() / 1e6
	local pos = player:get_pos()
	local props = player:get_properties()
	update_flying(player, state, pos, props.collisionbox, now)

	local scale = get_fov_effect_scale(player)
	local target = get_target_fov_modifier(player, state, physics, scale)

	-- Each tick, close half the distance to the target.  Over a step
	-- of DTIME the remaining distance is therefore multiplied by
	-- 0.5^(dtime / TICK), which is exactly Minecraft's behaviour at
	-- 20 steps per second.
	local k = 1 - 0.5 ^ (dtime / TICK)
	local modifier = state.fov_modifier + (target - state.fov_modifier) * k
	if math.abs(target - modifier) < 1e-4 then
		modifier = target
	end
	modifier = math.max(MIN_FOV_MODIFIER, math.min(MAX_FOV_MODIFIER, modifier))
	state.fov_modifier = modifier

	local fov = modifier

	local in_fluid = eyes_in_fluid(player, pos, props)
	if in_fluid then
		fov = fov * lerp(scale, 1, FLUID_FOV)
	end

	if player:get_hp() <= 0 then
		state.death_ticks = math.min(state.death_ticks + dtime / TICK, DEATH_FOV_TICKS)
		fov = fov / ((1 - 500 / (state.death_ticks + 500)) * 2 + 1)
	else
		state.death_ticks = 0
	end

	-- Entering or leaving a fluid changes the FOV at once; otherwise
	-- interpolate across this step, as Minecraft interpolates
	-- between ticks.
	local transition = in_fluid ~= state.in_fluid and 0 or dtime
	state.in_fluid = in_fluid
	send_fov(player, state, fov, true, transition)
end)
