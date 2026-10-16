--MCmobs v0.4
--maikerumine
--made for MC like Survival game
--License for code WTFPL and otherwise stated in readmes

local S = core.get_translator("mobs_mc")
local mob_class = mcl_mobs.mob_class
local mobs_spawn = core.settings:get_bool ("mobs_spawn", true)

--###################
--################### OCELOT AND CAT
--###################

-- #ocelot_food and #cat_food: cod and salmon.
local food = {
	"mcl_fishing:fish_raw",
	"mcl_fishing:salmon_raw",
}

------------------------------------------------------------------------
-- Ozelot.
------------------------------------------------------------------------
local ocelot = {
	description = S("Ocelot"),
	type = "animal",
	-- EntityTypes.java: MobCategory.CREATURE (though the jungle
	-- biomes list ocelots among their monster spawns), and allowed
	-- in peaceful.
	_spawn_category = "creature",
	can_despawn = true,
	hp_min = 10,
	hp_max = 10,
	xp_min = 1,
	xp_max = 3,
	visual_size = { x = 1.75, y = 1.75, },
	head_swivel = "head.control",
	bone_eye_height = 0,
	-- EntityTypes.java: no eyeHeight, so 0.85 * 0.7.
	head_eye_height = 0.595,
	-- Ocelot.java: BABY_DIMENSIONS 0.3 x 0.35, eye height 0.34375.
	child_head_eye_height = 0.34375,
	horizontal_head_height = -0,
	head_yaw = "z",
	curiosity = 4,
	collisionbox = {-0.3, 0, -0.3, 0.3, 0.7, 0.3},
	visual = "mesh",
	mesh = "mobs_mc_cat.b3d",
	textures = {"mobs_mc_cat_ocelot.png"},
	makes_footstep_sound = true,
	movement_speed = 6.0,
	floats = 1,
	runaway = false,
	_no_fall_damage = true,
	sounds = {
		damage = "mobs_mc_ocelot_hurt",
		death = "mobs_mc_ocelot_hurt",
		eat = "mobs_mc_animal_eat_generic",
		distance = 16,
	},
	animation = {
		stand_start = 0, stand_end = 0,
		walk_start = 0, walk_end = 40, walk_speed = 110,
		run_start = 0, run_end = 40, run_speed = 110,
		sit_start = 50, sit_end = 50,
		crouch_start = 61, crouch_end = 80, crouch_speed = 20,
		sleep_start = 94, sleep_end = 137, sleep_loop = false,
		sleep_speed = 80,
	},
	_child_animations = {
		stand_start = 140 + 0, stand_end = 140 + 0,
		walk_start = 140 + 0, walk_end = 140 + 40,
		walk_speed = 110,
		run_start = 140 + 0, run_end = 140 + 40,
		run_speed = 110,
		sit_start = 140 + 50, sit_end = 140 + 50,
		crouch_start = 140 + 61, crouch_end = 140 + 80,
		crouch_speed = 140 + 20,
		sleep_start = 140 + 94, sleep_end = 140 + 137,
		sleep_speed = 80, sleep_loop = false,
	},
	attack_type = "null",
	damage = 3,
	reach = 1,
	breed_bonus = 0.8,
	follow_bonus = 0.6,
	-- WaterAvoidingRandomStrollGoal (this, 0.8, ...).
	pace_bonus = 0.8,
	_trusts_players = false,
	runaway_from = {
		"players",
	},
	follow = food,
	runaway_bonus_near = 1.33,
	runaway_bonus_far = 0.8,
	_is_ocelot_tamable = false,
	-- Ocelot.finalizeSpawn: AgeableMobGroupData (1.0F).
	_group_baby_chance = 1.0,
	_age = 0.0,
}

------------------------------------------------------------------------
-- Ocelot visuals and animations.
------------------------------------------------------------------------

function ocelot:mob_activate (staticdata, dtime)
	if not mob_class.mob_activate (self, staticdata, dtime) then
		return false
	end
	-- Delete _head_pitch_offset fields applied by earlier
	-- versions of this code.
	if rawget (self, "_head_pitch_offset") then
		self._head_pitch_offset = nil
	end
	self._pose = "walk"
	-- Discard block targets saved by earlier versions of this
	-- code.
	for _, field in ipairs ({"_target_bed", "_target_block"}) do
		local data = rawget (self, field)
		if data and (type (data) ~= "table" or not data.block) then
			self[field] = nil
		end
	end
	-- Don't permit ocelots to be tamed, even if they previously
	-- were by reason of programming errors, though this should be
	-- possible with cats.
	if not self._is_ocelot_tamable then
		rawset (self, "tamed", nil)
	end
	return true
end

function ocelot:ai_step (dtime)
	mob_class.ai_step (self, dtime)
	self._age = self._age + dtime
	local v = self.object:get_velocity ()
	local xz = v.x * v.x + v.z * v.z

	if self.avoiding then
		if self.gowp_velocity == self.movement_speed * 1.33 then
			self._sprinting = true
		else
			self._sprinting = false
		end
	elseif not self.attack then
		self._sprinting = false
	end

	if self.order == "sit" then
		self._pose = "sit"
	elseif self._pose == "sit" and not self._target_bed
		and not self._target_block then
		self._pose = "walk"
	end

	if self._pose == "repose" and not self._sleeping_with_owner
		and not self._target_bed then
		self._pose = "walk"
	end

	if self._pose == "repose" then
		mob_class.set_animation (self, "sleep")
	elseif self._pose == "sit" then
		mob_class.set_animation (self, "sit")
	elseif xz > 0.0025 then
		if self._pose == "crouching" then
			mob_class.set_animation (self, "crouch")
		else
			mob_class.set_animation (self, "walk")
		end
	else
		mob_class.set_animation (self, "stand")
	end
end

function ocelot:set_animation (anim, custom_frame)
	return nil
end

function ocelot:set_animation_speed (custom_speed)
	local anim = self._current_animation
	if not anim then
		return
	end
	local name = anim .. "_speed"
	local normal_speed = self.animation[name]
		or self.animation.speed_normal
		or 25
	if anim ~= "walk" and self.anim ~= "run" then
		self.object:set_animation_frame_speed (normal_speed)
		return
	end
	local speed = custom_speed or normal_speed
	local v = self:get_velocity ()
	self.object:set_animation_frame_speed (speed / 4 * v)
end

------------------------------------------------------------------------
-- Ocelot AI.
------------------------------------------------------------------------

local FIVE_DEG = math.rad (5)

local function ocelot_follow_shyly (self, self_pos, dtime)
	if self._following_shyly then
		-- Can this mob continue to follow its target?
		local pos = self._following_shyly:get_pos ()
		local must_stop = false
		if not pos then
			self._following_shyly = nil
			-- TemptGoal.java: calmDown = 100 ticks.
			self.follow_cooldown = 5
			self:halt_in_tracks ()
			self._pose = "walk"
		else
			local distance = vector.distance (self_pos, pos)
			local player = self._following_shyly
			if not self:follow_holding (player) then
				distance = nil
			end
			local pitch = player:get_look_vertical ()
			local yaw = player:get_look_horizontal ()
			local v = player:get_velocity ()
			local diff_pitch = math.abs (pitch - self._f_last_view_pitch)
			local diff_yaw = math.abs (yaw - self._f_last_view_yaw)
			local alarmed = false
			-- TemptGoal.canUse: only a player within 6 blocks
			-- can scare this mob.
			if distance and distance < 6.0
				and (diff_pitch > FIVE_DEG or diff_yaw > FIVE_DEG
					or vector.length (v) > 2.0) then
				alarmed = not self._trusts_players
					and not self.tamed
			end
			if not distance
				or distance > self.follow_distance
				or distance <= self.stop_distance
				or alarmed then
				if not distance or distance > self.follow_distance
					or alarmed then
					self._following_shyly = nil
					self.follow_cooldown = 5
				end
				self:halt_in_tracks ()
				self:cancel_navigation ()
				self._pose = "walk"
				must_stop = true
			end
			self._f_last_view_pitch = pitch
			self._f_last_view_yaw = yaw
		end
		if self._following_shyly and not must_stop
			and self:check_timer ("ocelot_repath", 0.30) then
			-- check_head_swivel is responsible for
			-- looking at the target.
			self:gopath (pos, self.follow_bonus)
			self._pose = "crouching"
		end
		return true
	elseif self.follow and not self.follow_cooldown and not self.tamed then
		for player in mcl_util.connected_players () do
			local distance = vector.distance (player:get_pos (), self_pos)
			if distance < self.follow_distance
				and distance > self.stop_distance and self:follow_holding (player) then
				self._following_shyly = player
				self._f_last_view_pitch = player:get_look_vertical ()
				self._f_last_view_yaw = player:get_look_horizontal ()
				return "_following_shyly"
			end
		end
	end
	return false
end

function ocelot:attack_end ()
	mob_class.attack_end (self)
	self._sprinting = false
	self._crouching = false
end

function ocelot:attack_null (attach_pos, self_pos, dtime, target_pos, line_of_sight)
	if not self.attacking then
		self._attack_cooldown = 1
		self._leaping = false
		self.attacking = true
	end

	self._attack_cooldown = math.max (0, self._attack_cooldown - dtime)

	local moveresult = self._moveresult
	if self._leaping then
		if moveresult.touching_ground
			or moveresult.standing_on_object then
			self._leaping = false
		end
		return
	end

	local width = self.collisionbox[4] - self.collisionbox[1]
	local dist = vector.distance (attach_pos, target_pos)
	local chance = math.round (5 * dtime / 0.05)
	local r = math.random (chance)

	-- Possibly leap at the target if appropriate.
	if dist > 2 and dist < 4 and r == 1
		and (moveresult.touching_ground
			or moveresult.standing_on_object) then
		self._leaping = true
		self:cancel_navigation ()
		self:halt_in_tracks ()
		-- LeapAtTargetGoal (this, 0.3F): horizontal direction *
		-- 0.4 plus 0.2 * current velocity; vertical 0.3.
		local dx = target_pos.x - attach_pos.x
		local dz = target_pos.z - attach_pos.z
		local len = math.sqrt (dx * dx + dz * dz)
		local v = self.object:get_velocity ()
		local leap = vector.new (0, 6.0, 0)
		if len > 1.0e-3 then
			leap.x = dx / len * 8.0 + v.x * 0.2
			leap.z = dz / len * 8.0 + v.z * 0.2
		end
		self.object:set_velocity (leap)
		return
	end

	local reach = width * 2
	local movement_factor = 0.8
	self._sprinting = false
	self._crouching = false
	-- OcelotAttackGoal.java: 1.33 / 0.6 / 0.8.
	if dist > reach and dist < 4.0 then
		movement_factor = 1.33
		self._pose = "walk"
		self._crouching = false
		self._sprinting = true
	elseif dist < 15 then
		movement_factor = 0.6
		self._pose = "crouching"
		self._crouching = true
		self._sprinting = false
	end

	if self:check_timer ("ocelot_repath", 0.25) then
		self:gopath (target_pos, movement_factor)
	end
	if self._attack_cooldown == 0
		and dist <= reach
		and line_of_sight then
		self._attack_cooldown = 1
		self:custom_attack ()
	end
end

function ocelot:check_avoid (self_pos, dtime)
	if self._trusts_players or self.tamed then
		self.avoiding = nil
		return nil
	end
	return mob_class.check_avoid (self, self_pos, dtime)
end

ocelot.ai_functions = {
	ocelot_follow_shyly,
	ocelot.check_avoid,
	mob_class.check_attack,
	mob_class.check_breeding,
	mob_class.check_pace,
}

ocelot._targeting_rules = {
	mcl_mobs.build_nearest_target_rule ("mobs_mc:chicken", {
		"mobs_mc:chicken",
	}, nil, nil, false),
}

------------------------------------------------------------------------
-- Ocelot interaction.
------------------------------------------------------------------------

-- Ocelots need not trust players to breed (Animal.mobInteract).
function ocelot:breeding_possible ()
	return mob_class.breeding_possible (self)
end

-- Cat.canMate: only tame cats breed.
local function cat_breeding_possible (self)
	return self.tamed and mob_class.breeding_possible (self)
end

function ocelot:on_breed (parent2)
	local pos = self.object:get_pos ()
	local obj = mcl_mobs.spawn_child (pos, self.name)
	if obj then
		local entity = obj:get_luaentity ()
		entity.persistent = true
	end
	-- Sidestep texture assignment or default spawning mechanics.
end

function ocelot:on_rightclick (clicker)
	if not clicker or not clicker:is_player () then
		return
	end
	local item = clicker:get_wielded_item ()
	local self_pos = self.object:get_pos ()
	-- Ocelot.java: distanceToSqr < 9.0.
	if not self._trusts_players and self._following_shyly
		and vector.distance (self_pos, clicker:get_pos ()) < 3.0
		and table.indexof (food, item:get_name ()) ~= -1 then
		-- Try to gain trust of ocelot.
		if not core.is_creative_enabled (clicker:get_player_name ()) then
			item:take_item ()
			clicker:set_wielded_item (item)
		end

		local random = math.random (3)
		if random == 3 then
			self._trusts_players = true
			self.persistent = true
			mcl_mobs.effect (vector.offset (self_pos, 0, 0.7, 0),
				5, "heart.png", 2, 4, 2.0, 0.1)
		else
			mcl_mobs.effect (vector.offset (self_pos, 0, 0.7, 0),
				5, "mcl_particles_mob_death.png^[colorize:#000000:255",
				2, 4, 2.0, 0.1)
		end
	elseif table.indexof (food, item:get_name ()) ~= -1
	-- Begin breeding.
		and self:feed_tame (clicker, nil, true, false, false, nil) then
		return
	end
end

-- Ocelot.removeWhenFarAway: untrusting ocelots older than 2400 ticks.
function ocelot:despawn_allowed ()
	return self._age > 120
		and mob_class.despawn_allowed (self)
end

mcl_mobs.register_mob ("mobs_mc:ocelot", ocelot)

------------------------------------------------------------------------
-- Cat.
------------------------------------------------------------------------

local cat_default_textures = {
	"mobs_mc_cat_black.png",
	"mobs_mc_cat_british_shorthair.png",
	"mobs_mc_cat_calico.png",
	"mobs_mc_cat_jellie.png",
	"mobs_mc_cat_persian.png",
	"mobs_mc_cat_ragdoll.png",
	"mobs_mc_cat_red.png",
	"mobs_mc_cat_siamese.png",
	"mobs_mc_cat_tabby.png",
	"mobs_mc_cat_white.png",
}

local cat_witch_hut_textures = {
	"mobs_mc_cat_all_black.png",
}

local cat_full_moon_textures = {
	"mobs_mc_cat_all_black.png",
	"mobs_mc_cat_black.png",
	"mobs_mc_cat_british_shorthair.png",
	"mobs_mc_cat_calico.png",
	"mobs_mc_cat_jellie.png",
	"mobs_mc_cat_persian.png",
	"mobs_mc_cat_ragdoll.png",
	"mobs_mc_cat_red.png",
	"mobs_mc_cat_siamese.png",
	"mobs_mc_cat_tabby.png",
	"mobs_mc_cat_white.png",
}

local cat = table.merge (ocelot, {
	description = S("Cat"),
	textures = cat_default_textures,
	can_despawn = true,
	tamed = false,
	runaway = false,
	visual_size = { x = 1.75 * 0.8, y = 1.75 * 0.8, },
	chase_owner_distance = 10.0,
	stop_chasing_distance = 5.0,
	drops = {
		{
			name = "mcl_mobitems:string",
			chance = 1,
			min = 0,
			max = 2,
		},
	},
	sounds = {
		random = "mobs_mc_cat_idle",
		damage = "mobs_mc_cat_hiss",
		death = "mobs_mc_ocelot_hurt",
		eat = "mobs_mc_animal_eat_generic",
		distance = 16,
	},
	_spawn_category = "creature",
	head_eye_height = 0.35,
	-- TamableAnimalPanicGoal (1.5).
	run_bonus = 1.5,
	-- AgeableMob.finalizeSpawn: AgeableMobGroupData (true), 0.05.
	_group_baby_chance = 0.05,
	_sitting_on_block_timeout = 0,
	_sitting_on_bed_timeout = 0,
	_age = 0.0,
	_is_ocelot_tamable = true,
})

------------------------------------------------------------------------
-- Cat AI.
------------------------------------------------------------------------

function cat:bed_occupied (bedpos)
	for object in core.objects_inside_radius (bedpos, 2.0) do
		local entity = object:get_luaentity ()
		if entity and entity.name == "mobs_mc:cat"
			and entity ~= self
			and entity._pose == "repose" then
			return true
		end
	end
	return false
end

local cat_loot_table = {
	stacks_min = 1,
	stacks_max = 1,
	items = {
		{
			weight = 10,
			itemstring = "mcl_mobitems:rabbit_hide",
		},
		{
			weight = 10,
			itemstring = "mcl_mobitems:rabbit_foot",
		},
		{
			weight = 10,
			itemstring = "mcl_mobitems:chicken",
		},
		{
			weight = 10,
			itemstring = "mcl_mobitems:feather",
		},
		{
			weight = 10,
			itemstring = "mcl_mobitems:rotten_flesh",
		},
		{
			weight = 10,
			itemstring = "mcl_mobitems:string",
		},
		-- {
		-- 	weight = 2,
		-- 	itemstack = ItemStack ("mcl_mobitems:phantom_membrane"),
		-- },
	},
}

local pr = PcgRandom (os.time () + -431)

function cat:give_wakeup_gift (self_pos)
	local tod = core.get_timeofday ()
	if tod >= 0.25 and tod <= 0.30 and math.random () < 0.7 then
		local rx = math.random (0, 10) - 5
		-- Cat.giveMorningGift: y + nextInt (5) - 2.
		local ry = math.random (0, 4) - 2
		local rz = math.random (0, 10) - 5
		local pos = vector.offset (self_pos, rx, ry, rz)
		local class = self:gwp_classify_for_movement (pos)
		local dy = 0
		while class == "OPEN" and dy < 128 do
			dy = dy + 1
			pos.y = pos.y - 1
			class = self:gwp_classify_for_movement (pos)
		end
		if class == "WALKABLE" then
			self:teleport_safely (pos)
		end
		local loot = mcl_loot.get_loot (cat_loot_table, pr)
		if #loot >= 1 then
			mcl_util.drop_item_stack (self.object:get_pos (), loot[1])
		end
	end
end

local function cat_sleep_with_owner (self, self_pos, dtime)
	if not self.tamed then
		return false
	elseif self.order == "sit" then
		return false
	elseif self._sleeping_with_owner then
		local owner = core.get_player_by_name (self.owner)
		if not owner then
			self:cancel_navigation ()
			self:halt_in_tracks ()
			self._pose = "walk"
			self._sleeping_with_owner = false
			return true
		end
		local bed_occupied = self:bed_occupied (self._bed)
		if not mcl_beds.player[self.owner] or bed_occupied then
			self:cancel_navigation ()
			self:halt_in_tracks ()
			self._pose = "walk"

			if not mcl_beds.player[self.owner] then
				self:give_wakeup_gift (self_pos)
			end
			self._sleeping_with_owner = false
			return true
		end
		if self:navigation_finished () then
			self._pose = "repose"
		end
		return true
	else
		local owner = self.owner
			and core.get_player_by_name (self.owner)
		if not owner then
			return false
		end
		local owner_pos = owner:get_pos ()
		if not mcl_beds.player[self.owner]
			or vector.distance (owner_pos, self_pos) > 10 then
			return false
		end
		local pos = {
			x = math.floor (owner_pos.x + 0.5),
			y = math.floor (owner_pos.y + 0.5),
			z = math.floor (owner_pos.z + 0.5),
		}
		local bed = core.get_node (pos)
		if core.get_item_group (bed.name, "bed") > 0 then
			if string.find (bed.name, "_top") then
				local target_off
					= core.facedir_to_dir (bed.param2)
				pos.x = -target_off.x + pos.x
				pos.y = -target_off.y + pos.y
				pos.z = -target_off.z + pos.z
			end
			if not self:bed_occupied (pos) then
				self._bed = pos
				self:gopath (vector.offset (pos, 0, 1, 0),
						1.1, nil, 0)
				self._sleeping_with_owner = true
				return "_sleeping_with_owner"
			end
		end
	end
end

-- MoveToBlockGoal.findNearestBlock: search layers from VSTART to
-- VRANGE (in the order 0, 1, -1, 2, -2...) and, within each, square
-- rings of increasing radius up to RANGE - 1 for a block satisfying
-- IS_VALID.

local function find_nearest_block (self_pos, range, vstart, vrange, is_valid)
	local base = mcl_util.get_nodepos (self_pos)
	local y = vstart
	while y <= vrange do
		for r = 0, range - 1 do
			local x = 0
			while x <= r do
				local z = (x < r and x > -r) and r or 0
				while z <= r do
					local pos = vector.offset (base, x, y - 1, z)
					if is_valid (pos) then
						return pos
					end
					z = z > 0 and -z or 1 - z
				end
				x = x > 0 and -x or 1 - x
			end
		end
		y = y > 0 and -y or 1 - y
	end
	return nil
end

local function is_empty_block (pos)
	return core.get_node (pos).name == "air"
end

-- MoveToBlockGoal.start: maxStayTicks.
local function random_max_stay ()
	return (math.random (0, math.random (0, 1199) + 1199) + 1200) / 20
end

-- MoveToBlockGoal.tick and canContinueToUse.  ELAPSED corresponds to
-- tryTicks (in seconds): it increases while the target is being
-- approached and decreases while it is occupied.  Return whether the
-- target was reached, or nil if the goal should be abandoned.

local function move_to_block_tick (self, self_pos, dtime, field, speed, is_valid)
	local data = self[field]
	if data.elapsed > 60 or data.elapsed < -data.max_stay
		or not is_valid (data.block) then
		return nil
	end
	local target = vector.offset (data.block, 0, 1, 0)
	if vector.distance (self_pos, target) >= 1.0 then
		data.elapsed = data.elapsed + dtime
		if self:check_timer ("cat_repath", 2.0) then
			self:gopath (target, speed)
		end
		return false
	else
		data.elapsed = data.elapsed - dtime
		return true
	end
end

local function is_chest (name)
	return name == "mcl_chests:chest_small"
		or name == "mcl_chests:chest_left"
		or name == "mcl_chests:chest_right"
end

-- CatLieOnBlockGoal: #cats_can_lie_on, i.e. beds.
local function cat_can_lie_on (pos)
	local node = core.get_node (pos)
	return core.get_item_group (node.name, "bed") > 0
		and is_empty_block (vector.offset (pos, 0, 1, 0))
end

-- CatSitOnBlockGoal: closed chests, lit furnaces, and the foot of a
-- bed.
local function cat_can_sit_on (pos)
	if not is_empty_block (vector.offset (pos, 0, 1, 0)) then
		return false
	end
	local name = core.get_node (pos).name
	if is_chest (name) then
		return not mcl_chests.is_opened (pos)
	elseif name == "mcl_furnaces:furnace_active" then
		return true
	elseif core.get_item_group (name, "bed") > 0 then
		return string.find (name, "_top") == nil
	end
	return false
end

-- CatLieOnBlockGoal (this, 1.1, 8): search range 8, vertical range
-- -2 to 6, a fresh search every 40 goal evaluations (80 ticks).
local function cat_lie_on_bed (self, self_pos, dtime)
	if not self.tamed or self.order == "sit" then
		return false
	elseif self._target_bed then
		local reached = move_to_block_tick (self, self_pos, dtime,
						    "_target_bed", 1.1,
						    cat_can_lie_on)
		if reached == nil then
			self._target_bed = nil
			self:cancel_navigation ()
			self:halt_in_tracks ()
			self._pose = "walk"
			return false
		elseif reached then
			self:cancel_navigation ()
			self:halt_in_tracks ()
			self._pose = "repose"
		else
			self._pose = "walk"
		end
		return true
	else
		local rem = self._sitting_on_bed_timeout - dtime
		self._sitting_on_bed_timeout = math.max (0, rem)

		if rem <= 0 then
			self._sitting_on_bed_timeout = 4.0
			local block = find_nearest_block (self_pos, 8, -2, 6,
							  cat_can_lie_on)
			if block then
				self._target_bed = {
					block = block,
					elapsed = 0,
					max_stay = random_max_stay (),
				}
				self:gopath (vector.offset (block, 0, 1, 0), 1.1)
				return "_target_bed"
			end
		end
		return false
	end
end

-- CatSitOnBlockGoal (this, 0.8): search range 8, vertical range 1,
-- a fresh search every 10 to 20 seconds.
local function cat_sit_on_block (self, self_pos, dtime)
	if not self.tamed or self.order == "sit" then
		return false
	elseif self._target_block then
		local reached = move_to_block_tick (self, self_pos, dtime,
						    "_target_block", 0.8,
						    cat_can_sit_on)
		if reached == nil then
			self._target_block = nil
			self:cancel_navigation ()
			self:halt_in_tracks ()
			self._pose = "walk"
			return false
		elseif reached then
			self:cancel_navigation ()
			self:halt_in_tracks ()
			self._pose = "sit"
		else
			self._pose = "walk"
		end
		return true
	else
		local rem = self._sitting_on_block_timeout - dtime
		self._sitting_on_block_timeout = math.max (0, rem)

		if rem <= 0 then
			self._sitting_on_block_timeout = 10 + pr:next (0, 199) / 20
			local block = find_nearest_block (self_pos, 8, 0, 1,
							  cat_can_sit_on)
			if block then
				self._target_block = {
					block = block,
					elapsed = 0,
					max_stay = random_max_stay (),
				}
				self:gopath (vector.offset (block, 0, 1, 0), 0.8)
				return "_target_block"
			end
		end
		return false
	end
end

cat.breeding_possible = cat_breeding_possible

function cat:ai_step (dtime)
	ocelot.ai_step (self, dtime)
end

cat.ai_functions = {
	mob_class.check_frightened,
	mob_class.sit_if_ordered,
	cat_sleep_with_owner,
	ocelot_follow_shyly,
	ocelot.check_avoid,
	cat_lie_on_bed,
	mob_class.check_travel_to_owner,
	cat_sit_on_block,
	mob_class.check_attack,
	mob_class.check_breeding,
	mob_class.check_pace,
}

local function cat_wild_p (self)
	if self.tamed then
		return false
	end
	return true
end

cat._targeting_rules = {
	mcl_mobs.build_nearest_target_rule ("mobs_mc:rabbit", {
		"mobs_mc:rabbit",
	}, cat_wild_p, nil, false),
}

------------------------------------------------------------------------
-- Cat visuals.
------------------------------------------------------------------------

local function any_witch_hut (pos)
	local pieces = mcl_levelgen.get_structures_at (pos, false)
	for _, piece in pairs (pieces) do
		if piece.data == "mcl_levelgen:swamp_hut" then
			return true
		end
	end
	return false
end

function cat:any_witch_hut ()
	local self_pos = self.object:get_pos ()
	return any_witch_hut (mcl_util.get_nodepos (self_pos))
end

function cat:update_textures ()
	local texturelist = cat_default_textures
	if self:any_witch_hut () then
		texturelist = cat_witch_hut_textures
	elseif mcl_moon.get_moon_phase () == 0 then
		texturelist = cat_full_moon_textures
	end

	self.texture_list = texturelist
	if not self._default_texture then
		local r = pr:next (1, #texturelist)
		self._default_texture = texturelist[r]
	end
	local texture = self._default_texture
	if self.tamed then
		local color = self._collar_color or "#FF0000"
		texture = table.concat ({
			texture,
			"^(mobs_mc_cat_collar.png^[colorize:",
			color,
			":192)",
		})
	end
	self.base_texture = {
		texture,
	}
	self.base_mesh = self.initial_properties.mesh
	self.base_size = self.initial_properties.visual_size
	self.base_colbox = self.initial_properties.collisionbox
	self.base_selbox = self.initial_properties.selectionbox
end

function cat:who_are_you_looking_at ()
	if self._pose == "repose" then
		self._locked_object = nil
	else
		mob_class.who_are_you_looking_at (self)
	end
end

------------------------------------------------------------------------
-- Cat breeding.
------------------------------------------------------------------------

function cat:on_breed (parent2)
	local self_pos = self.object:get_pos ()
	local child = mcl_mobs.spawn_child (self_pos, self.name)
	if child then
		local ent_c = child:get_luaentity ()
		-- Use texture of one of the parents
		local p = math.random (1, 2)
		if p == 1 then
			ent_c.base_texture = self.base_texture
			ent_c._default_texture = self._default_texture
			ent_c._collar_color = self._collar_color
		else
			ent_c.base_texture = parent2.base_texture
			ent_c._default_texture = parent2._default_texture
			ent_c._collar_color = parent2._collar_color
		end
		ent_c:set_textures (ent_c.base_texture)
		ent_c.tamed = true
		ent_c.owner = self.owner
	end
end

------------------------------------------------------------------------
-- Cat interaction.
------------------------------------------------------------------------

-- Collar colors
local colors = {
	["unicolor_black"] = "#000000",
	["unicolor_blue"] = "#0000BB",
	["unicolor_dark_orange"] = "#663300", -- brown
	["unicolor_cyan"] = "#01FFD8",
	["unicolor_dark_green"] = "#005B00",
	["unicolor_grey"] = "#C0C0C0",
	["unicolor_darkgrey"] = "#303030",
	["unicolor_green"] = "#00FF01",
	["unicolor_red_violet"] = "#FF05BB", -- magenta
	["unicolor_orange"] = "#FF8401",
	["unicolor_light_red"] = "#FF65B5", -- pink
	["unicolor_red"] = "#FF0000",
	["unicolor_violet"] = "#5000CC",
	["unicolor_white"] = "#FFFFFF",
	["unicolor_yellow"] = "#FFFF00",
	["unicolor_light_blue"] = "#B0B0FF",
}

local cat_food = {
	"mcl_fishing:fish_raw",
	"mcl_fishing:salmon_raw",
}

function cat:actionable_on_rightclick (clicker)
	local wielditem = clicker:get_wielded_item ()
	local wield_food = table.indexof(cat_food, wielditem:get_name()) ~= -1
	return self.tamed or wield_food
end

function cat:on_rightclick (clicker)
	if not clicker or not clicker:is_player () then
		return
	end
	local item = clicker:get_wielded_item ()
	local self_pos = self.object:get_pos ()
	local name = item:get_name ()
	local playername = clicker:get_player_name ()
	local creative = core.is_creative_enabled (playername)

	if self.tamed and self.owner == playername then
		if core.get_item_group (name, "dye") == 1 then
			-- Dye if possible (Cat.java: only if the color
			-- differs).
			local consumed = false
			for group, color in pairs (colors) do
				-- Check if color is supported
				if core.get_item_group (name, group) == 1
					and color ~= (self._collar_color or "#FF0000") then
					self._collar_color = color
					consumed = true
				end
			end
			if consumed then
				self:update_textures ()
				self:set_textures (self.base_texture)
				if not creative then
					item:take_item ()
					clicker:set_wielded_item (item)
				end
				return
			end
		elseif table.indexof (cat_food, item:get_name ()) ~= -1 then
			-- Begin breeding.
			-- Cat.java: feed (..., 1.0F, 1.0F), i.e. the
			-- food's nutrition.
			local heal = core.get_item_group (name, "eatable")
			if self:feed_tame (clicker, heal, true, false, false, nil) then
				return
			end
		end

		-- Otherwise sit or stand.
		if self.order == "sit" then
			self.order = ""
		else
			self:stay ()
		end
	elseif not self.tamed
		and table.indexof (cat_food, item:get_name ()) ~= -1 then
		local r = pr:next (1, 3)
		if r == 1 then
			self:just_tame (self_pos, clicker)
			self:update_textures ()
			self:set_textures (self.base_texture)
			self.order = "sit"
		else
			mcl_mobs.effect (vector.offset (self_pos, 0, 0.7, 0),
					5, "mcl_particles_mob_death.png^[colorize:#000000:255",
					2, 4, 2.0, 0.1)
		end
		if not creative then
			item:take_item ()
			clicker:set_wielded_item (item)
		end
		-- Feeding cats fish renders them persistent
		-- independently of taming.
		self.persistent = true
	end
end

------------------------------------------------------------------------
-- Cat mechanics.
------------------------------------------------------------------------

mcl_mobs.register_mob ("mobs_mc:cat", cat)

------------------------------------------------------------------------
-- Cat & Ocelot spawning.
------------------------------------------------------------------------

if mobs_spawn then

local time_since_spawn_attempt = 0

local function is_cat_spawn_position (spawn_pos)
	return mcl_mobs.spawning_possible (spawn_pos, "mobs_mc:cat")
end

core.register_globalstep (function (dtime)
	time_since_spawn_attempt = time_since_spawn_attempt + dtime
	if time_since_spawn_attempt < 60 then
		return
	end
	time_since_spawn_attempt = 0

	for player in mcl_util.connected_players () do
		local pos = player:get_pos ()
		local dx = pr:next (8, 31) * (pr:next (0, 1) == 0 and -1 or 1)
		local dz = pr:next (8, 31) * (pr:next (0, 1) == 0 and -1 or 1)
		local spawn_pos = vector.offset (pos, dx, 0, dz)
		spawn_pos.x = math.floor (spawn_pos.x + 0.5)
		spawn_pos.y = math.floor (spawn_pos.y + 0.5)
		spawn_pos.z = math.floor (spawn_pos.z + 0.5)

		if is_cat_spawn_position (spawn_pos) then
			if mcl_villages.get_poi_heat (spawn_pos) >= 4 then
				-- Count nearby homes and cats.
				local count_homes = 0
				local aa = vector.offset (spawn_pos, -48, -8, -48)
				local bb = vector.offset (spawn_pos, 48, 8, 48)
				local pois = mcl_villages.get_pois_in_by_nodepos (aa, bb)
				for _, poi in pairs (pois) do
					local def = mcl_villages.registered_pois[poi.data]
					if def and def.is_home then
						count_homes = count_homes + 1
					end
				end
				if count_homes >= 5 then
					local count_cats = 0
					for obj in core.objects_in_area (aa, bb) do
						local entity = obj:get_luaentity ()
						if entity and entity.name == "mobs_mc:cat" then
							count_cats = count_cats + 1
							if count_cats > 4 then
								break
							end
						end
					end

					if count_cats <= 4 then
						mcl_mobs.spawn_abnormally (spawn_pos, "mobs_mc:cat")
					end
				end
			-- Cat spawning in swamp huts is also
			-- conducted from the same timer as spawning
			-- in villages, but as when spawned by the
			-- natural spawning system, a grass block is
			-- required for spawning to succeed.
			--
			-- https://minecraft.wiki/w/Cat#Natural_spawning
			elseif any_witch_hut (spawn_pos) then
				local count_cats = 0
				local aa = vector.offset (spawn_pos, -16, -8, -16)
				local bb = vector.offset (spawn_pos, 16, 8, 16)
				for obj in core.objects_in_area (aa, bb) do
					local entity = obj:get_luaentity ()
					if entity and entity.name == "mobs_mc:cat" then
						count_cats = count_cats + 1
						break
					end
				end
				if count_cats < 1 then
					mcl_mobs.spawn_abnormally (spawn_pos, "mobs_mc:cat")
				end
			end
		end
	end
end)

end

-- spawn eggs
mcl_mobs.register_egg("mobs_mc:ocelot", S("Ocelot"), "#efde7d", "#564434", 0)
mcl_mobs.register_egg("mobs_mc:cat", S("Cat"), "#AA8755", "#505438", 0)

------------------------------------------------------------------------
-- Modern Cat spawning.
------------------------------------------------------------------------

local cat_spawner_swamp_hut = table.merge (mobs_mc.animal_spawner, {
	name = "mobs_mc:cat",
	weight = 1,
	pack_min = 1,
	pack_max = 1,
	biomes = {},
	structures = {
		"mcl_levelgen:swamp_hut",
	},
})

mcl_mobs.register_spawner (cat_spawner_swamp_hut)

------------------------------------------------------------------------
-- Modern Ocelot spawning.
------------------------------------------------------------------------

local default_spawner = mcl_mobs.default_spawner

-- Yes, ozelots are monsters in Minecraft.
local ocelot_spawner = table.merge (mobs_mc.monster_spawner, {
	name = "mobs_mc:ocelot",
	weight = 2,
	pack_min = 1,
	pack_max = 3,
	biomes = {
		"Jungle",
	},
})

function ocelot_spawner:floor_is_grass_or_leaves (node_pos, node_cache)
	local node = self:get_node (node_cache, -1, node_pos)
	return core.get_item_group (node.name, "leaves") > 0
		or core.get_item_group (node.name, "grass_block") > 0
end

function ocelot_spawner:test_spawn_position (spawn_pos, node_pos, sdata, node_cache,
					     spawn_flag)
	-- Ocelot.checkOcelotSpawnRules: random.nextInt (3) != 0.
	-- Monster spawning never takes place in peaceful.
	return mcl_vars.difficulty ~= 0
		and math.random (3) ~= 1
		and spawn_pos.y >= 0.5
		and self:floor_is_grass_or_leaves (node_pos, node_cache)
		and default_spawner.test_spawn_position (self, spawn_pos,
							 node_pos, sdata,
							 node_cache,
							 spawn_flag)
end

function ocelot_spawner:get_misc_spawning_description ()
	return S ("This mob will spawn infrequently on grass or leaves when no obstructions exist within a volume @1 nodes in size around the center of such a node's upper surface.", self:describe_mob_collision_box ())
end

function ocelot_spawner:describe_additional_spawning_criteria ()
	return nil
end

local ocelot_spawner_bamboo_jungle = table.merge (ocelot_spawner, {
	name = "mobs_mc:ocelot",
	weight = 2,
	pack_min = 1,
	pack_max = 1,
	biomes = {
		"BambooJungle",
	},
})

mcl_mobs.register_spawner (ocelot_spawner)
mcl_mobs.register_spawner (ocelot_spawner_bamboo_jungle)
