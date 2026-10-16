--MCmobs v0.4
--maikerumine
--made for MC like Survival game
--License for code WTFPL and otherwise stated in readmes

local S = core.get_translator(core.get_current_modname())
local mob_class = mcl_mobs.mob_class

--###################
--################### salmon
--###################

local salmon = {
	description = S("Salmon"),
	type = "animal",
	_spawn_category = "water_ambient",
	can_despawn = true,
	hp_min = 3,
	hp_max = 3,
	xp_min = 1,
	xp_max = 3,
	armor = 100,
	tilt_swim = true,
	head_eye_height = 0.26,
	collisionbox = {-0.35, 0.0, -0.35, 0.35, 0.4, 0.35},
	visual = "mesh",
	mesh = "extra_mobs_salmon.b3d",
	textures = {
		{"extra_mobs_salmon.png"}
	},
	sounds = {
	},
	animation = {
		stand_start = 1, stand_end = 20,
		walk_start = 1, walk_end = 20,
		run_start = 1, run_end = 20,
	},
	drops = {
		{name = "mcl_fishing:salmon_raw",
		chance = 1,
		min = 1,
		max = 1,},
		{name = "mcl_bone_meal:bone_meal",
		chance = 20,
		min = 1,
		max = 1,},
	},
	runaway_from = {"players"},
	runaway_bonus_near = 1.6,
	runaway_bonus_far = 1.4,
	runaway_view_range = 8,
	visual_size = {x=3, y=3},
	makes_footstep_sound = false,
	can_ride_boat = false,
	swims = true,
	pace_height = 1.0,
	do_go_pos = mob_class.fish_do_go_pos,
	-- Salmon.getMaxSchoolSize: 5 including the leader.
	_school_size = 4,
	breathes_in_water = true,
	flops = true,
	runaway = true,
	movement_speed = 14,
	pace_chance = 40,
}

------------------------------------------------------------------------
-- Salmon interaction.
------------------------------------------------------------------------

function salmon:on_rightclick (clicker)
	local bn = clicker:get_wielded_item():get_name()
	if bn == "mcl_buckets:bucket_water" or bn == "mcl_buckets:bucket_river_water" then
		if clicker:set_wielded_item("mcl_buckets:bucket_salmon") then
			-- Salmon.saveToBucketTag: preserve health, name,
			-- and size.
			local it = clicker:get_wielded_item()
			local m = it:get_meta()
			m:set_string("properties", core.serialize({
				nametag = self:get_nametag (),
				health = self.health,
				_salmon_size = self._salmon_size,
			}))
			clicker:set_wielded_item(it)
			self:safe_remove()
		end
		awards.unlock(clicker:get_player_name(), "mcl:tacticalFishing")
	end
end

------------------------------------------------------------------------
-- Salmon sizes.
------------------------------------------------------------------------

-- Salmon.Variant bounding box scales.
local salmon_scales = {
	small = 0.5,
	medium = 1.0,
	large = 1.5,
}

-- Salmon.finalizeSpawn: weights 30, 50, and 15.
local function random_salmon_size ()
	local n = math.random (95)
	if n <= 30 then
		return "small"
	elseif n <= 80 then
		return "medium"
	else
		return "large"
	end
end

function salmon:apply_salmon_size ()
	local scale = salmon_scales[self._salmon_size] or 1.0
	local def = mcl_mobs.registered_mobs[self.name]
	local cbox = def.initial_properties.collisionbox
	local size = def.initial_properties.visual_size
	local scaled = {
		cbox[1] * scale, cbox[2] * scale, cbox[3] * scale,
		cbox[4] * scale, cbox[5] * scale, cbox[6] * scale,
	}
	local visual_size = {
		x = size.x * scale,
		y = size.y * scale,
	}
	self.collisionbox = scaled
	self.base_colbox = scaled
	self.base_selbox = scaled
	self.base_size = visual_size
	self.head_eye_height = def.head_eye_height * scale
	self.object:set_properties ({
		collisionbox = scaled,
		selectionbox = scaled,
		visual_size = visual_size,
	})
end

function salmon:mob_activate (staticdata, dtime)
	if not mob_class.mob_activate (self, staticdata, dtime) then
		return false
	end
	if not salmon_scales[self._salmon_size] then
		self._salmon_size = random_salmon_size ()
	end
	self:apply_salmon_size ()
	return true
end

------------------------------------------------------------------------
-- Salmon AI.
------------------------------------------------------------------------

salmon.ai_functions = {
	mob_class.check_frightened,
	mob_class.check_avoid,
	mob_class.check_schooling,
	mob_class.check_pace,
}

mcl_mobs.register_mob ("mobs_mc:salmon", salmon)

------------------------------------------------------------------------
-- Salmon spawning.
------------------------------------------------------------------------

--spawn egg
mcl_mobs.register_egg("mobs_mc:salmon", S("Salmon"), "#a00f10", "#0e8474", 0)

------------------------------------------------------------------------
-- Modern Salmon spawning.
------------------------------------------------------------------------

local aquatic_animal_spawner = mobs_mc.aquatic_animal_spawner
local salmon_spawner = table.merge (aquatic_animal_spawner, {
	name = "mobs_mc:salmon",
	-- Salmon.getMaxSchoolSize.
	max_cluster = 5,
	biomes = {
		"FrozenOcean",
		"ColdOcean",
		"DeepColdOcean",
		"DeepFrozenOcean",
	},
	weight = 15,
	pack_min = 1,
	pack_max = 5,
})

function salmon_spawner:init_group (list, sdata)
	mob_class.school_init_group (list)
end

function salmon_spawner:describe_criteria (tbl, omit_group_details)
	aquatic_animal_spawner.describe_criteria (self, tbl, omit_group_details)
	if not omit_group_details then
		table.insert (tbl, S ("Each mob spawned will form a school with the remainder of the mobs in the group."))
	end
end

local salmon_spawner_river = table.merge (salmon_spawner, {
	weight = 5,
	biomes = {
		"River",
		"FrozenRiver",
	},
})

mcl_mobs.register_spawner (salmon_spawner)
mcl_mobs.register_spawner (salmon_spawner_river)
