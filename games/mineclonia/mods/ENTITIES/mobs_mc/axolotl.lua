local S = core.get_translator(core.get_current_modname())
local mob_class = mcl_mobs.mob_class

------------------------------------------------------------------------
-- Axolotl
------------------------------------------------------------------------

local axolotl = {
	description = S("Axolotl"),
	type = "animal",
	_spawn_category = "axolotl",
	can_despawn = true,
	hp_min = 14,
	hp_max = 14,
	xp_min = 1,
	xp_max = 3,
	head_swivel = "head.control",
	bone_eye_height = -1,
	head_eye_height = -0.5,
	horizontal_head_height = 0,
	curiosity = 10,
	head_yaw = "z",
	-- This field only exists for compatibility with Luanti <5.10
	-- clients.  See:
	-- https://github.com/luanti-org/luanti/issues/15692 &
	-- company.
	_head_axis_scale = {
		vec = vector.new (-1.0, -1.0, 1.0),
		absolute = true,
	},
	armor = 100,
	rotate = 180,
	tilt_swim = true,
	collisionbox = {-0.375, 0.0, -0.375, 0.375, 0.42, 0.375},
	visual = "mesh",
	mesh = "mobs_mc_axolotl.b3d",
	-- Axolotl.Variant: the first four are common variants; the
	-- last (blue) is only produced by breeding.
	textures = {
		{"mobs_mc_axolotl_brown.png"}, -- wild
		{"mobs_mc_axolotl_yellow.png"}, -- gold
		{"mobs_mc_axolotl_pink.png"}, -- lucy
		{"mobs_mc_axolotl_white.png"}, -- cyan
		{"mobs_mc_axolotl_purple.png"}, -- blue
	},
	sounds = {
		random = "mobs_mc_axolotl",
		damage = "mobs_mc_axolotl_hurt",
		distance = 16,
	},
	animation = {-- Stand: 1-20; Walk: 20-60; Swim: 61-81
		stand_start = 61, stand_end = 81, stand_speed = 15,
		walk_start = 61, walk_end = 81, walk_speed = 15,
		run_start = 61, run_end = 81, run_speed = 20,
	},
	follow = {
		"mcl_buckets:bucket_tropical_fish"
	},
	on_rightclick = function(self, clicker)
		local bn = clicker:get_wielded_item():get_name()
		if bn == "mcl_buckets:bucket_water" or bn == "mcl_buckets:bucket_river_water" then
			if clicker:set_wielded_item("mcl_buckets:bucket_axolotl") then
				local it = clicker:get_wielded_item()
				local m = it:get_meta()
				-- Axolotl.saveToBucketTag: also preserve
				-- health, age, and the hunting cooldown.
				m:set_string("properties",core.serialize ({
					nametag = self:get_nametag (),
					base_texture = self.base_texture,
					texture_selected = self.texture_selected,
					health = self.health,
					child = self.child,
					_mob_age = self._mob_age,
					_hunting_cooldown = self._hunting_cooldown,
				}))
				clicker:set_wielded_item(it)
				self:safe_remove()
			end
			awards.unlock(clicker:get_player_name(), "mcl:cutestPredator")
			return
		end
		if self:follow_holding (clicker)
			and self:feed_tame (clicker, nil, true, false, true) then
			local item = clicker:get_wielded_item()
			if not core.is_creative_enabled(clicker:get_player_name()) then
				item:take_item()
				clicker:set_wielded_item("mcl_buckets:bucket_water")
			end
			return
		end
	end,
	makes_footstep_sound = false,
	amphibious = true,
	do_go_pos = mcl_mobs.mob_class.pitchswim_do_go_pos,
	idle_gravity_in_liquids = true,
	breathes_in_water = true,
	damage = 2,
	reach = 2,
	attack_type = "melee",
	runaway = true,
	movement_speed = 20,
	stepheight = 1.02,
	pace_bonus = 0.5,
	-- AxolotlAi: tempted 0.5, following adults 0.6 (in water).
	follow_bonus = 0.5,
	follow_herd_bonus = 0.6,
	run_bonus = 0.6,
	pursuit_bonus = 0.6,
	breed_bonus = 0.2,
	pace_chance = 10,
	pace_interval = 0.5,
	swim_speed_factor = 0.1,
	grounded_speed_factor = 0.5,
	fixed_grounded_speed = 3.0,
	_max_air_supply = 300,
	-- AxolotlAttackablesSensor.TARGET_DETECTION_DISTANCE.
	view_range = 8,
	child_collisionbox = {-0.1875, 0.0, -0.1875, 0.1875, 0.21, 0.1875},
}

------------------------------------------------------------------------
-- Axolotl variants.
------------------------------------------------------------------------

local N_COMMON_VARIANTS = 4
local BLUE_VARIANT = 5

function axolotl:update_textures ()
	local def = mcl_mobs.registered_mobs[self.name]
	local list = def.texture_list
	local selected = self.texture_selected
	-- Replace missing or legacy variants (which no longer exist
	-- in Minecraft) with a common variant.
	if not selected or not list[selected]
		or (self.base_texture
		    and self.base_texture[1] ~= list[selected][1]) then
		self.texture_selected = math.random (N_COMMON_VARIANTS)
		self.base_texture = nil
	end
	mob_class.update_textures (self)
end

function axolotl:on_breed (mate)
	local self_pos = self.object:get_pos ()
	local child = mcl_mobs.spawn_child (self_pos, self.name)
	if child then
		local ent_c = child:get_luaentity ()
		local def = mcl_mobs.registered_mobs[self.name]
		local variant
		-- Axolotl.getBreedOffspring: 1 in 1200 offspring are
		-- of the rare variant.
		if math.random (1200) == 1 then
			variant = BLUE_VARIANT
		elseif math.random (2) == 1 then
			variant = self.texture_selected
		else
			variant = mate.texture_selected
		end
		variant = variant or math.random (N_COMMON_VARIANTS)
		ent_c.texture_selected = variant
		ent_c.base_texture = table.copy (def.texture_list[variant])
		ent_c:set_textures (ent_c.base_texture)
		ent_c.persistent = true
		ent_c.tamed = true
		ent_c.owner = self.owner
	end
end

------------------------------------------------------------------------
-- Axolotl AI.  Axolotls may play dead when hurt, and periodically
-- surface onto land, before returning to water.  While swimming, they
-- occasionally move towards the player or other mob at which they are
-- gazing, rather than a random position.
------------------------------------------------------------------------

function axolotl:valid_enemy ()
	return self._regeneration_time == nil
end

local function axolotl_regenerate (self, self_pos, dtime)
	if self._regeneration_time then
		-- PlayDead.canStillUse: only while in water.
		if core.get_item_group (self.standing_in, "water") == 0 then
			self._regeneration_time = nil
			return false
		end
		self:cancel_navigation ()
		self:halt_in_tracks ()
		self._regeneration_time
			= self._regeneration_time - dtime
		if self._regeneration_time <= 0 then
			self._regeneration_time = nil
		end
		return true
	else
		-- This activity is only initialized by damage
		-- callbacks.
		return false
	end
end

local function manhattan3d (v1, v2)
	return math.abs (v1.x - v2.x)
		+ math.abs (v1.y - v2.y)
		+ math.abs (v1.z - v2.z)
end

local function axolotl_find_water_1 (self_pos)
	local aa = vector.offset (self_pos, -6, -6, -6)
	local bb = vector.offset (self_pos, 6, 6, 6)
	local nodes = core.find_nodes_in_area (aa, bb, {
		"group:water",
	})
	table.sort (nodes, function (v1, v2)
		return manhattan3d (self_pos, v1)
			< manhattan3d (self_pos, v2)
	end)
	for _, node in ipairs (nodes) do
		local node_above = vector.offset (node, 0, 1, 0)
		-- Initially search for water above air, but settle
		-- for water in general.
		if core.get_node (node_above).name == "air" then
			return node
		end
	end
	return #nodes > 1 and nodes[math.random (#nodes)] or nil
end

local function axolotl_find_water (self, self_pos, dtime)
	if self._moving_to_water then
		if self:navigation_finished () then
			self:halt_in_tracks ()
			self:cancel_navigation ()
			self._moving_to_water = false
			return false
		end
		return true
	end
	if self.pacing then
		return false
	end
	if core.get_item_group (self.standing_in, "water") ~= 0 then
		return false
	end
	local node = axolotl_find_water_1 (self_pos)
	if node and self:gopath (node) then
		self._moving_to_water = true
		return "_moving_to_water"
	end
	return false
end

function axolotl:receive_damage (mcl_reason, damage)
	-- If a 1 in 3 chance is realized (Axolotl.hurtServer) and
	-- either the damage is greater than a number between 0 and 2
	-- or this mob is at half health or worse, and this mob is
	-- waterborne, play dead while regenerating.
	if math.random (3) == 1
		and (math.random (3) - 1 < damage
			or self.health / self.initial_properties.hp_max < 0.5)
		and damage < self.health
		and core.get_item_group (self.standing_in, "water") ~= 0
		and mcl_reason and mcl_reason.source
		and not self._regeneration_time then
		self._regeneration_time = 10
		self:replace_activity ("_regeneration_time")
		mcl_potions.give_effect_by_level ("regeneration", self.object, 1, 10)
	end

	return mob_class.receive_damage (self, mcl_reason, damage)
end

function axolotl:track_current_target (self_pos, dtime, obj, persistence)
	local result = mob_class.track_current_target (self, self_pos, dtime,
						       obj, persistence)
	local entity = obj:get_luaentity ()

	-- If this entity was just slain by a player, grant
	-- regeneration and remove mining fatigue.
	if entity and entity.dead then
		local attacker = entity._last_attacker
		if attacker and attacker:is_valid ()
			and attacker:is_player ()
			and vector.distance (attacker:get_pos (),
						self.object:get_pos ()) < 20 then
			-- Axolotl.applySupportingEffects: refresh unless
			-- more than 2399 ticks remain.
			local effect = mcl_potions.get_effect (attacker, "regeneration")
			local current_dur = 0
			if effect then
				current_dur = math.max (0, effect.dur - effect.timer)
			end
			if not effect or current_dur < 120 then
				local dur = math.min (120, current_dur + 5)
				mcl_potions.give_effect_by_level ("regeneration", attacker,
								1, dur)
			end
			mcl_potions.clear_effect (attacker, "fatigue")
		end
		-- Wait for a cooldown period before hunting another mob.
		self._hunting_cooldown = 120
	elseif not result then
		-- AxolotlAi.updateActivity: the cooldown commences
		-- whenever the fight activity ends.
		self._hunting_cooldown = 120
	end
	return result
end

function axolotl:ai_step (dtime)
	mob_class.ai_step (self, dtime)
	if self._hunting_cooldown then
		self._hunting_cooldown
			= math.max (0, self._hunting_cooldown - dtime)
	end
end

function axolotl:mob_activate (staticdata, dtime)
	if not mob_class.mob_activate (self, staticdata, dtime) then
		return false
	end
	self:update_tag ()
	return true
end

axolotl.ai_functions = {
	axolotl_regenerate,
	mob_class.check_breeding,
	mob_class.check_attack,
	mob_class.check_following,
	mob_class.follow_herd,
	axolotl_find_water,
	mob_class.check_pace,
}

-- #axolotl_hunt_targets (less tadpoles).
local axolotl_prey = {
	"mobs_mc:tropical_fish",
	"mobs_mc:pufferfish",
	"mobs_mc:salmon",
	"mobs_mc:cod",
	"mobs_mc:squid",
	"mobs_mc:glow_squid",
}

-- #axolotl_always_hostiles.
local axolotl_enemies = {
	"mobs_mc:drowned",
	"mobs_mc:baby_drowned",
	"mobs_mc:guardian",
	"mobs_mc:guardian_elder",
}

-- AxolotlAttackablesSensor: targets must be in water.
local function build_waterborne_predicate (names)
	local predicate = mcl_mobs.build_search_predicate (names)
	return function (self, self_pos, obj, luaentity)
		return predicate (self, self_pos, obj, luaentity)
			and luaentity and luaentity.standing_in
			and core.get_item_group (luaentity.standing_in, "water") ~= 0
	end
end

axolotl._targeting_rules = {
	mcl_mobs.build_nearest_target_rule ("mob", build_waterborne_predicate (axolotl_enemies),
					    nil, nil, true),
	mcl_mobs.build_nearest_target_rule ("mob", build_waterborne_predicate (axolotl_prey),
					    function (self)
		return not self._hunting_cooldown or self._hunting_cooldown <= 0
	end, nil, true),
}

------------------------------------------------------------------------
-- Axolotl environment.
------------------------------------------------------------------------

-- Axolotl.handleAirSupply: rain prevents axolotls from drying out.
function axolotl:step_drowning (dtime, is_in_water)
	if not is_in_water then
		local node_pos = mcl_util.get_nodepos (self.object:get_pos ())
		if self:is_exposed_to_rain (node_pos) then
			is_in_water = true
		end
	end
	return mob_class.step_drowning (self, dtime, is_in_water)
end

------------------------------------------------------------------------
-- Axolotl spawning.
------------------------------------------------------------------------

mcl_mobs.register_mob ("mobs_mc:axolotl", axolotl)

------------------------------------------------------------------------
-- Modern Axolotl spawning.
------------------------------------------------------------------------

local default_spawner = mcl_mobs.default_spawner
local group_variants = nil

local axolotl_spawner = {
	name = "mobs_mc:axolotl",
	spawn_category = "axolotl",
	spawn_placement = "aquatic",
	pack_min = 4,
	pack_max = 6,
	weight = 10,
	biomes = {
		"LushCaves",
	},
}

function axolotl_spawner:test_spawn_position (spawn_pos, node_pos, sdata, node_cache,
					      spawn_flag)
	if default_spawner.test_spawn_position (self, spawn_pos, node_pos,
						sdata, node_cache, spawn_flag) then
		local block = self:get_node (node_cache, -1, node_pos)
		if block.name == "mcl_core:clay" then
			return true
		end
	end
	return false
end

-- Axolotl.finalizeSpawn: each group selects two common variants,
-- one of which is assigned to each member, and members after the
-- second spawn as babies.
function axolotl_spawner:spawn (spawn_pos, idx, sdata, pack_size)
	if not idx or idx <= 1 or not group_variants then
		group_variants = {
			math.random (N_COMMON_VARIANTS),
			math.random (N_COMMON_VARIANTS),
		}
	end
	local data = table.merge (sdata or {}, {
		texture_selected = group_variants[math.random (2)],
	})
	if idx and idx >= 3 then
		data.child = true
	end
	return core.add_entity (spawn_pos, self.name, core.serialize (data))
end

function axolotl_spawner:describe_additional_spawning_criteria ()
	return S ("Spawning will only be successful on clay.")
end

mcl_mobs.register_spawner (axolotl_spawner)

-- spawn eggs
mcl_mobs.register_egg("mobs_mc:axolotl", S("Axolotl"), "#e890bf", "#b83D7e", 0)
