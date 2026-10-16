-------------------------------------------------------------------------
-- Spawning initialization.
-------------------------------------------------------------------------

local S = core.get_translator (core.get_current_modname ())

local only_peaceful_mobs
	= core.settings:get_bool ("only_peaceful_mobs", false)

mobs_mc.overworld_biomes = {
	"BambooJungle",
	"Beach",
	"BirchForest",
	"CherryGrove",
	"ColdOcean",
	"DarkForest",
	"DeepColdOcean",
	"DeepFrozenOcean",
	"DeepLukewarmOcean",
	"DeepOcean",
	"Desert",
	"DripstoneCaves",
	"ErodedMesa",
	"FlowerForest",
	"Forest",
	"FrozenOcean",
	"FrozenPeaks",
	"FrozenRiver",
	"Grove",
	"IceSpikes",
	"JaggedPeaks",
	"Jungle",
	"LukewarmOcean",
	"LushCaves",
	"MangroveSwamp",
	"Meadow",
	"Mesa",
	"MushroomIslands",
	"Ocean",
	"OldGrowthBirchForest",
	"OldGrowthPineTaiga",
	"OldGrowthSpruceTaiga",
	"PaleGarden",
	"Plains",
	"River",
	"Savannah",
	"SavannahPlateau",
	"SnowyBeach",
	"SnowyPlains",
	"SnowySlopes",
	"SnowyTaiga",
	"SparseJungle",
	"StonyPeaks",
	"StonyShore",
	"SunflowerPlains",
	"Swamp",
	"Taiga",
	"WarmOcean",
	"WindsweptForest",
	"WindsweptGravellyHills",
	"WindsweptHills",
	"WindsweptSavannah",
	"WoodedMesa",
}

-- Biomes that receive BiomeDefaultFeatures.farmAnimals (OverworldBiomes).
-- Cherry groves do not (OverworldBiomes.meadowOrCherryGrove); badlands do
-- (OverworldBiomes.badlands).
mobs_mc.farm_animal_biomes = {
	"BambooJungle",
	"BirchForest",
	"DarkForest",
	"ErodedMesa",
	"FlowerForest",
	"Forest",
	"Jungle",
	"Mesa",
	"OldGrowthBirchForest",
	"OldGrowthPineTaiga",
	"OldGrowthSpruceTaiga",
	"Plains",
	"SavannahPlateau",
	"Savannah",
	"SnowyTaiga",
	"SparseJungle",
	"SunflowerPlains",
	"Swamp",
	"Taiga",
	"WindsweptForest",
	"WindsweptGravellyHills",
	"WindsweptHills",
	"WindsweptSavannah",
	"WoodedMesa",
}

-- Biomes that receive BiomeDefaultFeatures.commonMonsters (every
-- overworld biome but mushroom fields).
mobs_mc.monster_biomes = {
	"BambooJungle",
	"Beach",
	"BirchForest",
	"CherryGrove",
	"ColdOcean",
	"DarkForest",
	"DeepColdOcean",
	"DeepFrozenOcean",
	"DeepLukewarmOcean",
	"DeepOcean",
	"Desert",
	"DripstoneCaves",
	"ErodedMesa",
	"FlowerForest",
	"Forest",
	"FrozenOcean",
	"FrozenPeaks",
	"FrozenRiver",
	"Grove",
	"IceSpikes",
	"JaggedPeaks",
	"Jungle",
	"LukewarmOcean",
	"LushCaves",
	"MangroveSwamp",
	"Meadow",
	"Mesa",
	"Ocean",
	"OldGrowthBirchForest",
	"OldGrowthPineTaiga",
	"OldGrowthSpruceTaiga",
	"PaleGarden",
	"Plains",
	"River",
	"Savannah",
	"SavannahPlateau",
	"SnowyBeach",
	"SnowyPlains",
	"SnowySlopes",
	"SnowyTaiga",
	"SparseJungle",
	"StonyPeaks",
	"StonyShore",
	"SunflowerPlains",
	"Swamp",
	"Taiga",
	"WarmOcean",
	"WindsweptForest",
	"WindsweptGravellyHills",
	"WindsweptHills",
	"WindsweptSavannah",
	"WoodedMesa",
}

-------------------------------------------------------------------------
-- Default spawners.
-------------------------------------------------------------------------

-- Land animals.

local default_spawner = mcl_mobs.default_spawner
local animal_spawner = table.merge (default_spawner, {
	spawn_category = "creature",
	spawn_placement = "ground",
})

function animal_spawner:test_supporting_node (node)
	return core.get_item_group (node.name, "grass_block") > 0
end

function animal_spawner:describe_supporting_nodes ()
	return S ("on grass nodes")
end

function animal_spawner:get_misc_spawning_description ()
	return S ("This mob will spawn infrequently @1 with a surface occupying a full node when no obstructions exist within a volume @2 nodes in size around the center of such a node's upper surface, in light levels of 9 or greater.",
		  self:describe_supporting_nodes (), self:describe_mob_collision_box ())
end

function animal_spawner:test_spawn_position (spawn_pos, node_pos, sdata, node_cache,
					     spawn_flag)
	-- Animal.isBrightEnoughToSpawn: getRawBrightness (pos, 0) > 8,
	-- i.e. sky light without darkening by the time of day.
	local light = core.get_node_light (node_pos, 0.5)
	if not light or light <= 8 then
		return false
	end
	local node_below = self:get_node (node_cache, -1, node_pos)
	if self:test_supporting_node (node_below) then
		if default_spawner.test_spawn_position (self, spawn_pos,
							node_pos, sdata,
							node_cache,
							spawn_flag) then
			return true
		end
	end
	return false
end

mobs_mc.animal_spawner = animal_spawner

-- Aquatic animals.

local default_spawner = mcl_mobs.default_spawner
local aquatic_animal_spawner = table.merge (default_spawner, {
	spawn_category = "water_ambient",
	spawn_placement = "aquatic",
})

function aquatic_animal_spawner:test_spawn_position (spawn_pos, node_pos, sdata, node_cache,
						     spawn_flag)
	if spawn_pos.y > 0.5 or spawn_pos.y < -12.5 then
		return false
	end

	local node_below = self:get_node (node_cache, -1, node_pos)
	local node_above = self:get_node (node_cache, 1, node_pos)
	if core.get_item_group (node_below.name, "water") > 0
		and core.get_item_group (node_above.name, "water") > 0 then
		if default_spawner.test_spawn_position (self, spawn_pos,
							node_pos, sdata,
							node_cache,
							spawn_flag) then
			return true
		end
	end
	return false
end

function aquatic_animal_spawner:get_misc_spawning_description ()
	return S ("This mob will spawn between sea level and Y level -12 when the nodes above and below are water and no obstructions exist within a volume @1 nodes in size around the center of the base of the fluid node where spawning is being attempted.",
		  self:describe_mob_collision_box ())
end

mobs_mc.aquatic_animal_spawner = aquatic_animal_spawner

-- Monsters.

-- Monster spawning light rules (Monster.checkMonsterSpawnRules).
--
-- By default a spawner of this type applies
-- Monster.isDarkEnoughToSpawn with the rules of the dimension at the
-- spawn position (`mcl_mobs.monster_spawn_light', i.e. the dimension
-- type's monster_spawn_block_light_limit and
-- monster_spawn_light_level).  Spawners may set:
--
--   ignore_light = true
--     No light test at all: Monster.checkAnyLightMonsterSpawnRules
--     (blaze, zoglin, silverfish, endermite) and mobs whose spawn
--     rules ignore light (piglin, zombified piglin, ghast, hoglin,
--     magma cube).
--
--   max_block_light = N
--     Spawning fails where the block light exceeds N.  Applied in
--     addition to (or, with ignore_light, instead of) the dimension
--     rules; PatrollingMonster.checkPatrollingMonsterSpawnRules uses
--     ignore_light = true, max_block_light = 8.
--
-- The former `max_light' and `max_artificial_light' fields are no
-- longer consulted.  None of these tests apply to trial spawners
-- (EntitySpawnReason.ignoresLightRequirements).

local monster_spawner = table.merge (default_spawner, {
	spawn_placement = "ground",
	spawn_category = "monster",
	pack_min = 4,
	pack_max = 4,
	ignore_light = false,
	max_block_light = nil,
})

function monster_spawner:test_light (node_pos, node_data, spawn_flag)
	if spawn_flag == "trial_spawner" then
		return true
	end
	if self.max_block_light
		and mcl_mobs.get_block_light (node_pos, node_data) > self.max_block_light then
		return false
	end
	if self.ignore_light then
		return true
	end
	return mcl_mobs.is_dark_enough_to_spawn (node_pos, node_data)
end

function monster_spawner:test_spawn_position (spawn_pos, node_pos, sdata, node_cache,
					      spawn_flag)
	if mcl_vars.difficulty == 0 or only_peaceful_mobs then
		return false
	end

	if default_spawner.test_spawn_position (self, spawn_pos, node_pos,
						sdata, node_cache, spawn_flag) then
		local node_data = self:get_node (node_cache, 0, node_pos)
		return self:test_light (node_pos, node_data, spawn_flag)
	end
	return false
end

function monster_spawner:describe_additional_spawning_criteria ()
	if self.ignore_light then
		if self.max_block_light then
			return S ("Spawning will only succeed where the block light level is @1 or less.", self.max_block_light)
		end
		return nil
	end
	return S ("Spawning will only succeed in darkness: never where block light exceeds the dimension's limit (0 in the Overworld and the End), increasingly rarely in sky light, and in the Overworld only at a combined light level no greater than a random value from 0 to 7 (7 in the Nether).")
end

mobs_mc.monster_spawner = monster_spawner

-------------------------------------------------------------------------
-- Default structure spawning configurations.
-------------------------------------------------------------------------

mcl_mobs.suppress_spawning_in_structure ("mcl_levelgen:trial_chambers", "ambient")
mcl_mobs.suppress_spawning_in_structure ("mcl_levelgen:trial_chambers", "axolotl")
mcl_mobs.suppress_spawning_in_structure ("mcl_levelgen:trial_chambers", "creature")
mcl_mobs.suppress_spawning_in_structure ("mcl_levelgen:trial_chambers", "monster")
mcl_mobs.suppress_spawning_in_structure ("mcl_levelgen:trial_chambers", "underground_water_creature")
mcl_mobs.suppress_spawning_in_structure ("mcl_levelgen:trial_chambers", "water_ambient")
mcl_mobs.suppress_spawning_in_structure ("mcl_levelgen:trial_chambers", "water_creature")
