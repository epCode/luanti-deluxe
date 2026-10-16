--MCmobs v0.4
--maikerumine
--made for MC like Survival game
--License for code WTFPL and otherwise stated in readmes

local S = core.get_translator("mobs_mc")
local mob_class = mcl_mobs.mob_class

--###################
--################### VEX
--###################

local vex = {
	description = S("Vex"),
	-- Vex.isFlapping: every TICKS_PER_FLAP = ceil (5 pi / 4) ticks
	_is_flapping = mcl_mobs.flap_every (4),
	type = "monster",
	_spawn_category = "monster",
	attack_type = "null",
	physical = false,
	hp_min = 14,
	hp_max = 14,
	-- Vex.java: xpReward 3 (plus the usual equipment bonus).
	xp_min = 3,
	xp_max = 3,
	head_eye_height = 0.51875,
	bone_eye_height = 2.39532,
	head_swivel = "head",
	collisionbox = {-0.2, 0.0, -0.2, 0.2, 0.8, 0.2},
	visual = "mesh",
	mesh = "mobs_mc_vex.b3d",
	textures = {
		{
			"mobs_mc_vex.png",
		},
	},
	visual_size = {
		x = 1.0,
		y = 1.25,
	},
	damage = 4,
	movement_speed = 14,
	sounds = {
		death = "mobs_mc_vex_death",
		damage = "mobs_mc_vex_hurt",
		distance = 16,
	},
	animation = {
		stand_speed = 25,
		stand_start = 0,
		stand_end = 40,
	},
	_no_fall_damage = true,
	makes_footstep_sound = false,
	can_wield_items = "no_pickup",
	wielditem_drop_probability = 0.0,
	wielditem_info = {
		toollike_position = vector.new (0, 1.8, -1.2),
		toollike_rotation = vector.new (-90, 45, -90),
		bow_position = vector.new (0, 1.8, 0),
		bow_rotation = vector.new (-90, 45, -90),
		crossbow_position = vector.new (0, 2.0, -0.44),
		crossbow_rotation = vector.new (0, 0, -45),
		blocklike_position = vector.new (0, 1.8, -0.5),
		blocklike_rotation = vector.new (0, 45, 180),
		position = vector.new (0.2, 1.8, -0.7),
		rotation = vector.new (90, 0, 0),
		bone = "wield_item",
		rotate_bone = true,
	},
	-- Yes, vexes really ascend in water.
	floats = 1,
	-- EntityTypes.VEX: fireImmune.
	_fire_resistant = true,
	fire_resistant = true,
	fire_damage_resistant = true,
	_charging = false,
}

------------------------------------------------------------------------
-- Vex visuals.
------------------------------------------------------------------------

function vex:do_custom (dtime)
	-- Glow red while charging (Vex.isCharging).
	if self._charging then
		if self._active_texture_list[1] ~= "mobs_mc_vex_charging.png" then
			self:set_textures ({
				"mobs_mc_vex_charging.png",
			})
		end
	else
		if self._active_texture_list[1] == "mobs_mc_vex_charging.png" then
			self:set_textures ({
				"mobs_mc_vex.png"
			})
		end
	end
end

function vex:wielditem_transform (info, stack)
	local rot, pos, size
		= mob_class.wielditem_transform (self, info, stack)

	size.x = size.x / 3
	size.y = size.y / 3
	return rot, pos, size
end

------------------------------------------------------------------------
-- Vex mechanics.
------------------------------------------------------------------------

local pr = PcgRandom (os.time () - 30)

function vex:on_spawn ()
	local self_pos = self.object:get_pos ()
	local mob_factor = mcl_worlds.get_special_difficulty (self_pos)
	self:set_wielditem (ItemStack ("mcl_tools:sword_iron"))
	self:enchant_default_weapon (mob_factor, pr)
end

------------------------------------------------------------------------
-- Vex movement.
------------------------------------------------------------------------

-- Vexes do not sustain environmental damage from any source, whether
-- lava, drowning, or suffocation.

function vex:apply_environment_damage (_, _, _, _, _)
	return false
end

local AIR_FRICTION = mcl_mobs.AIR_FRICTION
local AIR_FRICTION_Y = 0.98
local pow_by_step = mcl_mobs.pow_by_step

function vex:motion_step (dtime, moveresult, attach_pos)
	if not moveresult then
		return
	end
	local v = self.object:get_velocity ()
	local p, f

	p = pow_by_step (AIR_FRICTION, dtime)
	f = pow_by_step (AIR_FRICTION_Y, dtime)

	v.x = v.x * p
	v.y = v.y * f
	v.z = v.z * p
	self.object:set_velocity (v)
end

function vex:do_go_pos (dtime, moveresult)
	local self_pos = self.object:get_pos ()
	local target = self.movement_target or vector.zero ()
	local d = vector.distance (target, self_pos)

	local v = self.object:get_velocity ()
	-- VexMoveControl: arrival within the bounding box's average
	-- dimension halves velocity and ends the movement.
	if d < self._bbox_size then
		self.object:set_velocity (vector.multiply (v, 0.5))
		self:cancel_navigation ()
	else
		local modifier = self.movement_velocity
			/ self.movement_speed
		local dir = vector.direction (self_pos, target)
		local p = pow_by_step (AIR_FRICTION, dtime)
		local h_scale = (1 - p) / (1 - AIR_FRICTION)
		local f = pow_by_step (AIR_FRICTION_Y, dtime)
		local v_scale = (1 - f) / (1 - AIR_FRICTION_Y)
		local scale = vector.new (h_scale, v_scale, h_scale)
		local fv = vector.multiply (dir, vector.multiply (scale, modifier))
		self.object:add_velocity (fv)

		if self.attack and self.attack:is_valid () then
			local target_pos = mcl_attachments.get_attachment_pos (self.attack)
			self:look_at (target_pos)
		else
			local v = vector.add (fv, v)
			local yaw = math.atan2 (v.z, v.x) - math.pi / 2
			self:set_yaw (yaw)
		end
	end
end

------------------------------------------------------------------------
-- Vex AI.
------------------------------------------------------------------------

local pr = PcgRandom (os.time () + 40)
local scale_chance = mcl_mobs.scale_chance

do
	local cbox = vex.collisionbox
	vex._bbox_size = ((cbox[4] - cbox[1]) + (cbox[5] - cbox[2])
		+ (cbox[6] - cbox[3])) / 3
end

-- MoveControl.hasWanted.
local function vex_has_wanted (self)
	if not self.stupid_target then
		return false
	end
	local self_pos = self.object:get_pos ()
	if vector.distance (self_pos, self.stupid_target) < self._bbox_size then
		self:cancel_navigation ()
		return false
	end
	return true
end

local function boxes_intersect (pos1, box1, pos2, box2)
	return pos1.x + box1[1] < pos2.x + box2[4]
		and pos1.x + box1[4] > pos2.x + box2[1]
		and pos1.y + box1[2] < pos2.y + box2[5]
		and pos1.y + box1[5] > pos2.y + box2[2]
		and pos1.z + box1[3] < pos2.z + box2[6]
		and pos1.z + box1[6] > pos2.z + box2[3]
end

local vex_pace

-- VexChargeAttackGoal.
function vex:attack_null (attach_pos, self_pos, dtime, target_pos, line_of_sight)
	local target = self.attack

	if not self.attacking then
		self.attacking = true
		self._charging = false
	end

	local distance = vector.distance (attach_pos, target_pos)
	if self._charging then
		-- canContinueToUse.
		if not vex_has_wanted (self) then
			self._charging = false
		else
			local cbox = target:get_properties ().collisionbox
			if boxes_intersect (attach_pos, self.collisionbox,
					    target_pos, cbox) then
				self:custom_attack ()
				self._charging = false
			elseif distance < 3.0 then
				self:go_to_stupidly (mcl_util.target_eye_pos (target), 1.0)
			end
		end
		return
	end

	-- canUse: a 1 in 4 chance every other tick, provided that no
	-- movement is in progress and the target is more than 2
	-- blocks distant.
	self._did_charge_check = not self._did_charge_check
	if self._did_charge_check
		and not vex_has_wanted (self)
		and pr:next (1, scale_chance (4, dtime)) == 1
		and distance > 2.0 then
		self:go_to_stupidly (mcl_util.target_eye_pos (target), 1.0)
		self._charging = true
		return
	end

	-- Otherwise VexRandomMoveGoal may run.
	vex_pace (self, self_pos, dtime)
end

function vex:attack_end ()
	mob_class.attack_end (self)
	self._charging = false
end

function vex:ai_step (dtime)
	mob_class.ai_step (self, dtime)

	if self._summoned_by and not self._summoned_by:is_valid () then
		self._summoned_by = nil
	end

	-- Take constant damage if the vex' life clock ran out
	-- (only for vexes summoned by evokers)
	if self._summoned then
		-- Evoker: setLimitedLife (20 * (30 + nextInt (90))),
		-- after which 1 starvation damage is dealt every 20
		-- ticks.
		if not self._lifetimer then
			self._lifetimer = 30 + math.random (0, 89)
		end
		self._lifetimer = self._lifetimer - dtime
		if self._lifetimer <= 0 then
			self._lifetimer = self._lifetimer + 1.0
			self:damage_mob ("starve", 1)
		end
	end
end

local function is_clear (node)
	local node = core.get_node (node)
	local def = core.registered_nodes[node.name]
	return def and not def.walkable and def.liquidtype == "none"
end

function vex:get_pace_pos (self_pos)
	local basis = self._restriction_center
		or mcl_util.get_nodepos (self_pos)

	for i = 1, 3 do
		local x = basis.x + pr:next (-7, 7)
		local y = basis.y + pr:next (-5, 5)
		local z = basis.z + pr:next (-7, 7)
		local node = vector.new (x, y, z)

		-- VexRandomMoveGoal: the center of the block.
		if is_clear (node) then
			return node
		end
	end
	return nil
end

function vex_pace (self, self_pos, dtime)
	local rc = false
	if self._vex_pacing then
		if not vex_has_wanted (self) then
			self._vex_pacing = false
			return false
		end

		return true
	end

	self._did_check = not self._did_check
	local frequency = scale_chance (4, dtime)
	if self._did_check and not vex_has_wanted (self)
		and pr:next (1, frequency) == 1 then
		local pos = self:get_pace_pos (self_pos)
		if pos then
			self:go_to_stupidly (pos, 0.25)
			if not rc then
				self._vex_pacing = true
				rc = "_vex_pacing"
			end
		end
	end
	return rc
end

vex.ai_functions = {
	mob_class.check_attack,
	vex_pace,
}

local function vex_adopt_owner_target (self, self_pos, dtime, obj, is_current)
	if is_current then
		local dist = self.tracking_distance * self.tracking_distance
		return self:track_current_target (self_pos, dtime, obj, dist, nil)
	elseif self._summoned_by and self._summoned_by:is_valid () then
		local entity = self._summoned_by:get_luaentity ()
		local target = entity._active_target
		local pos = target
			and mcl_attachments.get_attachment_pos (target)
		-- VexCopyOwnerTargetGoal: no range or visibility
		-- requirements.
		if pos
			and self:test_object_and_restriction (target, pos) then
			return target
		end
	end

	return nil
end

vex._targeting_rules = {
	mcl_mobs.build_retaliation_target_rule (mobs_mc.raid_mob_predicate,
						true, {"mobs_mc:vex",}),
	mcl_mobs.build_target_rule ({
		fn = vex_adopt_owner_target,
		on_complete = nil,
	}),
	mcl_mobs.build_nearest_target_rule ("player", nil, nil, nil, nil),
	mcl_mobs.build_alert_receiver_rule (),
}

mcl_mobs.register_mob ("mobs_mc:vex", vex)

------------------------------------------------------------------------
-- Vex spawning.
------------------------------------------------------------------------

-- spawn eggs
mcl_mobs.register_egg ("mobs_mc:vex", S("Vex"), "#7a90a4", "#e8edf1", 0)
