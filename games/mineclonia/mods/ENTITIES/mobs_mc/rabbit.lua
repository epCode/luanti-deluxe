--License for code WTFPL and otherwise stated in readmes

local S = core.get_translator("mobs_mc")
local mob_class = mcl_mobs.mob_class

local rabbit = {
	description = S("Rabbit"),
	type = "animal",
	_spawn_category = "creature",
	reach = 1,
	hp_min = 3,
	hp_max = 3,
	xp_min = 1,
	xp_max = 3,
	-- EntityTypes.RABBIT: 0.49x0.6, eye height 0.59.
	collisionbox = {-0.245, 0.0, -0.245, 0.245, 0.6, 0.245},
	-- Rabbit.java: BABY_DIMENSIONS 0.24x0.4, eye height 0.39.
	child_collisionbox = {-0.12, 0.0, -0.12, 0.12, 0.4, 0.12},
	child_head_eye_height = 0.39,
	-- Rabbit.RabbitGroupData: every rabbit after the first in a
	-- group spawns as a baby.
	_group_baby_chance = 1.0,
	head_swivel = "head.control",
	bone_eye_height = 2,
	head_eye_height = 0.59,
	horizontal_head_height = -.3,
	curiosity = 20,
	head_yaw = "z",
	visual = "mesh",
	mesh = "mobs_mc_rabbit.b3d",
	textures = {
		{"mobs_mc_rabbit_brown.png"},
		{"mobs_mc_rabbit_gold.png"},
		{"mobs_mc_rabbit_white.png"},
		{"mobs_mc_rabbit_white_splotched.png"},
		{"mobs_mc_rabbit_salt.png"},
		{"mobs_mc_rabbit_black.png"},
	},
	sounds = {
		random = "mobs_mc_rabbit_random",
		damage = "mobs_mc_rabbit_hurt",
		death = "mobs_mc_rabbit_death",
		attack = "mobs_mc_rabbit_attack",
		eat = "mobs_mc_animal_eat_generic",
		distance = 16,
	},
	makes_footstep_sound = false,
	movement_speed = 6.0,
	runaway_from = {
		"mobs_mc:wolf",
		"players",
		"monsters",
	},
	runaway_view_range = 10.0,
	_runaway_player_view_range = 8.0,
	_runaway_monster_view_range = 4.0,
	runaway = true,
	drops = {
		{
			name = "mcl_mobitems:rabbit",
			chance = 1, min = 1, max = 1,
			looting = "common",
		},
		{
			name = "mcl_mobitems:rabbit_hide",
			chance = 1, min = 0, max = 1,
			looting = "common",
		},
		-- entities/rabbit.json: 10% (13%, 16%, 19% with
		-- looting), killed by a player only.
		{
			name = "mcl_mobitems:rabbit_foot",
			chance = 10, min = 1, max = 1,
			looting = "rare",
			looting_factor = 0.03,
			player_kill_only = true,
		},
	},
	animation = {
		stand_start = 0, stand_end = 0,
		jump_start = 0, jump_end = 20, jump_speed = 40,
		jump_loop = false,
	},
	_child_animations = {
		stand_start = 21, stand_end = 21,
		walk_start = 21, walk_end = 41, walk_speed = 30,
		run_start = 21, run_end = 41, run_speed = 45,
	},
	-- Follow (yellow) dangelions, carrots and golden carrots
	follow = {
		"mcl_flowers:dandelion",
		"mcl_farming:carrot_item",
		"mcl_farming:carrot_item_gold",
	},
	climb_powder_snow = true,
	follow_bonus = 1.0,
	pursuit_bonus = 1.4,
	run_bonus = 2.2,
	breed_bonus = 0.8,
	pace_bonus = 0.6,
	runaway_bonus_near = 2.2,
	runaway_bonus_far = 2.2,
	_speed_modifier = 1.0,
	_jump_delay = 0,
	pace_interval = 0,
	_grief_time = 0,
}

------------------------------------------------------------------------
-- Rabbit mechanics.
------------------------------------------------------------------------

function rabbit:on_rightclick (clicker)
	if self:follow_holding (clicker) then
		self:feed_tame (clicker, nil, true, false)
	end
end

function rabbit:actionable_on_rightclick (clicker)
	local wielditem = clicker:get_wielded_item ()
	return table.indexof(self.follow, wielditem:get_name ()) ~= -1
end

function rabbit:set_nametag (nametag)
	if mob_class.set_nametag (self, nametag) then
		-- MC Easter egg: Change texture if rabbit is named
		-- "Toast."
		if nametag == "Toast" and not self._has_toast_texture then
			self._original_rabbit_texture = self.base_texture
			self.base_texture = { "mobs_mc_rabbit_toast.png" }
			self:set_textures (self.base_texture)
			self._has_toast_texture = true
		elseif nametag ~= "Toast" and self._has_toast_texture then
			self.base_texture = self._original_rabbit_texture
			self:set_textures (self.base_texture)
			self._has_toast_texture = false
		end
	end
end

local spawns_white_rabbits_p, spawns_gold_rabbits_p

core.register_on_mods_loaded (function ()
	spawns_white_rabbits_p = mcl_biome_dispatch.make_biome_test ({
		"FrozenOcean",
		"FrozenPeaks",
		"FrozenRiver",
		"Grove",
		"IceSpikes",
		"JaggedPeaks",
		"SnowyBeach",
		"SnowyPlains",
		"SnowySlopes",
		"SnowyTaiga",
	})
	spawns_gold_rabbits_p = mcl_biome_dispatch.make_biome_test ({
		"Desert",
	})
end)

-- Rabbit.getRandomRabbitVariant.
local function random_rabbit_texture (pos)
	local random = math.random (0, 99)
	local name = mcl_biome_dispatch.get_biome_name (pos)

	if spawns_white_rabbits_p (name) then
		if random < 80 then
			return "mobs_mc_rabbit_white.png"
		else
			return "mobs_mc_rabbit_white_splotched.png"
		end
	elseif spawns_gold_rabbits_p (name) then
		return "mobs_mc_rabbit_gold.png"
	elseif random < 50 then
		return "mobs_mc_rabbit_brown.png"
	elseif random < 90 then
		return "mobs_mc_rabbit_salt.png"
	else
		return "mobs_mc_rabbit_black.png"
	end
end

function rabbit:on_spawn ()
	local texture = self._spawn_texture
		or random_rabbit_texture (self.object:get_pos ())
	self.base_texture[1] = texture
	self:set_textures (self.base_texture)
end

local function rabbit_variant_texture (self)
	if self._has_toast_texture and self._original_rabbit_texture then
		return self._original_rabbit_texture[1]
	end
	return self.base_texture and self.base_texture[1]
end

-- Rabbit.getBreedOffspring: the offspring takes the variant of either
-- parent, except one time in 20, when it receives a random variant
-- appropriate to the biome.
function rabbit:on_breed (mate)
	if self.name ~= "mobs_mc:rabbit" then
		return mob_class.on_breed (self, mate)
	end
	local self_pos = self.object:get_pos ()
	local child = mcl_mobs.spawn_child (self_pos, self.name)
	if child then
		local ent_c = child:get_luaentity ()
		local texture
		if math.random (20) == 1 then
			texture = random_rabbit_texture (self_pos)
		elseif math.random (2) == 1 then
			texture = rabbit_variant_texture (mate)
		end
		texture = texture or rabbit_variant_texture (self)
		ent_c.base_texture = { texture, }
		ent_c:set_textures (ent_c.base_texture)
		ent_c.tamed = true
		ent_c.owner = self.owner
	end
end

------------------------------------------------------------------------
-- Rabbit movement.
------------------------------------------------------------------------

function rabbit:get_jump_force (moveresult)
	local collides = mcl_mobs.horiz_collision (moveresult)
	local self_pos = self.object:get_pos ()
	local v = 0.3

	if collides then
		v = 0.5
	elseif self.movement_goal == "go_pos"
		and self.movement_target
		and self.movement_target.y > self_pos.y + 0.5 then
		v = 0.5
	elseif self.waypoints
		and #self.waypoints >= 1
		and self.waypoints[#self.waypoints].y > self_pos.y + 0.5 then
		v = 0.5
	elseif self.pacing then
		v = 0.2
	end
	return self.jump_height * (v / 0.42)
end

function rabbit:jump_actual (v, jump_force)
	local v = mob_class.jump_actual (self, v, jump_force)
	local sqr = v.x * v.x + v.z * v.z

	-- Rabbit.jumpFromGround: jump forward if (nearly) immobile
	-- (horizontal speed below 0.1 blocks/tick), by
	-- moveRelative (0.1, (0, 1.5 or 0.5 if a baby, 1)).
	if sqr < 4.0 then
		local yaw = self:get_yaw ()
		local x = -math.sin (yaw)
		local z = math.cos (yaw)
		local up = self.child and 0.5 or 1.5
		local scale = 0.1 * 20 / math.sqrt (up * up + 1)

		v.x = v.x + scale * x
		v.y = v.y + scale * up
		v.z = v.z + scale * z
	end
	return v
end

function rabbit:do_go_pos (dtime, moveresult)
	local on_ground = moveresult.touching_ground
		or moveresult.standing_on_object

	if on_ground and not self._jump then
		self.acc_dir.z = 0
		self.acc_dir.x = 0
		self.acc_dir.y = 0
	else
		local depth = self._immersion_depth
		local factor = 1.0
		if depth > self.head_eye_height then
			factor = 1.5
		end

		local target = self.movement_target or vector.zero ()
		local vel = self.movement_velocity * factor
		local pos = self.object:get_pos ()
		local dist = vector.distance (pos, target)

		if dist < 0.0005 then
			self.acc_dir.z = 0
			return
		end

		self:look_at (target, math.pi / 2 * (dtime / 0.05))
		self:set_velocity (vel)
	end
end

function rabbit:movement_step (dtime, moveresult)
	local moveresult = self._moveresult
	local on_ground = moveresult.touching_ground
		or moveresult.standing_on_object

	self._jump_delay
		= math.max (self._jump_delay - dtime, 0.0)

	if on_ground then
		if not self._previously_on_ground then
			self._jump = false
			self._want_sprinting_particles = true

			-- Rabbit.setLandingDelay: 10 ticks, or 3 ticks
			-- while moving at a speed modifier of 2.2 or more.
			if not self.frightened and not self.avoiding then
				self._jump_delay = 0.5
			else
				self._jump_delay = 0.15
			end
		end

		if self.movement_goal == "go_pos"
			and self._jump_delay == 0 then
			local target = self.movement_target or vector.zero ()
			self:look_at (target)
			self._jump = true
		end
	end
	self._previously_on_ground = on_ground
	mob_class.movement_step (self, dtime, moveresult)
end

function rabbit:display_sprinting_particles ()
	local display_particles = self._want_sprinting_particles
	self._want_sprinting_particles = false
	return display_particles
end

------------------------------------------------------------------------
-- Rabbit AI.
------------------------------------------------------------------------

local mob_griefing = mobs_mc.is_mob_griefing_enabled("rabbit")

function rabbit:ai_step (dtime)
	mob_class.ai_step (self, dtime)
	self._grief_time
		= math.max (self._grief_time - dtime, 0.0)
end

local function manhattan3d (v1, v2)
	return math.abs (v1.x - v2.x)
		+ math.abs (v1.y - v2.y)
		+ math.abs (v1.z - v2.z)
end

-- Rabbit.RaidGardenGoal.isValidTarget: only fully grown carrots
-- (group carrot=8, Minecraft's age 7) are raided, and each raid
-- sets the crop back by a single stage.
local CARROT_MAX_STAGE = 8

local function rabbit_griefable (name)
	local age = core.get_item_group (name, "carrot")
	return age == CARROT_MAX_STAGE and age or nil
end

local function previous_stage (age)
	return age - 1
end

local function rabbit_grief_garden (self, self_pos, dtime)
	if not mob_griefing then
		return false
	end
	if self._griefing_garden then
		local target = self._grief_target
		local node = core.get_node (target)
		local age = rabbit_griefable (node.name)
		if not age then
			self:cancel_navigation ()
			self:halt_in_tracks ()
			self._griefing_garden = nil
			return false
		end
		local distance = vector.distance (self_pos, target)

		if distance < 1.0 then
			if not self:navigation_finished () then
				self:cancel_navigation ()
				self:halt_in_tracks ()
			end

			-- Grief this carrot block and wait a random
			-- period before proceeding to do so again.
			if core.remove_node (target) then
				core.sound_play ("default_grass_footstep", {
					pos = target,
				}, true)

				local carrot = "mcl_farming:carrot_"
					.. previous_stage (age)
				core.place_node (target, {
					name = carrot,
					param2 = 3,
				}, self.object)
			end

			local next_start_time = math.random (200, 400) / 20
			local rabbit_time = math.random (20, 120) / 20
			self._grief_time = next_start_time + rabbit_time
			self._griefing_garden = false
			return false
		end

		if self._griefing_garden > 60 then
			self._griefing_garden = nil
			self:cancel_navigation ()
			self:halt_in_tracks ()
			return false
		end

		self._griefing_garden = self._griefing_garden + dtime
		if self:check_timer ("rabbit_repath", 2.0) then
			self:gopath (target, 0.7)
		end
		return true
	elseif self._grief_time == 0 then
		if not self:check_timer ("grief_carrots", 0.5) then
			return false
		end
		-- MoveToBlockGoal.findNearestBlock (searchRange 16,
		-- verticalSearchRange 1): farmland is sought 15 blocks
		-- horizontally around the rabbit at Y offsets 0, 1 and
		-- -1 (in that order), nearest ring first, so the crops
		-- themselves lie at offsets 1, 2 and 0.
		local nodepos = mcl_util.get_nodepos (self_pos)
		local aa = vector.offset (nodepos, -15, 0, -15)
		local bb = vector.offset (nodepos, 15, 2, 15)
		local carrots = core.find_nodes_in_area (aa, bb, {
			"group:carrot",
		})
		if #carrots == 0 then
			return false
		end
		local layer_order = { [1] = 0, [2] = 1, [0] = 2, }
		table.sort (carrots, function (a, b)
			local la = layer_order[a.y - nodepos.y]
			local lb = layer_order[b.y - nodepos.y]
			if la ~= lb then
				return la < lb
			end
			local ra = math.max (math.abs (a.x - nodepos.x),
					     math.abs (a.z - nodepos.z))
			local rb = math.max (math.abs (b.x - nodepos.x),
					     math.abs (b.z - nodepos.z))
			if ra ~= rb then
				return ra < rb
			end
			return manhattan3d (a, nodepos)
				< manhattan3d (b, nodepos)
		end)
		for i = 1, #carrots do
			local carrot = carrots[i]
			local node = core.get_node (carrot)
			if rabbit_griefable (node.name) then
				self._grief_target = carrot
				self._griefing_garden = 0.0
				self:gopath (carrot, 0.7)
				return "_griefing_garden"
			end
		end
		return false
	end
	return false
end

rabbit.ai_functions = {
	mob_class.ascend_in_powder_snow,
	mob_class.check_frightened,
	mob_class.check_breeding,
	mob_class.check_following,
	mob_class.check_avoid,
	rabbit_grief_garden,
	mob_class.check_pace,
}

mcl_mobs.register_mob ("mobs_mc:rabbit", rabbit)

------------------------------------------------------------------------
-- Killer bunny.
------------------------------------------------------------------------

local killer_bunny = table.merge (rabbit, {
	description = S("Killer Bunny"),
	attack_type = "melee",
	damage = 8,
	does_not_prevent_sleep = true,
	-- Rabbit.setVariant: EVIL_ARMOR_VALUE 8.
	armor = 100,
	_natural_armor = 8,
	textures = {
		"mobs_mc_rabbit_caerbannog.png",
	},
	-- The killer bunny panics when hurt (see below), but does not
	-- avoid players, wolves or monsters (RabbitAvoidEntityGoal).
	runaway = true,
})

function killer_bunny:on_spawn ()
	self:set_nametag ("The Killer Bunny")
end

-- Rabbit.registerGoals: the RabbitPanicGoal (priority 1) is retained
-- by the killer bunny and outranks its MeleeAttackGoal (priority 4).
killer_bunny.ai_functions = {
	mob_class.ascend_in_powder_snow,
	mob_class.check_frightened,
	mob_class.check_attack,
	mob_class.check_breeding,
	mob_class.check_following,
	rabbit_grief_garden,
	mob_class.check_pace,
}

killer_bunny._targeting_rules = {
	mcl_mobs.build_retaliation_target_rule (nil, true, {"mobs_mc:killer_bunny",}),
	mcl_mobs.build_nearest_target_rule ("player", nil, nil, nil, nil),
	mcl_mobs.build_nearest_target_rule ("mobs_mc:wolf", {"mobs_mc:wolf",},
					    nil, nil, nil),
	mcl_mobs.build_alert_receiver_rule (),
}

mcl_mobs.register_mob ("mobs_mc:killer_bunny", killer_bunny)

------------------------------------------------------------------------
-- Rabbit spawning.
------------------------------------------------------------------------
-- Mob spawning rules.
-- Different skins depending on spawn location.

-- Spawn egg
mcl_mobs.register_egg("mobs_mc:rabbit", S("Rabbit"), "#995f40", "#734831", 0)

------------------------------------------------------------------------
-- Modern Rabbit spawning.
------------------------------------------------------------------------

local rabbit_spawner_woody = table.merge (mobs_mc.animal_spawner, {
	name = "mobs_mc:rabbit",
	weight = 4,
	pack_min = 2,
	pack_max = 3,
	-- OverworldBiomes: forest (flower), oldGrowthTaiga, taiga
	-- (including snowy), snowySlopes: rabbit 4 (2-3).
	biomes = {
		"FlowerForest",
		"OldGrowthPineTaiga",
		"OldGrowthSpruceTaiga",
		"Taiga",
		"SnowyTaiga",
		"SnowySlopes",
	},
})

function rabbit_spawner_woody:test_supporting_node (node)
	return core.get_item_group (node.name, "grass_block") > 0
		or node.name == "mcl_core:sand"
		or node.name == "mcl_core:snowblock"
end

function rabbit_spawner_woody:prepare_to_spawn (pack_size, center)
	-- Select a variant for the entire pack (Rabbit.RabbitGroupData).
	return {
		_spawn_texture = random_rabbit_texture (center),
	}
end

-- OverworldBiomes.meadowOrCherryGrove: rabbit 2 (2-6).
local rabbit_spawner_meadow_or_cherry_grove = table.merge (rabbit_spawner_woody, {
	weight = 2,
	pack_min = 2,
	pack_max = 6,
	biomes = {
		"Meadow",
		"CherryGrove",
	},
})

-- BiomeDefaultFeatures.snowySpawns (snowy plains and ice spikes
-- only): rabbit 10 (2-3).
local rabbit_spawner_snowy = table.merge (rabbit_spawner_woody, {
	weight = 10,
	pack_min = 2,
	pack_max = 3,
	biomes = {
		"IceSpikes",
		"SnowyPlains",
	},
})

local rabbit_spawner_grove = table.merge (rabbit_spawner_woody, {
	weight = 8,
	pack_min = 2,
	pack_max = 3,
	biomes = {
		"Grove",
	},
})

-- BiomeDefaultFeatures.desertSpawns: rabbit 12 (2-3).
local rabbit_spawner_desert = table.merge (rabbit_spawner_woody, {
	weight = 12,
	pack_min = 2,
	pack_max = 3,
	biomes = {
		"Desert",
	},
})

mcl_mobs.register_spawner (rabbit_spawner_woody)
mcl_mobs.register_spawner (rabbit_spawner_meadow_or_cherry_grove)
mcl_mobs.register_spawner (rabbit_spawner_snowy)
mcl_mobs.register_spawner (rabbit_spawner_grove)
mcl_mobs.register_spawner (rabbit_spawner_desert)
