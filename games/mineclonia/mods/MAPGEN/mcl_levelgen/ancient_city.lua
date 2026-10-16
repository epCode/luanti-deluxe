------------------------------------------------------------------------
-- Ancient Cities.
--
-- A port of Minecraft 26.3's ancient city (worldgen/structure/
-- ancient_city.json, structure_set/ancient_cities.json, template_pool/
-- ancient_city/**, processor_list/ancient_city_*.json and loot_table/
-- chests/ancient_city*.json), generated from Minecraft's own templates
-- (converted by tools/mc_structure_to_template.py into
-- templates/ancient_city/, which are Mojang assets for local use only)
-- by the Minecraft jigsaw placer in jigsaw_mc.lua.
------------------------------------------------------------------------

dofile (mcl_levelgen.prefix .. "/jigsaw_mc.lua")

local R = mcl_levelgen.build_random_spread_placement
local floor = math.floor
local mathabs = math.abs
local ull = mcl_levelgen.ull
local seed_from_position = mcl_levelgen.seed_from_position

------------------------------------------------------------------------
-- Loot tables.
------------------------------------------------------------------------

local function enchant_with_levels (min, max)
	return function (stack, pr)
		mcl_enchanting.enchant_randomly (stack, pr:next (min, max), false,
						 false, false, pr)
	end
end

local function enchant_randomly (stack, pr)
	mcl_enchanting.enchant_uniform_randomly (stack, {"soul_speed", "swift_sneak",}, pr)
end

local function damage_80_100 (stack, pr)
	-- set_damage uniform 0.8 .. 1.0 (remaining durability).
	local remaining = 0.8 + pr:next (0, 1000) / 5000
	stack:set_wear (floor ((1 - remaining) * 65535))
end

-- minecraft:chests/ancient_city.  Items Mineclonia lacks are replaced
-- by their nearest equivalents (see the comments).
mcl_levelgen.register_loot_table ("mcl_levelgen:ancient_city_chest", {
	{
		stacks_min = 5,
		stacks_max = 10,
		items = {
			{ itemstring = "mcl_core:apple_gold_enchanted", weight = 1, amount_min = 1, amount_max = 2, },
			-- music_disc_otherside (absent).
			{ itemstring = "mcl_jukebox:record_wait", weight = 1, },
			{ itemstring = "mcl_compass:compass", weight = 2, },
			{ itemstring = "mcl_sculk:catalyst", weight = 2, amount_min = 1, amount_max = 2, },
			{ itemstring = "mcl_farming:hoe_diamond", weight = 2,
			  func = function (stack, pr)
				  damage_80_100 (stack, pr)
				  enchant_with_levels (30, 50) (stack, pr)
			  end, },
			-- lead (absent).
			{ itemstring = "mcl_mobitems:string", weight = 2, },
			{ itemstring = "mcl_mobitems:diamond_horse_armor", weight = 2, },
			{ itemstring = "mcl_mobitems:leather", weight = 2, amount_min = 1, amount_max = 5, },
			{ itemstring = "mcl_jukebox:record_13", weight = 2, },
			-- music_disc_cat (absent).
			{ itemstring = "mcl_jukebox:record_chirp", weight = 2, },
			{ itemstring = "mcl_armor:leggings_diamond", weight = 2,
			  func = enchant_with_levels (30, 50), },
			{ itemstring = "mcl_books:book", weight = 3,
			  func = function (stack, pr)
				  mcl_enchanting.enchant_swift_sneak (stack, pr)
			  end, },
			{ itemstring = "mcl_sculk:sculk", weight = 3, amount_min = 4, amount_max = 10, },
			{ itemstring = "mcl_sculk:sensor", weight = 3, amount_min = 1, amount_max = 3, },
			{ itemstring = "mcl_candles:candle_1", weight = 3, amount_min = 1, amount_max = 4, },
			{ itemstring = "mcl_amethyst:amethyst_shard", weight = 3, amount_min = 1, amount_max = 15, },
			{ itemstring = "mcl_experience:bottle", weight = 3, amount_min = 1, amount_max = 3, },
			{ itemstring = "mcl_lush_caves:glow_berry", weight = 3, amount_min = 1, amount_max = 15, },
			{ itemstring = "mcl_armor:leggings_iron", weight = 3,
			  func = enchant_with_levels (20, 39), },
			{ itemstring = "mcl_sculk:echo_shard", weight = 4, amount_min = 1, amount_max = 3, },
			{ itemstring = "mcl_jukebox:disc_fragment_5", weight = 4, amount_min = 1, amount_max = 3, },
			{ itemstring = "mcl_potions:regeneration_2", weight = 5, amount_min = 1, amount_max = 3, },
			{ itemstring = "mcl_books:book", weight = 5, func = enchant_randomly, },
			{ itemstring = "mcl_books:book", weight = 5, amount_min = 3, amount_max = 10, },
			{ itemstring = "mcl_mobitems:bone", weight = 5, amount_min = 1, amount_max = 15, },
			{ itemstring = "mcl_blackstone:soul_torch", weight = 5, amount_min = 1, amount_max = 15, },
			{ itemstring = "mcl_core:coal_lump", weight = 7, amount_min = 6, amount_max = 15, },
		},
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ nothing = true, weight = 75, },
			{ itemstring = "mcl_armor:ward", weight = 4, },
			{ itemstring = "mcl_armor:silence", weight = 1, },
		},
	},
})

-- minecraft:chests/ancient_city_ice_box.
mcl_levelgen.register_loot_table ("mcl_levelgen:ancient_city_ice_box_chest", {
	{
		stacks_min = 4,
		stacks_max = 10,
		items = {
			-- Suspicious stew: Mineclonia's stew carries one
			-- effect (Minecraft: night vision 7-10 s and blindness
			-- 5-7 s); stews do not stack.
			{ itemstring = "mcl_sus_stew:stew", weight = 1,
			  func = function (stack, pr)
				  stack:get_meta ():set_string ("effect", "night_vision")
			  end, },
			{ itemstring = "mcl_farming:carrot_item_gold", weight = 1, amount_min = 1, amount_max = 10, },
			{ itemstring = "mcl_farming:potato_item_baked", weight = 1, amount_min = 1, amount_max = 10, },
			{ itemstring = "mcl_core:packed_ice", weight = 2, amount_min = 2, amount_max = 6, },
			{ itemstring = "mcl_throwing:snowball", weight = 4, amount_min = 2, amount_max = 6, },
		},
	},
})

------------------------------------------------------------------------
-- Processors (processor_list/ancient_city_*.json).
--
-- Minecraft's block_rot and rule processors draw from a
-- LegacyRandomSource seeded with Mth.getSeed (position) for every
-- block, which is reproduced exactly.
------------------------------------------------------------------------

local pos_rng = mcl_levelgen.jvm_random (ull (0, 0))
local pos_seed = ull (0, 0)
local last_x, last_y, last_z, last_float

-- The first nextFloat () of RandomSource.create (Mth.getSeed (x, y, z)).
local function position_float (x, y, z)
	if x ~= last_x or y ~= last_y or z ~= last_z then
		seed_from_position (pos_seed, x, y, z)
		pos_rng:reseed (pos_seed)
		-- jvm_random scales next (24) by 1 / 0xffffff.
		local f = pos_rng:next_float ()
		last_float = floor (f * 0xffffff + 0.5) / 16777216
		last_x, last_y, last_z = x, y, z
	end
	return last_float
end

-- Single precision constants as in the JSON (float literals).
local F_095 = 0.949999988079071
local F_03 = 0.30000001192092896
local F_005 = 0.05000000074505806

local cids = nil

local function cid_set (names)
	local set = {}
	for _, name in ipairs (names) do
		if core.registered_nodes[name] then
			set[core.get_content_id (name)] = true
		end
	end
	return set
end

local function initialize_cids ()
	cids = {}
	-- #minecraft:ancient_city_replaceable.
	cids.rottable = cid_set ({
		"mcl_deepslate:deepslate",
		"mcl_deepslate:deepslate_bricks",
		"mcl_deepslate:deepslate_tiles",
		"mcl_stairs:slab_deepslate_bricks",
		"mcl_stairs:slab_deepslate_bricks_top",
		"mcl_stairs:slab_deepslate_bricks_double",
		"mcl_stairs:slab_deepslate_tiles",
		"mcl_stairs:slab_deepslate_tiles_top",
		"mcl_stairs:slab_deepslate_tiles_double",
		"mcl_stairs:stair_deepslate_bricks",
		"mcl_stairs:stair_deepslate_bricks_inner",
		"mcl_stairs:stair_deepslate_bricks_outer",
		"mcl_deepslate:deepslatetileswall_short_flat",
		"mcl_deepslate:deepslatetileswall_tall_flat",
		"mcl_deepslate:deepslatetileswall_short_pillar",
		"mcl_deepslate:deepslatetileswall_tall_pillar",
		"mcl_deepslate:deepslatebrickswall_short_flat",
		"mcl_deepslate:deepslatebrickswall_tall_flat",
		"mcl_deepslate:deepslatebrickswall_short_pillar",
		"mcl_deepslate:deepslatebrickswall_tall_pillar",
		"mcl_deepslate:deepslate_cobbled",
		"mcl_deepslate:deepslate_bricks_cracked",
		"mcl_deepslate:deepslate_tiles_cracked",
		"mcl_wool:grey",
	})
	cids.deepslate_bricks = cid_set ({ "mcl_deepslate:deepslate_bricks", })
	cids.deepslate_tiles = cid_set ({ "mcl_deepslate:deepslate_tiles", })
	cids.deepslate_tile_slab = cid_set ({
		"mcl_stairs:slab_deepslate_tiles",
		"mcl_stairs:slab_deepslate_tiles_top",
		"mcl_stairs:slab_deepslate_tiles_double",
	})
	cids.soul_lantern = cid_set ({
		"mcl_lanterns:soul_lantern_floor",
		"mcl_lanterns:soul_lantern_ceiling",
	})
	cids.cracked_bricks = core.get_content_id ("mcl_deepslate:deepslate_bricks_cracked")
	cids.cracked_tiles = core.get_content_id ("mcl_deepslate:deepslate_tiles_cracked")
	-- #minecraft:features_cannot_replace.
	cids.protected = {}
	for name, def in pairs (core.registered_nodes) do
		if (def.groups.features_cannot_replace or 0) > 0 then
			cids.protected[core.get_content_id (name)] = true
		end
	end
	cids.chest = core.get_content_id ("mcl_chests:chest_small")
	-- Redstone wire connections are encoded in node names
	-- (mcl_redstone/wire.lua), which rotate_param2 cannot rotate.
	cids.wire_flags = {}
	cids.wire_by_flags = {}
	for flags = 0, 255 do
		local name = flags == 0 and "mcl_redstone:redstone"
			or string.format ("mcl_redstone:wire_%02x", flags)
		if core.registered_nodes[name] then
			local cid = core.get_content_id (name)
			cids.wire_flags[cid] = flags
			cids.wire_by_flags[flags] = cid
		end
	end
end

if core.register_on_mods_loaded then
	core.register_on_mods_loaded (initialize_cids)
else
	initialize_cids ()
end

local cid_air = core.CONTENT_AIR

-- Rotate the connections of redstone wire by the rotation of the
-- template being placed.  Bits: 1 = south (-Z), 2 = west, 4 = north,
-- 8 = east; the high nibble marks connections that climb.
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local ROTATION_STEPS = { ["0"] = 0, ["90"] = 1, ["180"] = 2, ["270"] = 3, }

local function rotate_sides_cw (m)
	return bor (band (lshift (m, 1), 0xf), rshift (m, 3))
end

local function rotate_wire (x, y, z, rng, cid_current, param2_current, cid, param2)
	local flags = cids.wire_flags[cid]
	if flags then
		local piece = mcl_levelgen.current_structure_piece ()
		local steps = piece and ROTATION_STEPS[piece.mc_rotation or "0"] or 0
		local low, high = band (flags, 0xf), rshift (flags, 4)
		for _ = 1, steps do
			low, high = rotate_sides_cw (low), rotate_sides_cw (high)
		end
		local new = cids.wire_by_flags[bor (low, lshift (high, 4))]
		if new then
			return new, param2
		end
	end
	return cid, param2
end

-- minecraft:block_rot (integrity 0.95, #ancient_city_replaceable).
local function block_rot (x, y, z, rng, cid_current, param2_current, cid, param2)
	if cids.rottable[cid] and not (position_float (x, y, z) <= F_095) then
		return nil, nil
	end
	return cid, param2
end

-- minecraft:rule (random_block_match rules).  Each block matches at
-- most one rule, which therefore draws the first float.
local function rule_cracking (x, y, z, cid, param2)
	if cids.deepslate_bricks[cid] then
		if position_float (x, y, z) < F_03 then
			return cids.cracked_bricks, 0
		end
	elseif cids.deepslate_tiles[cid] then
		if position_float (x, y, z) < F_03 then
			return cids.cracked_tiles, 0
		end
	end
	return cid, param2
end

local function rule_generic (x, y, z, rng, cid_current, param2_current, cid, param2)
	if cids.soul_lantern[cid] then
		if position_float (x, y, z) < F_005 then
			return cid_air, 0
		end
		return cid, param2
	end
	return rule_cracking (x, y, z, cid, param2)
end

local function rule_walls (x, y, z, rng, cid_current, param2_current, cid, param2)
	if cids.deepslate_tile_slab[cid] then
		if position_float (x, y, z) < F_03 then
			return cid_air, 0
		end
		return cid, param2
	end
	return rule_generic (x, y, z, rng, cid_current, param2_current, cid, param2)
end

-- minecraft:protected_blocks (#features_cannot_replace).
local function protected_blocks (x, y, z, rng, cid_current, param2_current, cid, param2)
	if cid_current and cids.protected[cid_current] then
		return nil, nil
	end
	return cid, param2
end

-- Chests with a loot table (the LootTable block entity tag).
local LOOT_TABLE_FIELD = "mcl_levelgen:loot_table"
local get_current_template_meta = mcl_levelgen.get_current_template_meta
local set_current_template_meta = mcl_levelgen.set_current_template_meta

local function chest_loot (x, y, z, rng, cid_current, param2_current, cid, param2)
	if cid == cids.chest then
		local meta = get_current_template_meta ()
		local loot = meta and meta.fields and meta.fields[LOOT_TABLE_FIELD]
		if loot then
			set_current_template_meta (nil, true)
			mcl_levelgen.set_loot_table (x, y, z, rng, loot)
		end
	end
	return cid, param2
end

local generic_degradation = {
	rotate_wire,
	block_rot,
	rule_generic,
	protected_blocks,
	chest_loot,
}

local start_degradation = {
	rotate_wire,
	rule_generic,
	protected_blocks,
	chest_loot,
}

local walls_degradation = {
	rotate_wire,
	block_rot,
	rule_walls,
	protected_blocks,
	chest_loot,
}

local no_processors = {
	rotate_wire,
	chest_loot,
}

------------------------------------------------------------------------
-- Template pools.
------------------------------------------------------------------------

local prefix = mcl_levelgen.prefix .. "/templates/ancient_city/"

local function S (name, weight, processors)
	return {
		weight = weight,
		type = "single",
		template = prefix .. name .. ".dat",
		processors = processors,
		projection = "rigid",
	}
end

local function E (weight)
	return {
		weight = weight,
		type = "empty",
	}
end

local register_pool = mcl_levelgen.register_mc_template_pool
local G = generic_degradation
local W = walls_degradation

register_pool ("mcl_levelgen:ancient_city/city_center", {
	elements = {
		S ("city_center/city_center_1", 1, start_degradation),
		S ("city_center/city_center_2", 1, start_degradation),
		S ("city_center/city_center_3", 1, start_degradation),
	},
})

register_pool ("mcl_levelgen:ancient_city/city_center/walls", {
	elements = {
		S ("city_center/walls/bottom_1", 1, G),
		S ("city_center/walls/bottom_2", 1, G),
		S ("city_center/walls/bottom_left_corner", 1, G),
		S ("city_center/walls/bottom_right_corner_1", 1, G),
		S ("city_center/walls/bottom_right_corner_2", 1, G),
		S ("city_center/walls/left", 1, G),
		S ("city_center/walls/right", 1, G),
		S ("city_center/walls/top", 1, G),
		S ("city_center/walls/top_right_corner", 1, G),
		S ("city_center/walls/top_left_corner", 1, G),
	},
})

register_pool ("mcl_levelgen:ancient_city/city/entrance", {
	elements = {
		S ("city/entrance/entrance_connector", 1, G),
		S ("city/entrance/entrance_path_1", 1, G),
		S ("city/entrance/entrance_path_2", 1, G),
		S ("city/entrance/entrance_path_3", 1, G),
		S ("city/entrance/entrance_path_4", 1, G),
		S ("city/entrance/entrance_path_5", 1, G),
	},
})

register_pool ("mcl_levelgen:ancient_city/structures", {
	elements = {
		E (7),
		S ("structures/barracks", 4, G),
		S ("structures/chamber_1", 4, G),
		S ("structures/chamber_2", 4, G),
		S ("structures/chamber_3", 4, G),
		S ("structures/sauna_1", 4, G),
		S ("structures/small_statue", 4, G),
		S ("structures/large_ruin_1", 1, G),
		S ("structures/tall_ruin_1", 1, G),
		S ("structures/tall_ruin_2", 1, G),
		S ("structures/tall_ruin_3", 2, G),
		S ("structures/tall_ruin_4", 2, G),
		{
			weight = 1,
			type = "list",
			projection = "rigid",
			elements = {
				S ("structures/camp_1", nil, G),
				S ("structures/camp_2", nil, G),
				S ("structures/camp_3", nil, G),
			},
		},
		S ("structures/medium_ruin_1", 1, G),
		S ("structures/medium_ruin_2", 1, G),
		S ("structures/small_ruin_1", 1, G),
		S ("structures/small_ruin_2", 1, G),
		S ("structures/large_pillar_1", 1, G),
		S ("structures/medium_pillar_1", 1, G),
		{
			weight = 1,
			type = "list",
			projection = "rigid",
			elements = {
				S ("structures/ice_box_1", nil, no_processors),
			},
		},
	},
})

register_pool ("mcl_levelgen:ancient_city/sculk", {
	elements = {
		{
			weight = 6,
			type = "feature",
			feature = "mcl_sculk:sculk_patch_ancient_city",
			projection = "rigid",
		},
		E (1),
	},
})

register_pool ("mcl_levelgen:ancient_city/walls", {
	elements = {
		S ("walls/intact_corner_wall_1", 1, W),
		S ("walls/intact_intersection_wall_1", 1, W),
		S ("walls/intact_lshape_wall_1", 1, W),
		S ("walls/intact_horizontal_wall_1", 1, W),
		S ("walls/intact_horizontal_wall_2", 1, W),
		S ("walls/intact_horizontal_wall_stairs_1", 1, W),
		S ("walls/intact_horizontal_wall_stairs_2", 1, W),
		S ("walls/intact_horizontal_wall_stairs_3", 1, W),
		S ("walls/intact_horizontal_wall_stairs_4", 4, W),
		S ("walls/intact_horizontal_wall_passage_1", 3, W),
		S ("walls/ruined_corner_wall_1", 1, W),
		S ("walls/ruined_corner_wall_2", 1, W),
		S ("walls/ruined_horizontal_wall_stairs_1", 2, W),
		S ("walls/ruined_horizontal_wall_stairs_2", 2, W),
		S ("walls/ruined_horizontal_wall_stairs_3", 3, W),
		S ("walls/ruined_horizontal_wall_stairs_4", 3, W),
	},
})

register_pool ("mcl_levelgen:ancient_city/walls/no_corners", {
	elements = {
		S ("walls/intact_horizontal_wall_1", 1, W),
		S ("walls/intact_horizontal_wall_2", 1, W),
		S ("walls/intact_horizontal_wall_stairs_1", 1, W),
		S ("walls/intact_horizontal_wall_stairs_2", 1, W),
		S ("walls/intact_horizontal_wall_stairs_3", 1, W),
		S ("walls/intact_horizontal_wall_stairs_4", 1, W),
		-- Minecraft's pool names a template that does not exist,
		-- which loads as an empty template.
		S ("walls/intact_horizontal_wall_stairs_5", 1, W),
		S ("walls/intact_horizontal_wall_bridge", 1, W),
	},
})

------------------------------------------------------------------------
-- Sculk patches.
------------------------------------------------------------------------

local notify_generated = mcl_levelgen.notify_generated
local schedule_feature_placement = mcl_levelgen.schedule_feature_placement

local function place_feature_piece (self, level, terrain, rng, x1, z1, x2, z2)
	local x, y, z = self.x, self.y, self.z
	if x < x1 or x > x2 or z < z1 or z > z2 then
		return
	end
	if not mcl_levelgen.enable_ersatz then
		schedule_feature_placement (x, y, z, self.configured_feature)
	else
		-- Features cannot be placed by the ersatz level
		-- generator; the main environment places this one
		-- (see below).
		local seed = mathabs (rng:next_integer ())
		notify_generated ("mcl_levelgen:ersatz_ancient_city_sculk",
				  x, y, z, { x, y, z, seed, }, true)
	end
end

local function feature_piece (feature, x, y, z)
	return {
		configured_feature = feature,
		place = place_feature_piece,
		x = x, y = y, z = z,
		bbox = { x, y, z, x, y, z, },
	}
end

------------------------------------------------------------------------
-- Structure registration.
------------------------------------------------------------------------

mcl_levelgen.modify_biome_groups ({ "DeepDark", }, {
	has_ancient_city = true,
})

local MINUS_27 = function (_) return -27 end

mcl_levelgen.register_structure ("mcl_levelgen:ancient_city", {
	create_start = mcl_levelgen.mc_jigsaw_create_start,
	step = mcl_levelgen.UNDERGROUND_DECORATION,
	terrain_adaptation = "beard_box",
	biomes = mcl_levelgen.build_biome_list ({ "#has_ancient_city", }),
	start_pool = "mcl_levelgen:ancient_city/city_center",
	start_jigsaw_name = "minecraft:city_anchor",
	max_distance_from_center = 116,
	size = 7,
	start_height = MINUS_27,
	feature_piece = feature_piece,
	-- spawn_overrides with "bounding_box": "full" apply to the whole
	-- structure start, which is recorded under this name.
	record_full_bounds = "mcl_levelgen:ancient_city_bounds",
})

mcl_levelgen.register_structure_set ("mcl_levelgen:ancient_cities", {
	structures = {
		"mcl_levelgen:ancient_city",
	},
	placement = R (1.0, "default", 24, 8, 20083232, "linear", nil, nil),
})

------------------------------------------------------------------------
-- Spawn overrides.
--
-- ancient_city.json overrides every mob category with an empty list
-- for the full bounding box of the structure, recorded as
-- mcl_levelgen:ancient_city_bounds.
------------------------------------------------------------------------

if not mcl_levelgen.is_levelgen_environment and core.register_on_mods_loaded then
	core.register_on_mods_loaded (function ()
		if not core.global_exists ("mcl_mobs")
			or not mcl_mobs.suppress_spawning_in_structure then
			return
		end
		for category, _ in pairs (mcl_mobs.spawn_categories or {}) do
			mcl_mobs.suppress_spawning_in_structure ("mcl_levelgen:ancient_city_bounds",
								 category)
		end
	end)
end

------------------------------------------------------------------------
-- Ersatz sculk patches (main environment).
------------------------------------------------------------------------

if mcl_levelgen.enable_ersatz and not mcl_levelgen.is_levelgen_environment
	and mcl_levelgen.register_notification_handler then

dofile (mcl_levelgen.prefix .. "/sculk_spreader.lua")
local sculk = mcl_levelgen.sculk_spreader

local vm_data, vm_param2 = {}, {}
local vm_area
local vm_dirty = false

-- Minecraft coordinates -> Luanti positions in the overworld.
local y_offset = nil

local function vm_get (x, y, z)
	local ly = y - y_offset
	local lz = -z - 1
	if not vm_area:contains (x, ly, lz) then
		return nil, nil
	end
	local i = vm_area:index (x, ly, lz)
	local cid = vm_data[i]
	if cid == core.CONTENT_IGNORE then
		return nil, nil
	end
	return cid, vm_param2[i]
end

local function vm_set (x, y, z, cid, param2)
	local ly = y - y_offset
	local lz = -z - 1
	if not vm_area:contains (x, ly, lz) then
		return
	end
	local i = vm_area:index (x, ly, lz)
	if vm_data[i] == core.CONTENT_IGNORE then
		return
	end
	vm_data[i] = cid
	vm_param2[i] = param2
	vm_dirty = true
end

-- nodeprops.lua's shape queries read blocks through
-- mcl_levelgen.get_block, which the main environment does not
-- otherwise provide.
local nodeprops_ready = false
local function vm_sturdy (x, y, z)
	return mcl_levelgen.get_sturdy_faces (x, y, z)
end

local CFG = {
	charge_count = 10,
	amount_per_charge = 32,
	spread_attempts = 64,
	growth_rounds = 0,
	spread_rounds = 1,
	catalyst_chance = 0.5,
	shriekers = true,
}

local function place_ersatz_sculk_patch (x, y, z, seed)
	if not nodeprops_ready then
		local old = mcl_levelgen.get_block
		mcl_levelgen.get_block = vm_get
		mcl_levelgen.initialize_nodeprops_in_async_env ()
		mcl_levelgen.get_block = old
		nodeprops_ready = true
	end
	local dim = mcl_levelgen.get_dimension ("mcl_levelgen:overworld")
	y_offset = dim.y_offset
	local lx, ly, lz = x, y - y_offset, -z - 1
	local vm = VoxelManip (vector.new (lx - 16, ly - 16, lz - 16),
			       vector.new (lx + 16, ly + 16, lz + 16))
	local emin, emax = vm:get_emerged_area ()
	vm_area = VoxelArea (emin, emax)
	vm:get_data (vm_data)
	vm:get_param2_data (vm_param2)
	vm_dirty = false
	sculk.set_accessors (vm_get, vm_set, vm_sturdy)
	local rng = mcl_levelgen.jvm_random (mcl_levelgen.extull (seed))
	sculk.place_sculk_patch_sequence (x, y, z, CFG, rng)
	if vm_dirty then
		vm:set_data (vm_data)
		vm:set_param2_data (vm_param2)
		vm:write_to_map (true)
	end
	if vm.close then
		vm:close ()
	end
end

local pending = {}

local function run_pending ()
	local list = pending
	pending = {}
	for _, data in ipairs (list) do
		local x, y, z, seed = data[1], data[2], data[3], data[4]
		local dim = mcl_levelgen.get_dimension ("mcl_levelgen:overworld")
		local lx, ly, lz = x, y - dim.y_offset, -z - 1
		core.emerge_area (vector.new (lx - 16, ly - 16, lz - 16),
				  vector.new (lx + 16, ly + 16, lz + 16),
				  function (_, _, remaining)
					  if remaining == 0 then
						  place_ersatz_sculk_patch (x, y, z, seed)
					  end
				  end)
	end
end

mcl_levelgen.register_notification_handler ("mcl_levelgen:ersatz_ancient_city_sculk",
	function (_, data)
		for _, item in ipairs (data) do
			table.insert (pending, item)
		end
		core.after (0, run_pending)
	end)

end
