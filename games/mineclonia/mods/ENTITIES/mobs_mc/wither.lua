local S = core.get_translator("mobs_mc")
local mobs_griefing = mobs_mc.is_mob_griefing_enabled("wither")
local mob_class = mcl_mobs.mob_class

------------------------------------------------------------------------
-- Wither.
-- This is modeled on Java Edition's WitherBoss.
------------------------------------------------------------------------

local wither_def = {
	description = S("Wither"),
	type = "monster",
	_spawn_category = "misc",
	-- WitherBoss.java: MAX_HEALTH 300, ARMOR 4.
	hp_max = 300,
	hp_min = 300,
	_natural_armor = 4,
	xp_min = 50,
	xp_max = 50,
	head_swivel = "head",
	bone_eye_height = 0.625,
	armor = {undead = 100, fleshy = 100},
	collisionbox = {-0.45, -0.01, -0.45, 0.45, 3.49, 0.45},
	doll_size_override = { x = 1.2, y = 1.2 },
	visual = "mesh",
	mesh = "mobs_mc_wither.b3d",
	textures = {
		{
			"mobs_mc_wither_invulnerable.png",
			"mobs_mc_wither_armor.png",
		},
	},
	visual_size = {x=4, y=4},
	-- MOVEMENT_SPEED 0.6.  While airborne, LivingEntity.travel
	-- accelerates the Wither by getFlyingSpeed () (0.02
	-- blocks/tick) rather than FLYING_SPEED, which yields a
	-- terminal velocity of about 4 blocks/s.
	movement_speed = 12.0,
	airborne_speed = 4.0,
	_airborne_agile = true,
	sounds = {
		shoot_attack = "mobs_fireball",
		distance = 60,
	},
	jump_height = 10,
	_no_fall_damage = true,
	makes_footstep_sound = false,
	can_ride_cart = false,
	can_ride_boat = false,
	can_despawn = false,
	drops = {
		{
			name = "mcl_mobitems:nether_star",
			chance = 1,
			min = 1,
			max = 1,
		},
	},
	_can_freeze = false,
	_fire_resistant = true,
	fire_resistant = true,
	-- RangedAttackGoal (this, 1.0, 40, 20.0F).
	attack_type = "ranged",
	ranged_interval_min = 2.0,
	ranged_interval_max = 2.0,
	ranged_attack_radius = 20,
	arrow = "mobs_mc:wither_skull",
	reach = 5,
	animation = {
		stand_speed = 12,
		stand_start = 20, stand_end = 40,
	},
	harmed_by_heal = true,
	is_boss = true,
	airborne = true,
	-- FOLLOW_RANGE 40.
	tracking_distance = 40,
	view_range = 40,
	gravity_drag = 0.6,
	slowdown_nodes = {},
	pace_interval = 5,
	pace_chance = 120,
	particlespawners = {
		{
			amount = 40,
			time = 0,
			minpos = vector.new (-1.0,1.5,-1.0),
			maxpos = vector.new (1.0,3.4,1.0),
			minvel = vector.new (-0.05,0.65,-0.05),
			maxvel = vector.new (0.05,0.60,0.05),
			minexptime = 1.9,
			maxexptime = 2.5,
			minsize = 0.8,
			maxsize = 1.5,
			glow = 5,
			collisiondetection = true,
			collision_removal = true,
			texture = "mcl_particles_mob_death.png^[colorize:#000000:255",
		},
	},
}

------------------------------------------------------------------------
-- Wither mechanics, combat and AI.
------------------------------------------------------------------------

-- WitherBoss.java: INVULNERABLE_TICKS.
local WITHER_INVULNERABLE_TIME = 11.0
local WITHER_SPAWN_BOOM = 7

local function is_powered (self)
	return self.health <= self.object:get_properties ().hp_max / 2
end

-- WitherBoss.java: destroy the blocks around the Wither one second
-- after it is damaged.
local function wither_destroy_blocks (self)
	if not mobs_griefing then
		return
	end
	local pos = mcl_util.get_nodepos (self.object:get_pos ())
	-- floor (getBbWidth () / 2 + 1), floor (getBbHeight ()).
	local width, height = 1, 3
	for z = pos.z - width, pos.z + width do
		for y = pos.y, pos.y + height do
			for x = pos.x - width, pos.x + width do
				local npos = vector.new (x, y, z)
				local name = core.get_node (npos).name
				local ndef = core.registered_nodes[name]
				if name ~= "air" and ndef
					and ndef._mcl_hardness and ndef._mcl_hardness >= 0
					and (ndef.can_dig == nil or ndef.can_dig (npos))
					and core.get_item_group (name, "wither_immune") == 0
					and not core.is_protected (npos, "") then
					core.remove_node (npos)
					local drops = core.get_node_drops (name, "")
					if drops then
						for _, item in pairs (drops) do
							core.add_item (npos, item)
						end
					end
				end
			end
		end
	end
end

function wither_def:receive_damage (mcl_reason, damage)
	-- Invulnerable while spawning.
	if self._spawning then
		return false
	end
	if mcl_reason.direct and is_powered (self) then
		local ent = mcl_reason.direct:get_luaentity ()
		local wind_charge = "mcl_charges:wind_charge_flying"
		if ent and (ent._is_arrow or ent.name == wind_charge) then
			return false
		end
	end
	if mob_class.receive_damage (self, mcl_reason, damage) then
		local ws = self._wither_state
		if ws.destroy_blocks_time <= 0 then
			ws.destroy_blocks_time = 1.0
		end
		for _, head in ipairs (ws.aux_heads) do
			head.idle_update = head.idle_update + 3
		end
		return true
	end
	return false
end

local function new_wither_state ()
	return {
		version = 2,
		-- Seconds remaining till blocks around the Wither
		-- are destroyed in response to damage.
		destroy_blocks_time = 0,
		-- Time accumulated towards the next passive heal.
		heal_timer = 0,
		-- Metadata for auxiliary heads.
		aux_heads = {
			-- Left.
			{
				-- Time remaining till next
				-- attempt to fire a skull.
				next_update = 0,
				-- Number of attempts elapsed
				-- since skulls were last
				-- fired from this head.
				idle_update = 0,
				bone = "minihead.left",
			},
			-- Right.
			{
				next_update = 0,
				idle_update = 0,
				bone = "minihead.right",
			},
		},
	}
end

function wither_def:on_spawn ()
	-- WitherBoss.java: makeInvulnerable.
	local hp_max = self.object:get_properties ().hp_max
	self.health = hp_max / 3.0
	core.sound_play("mobs_mc_wither_spawn", {gain=1.0})
	self._spawning = WITHER_INVULNERABLE_TIME
	self._spawn_heal_timer = 0
	return true
end

function wither_def:mob_activate (staticdata, dtime)
	if not mob_class.mob_activate (self, staticdata, dtime) then
		return false
	end

	-- Withers spawned by older versions possessed a maximum
	-- health contingent on difficulty.
	self.hp_max = nil
	local hp_max = self.object:get_properties ().hp_max
	self.health = math.min (self.health, hp_max)

	if not self._wither_state or self._wither_state.version ~= 2 then
		self._wither_state = new_wither_state ()
	end
	return true
end

function wither_def:do_custom (dtime, moveresult)
	if self._spawning then
		self._spawning = self._spawning - dtime
		local bardef = {
			color = "dark_purple",
			text = S ("Wither"),
			percentage = math.floor ((WITHER_INVULNERABLE_TIME - self._spawning)
					/ WITHER_INVULNERABLE_TIME * 100),
		}

		local pos = self.object:get_pos()
		for player in mcl_util.connected_players() do
			local d = vector.distance(pos, player:get_pos())
			if d <= 80 then
				mcl_bossbars.add_bar(player, bardef, true, d)
			end
		end
		self:set_yaw (self._spawning * math.pi * 5)
		self:rotate_step (dtime)

		local value = math.max (0, self._spawning / WITHER_INVULNERABLE_TIME)
		self.object:set_texture_mod (table.concat ({
			"^[colorize:#ffffff:", 128 + math.floor (value * 128),
		}))

		local v = self.object:get_velocity ()
		v.y = v.y * 0.6
		self.object:set_velocity (v)

		-- Heal 10 HP every 10 ticks while invulnerable.
		self._spawn_heal_timer = (self._spawn_heal_timer or 0) + dtime
		while self._spawn_heal_timer >= 0.5 do
			self._spawn_heal_timer = self._spawn_heal_timer - 0.5
			self:heal_mob (10)
		end

		if self._spawning <= 0 then
			-- Explode at eye level.
			local eye_pos = vector.offset (pos, 0, self:get_eye_height (), 0)
			mcl_explosions.explode (eye_pos, WITHER_SPAWN_BOOM, {
				griefing = mobs_griefing,
			}, self.object)
			self.object:set_texture_mod ("")
			self._spawning = nil
			self._spawn_heal_timer = nil
		else
			return false
		end
	end

	-- Heal 1 HP every 20 ticks.
	local ws = self._wither_state
	ws.heal_timer = ws.heal_timer + dtime
	while ws.heal_timer >= 1.0 do
		ws.heal_timer = ws.heal_timer - 1.0
		self:heal_mob (1)
	end

	if is_powered (self) then
		self.base_texture = {
			"mobs_mc_wither.png",
			"mobs_mc_wither_armor.png",
		}
	else
		self.base_texture = {
			"mobs_mc_wither.png",
			"blank.png",
		}
	end

	self:set_textures (self.base_texture)
	mcl_bossbars.update_boss(self.object, "Wither", "dark_purple")
end

-- Positions of the Wither's heads (WitherBoss.java: getHeadX/Y/Z).
-- Index 0 is the central head and 1 and 2 are the auxiliary heads.

local function get_head_pos (self, self_pos, idx)
	if idx == 0 then
		return vector.offset (self_pos, 0, 3.0, 0)
	end
	local yaw_off = self:get_yaw () + math.pi / 2
	local distance = idx == 2 and 1.3 or -1.3
	local x, z = -math.sin (yaw_off) * distance, math.cos (yaw_off) * distance
	return vector.offset (self_pos, x, 2.2, z)
end

-- WitherBoss.java: performRangedAttack.  Skulls are launched with
-- an initial velocity of 0.1 blocks/tick and accelerate thereafter.
function wither_def:shoot_skull (idx, target, dangerous)
	local self_pos = self.object:get_pos ()
	local origin = get_head_pos (self, self_pos, idx)
	local dir = vector.direction (origin, target)
	local name = dangerous and "mobs_mc:wither_skull_strong"
		or "mobs_mc:wither_skull"
	self:mob_sound ("shoot_attack")
	local arrow = core.add_entity (origin, name)
	if not arrow then
		return
	end
	local ent = arrow:get_luaentity ()
	ent.switch = 1
	ent.owner_id = tostring (self.object)
	arrow:set_velocity (vector.multiply (dir, ent.velocity))
	ent._shooter = self.object
	ent._saved_shooter_pos = self_pos
end

local function aim_position (object)
	local pos = mcl_attachments.get_attachment_pos (object)
	local eye_height = mcl_util.target_eye_height (object) or 0
	return vector.offset (pos, 0, eye_height * 0.5, 0)
end

-- Invoked by attack_ranged to fire the central head.
function wither_def:discharge_ranged (attach_pos, target_pos)
	local target = self.attack and self.attack:is_valid ()
		and aim_position (self.attack) or target_pos
	self:shoot_skull (0, target, math.random () < 0.001)
end

function wither_def:float_around (self_pos, dtime)
	self.ai_idle_time = self.ai_idle_time + dtime
	self:check_pace (self_pos, dtime)
end

-- WitherBoss.java: aiStep.  While a target exists, the Wither
-- ascends till it is at the target's height (or 5 blocks above
-- the target if not powered) and drifts towards the target till
-- within 3 blocks of the same horizontally.
local function wither_pursue (self, self_pos, target_pos, dtime)
	local ticks = dtime * 20
	local v = self.object:get_velocity ()

	if self_pos.y < target_pos.y
		or (not is_powered (self) and self_pos.y < target_pos.y + 5.0) then
		-- Each tick: yd = max (0, yd * 0.6), then
		-- yd += 0.3 - yd * 0.6, i.e. v = 0.24v + 0.3
		-- blocks/tick.
		local r = math.pow (0.24, ticks)
		v.y = math.max (0, v.y) * r + 6.0 / 0.76 * (1 - r)
	elseif v.y > 0 then
		v.y = v.y * math.pow (0.6, ticks)
	end

	local dx = target_pos.x - self_pos.x
	local dz = target_pos.z - self_pos.z
	local d = math.sqrt (dx * dx + dz * dz)
	if d > 3.0 then
		-- v += dir * 0.3 - v * 0.6 blocks/tick.
		local r = math.pow (0.4, ticks)
		local terminal = 6.0 / 0.6 * (1 - r)
		v.x = v.x * r + dx / d * terminal
		v.z = v.z * r + dz / d * terminal
	end
	self.object:set_velocity (v)
end

local FOURTY_DEG = math.rad (40)
local TEN_DEG = math.rad (10)
local object_targetable_p = mcl_mobs.object_targetable_p

function wither_def:find_head_target (self_pos)
	-- TargetingConditions.forCombat ().range (20.0) within
	-- getBoundingBox ().inflate (20.0, 8.0, 20.0).
	local candidates = {}
	local aa = vector.offset (self_pos, -20.45, -8.01, -20.45)
	local bb = vector.offset (self_pos, 20.45, 11.49, 20.45)
	for object in core.objects_in_area (aa, bb) do
		local pos = mcl_attachments.get_attachment_pos (object)
		local entity = object:get_luaentity ()
		if object ~= self.object
			and object_targetable_p (object)
			and (object:is_player () or (entity and entity.is_mob))
			and (not entity or not entity.harmed_by_heal)
			and vector.distance (self_pos, pos) <= 20.0
			and self:test_object_and_restriction (object, pos)
			and self:target_visible (self_pos, object) then
			table.insert (candidates, object)
		end
	end
	if #candidates > 0 then
		return candidates[math.random (#candidates)]
	end
	return nil
end

function wither_def:step_aux_heads (self_pos, dtime)
	local ws = self._wither_state
	for idx = 1, 2 do
		local head = ws.aux_heads[idx]
		local yaw, pitch
		head.next_update = head.next_update - dtime
		local name = "_wither_target_" .. idx
		local attack = self[name]
		local attack_pos = attack and attack:get_pos ()

		-- Turn this head towards any creature it is attacking.
		if attack_pos then
			-- Look at this target.
			local head_x, head_y, head_z, base_yaw
			local head_off = idx == 1 and -0.65 or 0.65

			base_yaw = self:get_yaw () + math.pi / 2
			head_x = self_pos.x + head_off * -math.sin (base_yaw)
			head_y = self_pos.y + 0.6
			head_z = self_pos.z + head_off * math.cos (base_yaw)

			local target_x = attack_pos.x
			local target_y = attack_pos.y + mcl_util.target_eye_height (attack)
			local target_z = attack_pos.z
			local dx, dy, dz = target_x - head_x,
				target_y - head_y,
				target_z - head_z
			local x_magnitude = math.sqrt (dx * dx + dz * dz)
			yaw = math.atan2 (dx, dz) + self:get_yaw ()
			pitch = -math.atan2 (dy, x_magnitude)
		else
			yaw = 0
			pitch = 0
		end

		if head.next_update <= 0 then
			-- nextHeadUpdate = tickCount + 10 + nextInt (10).
			head.next_update = 0.5 + math.random (0, 9) / 20
			if mcl_vars.difficulty >= 2 then
				local idle = head.idle_update
				head.idle_update = idle + 1
				if idle > 15 then
					local random = {
						x = self_pos.x + math.random () * 20 - 10,
						y = self_pos.y + math.random () * 10 - 5,
						z = self_pos.z + math.random () * 20 - 10,
					}
					self:shoot_skull (idx, random, true)
					head.idle_update = 0
				end
			end

			if attack then
				if attack_pos
					and self:should_continue_to_attack (attack)
					and vector.distance (self_pos, attack_pos) <= 30
					and self:target_visible (self_pos, attack) then
					self:shoot_skull (idx, aim_position (attack), false)
					-- tickCount + 40 + nextInt (20).
					head.next_update = 2 + math.random (0, 19) / 20
					head.idle_update = 0
				else
					self[name] = nil
				end
			else
				self[name] = self:find_head_target (self_pos)
			end
		end

		-- Interpolate head yaw and pitch.
		if yaw ~= head.yaw or pitch ~= head.pitch then
			head.yaw
				= mcl_mobs.clip_rotation (head.yaw or 0, yaw, FOURTY_DEG)
			head.pitch
				= mcl_mobs.clip_rotation (head.pitch or 0, pitch, TEN_DEG)
		end
		local vec = vector.new (head.pitch, head.yaw, 0)
		local info = {
			rotation = {
				vec = vec,
				absolute = true,
			},
		}
		self.object:set_bone_override (head.bone, info)
	end
end

function wither_def:run_ai (dtime, moveresult)
	local self_pos = self.object:get_pos ()
	local ws = self._wither_state

	if self:check_attack (self_pos, dtime) then
		self.ai_idle_time = 0
	end
	if not self.attack then
		-- WaterAvoidingRandomFlyingGoal.
		self:float_around (self_pos, dtime)
	end

	if self.dead then
		return
	end

	local target = self.attack
	local target_pos = target and target:get_pos ()

	if target_pos then
		wither_pursue (self, self_pos, target_pos, dtime)
	elseif self.movement_goal == "go_pos" then
		local v = self.object:get_velocity ()
		v.y = (self.movement_target.y - self_pos.y)
		self.object:set_velocity (v)
	end

	self:step_aux_heads (self_pos, dtime)

	if ws.destroy_blocks_time > 0 then
		ws.destroy_blocks_time
			= math.max (0, ws.destroy_blocks_time - dtime)
		if ws.destroy_blocks_time == 0 then
			wither_destroy_blocks (self)
		end
	end
end

function wither_def:step_drowning (_)
	return
end

local function is_not_undead (self, self_pos, obj, entity)
	return not entity or not entity.harmed_by_heal
end

wither_def._targeting_rules = {
	mcl_mobs.build_retaliation_target_rule (nil, nil, nil),
	mcl_mobs.build_nearest_target_rule ("entity", is_not_undead,
					    nil, nil, nil),
}

mcl_mobs.register_mob ("mobs_mc:wither", wither_def)

------------------------------------------------------------------------
-- Wither Skull.
------------------------------------------------------------------------

local wither_rose_soil = {
	"group:grass_block",
	"mcl_core:dirt",
	"mcl_core:coarse_dirt",
	"mcl_nether:netherrack",
	"group:soul_block",
	"mcl_mud:mud",
	"mcl_lush_caves:moss",
}

local function spawn_wither_rose (obj)
	local n = core.find_node_near(obj:get_pos(),2,wither_rose_soil)
	if n then
		local p = vector.offset(n,0,1,0)
		if core.get_node(p).name == "air" then
			if not ( mobs_griefing and core.place_node(p,{name="mcl_flowers:wither_rose"}) ) then
				core.add_item(p,"mcl_flowers:wither_rose")
			end
		end
	end
end

local skull_def = {
	visual = "cube",
	visual_size = {x = 0.35, y = 0.35},
	textures = {
		"mobs_mc_wither_projectile.png^[verticalframe:6:0", -- top
		"mobs_mc_wither_projectile.png^[verticalframe:6:1", -- bottom
		"mobs_mc_wither_projectile.png^[verticalframe:6:2", -- left
		"mobs_mc_wither_projectile.png^[verticalframe:6:3", -- right
		"mobs_mc_wither_projectile.png^[verticalframe:6:4", -- back
		"mobs_mc_wither_projectile.png^[verticalframe:6:5", -- front
	},
	-- AbstractHurtingProjectile: launched at accelerationPower
	-- (0.1 blocks/tick); see apply_skull_inertia below.
	velocity = 2,
	_inertia = 0.95,
	rotate = 90,
	_lifetime = 500,
	_explosioninfo = {
		griefing = mobs_griefing,
		damage_type = "wither_skull",
	},
	on_punch = function() end,

	-- direct hit
	hit_player = function(self, player)
		local pos = vector.new(self.object:get_pos())
		if mcl_vars.difficulty >= 2 then
			local duration = mcl_vars.difficulty == 2 and 10 or 40
			mcl_potions.give_effect_by_level ("withering", player, 2,
							  duration)
		end
		mcl_util.deal_damage (player, 8.0, {
			source = self._shooter,
			direct = self.object,
			type = "wither_skull",
		})
		-- This must come before mcl_explosions.explode, which
		-- is liable to remove this object.
		local v = self.object:get_velocity ()
		v.y = 0
		local dir = vector.normalize (v)
		mcl_explosions.explode (pos, 1, self._explosioninfo, self.object, self._shooter)
		if player:get_hp() <= 0 then
			local shooter = self._shooter:get_luaentity()
			if shooter then
				shooter:heal_mob (5)
			end
			spawn_wither_rose(player)
		else
			mcl_player.player_knockback (player, self.object, dir, nil, 8.0)
		end
	end,

	hit_mob = function(self, mob)
		local pos = vector.new (self.object:get_pos())
		if mcl_vars.difficulty >= 2 then
			local duration = mcl_vars.difficulty == 2 and 10 or 40
			mcl_potions.give_effect_by_level ("withering", mob, 2,
							  duration)
		end
		mcl_util.deal_damage (mob, 8.0, {
			source = self._shooter,
			direct = self.object,
			type = "wither_skull",
		})
		local v = self.object:get_velocity ()
		v.y = 0
		local dir = vector.normalize (v)
		mcl_explosions.explode (pos, 1, self._explosioninfo, self.object, self._shooter)
		local l = mob:get_luaentity()
		if l and l.health - 8 <= 0 then
			local shooter = self._shooter:get_luaentity()
			if shooter then
				shooter:heal_mob (5)
			end
			spawn_wither_rose(mob)
		end
		if l then
			l:projectile_knockback (1, dir)
		end
	end,
	hit_node = function(self, pos)
		mcl_explosions.explode (pos, 1, self._explosioninfo, self.object, self._shooter)
	end
}

-- AbstractHurtingProjectile.tick: each tick
-- v = (v + normalize (v) * 0.1) * inertia (blocks/tick), where
-- inertia is 0.95 (0.73 for dangerous skulls) in air and 0.8 in
-- liquids.  In m/s this converges on 2 * f / (1 - f).
local function apply_skull_inertia (self, dtime)
	local v = self.object:get_velocity ()
	local speed = v and vector.length (v) or 0
	if dtime and speed > 0 then
		local pos = self.object:get_pos ()
		local nn = mcl_mobs.node_ok (pos).name
		local f = core.get_item_group (nn, "liquid") > 0
			and 0.8 or self._inertia
		local limit = 2 * f / (1 - f)
		local s = limit + (speed - limit) * math.pow (f, dtime * 20)
		self.object:set_velocity (v * (s / speed))
	end
end

local function register_skull (name, def)
	mcl_mobs.register_arrow (name, def)
	local entity = core.registered_entities[name]
	local old_on_step = entity.on_step
	entity.on_step = function (self, dtime, moveresult)
		if self.switch ~= 0 then
			apply_skull_inertia (self, dtime)
		end
		return old_on_step (self, dtime, moveresult)
	end
end

register_skull ("mobs_mc:wither_skull", skull_def)

local strong_skull_def = table.copy (skull_def)
strong_skull_def._inertia = 0.73
strong_skull_def.redirectable = true
-- WitherSkull.java: dangerous skulls treat the blast resistance of
-- all blocks not immune to the Wither as no greater than 0.8.
strong_skull_def._explosioninfo = {
	max_blast_resistance = 0.8,
	griefing = mobs_griefing,
	damage_type = "wither_skull",
}
strong_skull_def.textures = {
	"mobs_mc_wither_projectile_strong.png^[verticalframe:6:0", -- top
	"mobs_mc_wither_projectile_strong.png^[verticalframe:6:1", -- bottom
	"mobs_mc_wither_projectile_strong.png^[verticalframe:6:2", -- left
	"mobs_mc_wither_projectile_strong.png^[verticalframe:6:3", -- right
	"mobs_mc_wither_projectile_strong.png^[verticalframe:6:4", -- back
	"mobs_mc_wither_projectile_strong.png^[verticalframe:6:5", -- front
}

register_skull ("mobs_mc:wither_skull_strong", strong_skull_def)

--Spawn egg
mcl_mobs.register_egg ("mobs_mc:wither", S("Wither"), "#4f4f4f", "#4f4f4f", 0, true)
