--License for code WTFPL and otherwise stated in readmes

local S = core.get_translator("mobs_mc")
local mob_class = mcl_mobs.mob_class

local bat = {
	description = S("Bat"),
	-- Bat.isFlapping (game event flap)
	_is_flapping = mcl_mobs.flap_every (10, function (self)
		return not self._resting
	end),
	type = "animal",
	_spawn_category = "ambient",
	can_despawn = true,
	hp_min = 6,
	hp_max = 6,
	head_eye_height = 0.45,
	collisionbox = {-0.25, 0.0, -0.25, 0.25, 0.9, 0.25},
	visual = "mesh",
	mesh = "mobs_mc_bat.b3d",
	textures = {
		{"mobs_mc_bat.png"},
	},
	sounds = {
		random = "mobs_mc_bat_idle",
		damage = "mobs_mc_bat_hurt",
		death = "mobs_mc_bat_death",
		distance = 16,
	},
	movement_speed = 14.0,
	animation = {
		stand_speed = 60,
		stand_start = 0,
		stand_end = 40,
		hang_start = 60,
		hang_end = 60,
		hang_speed = 1,
	},
	_no_fall_damage = true,
	makes_footstep_sound = false,
	can_ride_cart = false,
	can_ride_boat = false,
	gravity_drag = 0.6,
	_apply_gravity_drag_on_ground = true,
	pushable = false,
}

------------------------------------------------------------------------
-- Bat movement and "AI".
------------------------------------------------------------------------

local function is_opaque_solid (node)
	local node = core.get_node (node)
	local def = core.registered_nodes[node.name]
	return def and def.groups.opaque and def.groups.solid
end

local function is_walkable (node)
	local node = core.get_node (node)
	local def = core.registered_nodes[node.name]
	return def and def.walkable
end

local function signum (number)
	return (number == -0.0 or number < 0) and -1
		or (number == 0.0 and 0.0 or 1)
end

local scale_chance = mcl_mobs.scale_chance

function bat:motion_step (dtime, moveresult, attach_pos)
	local h_scale, v_scale
		= mob_class.motion_step (self, dtime, moveresult, attach_pos)
	local old_y = attach_pos.y
	local abovepos = {
		x = math.floor (attach_pos.x + 0.5),
		y = math.floor (attach_pos.y + 0.5) + 1,
		z = math.floor (attach_pos.z + 0.5),
	}

	if self._resting then
		-- Verify that the block above is still walkable and
		-- whole.
		if not is_opaque_solid (abovepos) then
			self._resting = false
			self:set_animation ("stand")
		else
			-- Be startled off by players wihin 4 nodes.
			for player in mcl_util.connected_players (attach_pos, 4) do
				self._resting = false
				self:set_animation ("stand")
				break
			end
		end

		if self._resting then
			self:set_animation ("hang")
			self.object:set_pos ({
				x = attach_pos.x,
				y = abovepos.y - 0.5 - 0.9,
				z = attach_pos.z,
			})
			self.object:set_velocity (vector.zero ())
			-- Rotate randomly.
			if math.random (scale_chance (200, dtime)) == 1 then
				self:set_yaw (math.random () * math.pi * 2)
			end
			return
		end
	end

	attach_pos.y = attach_pos.y + (self.collisionbox[5] - self.collisionbox[2]) / 2
	-- Bats feature no true AI and simply float aimlessly,
	-- applying input directly to their velocity.
	local target_pos = self._target_pos

	if not target_pos
		or is_walkable (target_pos)
		or math.random (scale_chance (30, dtime)) == 1
		or vector.distance (attach_pos, target_pos) <= 2.0 then
		-- Switch target positions.
		local x = math.random (0, 6) - math.random (0, 6)
		local z = math.random (0, 6) - math.random (0, 6)
		local y = math.random (0, 5) - 2.0
		attach_pos.y = old_y
		target_pos = vector.offset (attach_pos, x, y, z)
		target_pos.x = math.floor (target_pos.x + 0.5)
		target_pos.y = math.floor (target_pos.y)
		target_pos.z = math.floor (target_pos.z + 0.5)
	end

	attach_pos.y = old_y
	self._target_pos = target_pos
	local v = self.object:get_velocity ()
	local dx = target_pos.x + 0.5 - attach_pos.x
	local dy = target_pos.y + 0.1 - attach_pos.y
	local dz = target_pos.z + 0.5 - attach_pos.z
	local x_mod = (signum (dx) * 10 - v.x) * 0.1 * h_scale
	local y_mod = (signum (dy) * 14 - v.y) * 0.1 * v_scale
	local z_mod = (signum (dz) * 10 - v.z) * 0.1 * h_scale
	v.x = v.x + x_mod
	v.y = v.y + y_mod
	v.z = v.z + z_mod
	self.object:set_velocity (v)
	local yaw = math.atan2 (v.z, v.x) - math.pi / 2
	self:set_yaw (yaw)

	if math.random (scale_chance (100, dtime)) == 1
		and is_opaque_solid (abovepos) then
		self._resting = true
	end
	return
end

function bat:run_ai (dtime, moveresult)
	return
end

-- Bat.java: bats are created resting.
function bat:on_spawn ()
	self._resting = true
end

-- Bat.java hurtServer: being hurt startles a resting bat.
function bat:receive_damage (mcl_reason, damage)
	if self._resting then
		self._resting = false
		self:set_animation ("stand")
	end
	return mob_class.receive_damage (self, mcl_reason, damage)
end

mcl_mobs.register_mob ("mobs_mc:bat", bat)

------------------------------------------------------------------------
-- Bat spawning.
------------------------------------------------------------------------

-- spawn eggs
mcl_mobs.register_egg("mobs_mc:bat", S("Bat"), "#4c3e30", "#0f0f0f", 0)

------------------------------------------------------------------------
-- Modern Bat spawning.
------------------------------------------------------------------------

local default_spawner = mcl_mobs.default_spawner

local bat_spawner = {
	name = "mobs_mc:bat",
	spawn_category = "ambient",
	spawn_placement = "ground",
	pack_min = 8,
	pack_max = 8,
	weight = 10,
	biomes = mobs_mc.overworld_biomes,
}

-- #minecraft:bats_spawnable_on = #minecraft:base_stone_overworld.
local bats_spawnable_on = {
	["mcl_core:stone"] = true,
	["mcl_core:granite"] = true,
	["mcl_core:diorite"] = true,
	["mcl_core:andesite"] = true,
	["mcl_deepslate:tuff"] = true,
	["mcl_deepslate:deepslate"] = true,
}

local SURFACE_SCAN_LIMIT = 128

-- Approximate MC's WORLD_SURFACE heightmap test: a position is below
-- the world surface if any non-air node exists above it.
local function below_world_surface (node_pos)
	local v = vector.copy (node_pos)
	for y = node_pos.y + 1, node_pos.y + SURFACE_SCAN_LIMIT do
		v.y = y
		if core.get_node (v).name ~= "air" then
			return true
		end
	end
	return false
end

-- Bat.java checkBatSpawnRules.
function bat_spawner:test_spawn_position (spawn_pos, node_pos, sdata, node_cache,
					  spawn_flag)
	if not below_world_surface (node_pos) then
		return false
	elseif math.random (0, 1) == 0 then
		return false
	end
	-- getMaxLocalRawBrightness (pos) > random.nextInt (4).
	local light = mcl_mobs.get_raw_brightness (node_pos)
	if light > math.random (0, 3) then
		return false
	end
	local below = self:get_node (node_cache, -1, node_pos)
	if not bats_spawnable_on[below.name] then
		return false
	end
	return default_spawner.test_spawn_position (self, spawn_pos, node_pos,
						    sdata, node_cache,
						    spawn_flag)
end

function bat:describe_additional_spawning_criteria ()
	return S ("Spawning will only be successful underground on stone, deepslate or tuff, at light levels between 0 and 3, with lower light levels being more likely.")
end

mcl_mobs.register_spawner (bat_spawner)
