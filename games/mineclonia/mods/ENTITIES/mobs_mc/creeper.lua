--License for code WTFPL and otherwise stated in readmes

local S = core.get_translator("mobs_mc")

local mobs_griefing = mobs_mc.is_mob_griefing_enabled("creeper")
local mob_class = mcl_mobs.mob_class

--###################
--################### CREEPER
--###################

local creeper_defs = {
	type = "monster",
	_spawn_category = "monster",
	hp_min = 20,
	hp_max = 20,
	xp_min = 5,
	xp_max = 5,
	collisionbox = {-0.3, 0.0, -0.3, 0.3, 1.7, 0.3},
	visual = "mesh",
	mesh = "mobs_mc_creeper.b3d",
	visual_size = { x = 3, y = 3 },
	makes_footstep_sound = true,
	movement_speed = 5.0,
	runaway = true,
	runaway_from = { "mobs_mc:ocelot", "mobs_mc:cat", },
	-- Creeper.java: AvoidEntityGoal (6.0, 1.0, 1.2).
	runaway_view_range = 6,
	runaway_bonus_near = 1.2,
	attack_type = "melee",
	sounds = {
		attack = "tnt_ignite",
		death = "mobs_mc_creeper_death",
		damage = "mobs_mc_creeper_hurt",
		fuse = "tnt_ignite",
		explode = "tnt_explode",
		distance = 16,
	},
	drops = {
		{
			name = "mcl_mobitems:gunpowder",
			chance = 1,
			min = 0,
			max = 2,
			looting = "common",
		},
		{
			name = "mcl_heads:creeper",
			chance = 1,
			min = 0,
			max = 0,
			mob_head = true,
		},
	},
	animation = {
		stand_start = 0, stand_end = 0,
		walk_start = 0, walk_end = 40, walk_speed = 48,
		run_start = 0, run_end = 40, run_speed = 48,
		hurt_start = 110, hurt_end = 139,
		death_start = 140, death_end = 189,
		look_start = 50, look_end = 108,
	},
	floats = 1,
	reach = 3,
	-- SwellGoal starts at a distance of 3, not the attack box.
	_melee_reach_mode = "distance",
	-- SwellGoal re-arms the fuse as soon as the target is in
	-- range again.
	melee_interval = 0,
	pace_bonus = 0.8,
	_unplaceable_by_default = true,
	head_swivel = "Head_Control",
	bone_eye_height = 2.35,
	curiosity = 2,
}

---------------------------------------------------------------
-- Creeper mechanics.
---------------------------------------------------------------

local CREEPER_SWELL_TIME = 30/20

-- Creeper.mobInteract: items in #creeper_igniters ignite the
-- creeper permanently.
function creeper_defs:on_rightclick (clicker)
	local item = clicker:get_wielded_item()
	local name = item:get_name ()
	local is_flint = core.get_item_group(name, "flint_and_steel") > 0
	if is_flint or name == "mcl_fire:fire_charge" then
		if not core.is_creative_enabled(clicker:get_player_name()) then
			if is_flint then
				-- Wear tool
				local wdef = item:get_definition()
				mcl_util.use_item_durability (item, 1)
				-- Tool break sound
				if item:get_count() == 0 and wdef.sound and wdef.sound.breaks then
					core.sound_play(wdef.sound.breaks, {pos = clicker:get_pos(), gain = 0.5}, true)
				end
			else
				item:take_item ()
			end
			clicker:set_wielded_item(item)
		end
		self._ignited = true
		self._swell_time = self._swell_time or 0
		self._swell_dir = 1
	end
end

function creeper_defs:update_swell ()
	local self_pos = self.object:get_pos ()
	self:cancel_navigation ()
	self:halt_in_tracks ()

	if self._ignited then
		self._swell_dir = 1
	elseif not self.attack
		or not self.attack:is_valid ()
		or self._swell_time <= 0 then
		self._swell_dir = -1
	else
		local target_pos
			= mcl_attachments.get_attachment_pos (self.attack)
		if vector.distance (self_pos, target_pos) > 7.0
			or not self:target_visible (self_pos, self.attack) then
			-- Cancel swelling if the target is no longer valid.
			self._swell_dir = -1
		end
	end

	if self._swell_time >= CREEPER_SWELL_TIME then
		self._swell_time = CREEPER_SWELL_TIME
		-- Creeper.explodeCreeper: at the creeper's feet.
		self:creeper_explode (self.object:get_pos (),
				      self.explosion_strength)
		return
	end
	self:update_visual_swell ()
end

function creeper_defs:update_visual_swell ()
	local visual_size = self.initial_properties.visual_size
	-- Creeper.getSwelling: swell / (maxSwell - 2).
	local swell = math.min (self._swell_time / (CREEPER_SWELL_TIME - 0.1), 1.0)
	local interpolated = 1 + math.sin (swell * 100) * swell * 0.01
	swell = swell * swell * swell
	local xz = (1.0 + swell * 0.4) * interpolated
	local y = (1.0 + swell * 0.1) / interpolated
	self:set_properties ({
		visual_size = {
			x = visual_size.x * xz,
			y = visual_size.y * y,
		},
	})

	local t = math.floor (self._swell_time * 20)
	if t % 12 == 6 or self._swell_dir == -1 then
		self:remove_texture_mod ("^[brighten")
	elseif t % 12 == 0 then
		self:add_texture_mod ("^[brighten")
	end
end

function creeper_defs:creeper_explode (pos, strength)
	-- Prevent any further damage from being dealt to this mob
	-- by the explosion by removing it now.
	self:safe_remove ()
	mcl_explosions.explode (pos, strength, {
		griefing = mobs_griefing,
	}, self.object)
	-- Dissipate active status effects.
	for name, val in pairs (mcl_potions.all_effects (self.object)) do
		local level = mcl_potions.get_effect_level (self.object,
							    name)
		-- Creeper.spawnLingeringCloud: the cloud lasts 300
		-- ticks and applies effects at a quarter of their
		-- remaining duration.
		mcl_potions.add_lingering_effect (pos, name, (val.dur - (val.timer or 0)) / 4,
						  level, 2.5, 15)
	end
end

function creeper_defs:do_custom (dtime)
	if self._ignited then
		self._swell_dir = 1
	end
	local swell_time = self._swell_time or 0
	local swell_dir  = self._swell_dir
	if swell_dir == 1 then
		if swell_time == 0 then
			-- Creeper.tick: primed sound.
			self:mob_sound ("attack")
			if mcl_gameevent then
				mcl_gameevent.emit_entity (self.object, "prime_fuse")
			end
		end
		self._swell_time = swell_time + dtime
		self:update_swell ()
		-- SwellGoal holds the MOVE flag while swelling.
		return false
	elseif swell_dir == -1 then
		-- The fuse winds down while the creeper is free to
		-- move and to resume swelling.
		local t = swell_time - dtime
		self._swell_time = t
		if t <= 0 then
			self._swell_time = 0
		end
		self:update_visual_swell ()
		if t <= 0 then
			self._swell_dir = nil
		end
	end
end

function creeper_defs:on_die (pos, mcl_reason)
	-- Drop a random music disc when killed by skeleton or stray
	if mcl_reason and mcl_reason.type == "arrow" then
		if mcl_reason.mob_name == "mobs_mc:skeleton"
			or mcl_reason.mob_name == "mobs_mc:stray" then
			local loot = mcl_jukebox.get_random_creeper_loot()
			if loot then
				core.add_item({x=pos.x, y=pos.y+1, z=pos.z}, loot)
			end
		end
	end
end

-- Creeper.causeFallDamage: every landing adds (int) (fallDistance *
-- 1.5) ticks to the fuse, up to maxSwell - 5.
function creeper_defs:check_fall_damage (dtime, attach_pos, moveresult)
	local reset = self.reset_fall_damage
	local fall_y = self._last_fall_y or attach_pos.y
	local d = math.max ((self._fall_distance or 0)
		+ (fall_y - attach_pos.y), 0)
	mob_class.check_fall_damage (self, dtime, attach_pos, moveresult)
	if not reset and not self.dead
		and moveresult.touching_ground
		and self.standing_on ~= "ignore"
		and self._liquidtype ~= "water" and not self._stuck_in
		and d > 0 then
		local t = (self._swell_time or 0) + math.floor (d * 1.5) / 20
		self._swell_time = math.min (t, CREEPER_SWELL_TIME - 0.25)
		if self._swell_dir ~= 1 then
			self._swell_dir = -1
		end
	end
end

---------------------------------------------------------------
-- Creeper AI.
---------------------------------------------------------------

function creeper_defs:custom_attack ()
	-- Begin swelling.
	self._swell_time = self._swell_time or 0
	self._swell_dir = 1
	self:cancel_navigation ()
	self:halt_in_tracks ()
end

creeper_defs.ai_functions = {
	mob_class.check_avoid,
	mob_class.check_attack,
	mob_class.check_pace,
}

creeper_defs._targeting_rules = {
	mcl_mobs.build_nearest_target_rule ("player", nil, nil, nil, nil),
	mcl_mobs.build_retaliation_target_rule (nil, nil, nil),
}

---------------------------------------------------------------
-- Creeper registration and spawning.
---------------------------------------------------------------

local regular_creeper = table.merge (creeper_defs, {
	description = S("Creeper"),
	textures = {
		{
			"mobs_mc_creeper.png",
			"mobs_mc_empty.png",
		},
	},
	explosion_strength = 3,
})

-- Entity.thunderHit: 8 seconds of fire (if not already burning)
-- and 5 damage.
local function creeper_thunder_hit (object)
	if not mcl_burning.is_burning (object) then
		mcl_burning.set_on_fire (object, 8)
	end
	mcl_util.deal_damage (object, 5, { type = "lightning_bolt" })
end

function regular_creeper:_on_lightning_strike ()
	-- Creeper.thunderHit: become powered, then take the usual
	-- lightning damage.
	local new = self:replace_with ("mobs_mc:creeper_charged", false, {
		_swell_time = self._swell_time,
		_swell_dir = self._swell_dir,
		_ignited = self._ignited,
	})
	if new then
		local entity = new:get_luaentity ()
		entity.health = self.health
		creeper_thunder_hit (new)
	end
	return true
end

mcl_mobs.register_mob ("mobs_mc:creeper", regular_creeper)

local charged_creeper = table.merge (creeper_defs, {
	description = S("Charged Creeper"),
	textures = {
		{
			"mobs_mc_creeper.png",
			"mobs_mc_creeper_charge.png^[opacity:95",
		},
	},
	explosion_strength = 6,
	use_texture_alpha = true,
})

function charged_creeper:_on_lightning_strike ()
	creeper_thunder_hit (self.object)
	return true
end

mcl_mobs.register_mob ("mobs_mc:creeper_charged", charged_creeper)

-- spawn eggs
mcl_mobs.register_egg("mobs_mc:creeper", S("Creeper"), "#0da70a", "#000000", 0)

---------------------------------------------------------------
-- Modern Creeper spawning.
---------------------------------------------------------------

local creeper_spawner = table.merge (mobs_mc.monster_spawner, {
	name = "mobs_mc:creeper",
	weight = 100,
	pack_max = 4,
	pack_min = 4,
	biomes = mobs_mc.monster_biomes,
})

mcl_mobs.register_spawner (creeper_spawner)
