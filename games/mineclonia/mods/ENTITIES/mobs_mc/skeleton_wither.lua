--MCmobs v0.4
--maikerumine
--made for MC like Survival game
--License for code WTFPL and otherwise stated in readmes

local S = core.get_translator("mobs_mc")
local mob_class = mcl_mobs.mob_class
local skeleton = mobs_mc.skeleton

--###################
--################### WITHER SKELETON
--###################

local wither_skeleton = table.merge (skeleton, {
	description = S("Wither Skeleton"),
	damage = 4.0,
	collisionbox = {-0.35, 0.0, -0.35, 0.35, 2.4, 0.35},
	visual = "mesh",
	mesh = "mobs_mc_witherskeleton.b3d",
	head_swivel = "head.control",
	head_eye_height = 2.1,
	-- Arrows are released from getEyeY () - 0.1.
	shoot_offset = 2.0,
	bone_eye_height = 2.38,
	curiosity = 60,
	textures = {
		{
			"mobs_mc_empty.png",
			"mobs_mc_wither_skeleton.png",
		}
	},
	visual_size = {
		x = 1.2,
		y = 1.2,
	},
	movement_speed = 5.0,
	drops = {
		-- entities/wither_skeleton.json: uniform (-1, 1).
		{
			name = "mcl_core:coal_lump",
			chance = 1,
			min = -1,
			max = 1,
			looting = "common",
		},
		{
			name = "mcl_mobitems:bone",
			chance = 1,
			min = 0,
			max = 2,
			looting = "common",
		},

		-- Head (killed_by_player, 2.5% + 1% per level of
		-- Looting).
		{
			name = "mcl_heads:wither_skeleton",
			chance = 40, -- 2.5% chance
			min = 1,
			max = 1,
			looting = "rare",
			player_kill_only = true,
		},
		-- Charged creeper explosions.
		{
			name = "mcl_heads:wither_skeleton",
			chance = 1,
			min = 0,
			max = 0,
			mob_head = true,
		},
	},
	animation = {
		stand_start = 0,
		stand_end = 40,
		stand_speed = 15,
		walk_start = 40,
		walk_end = 60,
		walk_speed = 15,
		punch_start = 61,
		punch_end = 81,
		punch_speed = 50,
	},
	fire_resistant = true,
	_fire_resistant = true,
	dealt_effect = {
		name = "withering",
		level = 1,
		dur = 10,
	},
	_wither_parent = nil,
	_can_freeze = true,
})

------------------------------------------------------------------------
-- Wither Skeleton visuals.
------------------------------------------------------------------------

local wither_skeleton_poses = {
	default = {
		["arm.right"] = {},
		["arm.left"] = {},
	},
	shoot = {
		["arm.right"] = {
			nil,
			vector.new (0, 0, -90),
		},
		["arm.left"] = {
			nil,
			vector.new (-110, 0, -90),
		},
	},
	attack = {
		["arm.right"] = {
			nil,
			vector.new (0, 0, -90),
		},
		["arm.left"] = {
			nil,
			vector.new (-90, 0, -90),
		},
	},
}

mcl_mobs.define_composite_pose (wither_skeleton_poses, "jockey", {
	["leg.right"] = {
		nil,
		vector.new (115, 0, 90),
		vector.new (1, 1, 1),
	},
	["leg.left"] = {
		nil,
		vector.new (115, 0, -90),
	},
})

wither_skeleton._arm_poses = wither_skeleton_poses

------------------------------------------------------------------------
-- Wither Skeleton mechanics.
------------------------------------------------------------------------

function wither_skeleton:skelly_generate_default_equipment (mob_factor)
	self:set_wielditem (ItemStack ("mcl_tools:sword_stone"))
end

-- WitherSkeleton.java: arrows are set alight for 100 seconds.
function wither_skeleton:shoot_arrow (pos, dir)
	local wielditem = self:get_wielditem ()
	local arrow = mcl_bows.shoot_arrow ("mcl_bows:arrow", pos, dir,
			self:get_yaw (), self.object, 0.5333333, nil,
			false, wielditem)
	if arrow and arrow:get_pos () then
		mcl_burning.set_on_fire (arrow, 100)
	end
end

function wither_skeleton:on_die (pos, mcl_reason)
	-- `snipeSkeleton' should not be granted for sniping a wither
	-- skeleton.
end

wither_skeleton.conversion_step = nil

------------------------------------------------------------------------
-- Wither Skeleton AI.
------------------------------------------------------------------------

function wither_skeleton:test_object_and_restriction (object, pos)
	return object ~= self._wither_parent
		and mob_class.test_object_and_restriction (self, object, pos)
end

wither_skeleton._targeting_rules = {
	mcl_mobs.build_retaliation_target_rule (nil, false, nil),
	mcl_mobs.build_nearest_target_rule ("player", nil, nil, nil, nil),
	mcl_mobs.build_nearest_target_rule ("mobs_mc:iron_golem", {"mobs_mc:iron_golem",},
					    nil, nil, nil),
	mcl_mobs.build_nearest_target_rule ("mobs", {
		"mobs_mc:piglin",
		"mobs_mc:piglin_brute",
	}, nil, nil, nil),
}

mcl_mobs.register_mob ("mobs_mc:witherskeleton", wither_skeleton)

------------------------------------------------------------------------
-- Wither Skeleton spawning.
------------------------------------------------------------------------

local wither_skeleton_spawner = table.merge (mobs_mc.monster_spawner, {
	name = "mobs_mc:witherskeleton",
	weight = 8,
	pack_min = 5,
	pack_max = 5,
	-- Monster.checkMonsterSpawnRules with the Nether's light rules.
	biomes = {},
	structures = {
		"mcl_levelgen:nether_fortress",
	},
})

mcl_mobs.register_spawner (wither_skeleton_spawner)

mcl_mobs.register_egg ("mobs_mc:witherskeleton", S("Wither Skeleton"), "#141414", "#474d4d", 0)
