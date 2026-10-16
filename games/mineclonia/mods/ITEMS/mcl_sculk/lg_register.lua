------------------------------------------------------------------------
-- Sculk world generation (level generator script).
--
-- Minecraft 26.3's sculk_patch_deep_dark, sculk_patch_ancient_city and
-- sculk_vein features.  The spreading logic itself (SculkSpreader's
-- world generation spreader, its charge cursors, SculkBlock,
-- SculkVeinBlock, MultifaceSpreader and MultifaceGrowthFeature) lives
-- in mcl_levelgen/sculk_spreader.lua so that the ersatz level
-- generator can share it.
------------------------------------------------------------------------

dofile (mcl_levelgen.prefix .. "/sculk_spreader.lua")

local sculk = mcl_levelgen.sculk_spreader
local run_minp = mcl_levelgen.placement_run_minp
local run_maxp = mcl_levelgen.placement_run_maxp
local mathmin = math.min
local mathmax = math.max

------------------------------------------------------------------------
-- Level access with lighting bookkeeping.
------------------------------------------------------------------------

local x1, y1, z1, x2, y2, z2

local function tracking_set_block (x, y, z, cid, param2)
	mcl_levelgen.set_block (x, y, z, cid, param2)
	x1, y1, z1 = mathmin (x1, x), mathmin (y1, y), mathmin (z1, z)
	x2, y2, z2 = mathmax (x2, x), mathmax (y2, y), mathmax (z2, z)
end

local function begin_placement ()
	sculk.set_accessors (mcl_levelgen.get_block, tracking_set_block,
			     mcl_levelgen.get_sturdy_faces)
	x1, y1, z1 = math.huge, math.huge, math.huge
	x2, y2, z2 = -math.huge, -math.huge, -math.huge
end

local function end_placement ()
	if x1 <= x2 then
		mcl_levelgen.fix_lighting (x1, y1, z1, x2, y2, z2)
	end
end

local function in_run_p (y)
	return y >= run_minp.y and y <= run_maxp.y
end

------------------------------------------------------------------------
-- Sculk patches.
--
-- sculk_patch_deep_dark: sequence [sculk_patch, simple_block
-- sculk_catalyst (random_chance 0.5, has_sturdy_face up below)].
--
-- sculk_patch_ancient_city: sequence [sculk_patch, overlay [the same
-- catalyst, simple_block sculk_shrieker can_summon=true (count
-- uniform 1-3, offset uniform -2..2 per axis, matching_block_tag air
-- and has_sturdy_face up below)]].
------------------------------------------------------------------------

mcl_levelgen.register_feature ("mcl_sculk:sculk_patch", {
	place = function (_, x, y, z, cfg, rng)
		if not in_run_p (y) then
			return false
		end
		begin_placement ()
		local placed = sculk.place_sculk_patch_sequence (x, y, z, cfg, rng)
		end_placement ()
		return placed
	end,
})

local SCULK_PATCH = {
	charge_count = 10,
	amount_per_charge = 32,
	spread_attempts = 64,
	growth_rounds = 0,
	spread_rounds = 1,
	catalyst_chance = 0.5,
}

mcl_levelgen.register_configured_feature ("mcl_sculk:sculk_patch_deep_dark",
	table.merge (SCULK_PATCH, {
		feature = "mcl_sculk:sculk_patch",
		shriekers = false,
	}))

mcl_levelgen.register_configured_feature ("mcl_sculk:sculk_patch_ancient_city",
	table.merge (SCULK_PATCH, {
		feature = "mcl_sculk:sculk_patch",
		shriekers = true,
	}))

local uniform_height = mcl_levelgen.uniform_height
local overworld = mcl_levelgen.overworld_preset
local OVERWORLD_MIN = overworld.min_y

local function constant (n)
	return function (_)
		return n
	end
end

mcl_levelgen.register_placed_feature ("mcl_sculk:sculk_patch_deep_dark", {
	configured_feature = "mcl_sculk:sculk_patch_deep_dark",
	placement_modifiers = {
		mcl_levelgen.build_count (constant (256)),
		mcl_levelgen.build_in_square (),
		mcl_levelgen.build_height_range (uniform_height (OVERWORLD_MIN, 256)),
		mcl_levelgen.build_in_biome (),
	},
})

-- The ancient city's sculk pool places this configured feature
-- through its feature pool elements (placed_feature
-- sculk_patch_ancient_city has no placement modifiers).
mcl_levelgen.register_placed_feature ("mcl_sculk:sculk_patch_ancient_city", {
	configured_feature = "mcl_sculk:sculk_patch_ancient_city",
	placement_modifiers = {},
})

------------------------------------------------------------------------
-- Sculk veins (MultifaceGrowthFeature).
------------------------------------------------------------------------

mcl_levelgen.register_feature ("mcl_sculk:sculk_vein", {
	place = function (_, x, y, z, cfg, rng)
		if not in_run_p (y) then
			return false
		end
		begin_placement ()
		local placed = sculk.place_multiface_growth (x, y, z, cfg, rng)
		end_placement ()
		return placed
	end,
})

local can_be_placed_on = {}
for _, name in ipairs ({
	"mcl_core:stone",
	"mcl_core:andesite",
	"mcl_core:diorite",
	"mcl_core:granite",
	"mcl_dripstone:dripstone_block",
	"mcl_amethyst:calcite",
	"mcl_deepslate:tuff",
	"mcl_deepslate:deepslate",
}) do
	if core.registered_nodes[name] then
		can_be_placed_on[core.get_content_id (name)] = true
	end
end

mcl_levelgen.register_configured_feature ("mcl_sculk:sculk_vein", {
	feature = "mcl_sculk:sculk_vein",
	search_range = 20,
	can_place_on_floor = true,
	can_place_on_ceiling = true,
	can_place_on_wall = true,
	chance_of_spreading = 1.0,
	can_be_placed_on = can_be_placed_on,
})

mcl_levelgen.register_placed_feature ("mcl_sculk:sculk_vein", {
	configured_feature = "mcl_sculk:sculk_vein",
	placement_modifiers = {
		mcl_levelgen.build_count (uniform_height (204, 250)),
		mcl_levelgen.build_in_square (),
		mcl_levelgen.build_height_range (uniform_height (OVERWORLD_MIN, 256)),
		mcl_levelgen.build_in_biome (),
	},
})
