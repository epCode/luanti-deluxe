mcl_damage = {
	modifiers = {},
	damage_callbacks = {},
	death_callbacks = {},
	types = {
		in_fire = {is_fire = true},
		lightning_bolt = {is_lightning = true},
		on_fire = {is_fire = true, bypasses_armor = true},
		lava = {is_fire = true},
		hot_floor = {is_fire = true},
		in_wall = {bypasses_armor = true},
		drown = {bypasses_armor = true},
		freeze = {bypasses_armor = true},
		starve = {bypasses_armor = true, bypasses_magic = true},
		cactus = {},
		sweet_berry = {},
		fall = {bypasses_armor = true},
		fly_into_wall = {},
		out_of_world = {bypasses_armor = true, bypasses_magic = true, bypasses_invulnerability = true, bypasses_totem = true},
		generic = {bypasses_armor = true},
		magic = {is_magic = true, bypasses_armor = true, bypasses_guardian = true,},
		dragon_breath = {is_magic = true, bypasses_armor = true},	-- this is only used for dragon fireball; dragon fireball does not actually deal impact damage tho, so this is unreachable
		wither = {bypasses_armor = true},
		wither_skull = {is_magic = true, is_explosion = true},
		anvil = {},
		falling_node = {},	-- this is falling_block in MC
		spit = {is_projectile = true},
		mob = {},
		player = {},
		arrow = {is_projectile = true},
		fireball = {is_projectile = true, is_fire = true},
		thorns = {is_magic = true, bypasses_guardian = true,},
		explosion = {is_explosion = true, scales = true, always_affects_dragons = true},
		cramming = {bypasses_armor = true},
		fireworks = {is_explosion = true}, -- unused
		environment = {},
		light = {},
		trident = {},
	}
}

local damage_enabled = core.settings:get_bool("enabled_damage",true)

function mcl_damage.register_modifier(func, priority)
	table.insert(mcl_damage.modifiers, {func = func, priority = priority or 0})
end

function mcl_damage.register_on_damage(func)
	table.insert(mcl_damage.damage_callbacks, func)
end

function mcl_damage.register_on_death(func)
	table.insert(mcl_damage.death_callbacks, func)
end

-- Run damage modifiers whose priorities are >= MIN_PRIORITY and <
-- MAX_PRIORITY (either of which may be nil).
function mcl_damage.run_modifiers(obj, damage, reason, min_priority, max_priority)
	for _, modf in ipairs(mcl_damage.modifiers) do
		if (not min_priority or modf.priority >= min_priority)
			and (not max_priority or modf.priority < max_priority) then
			damage = modf.func(obj, damage, reason) or damage
			if damage == 0 then
				return 0
			end
		end
	end

	return damage
end

------------------------------------------------------------------------
-- Damage cooldown (LivingEntity.hurtServer).
--
-- Upon receiving damage, a living entity's damageCooldownTime is set
-- to 20 ticks.  While it exceeds 10 ticks, further damage is only
-- applied insofar as it exceeds the damage last received, and such
-- partial damage neither resets the cooldown nor produces knockback,
-- hurt animations, or hurt sounds.
--
-- Modifiers with priorities below COOLDOWN_PRIORITY are applied to
-- damage before it is compared against the cooldown (attack damage,
-- difficulty scaling, critical hits, and the like), and the rest
-- (armor, resistance, enchantments, absorption) to the damage
-- actually applied, as in LivingEntity.actuallyHurt.
------------------------------------------------------------------------

mcl_damage.COOLDOWN_PRIORITY = -10
mcl_damage.time = 0

-- 10 ticks, with allowance for rounding errors in dtime.
local HURT_COOLDOWN_PARTIAL = 0.5 - 0.025

core.register_globalstep (function (dtime)
	mcl_damage.time = mcl_damage.time + dtime
end)

-- STATE is a table (a mob's luaentity or a player's record) in which
-- the time and amount of the last damage are recorded.  Return the
-- damage to apply and whether it is "full" damage, or nil if the
-- damage should be disregarded altogether.

function mcl_damage.apply_hurt_cooldown (state, damage)
	if damage <= 0 then
		return damage, true
	end
	local now = mcl_damage.time
	local stamp = state._hurt_stamp
	if stamp and now - stamp < HURT_COOLDOWN_PARTIAL then
		local last = state._last_hurt or 0
		if damage <= last then
			return nil, false
		end
		state._last_hurt = damage
		return damage - last, false
	end
	state._last_hurt = damage
	state._hurt_stamp = now
	return damage, true
end

-- Return whether STATE is within the first ten ticks of its damage
-- cooldown and has not received full damage during this server step.
function mcl_damage.in_hurt_cooldown (state)
	local stamp = state._hurt_stamp
	local now = mcl_damage.time
	return stamp ~= nil and stamp ~= now
		and now - stamp < HURT_COOLDOWN_PARTIAL
end

local player_hurt_states = {}

function mcl_damage.get_player_hurt_state (player)
	local state = player_hurt_states[player]
	if not state then
		state = {}
		player_hurt_states[player] = state
	end
	return state
end

core.register_on_leaveplayer (function (player)
	player_hurt_states[player] = nil
end)

core.register_on_respawnplayer (function (player)
	player_hurt_states[player] = nil
end)

-- Apply pre-cooldown modifiers and the damage cooldown to AMOUNT of
-- damage sustained by PLAYER, followed by the remaining modifiers.
local function player_damage_with_cooldown (player, amount, reason)
	local cp = mcl_damage.COOLDOWN_PRIORITY
	amount = mcl_damage.run_modifiers (player, amount, reason, nil, cp)
	if amount <= 0 then
		return 0
	end
	local state = mcl_damage.get_player_hurt_state (player)
	local full
	amount, full = mcl_damage.apply_hurt_cooldown (state, amount)
	if not amount then
		return 0
	end
	reason.partial_hurt = not full
	return mcl_damage.run_modifiers (player, amount, reason, cp, nil)
end

-- Player.getAttackStrengthScale.  TFLP is the time since the
-- attacker's last punch, and FPI the full punch interval of its weapon
-- (i.e., 1 / ATTACK_SPEED).
function mcl_damage.attack_strength_scale (tflp, fpi)
	fpi = fpi or 1.4
	if fpi <= 0 then
		return 1.0
	end
	return math.max (0.0, math.min (1.0, (tflp or fpi) / fpi))
end

-- Player.baseDamageScaleFactor.
function mcl_damage.base_damage_scale (s)
	return 0.2 + s * s * 0.8
end

-- Return whether a punch by the player HITTER with TOOL_CAPABILITIES
-- is a melee attack with its wielded item (as opposed to a punch
-- delivered on its behalf by a projectile or the like).
function mcl_damage.get_attack_item (player)
	local stack = player:get_wielded_item ()
	if stack:is_empty () then
		-- Minetest punches with the item in the `hand' list,
		-- if any, when nothing is wielded.
		local inv = player:get_inventory ()
		local hand = inv and inv:get_size ("hand") > 0
			and inv:get_stack ("hand", 1)
		if hand and not hand:is_empty () then
			return hand
		end
	end
	return stack
end

function mcl_damage.is_melee_punch (hitter, tool_capabilities)
	if not hitter or not hitter:is_player () or not tool_capabilities then
		return false
	end
	local caps = mcl_damage.get_attack_item (hitter):get_tool_capabilities ()
	if caps.full_punch_interval ~= tool_capabilities.full_punch_interval then
		return false
	end
	local a, b = caps.damage_groups or {}, tool_capabilities.damage_groups or {}
	for group, value in pairs (a) do
		if b[group] ~= value then
			return false
		end
	end
	for group, value in pairs (b) do
		if a[group] ~= value then
			return false
		end
	end
	return true
end

local function run_callbacks(funcs, ...)
	for _, func in pairs(funcs) do
		func(...)
	end
end

function mcl_damage.run_damage_callbacks(obj, damage, reason)
	run_callbacks(mcl_damage.damage_callbacks, obj, damage, reason)
end

function mcl_damage.run_death_callbacks(obj, reason)
	run_callbacks(mcl_damage.death_callbacks, obj, reason)
end

function mcl_damage.from_punch(mcl_reason, object)
	if object then
		mcl_reason.direct = object
		local luaentity = object:get_luaentity()
		if luaentity then
			if luaentity._is_arrow then
				mcl_reason.type = "arrow"
			elseif luaentity._is_fireball then
				mcl_reason.type = "fireball"
			elseif luaentity.is_mob then
				mcl_reason.type = "mob"
			end
			mcl_reason.source = mcl_reason.source or luaentity._source_object
		else
			mcl_reason.type = "player"
		end
	else
		mcl_reason.type = "generic"
	end
end

function mcl_damage.finish_reason(mcl_reason)
	mcl_reason.source = mcl_reason.source or mcl_reason.direct
	mcl_reason.flags = mcl_damage.types[mcl_reason.type] or {}

	if mcl_reason.source then
		if not mcl_reason.source:is_player () then
			local entity = mcl_reason.source:get_luaentity ()
			if entity and entity.is_mob then
				mcl_reason.mob_name = entity.name
			end
		end
	end
end

function mcl_damage.from_mt(mt_reason)
	if mt_reason._mcl_cached_reason then
		return mt_reason._mcl_cached_reason
	end

	local mcl_reason

	if mt_reason._mcl_reason then
		mcl_reason = mt_reason._mcl_reason
	else
		mcl_reason = {type = "generic"}

		if mt_reason._mcl_type then
			mcl_reason.type = mt_reason._mcl_type
		elseif mt_reason.type == "fall" then
			mcl_reason.type = "fall"
		elseif mt_reason.type == "drown" then
			mcl_reason.type = "drown"
		elseif mt_reason.type == "punch" then
			mcl_damage.from_punch(mcl_reason, mt_reason.object)
		elseif mt_reason.type == "node_damage" and mt_reason.node then
			if core.get_item_group(mt_reason.node, "fire") > 0 then
				mcl_reason.type = "in_fire"
			end
			if core.get_item_group(mt_reason.node, "lava") > 0 then
				mcl_reason.type = "lava"
			end
		end

		for key, value in pairs(mt_reason) do
			if key:find("_mcl_") == 1 then
				mcl_reason[key:sub(6, #key)] = value
			end
		end
	end

	mcl_damage.finish_reason(mcl_reason)
	mt_reason._mcl_cached_reason = mcl_reason

	return mcl_reason
end

function mcl_damage.register_type(name, def)
	mcl_damage.types[name] = def
end

--- Player damage.

local function emulate_damage_tick (player)
	core.sound_play ("player_damage",
			{ to_player = player:get_player_name (), gain = 0.5, },
			true)
end

--- An independent floating point health statistic is associated with
--- players which is synchronized with the engine HP whenever damage
--- is sustained or healing takes place.  If the engine HP changes
--- independently of this statistic, the change is adjusted by the
--- statistic.

function mcl_damage.damage_player (player, amount, mcl_reason)
	if not mcl_reason.flags then
	  mcl_damage.finish_reason (mcl_reason)
	end
	if amount < 0 then
	  mcl_damage.heal_player (player, -amount)
	end

	local meta = player:get_meta ()
	local mcl_health = meta:get_float ("mcl_health")
	local engine_hp = player:get_hp ()

	-- It's probably wise to be cautious and verify that the engine and
	-- internal HPs match.

	if math.ceil (mcl_health) ~= engine_hp then
	  core.log ("warning", ("Engine health of player "
				.. player:get_player_name ()
				.. " disagrees with MCL health "
				.. mcl_health ..""))
	  -- Reset internal health to the engine value.
	  mcl_health = engine_hp
	end
	amount = player_damage_with_cooldown (player, amount, mcl_reason)
	mcl_health = math.max (0, mcl_health - amount)
	meta:set_float ("mcl_health", mcl_health)

	mcl_health = math.ceil (mcl_health)
	if mcl_health < engine_hp then
	  player:set_hp (mcl_health, { type = "set_hp", mcl_damage = true,
					_mcl_reason = mcl_reason, })
	elseif amount > 0 then
	  -- Play a damage sound to the player.  Minetest affords games no
	  -- control over the tilt animation, unfortunately.
	  emulate_damage_tick (player)
	end
end

function mcl_damage.heal_player (player, amount)
	if amount < 0 then
	  return
	end

	local meta = player:get_meta ()
	local mcl_health = meta:get_float ("mcl_health")
	local engine_hp = player:get_hp ()
	if math.ceil (mcl_health) ~= engine_hp then
	  core.log ("warning", ("Engine health of player "
				.. player:get_player_name ()
				.. " disagrees with MCL health "
				.. mcl_health ..""))
	  -- Reset internal health to the engine value.
	  mcl_health = engine_hp
	end
	mcl_health = math.min (player:get_properties ().hp_max,
			  mcl_health + amount)
	meta:set_float ("mcl_health", mcl_health)
	mcl_serverplayer.update_vitals (player)

	mcl_health = math.ceil (mcl_health)
	if mcl_health > engine_hp then
	  player:set_hp (mcl_health, { type = "set_hp", mcl_damage = true, })
	end
end

function mcl_damage.get_hp (player)
	local meta = player:get_meta ()
	local mcl_health = meta:get_float ("mcl_health")
	local engine_hp = player:get_hp ()
	if math.ceil (mcl_health) ~= engine_hp then
	  core.log ("warning", ("Engine health of player "
				.. player:get_player_name ()
				.. " disagrees with MCL health "
				.. mcl_health ..""))
	  -- Reset internal health to the engine value.
	  mcl_health = engine_hp
	end
	return mcl_health
end

core.register_on_player_hpchange(function(player, hp_change, mt_reason)
	if not damage_enabled then return 0 end
	-- Take engine damage modifications from mcl_damage at face value.
	if mt_reason.mcl_damage then
		return hp_change
	end

	-- Detect damage from hazardous nodes and deduct the full
	-- amount of the damage, rather than hp_change, which is
	-- restricted to the player's remaining health and may be
	-- attenuated by armor or other protection.

	if mt_reason.type == "node_damage" and mt_reason.node then
		local nodedef = core.registered_nodes[mt_reason.node]

		if nodedef.damage_per_second then
		  hp_change = -nodedef.damage_per_second
		end
	end

	if hp_change < 0 then
		if player:get_hp() <= 0 then
		  return 0
		end
		hp_change = -player_damage_with_cooldown (player, -hp_change,
							     mcl_damage.from_mt (mt_reason))
	end

	-- Apply this as internal damage.
	local meta = player:get_meta ()
	local mcl_health = meta:get_float ("mcl_health")
	local engine_hp = player:get_hp ()

	-- It's probably wise to be cautious and verify that the
	-- engine and internal HPs match.

	if math.ceil (mcl_health) ~= engine_hp then
		core.log ("warning", ("Engine health of player "
					 .. player:get_player_name ()
					 .. " disagrees with MCL health "
					 .. mcl_health ..""))
		-- Reset internal health to the engine value.
		mcl_health = engine_hp
	end

	-- Deduct engine damage.
	mcl_health = math.max (0, mcl_health + hp_change)
	meta:set_float ("mcl_health", mcl_health)
	mcl_serverplayer.update_vitals (player)

	-- Return the difference in engine damage.
	local difference = math.ceil (mcl_health) - engine_hp
	if mt_reason.type ~= "fall" and difference == 0 and hp_change < 0 then
		emulate_damage_tick (player)
	end
	return difference
end, true)

core.register_on_punchplayer (function (player, hitter, tflp, tool_capabilities, _, damage)
	  -- Inflict the Minetest-computed damage by means of
	  -- mcl_damage.damage_player.
	  local mcl_reason = { type = "generic", }
	  mcl_damage.from_punch (mcl_reason, hitter)
	  if mcl_damage.is_melee_punch (hitter, tool_capabilities) then
	 -- Recompute player attack damage with Minecraft's attack
	 -- strength scale (Player.attack) rather than Minetest's
	 -- linear one.
	 local s = mcl_damage.attack_strength_scale (tflp, tool_capabilities.full_punch_interval)
	 local armor = player:get_armor_groups () or {}
	 local base = 0
	 for group, value in pairs (tool_capabilities.damage_groups or {}) do
		base = base + value * ((armor[group] or 0) / 100.0)
	 end
	 -- Strength and Weakness modify the ATTACK_DAMAGE attribute.
	 if mcl_potions then
		local str = mcl_potions.get_effect_level (hitter, "strength") or 0
		local weak = mcl_potions.get_effect_level (hitter, "weakness") or 0
		base = math.max (0, base + (3 * str - 4 * weak)
				 * ((armor.fleshy or 0) / 100.0))
	 end
	 damage = base * mcl_damage.base_damage_scale (s)
	 mcl_reason.attack_strength = s
	 mcl_reason.melee = true
	 mcl_reason.attack_damage_applied = true
	  end
	  if damage > 0 then
	 mcl_damage.damage_player (player, damage, mcl_reason)
	 return true
	  end
end)

-- Knockback is only applied to players by hits that were not
-- attenuated by the damage cooldown (LivingEntity.hurtServer).
core.register_on_mods_loaded (function ()
	if not (mcl_player and mcl_player.player_knockback) then
		return
	end
	local player_knockback = mcl_player.player_knockback
	mcl_player.player_knockback = function (player, ...)
		if player:is_player ()
			and mcl_damage.in_hurt_cooldown (mcl_damage.get_player_hurt_state (player)) then
			return
		end
		return player_knockback (player, ...)
	end
end)

core.register_on_joinplayer (function (player, _)
	  -- Convert the player's engine HP into a floating point internal
	  -- value if none already exists.
	  local meta = player:get_meta ()
	  if meta:get_float ("mcl_health") == 0 then
	 meta:set_float ("mcl_health", player:get_hp ())
	mcl_serverplayer.update_vitals (player)
	  end
end)

core.register_on_dieplayer(function(player, mt_reason)
	  -- Clear the internal HP of players who die.
	  local meta = player:get_meta ()
	  meta:set_float ("mcl_health", 0)
	  mcl_damage.run_death_callbacks(player, mcl_damage.from_mt(mt_reason))
end)

-- Register a modifier that adjusts damage by difficulty.

local function is_mob (source)
	if not source then
		return false
	end
	local entity = source:get_luaentity ()
	return entity and entity.is_mob
end

mcl_damage.register_modifier (function (obj, damage, reason)
	if not obj:is_player () then
		return damage
	end
	if (reason.flags.scales == true) or is_mob (reason.source) then
		if mcl_vars.difficulty == 0 then
			return 0
		elseif mcl_vars.difficulty == 1 then
			return math.min (damage / 2.0 + 1.0, damage)
		elseif mcl_vars.difficulty == 3 then
			return damage * 1.5
		end
	end
	return damage
end, -1000)

core.register_on_mods_loaded(function()
	table.sort(mcl_damage.modifiers, function(a, b) return a.priority < b.priority end)
end)
