--MCmobs v0.4
--maikerumine
--made for MC like Survival game
--License for code WTFPL and otherwise stated in readmes

local S = core.get_translator("mobs_mc")
local mob_class = mcl_mobs.mob_class
local illager = mobs_mc.illager
local posing_humanoid = mcl_mobs.posing_humanoid
local mob_griefing = mobs_mc.is_mob_griefing_enabled("vindicator")

------------------------------------------------------------------------
-- Vindicator.
------------------------------------------------------------------------

local vindicator = table.merge (illager, table.merge (posing_humanoid, {
	description = S("Vindicator"),
	type = "monster",
	_spawn_category = "monster",
	pathfinding = 1,
	hp_min = 24,
	hp_max = 24,
	xp_min = 5,
	xp_max = 5,
	collisionbox = {-0.3, 0, -0.3, 0.3, 1.95, 0.3},
	visual = "mesh",
	mesh = "mobs_mc_vindicator.b3d",
	head_swivel = "head.control",
	bone_eye_height = 6.61948,
	curiosity = 10,
	textures = {
		{
			"mobs_mc_vindicator.png",
		},
	},
	makes_footstep_sound = true,
	-- Vindicator.java: ATTACK_DAMAGE 5 (+8 from the iron axe).
	damage = 5.0,
	tracking_distance = 12.0,
	view_range = 12.0,
	reach = 2,
	movement_speed = 7.0,
	attack_type = "melee",
	drops = {
		{
			name = "mcl_core:emerald",
			chance = 1,
			min = 0,
			max = 1,
			looting = "common",
			player_kill_only = true,
		},
	},
	animation = {
		stand_start = 0, stand_end = 0, stand_speed = 0,
		walk_start = 0, walk_end = 40, walk_speed = 20,
		punch_start = 41, punch_end = 61, punch_speed = 35,
	},
	can_wield_items = "no_pickup",
	wielditem_info = {
		toollike_position = vector.new (-1.0, 2.0, 0) * 2.75,
		toollike_rotation = vector.new (-180, 0, -135),
		bow_position = vector.new (0, 2.1, 0) * 2.75,
		bow_rotation = vector.new (-7, 7, -45),
		crossbow_position = vector.new (-0.45, 2.0, 0) * 2.75,
		crossbow_rotation = vector.new (90, 135, 90),
		blocklike_position = vector.new (-0.8, 2.0, -0.3) * 2.75,
		blocklike_rotation = vector.new (135, 0, 0),
		position = vector.new (-0.6, 2.0, 0) * 2.75,
		rotation = vector.new (-90, 0, 0),
		bone = "bow",
		rotate_bone = true,
	},
	wielditem_drop_probability = 0.085,
	_humanoid_superclass = illager,
	_is_johnny = false,
	floats = 1,
	pace_bonus = 0.6,
	_banner_bone = "head",
	_banner_bone_position = vector.new (0, 0, -2.556729),
}))

------------------------------------------------------------------------
-- Vindicator visuals.
------------------------------------------------------------------------

local vindicator_poses = {
	default = {
		["arm"] = {},
		["magic.arm.left"] = {
			nil,
			nil,
			vector.zero (),
		},
		["magic.arm.right"] = {
			nil,
			nil,
			vector.zero (),
		},
	},
	attack = {
		["arm"] = {
			nil,
			nil,
			vector.zero (),
		},
		["magic.arm.right"] = {
			vector.zero (),
			vector.new (0, 180, 80),
			vector.new (1.0, 1.0, 1.0),
		},
		["magic.arm.left"] = {
			vector.zero (),
			vector.new (0, 180, 180),
			vector.new (1.0, 1.0, 1.0),
		},
	},
}

mcl_mobs.define_composite_pose (vindicator_poses, "jockey", {
	["leg.left"] = {
		vector.zero (),
		vector.new (90, -30, 0),
		nil,
	},
	["leg.right"] = {
		vector.zero (),
		vector.new (90, 30, 0),
		nil,
	},
})

vindicator._arm_poses = vindicator_poses

function vindicator:select_arm_pose ()
	local pose
	if self.attack
		or self._current_animation == "punch" then
		pose = "attack"
	else
		pose = "default"
	end
	return self.jockey_vehicle and "jockey_" .. pose or pose
end

------------------------------------------------------------------------
-- Vindicator mechanics.
------------------------------------------------------------------------

local pr = PcgRandom (os.time () + 4)

function vindicator:apply_raid_buffs (stage)
	illager.apply_raid_buffs (self, stage)

	local raid = self:_get_active_raid ()
	if mcl_raids.should_enchant (raid) then
		local wielditem = self:get_wielditem ()
		local name = wielditem:get_name ()
		if name ~= "mcl_tools:axe_iron"
			and name ~= "mcl_tools:axe_iron_enchanted" then
			return
		end
		-- enchantment_provider/raid/vindicator{,_post_wave_5}.
		if stage > 5 then -- Max number of stages on Normal difficulty.
			mcl_enchanting.enchant (wielditem, "sharpness", 2)
		else
			mcl_enchanting.enchant (wielditem, "sharpness", 1)
		end
		self:set_wielditem (wielditem)
	end
end

function vindicator:on_spawn ()
	illager.on_spawn (self)

	local self_pos = self.object:get_pos ()
	local mob_factor = mcl_worlds.get_special_difficulty (self_pos)
	local wielditem = ItemStack ("mcl_tools:axe_iron")
	self:set_wielditem (wielditem)
	self:enchant_default_weapon (mob_factor, pr)
end

function vindicator:set_nametag (nametag)
	mob_class.set_nametag (self, nametag)
	if nametag == "Johnny" then
		self._is_johnny = true
	end
end

------------------------------------------------------------------------
-- Vindicator AI.
------------------------------------------------------------------------

local door_penalties = table.merge (mob_class.gwp_penalties, {
	DOOR_WOOD_CLOSED = 0.0,
})

function vindicator:ai_step (dtime)
	illager.ai_step (self, dtime)
	self.can_open_doors = false
	self.gwp_penalties = mob_class.gwp_penalties
	local raid = self:_get_active_raid ()

	if raid then
		self.can_open_doors = true
		self.gwp_penalties = door_penalties
	end
	if self._breaking_door then
		self:break_door_step (self.object:get_pos (), dtime)
	end
end

-- Vindicators do not close doors they have passed.

function vindicator:gwp_close_memorized_doors ()
end

function vindicator:gwp_memorize_door (door_node)
end

-- Vindicator.java: VindicatorBreakDoorGoal (BreakDoorGoal with a
-- break time of max (240, 6) ticks), which only operates on Normal
-- and Hard during active raids, and is selected with a chance of
-- 1 in reducedTickDelay (10) per goal evaluation.
local DOOR_BREAK_TIME = 12.0

local function is_closed_wooden_door (pos)
	local node = core.get_node (pos)
	return core.get_item_group (node.name, "door") > 0
		and core.get_item_group (node.name, "door_iron") == 0
		and not mcl_doors.is_open (pos)
end

local function can_break_doors (self)
	return mob_griefing and mcl_vars.difficulty >= 2
		and self:_get_active_raid () ~= nil
end

function vindicator:gwp_open_door (door, nodedef, dtime)
	if self._breaking_door then
		return
	end
	if can_break_doors (self)
		and pr:next (1, 5) == 1
		and not core.is_protected (door, "") then
		self._breaking_door = door
		self._door_break_time = 0
		self._door_break_progress = 0
	else
		mob_class.gwp_open_door (self, door, nodedef, dtime)
	end
end

local function remove_door (door)
	-- BreakDoorGoal: level.removeBlock (doorPos, false), which
	-- yields no drops.
	local node = core.get_node (door)
	local other = node.name:find ("_t_") and -1 or 1
	core.remove_node (door)
	local other_pos = vector.offset (door, 0, other, 0)
	if core.get_item_group (core.get_node (other_pos).name, "door") > 0 then
		core.remove_node (other_pos)
	end
	core.sound_play ("default_dig_choppy", {
		pos = door,
		gain = 0.5,
	})
end

function vindicator:break_door_step (self_pos, dtime)
	local door = self._breaking_door
	local dx = door.x - self_pos.x
	local dy = door.y - 0.5 - self_pos.y
	local dz = door.z - self_pos.z

	-- canContinueToUse: the door must remain closed and within
	-- 2 blocks of this mob, and the conditions must hold.
	if dx * dx + dy * dy + dz * dz >= 4.0
		or not is_closed_wooden_door (door)
		or not can_break_doors (self) then
		self._breaking_door = nil
		self._door_break_time = nil
		self._door_break_progress = nil
		return
	end

	local t = self._door_break_time + dtime
	self._door_break_time = t
	if pr:next (1, 20) == 1 then
		self:set_animation ("punch")
	end
	if t >= DOOR_BREAK_TIME then
		if not core.is_protected (door, "") then
			remove_door (door)
		end
		self._breaking_door = nil
		self._door_break_time = nil
		self._door_break_progress = nil
	else
		local progress = math.floor (t / DOOR_BREAK_TIME * 10)
		if progress ~= self._door_break_progress then
			self._door_break_progress = progress
			core.sound_play ("mobs_mc_zombie_door_break", {
				pos = door,
				gain = 0.5,
			})
		end
	end
end

function vindicator:get_staticdata_table ()
	local supertable = mob_class.get_staticdata_table (self)
	if supertable then
		supertable._breaking_door = nil
		supertable._door_break_progress = nil
		supertable._door_break_time = nil
	end
	return supertable
end

function vindicator:gwp_initialize (targets, range, tolerance, penalties)
	-- Vindicators are assigned a relatively low tracking
	-- distance, but their pathfinding abilities should not be
	-- limited accordingly.
	if not range or range < 32.0 then
		range = 32.0
	end
	return mob_class.gwp_initialize (self, targets, range, tolerance, penalties)
end

vindicator.ai_functions = {
	illager.check_locked_target,
	illager.check_recover_banner,
	mob_class.check_attack,
	illager.check_pathfind_to_raid,
	illager.check_navigate_village,
	illager.check_distant_patrol,
	illager.check_celebrate,
	mob_class.check_pace,
}

local function johnny_attack_p (self)
	return self._is_johnny
end

vindicator._targeting_rules = {
	mcl_mobs.build_retaliation_target_rule (mobs_mc.raid_mob_predicate,
						true, {"mobs_mc:vindicator",}),
	mobs_mc.build_raid_player_detection_rule (),
	mcl_mobs.build_nearest_target_rule ("mobs_mc:villager", {
		"mobs_mc:villager",
		"mobs_mc:wandering_trader",
	}, nil, nil, nil),
	mcl_mobs.build_nearest_target_rule ("mobs_mc:iron_golem", {
		"mobs_mc:iron_golem",
	}, nil, nil, nil),
	-- Illagers are allies (AbstractIllager.considersEntityAsAlly)
	-- and are exempt from Johnny's wrath.
	mcl_mobs.build_nearest_target_rule ("mob", mobs_mc.not_illager_predicate,
					    johnny_attack_p, nil, nil),
	mcl_mobs.build_alert_receiver_rule (),
}

mcl_mobs.register_mob ("mobs_mc:vindicator", vindicator)

------------------------------------------------------------------------
-- Vindicator spawning.
------------------------------------------------------------------------

-- spawn eggs
mcl_mobs.register_egg ("mobs_mc:vindicator", S("Vindicator"), "#959b9b", "#275e61", 0)
