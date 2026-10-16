--Tropical Fish by cora
local S = core.get_translator(core.get_current_modname())
local mob_class = mcl_mobs.mob_class

local tropical_fish = {
	description = S("Tropical Fish"),
	type = "animal",
	_spawn_category = "water_ambient",
	can_despawn = true,
	hp_min = 3,
	hp_max = 3,
	xp_min = 1,
	xp_max = 3,
	armor = 100,
	head_eye_height = 0.26,
	-- AbstractFish.getMaxSpawnClusterSize: 8 including the leader.
	_school_size = 7,
	tilt_swim = true,
	movement_speed = 14,
	collisionbox = { -0.25, 0.0, -0.25, 0.25, 0.4, 0.25 },
	visual = "mesh",
	mesh = "extra_mobs_tropical_fish_a.b3d",
	textures = { "extra_mobs_tropical_fish_a.png" }, -- to be populated on_spawn
	sounds = {},
	animation = {
		stand_start = 0, stand_end = 20,
		walk_start = 20, walk_end = 40, walk_speed = 50,
		run_start = 20, run_end = 40, run_speed = 50,
	},
	drops = {
		{name = "mcl_fishing:clownfish_raw",
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
	do_go_pos = mcl_mobs.mob_class.fish_do_go_pos,
	breathes_in_water = true,
	flops = true,
	runaway = true,
	pace_chance = 40,
}

------------------------------------------------------------------------
-- Tropical Fish visuals.
------------------------------------------------------------------------

-- DyeColor.textureDiffuseColor, indexed by DyeColor id + 1.
local dye_colors = {
	"#F9FFFE", -- white
	"#F9801D", -- orange
	"#C74EBD", -- magenta
	"#3AB3DA", -- light_blue
	"#FED83D", -- yellow
	"#80C71F", -- lime
	"#F38BAA", -- pink
	"#474F52", -- gray
	"#9D9D97", -- light_gray
	"#169C9C", -- cyan
	"#8932B8", -- purple
	"#3C44AA", -- blue
	"#835432", -- brown
	"#5E7C16", -- green
	"#B02E26", -- red
	"#1D1D21", -- black
}

local WHITE, ORANGE, MAGENTA, LIGHT_BLUE, YELLOW, LIME, PINK, GRAY,
	LIGHT_GRAY, CYAN, PURPLE, BLUE, BROWN, GREEN, RED, BLACK
	= 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16

-- TropicalFish.Pattern: base model ("a" = SMALL, "b" = LARGE) and
-- pattern texture index.
local KOB, SUNSTREAK, SNOOPER, DASHER, BRINELY, SPOTTY
	= {"a", 1}, {"a", 2}, {"a", 3}, {"a", 4}, {"a", 5}, {"a", 6}
local FLOPPER, STRIPEY, GLITTER, BLOCKFISH, BETTY, CLAYFISH
	= {"b", 1}, {"b", 2}, {"b", 3}, {"b", 4}, {"b", 5}, {"b", 6}
local all_patterns = {
	KOB, SUNSTREAK, SNOOPER, DASHER, BRINELY, SPOTTY,
	FLOPPER, STRIPEY, GLITTER, BLOCKFISH, BETTY, CLAYFISH,
}

-- TropicalFish.COMMON_VARIANTS: pattern, base color, pattern color.
local common_variants = {
	{STRIPEY, ORANGE, GRAY},
	{FLOPPER, GRAY, GRAY},
	{FLOPPER, GRAY, BLUE},
	{CLAYFISH, WHITE, GRAY},
	{SUNSTREAK, BLUE, GRAY},
	{KOB, ORANGE, WHITE},
	{SPOTTY, PINK, LIGHT_BLUE},
	{BLOCKFISH, PURPLE, YELLOW},
	{CLAYFISH, WHITE, RED},
	{SPOTTY, WHITE, YELLOW},
	{GLITTER, WHITE, GRAY},
	{CLAYFISH, WHITE, ORANGE},
	{DASHER, CYAN, PINK},
	{BRINELY, LIME, LIGHT_BLUE},
	{BETTY, RED, WHITE},
	{SNOOPER, GRAY, RED},
	{BLOCKFISH, RED, WHITE},
	{FLOPPER, WHITE, YELLOW},
	{KOB, RED, WHITE},
	{SUNSTREAK, GRAY, WHITE},
	{DASHER, CYAN, YELLOW},
	{FLOPPER, YELLOW, YELLOW},
}

local function variant_fields (variant)
	local pattern, base_color, pattern_color
		= variant[1], variant[2], variant[3]
	return {
		_type = pattern[1],
		_pattern = table.concat ({
			"extra_mobs_tropical_fish_pattern_",
			pattern[1],
			"_",
			pattern[2],
			".png",
		}),
		_base_color = dye_colors[base_color],
		_pattern_color = dye_colors[pattern_color],
	}
end

local function random_common_variant ()
	return common_variants[math.random (#common_variants)]
end

local function random_variant ()
	return {
		all_patterns[math.random (#all_patterns)],
		math.random (#dye_colors),
		math.random (#dye_colors),
	}
end

-- TropicalFish.finalizeSpawn: 90% of fish are of a common variant.
-- Returns the fields of the selected variant and whether it is
-- common.
local function select_spawn_variant ()
	if math.random () < 0.9 then
		return variant_fields (random_common_variant ()), true
	else
		return variant_fields (random_variant ()), false
	end
end

function tropical_fish:update_textures ()
	if not self._type then
		local fields = select_spawn_variant ()
		self._type = fields._type
		self._pattern = fields._pattern
		self._base_color = fields._base_color
		self._pattern_color = fields._pattern_color
	end

	self._default_mesh = self._default_mesh or table.concat ({
		"extra_mobs_tropical_fish_",
		self._type,
		".b3d",
	})
	-- TropicalFishRenderer tints the base model and its pattern
	-- layer by multiplication.
	self._default_texture = self._default_texture or table.concat ({
		"(extra_mobs_tropical_fish_",
		self._type,
		".png^[multiply:",
		self._base_color,
		")^(",
		self._pattern,
		"^[multiply:",
		self._pattern_color..")",
	})

	self.base_texture = {
		self._default_texture,
	}
	self.object:set_properties ({
		mesh = self._default_mesh,
	})
	self:set_textures (self.base_texture)
	self.base_mesh = self._default_mesh
	self.base_size = self.initial_properties.visual_size
	self.base_colbox = self.initial_properties.collisionbox
	self.base_selbox = self.initial_properties.selectionbox
end

------------------------------------------------------------------------
-- Tropical Fish interaction.
------------------------------------------------------------------------

function tropical_fish:on_rightclick (clicker)
	local bn = clicker:get_wielded_item():get_name()
	if bn == "mcl_buckets:bucket_water" or bn == "mcl_buckets:bucket_river_water" then
		if clicker:set_wielded_item("mcl_buckets:bucket_tropical_fish") then
			local it = clicker:get_wielded_item()
			local m = it:get_meta()
			m:set_string("properties",core.serialize({
				nametag = self:get_nametag (),
				health = self.health,
				_default_mesh = self._default_mesh,
				_default_texture = self._default_texture,
				_base_color = self._base_color,
				_pattern = self._pattern,
				_pattern_color = self._pattern_color,
				_type = self._type,
			}))
			clicker:set_wielded_item(it)
			self:safe_remove()
		end
		awards.unlock(clicker:get_player_name(), "mcl:tacticalFishing")
	end
end

function tropical_fish:mob_activate (staticdata, dtime)
	if not mob_class.mob_activate (self, staticdata, dtime) then
		return false
	end
	self:update_tag ()
	return true
end

------------------------------------------------------------------------
-- Tropical Fish AI.
------------------------------------------------------------------------

tropical_fish.ai_functions = {
	mob_class.check_frightened,
	mob_class.check_avoid,
	mob_class.check_schooling,
	mob_class.check_pace,
}

mcl_mobs.register_mob ("mobs_mc:tropical_fish", tropical_fish)

------------------------------------------------------------------------
-- Tropical Fish spawning.
------------------------------------------------------------------------

--spawn egg
mcl_mobs.register_egg("mobs_mc:tropical_fish", S("Tropical Fish"), "#ef6915", "#fff9ef", 0)

------------------------------------------------------------------------
-- Modern Tropical Fish spawning.
------------------------------------------------------------------------

local aquatic_animal_spawner = mobs_mc.aquatic_animal_spawner
local tropical_fish_spawner = table.merge (aquatic_animal_spawner, {
	name = "mobs_mc:tropical_fish",
	biomes = {
		"WarmOcean",
		"LukewarmOcean",
		"MangroveSwamp",
		"LushCaves",
	},
	weight = 25,
	pack_min = 8,
	pack_max = 8,
	-- AbstractSchoolingFish.getMaxSpawnClusterSize.
	max_cluster = 8,
})

-- TropicalFish.finalizeSpawn: every member of a group shares the
-- variant of its first member if that variant is common; fish of
-- other variants spawn alone (TropicalFish.isMaxGroupSizeReached).
local group_variant, group_solitary = nil, false

function tropical_fish_spawner:spawn (spawn_pos, idx, sdata, pack_size)
	if not idx or idx <= 1 or not group_variant then
		group_variant, group_solitary = select_spawn_variant ()
		group_solitary = not group_solitary
	elseif group_solitary then
		return nil
	end
	local data = table.merge (sdata or {}, group_variant)
	return core.add_entity (spawn_pos, self.name, core.serialize (data))
end

-- TropicalFish.isMaxGroupSizeReached: !isSchool.
function tropical_fish_spawner:is_max_group_size_reached (group_size, object, sdata)
	return group_solitary
end

function tropical_fish_spawner:init_group (list, sdata)
	mob_class.school_init_group (list)
end

function tropical_fish_spawner:describe_criteria (tbl, omit_group_details)
	aquatic_animal_spawner.describe_criteria (self, tbl, omit_group_details)
	if not omit_group_details then
		table.insert (tbl, S ("Each mob spawned will form a school with the remainder of the mobs in the group."))
	end
end

mcl_mobs.register_spawner (tropical_fish_spawner)
