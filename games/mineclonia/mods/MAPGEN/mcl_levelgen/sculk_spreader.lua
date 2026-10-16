------------------------------------------------------------------------
-- Sculk spreading for world generation.
--
-- A port of Minecraft 26.3's SculkSpreader (createWorldGenSpreader),
-- SculkSpreader.ChargeCursor, SculkBehaviour.DEFAULT, SculkBlock,
-- SculkVeinBlock, MultifaceBlock, MultifaceSpreader, SculkPatchFeature
-- and MultifaceGrowthFeature (for sculk veins), operating on an
-- abstract level accessor so that it is usable both by level generator
-- features and by the ersatz level generator's main environment.
--
-- Coordinates are Minecraft's (north = -Z).  Sculk veins are
-- multi-face nodes named as in PLAN.md (mcl_sculk:vein with a
-- wallmounted param2 for a single face, mcl_sculk:vein_<nwseud> for
-- several faces).
------------------------------------------------------------------------

if mcl_levelgen.sculk_spreader then
	return
end

local sculk = {}
mcl_levelgen.sculk_spreader = sculk

local ipairs = ipairs
local floor = math.floor
local mathmax = math.max
local mathmin = math.min
local sqrt = math.sqrt
local band = bit.band
local bor = bit.bor
local bnot = bit.bnot

local FACE_NORTH = mcl_levelgen.FACE_NORTH
local FACE_WEST = mcl_levelgen.FACE_WEST
local FACE_SOUTH = mcl_levelgen.FACE_SOUTH
local FACE_EAST = mcl_levelgen.FACE_EAST
local FACE_UP = mcl_levelgen.FACE_UP
local FACE_DOWN = mcl_levelgen.FACE_DOWN

-- Direction.values (): DOWN, UP, NORTH, SOUTH, WEST, EAST.
local DOWN, UP, NORTH, SOUTH, WEST, EAST = 1, 2, 3, 4, 5, 6
local DIRECTIONS = { DOWN, UP, NORTH, SOUTH, WEST, EAST, }
local DX = { 0, 0, 0, 0, -1, 1, }
local DY = { -1, 1, 0, 0, 0, 0, }
local DZ = { 0, 0, -1, 1, 0, 0, }
local OPPOSITE = { UP, DOWN, SOUTH, NORTH, EAST, WEST, }
local AXIS = { 2, 2, 3, 3, 1, 1, } -- x = 1, y = 2, z = 3.
local FACE_BIT = {
	FACE_DOWN, FACE_UP, FACE_NORTH, FACE_SOUTH, FACE_WEST, FACE_EAST,
}
sculk.DIRECTIONS = DIRECTIONS
sculk.FACE_BIT = FACE_BIT

------------------------------------------------------------------------
-- Level access.
------------------------------------------------------------------------

local get_block, set_block, get_sturdy_faces

-- GET (X, Y, Z) -> CID, PARAM2 (or nil if inaccessible);
-- SET (X, Y, Z, CID, PARAM2); STURDY (X, Y, Z) -> FACE_* mask.
function sculk.set_accessors (get, set, sturdy)
	get_block, set_block, get_sturdy_faces = get, set, sturdy
end

------------------------------------------------------------------------
-- Node classification.
------------------------------------------------------------------------

local initialized = false
local cid_air = core.CONTENT_AIR
local cid_sculk, cid_vein
local cid_sensor, cid_shrieker_summon
local is_catalyst = {}
local is_inhibitor = {}
local is_moving_piston = {}
local is_water_source = {}
local is_water = {}
local is_other_fluid = {}
local is_fire = {}
local is_replaceable = {} -- BlockBehaviour.canBeReplaced ()
local sculk_replaceable = {}
local sculk_replaceable_world_gen = {}
local vein_cids = {}    -- face mask -> cid
local vein_param2s = {} -- face mask -> param2
local vein_masks = {}   -- (cid << 8) + param2 -> face mask
local is_vein_cid = {}

local function cid_of (name)
	if not core.registered_nodes[name] then
		return nil
	end
	local ok, cid = pcall (core.get_content_id, name)
	return ok and cid or nil
end

local function mark (tbl, names)
	for _, name in ipairs (names) do
		if name:sub (1, 6) == "group:" then
			local group = name:sub (7)
			for nodename, def in pairs (core.registered_nodes) do
				if def.groups and (def.groups[group] or 0) > 0 then
					tbl[core.get_content_id (nodename)] = true
				end
			end
		else
			local cid = cid_of (name)
			if cid then
				tbl[cid] = true
			end
		end
	end
end

-- Single faces of sculk veins are stored as wallmounted param2
-- values, exactly as glow lichen.
local SINGLE_FACE_PARAM2 = {
	[FACE_NORTH] = 4,
	[FACE_SOUTH] = 5,
	[FACE_EAST] = 2,
	[FACE_WEST] = 3,
	[FACE_UP] = 0,
	[FACE_DOWN] = 1,
}

local function vein_node_for_mask (mask)
	if SINGLE_FACE_PARAM2[mask] then
		return "mcl_sculk:vein", SINGLE_FACE_PARAM2[mask]
	end
	local name = "mcl_sculk:vein_"
	if band (mask, FACE_NORTH) ~= 0 then name = name .. "n" end
	if band (mask, FACE_WEST) ~= 0 then name = name .. "w" end
	if band (mask, FACE_SOUTH) ~= 0 then name = name .. "s" end
	if band (mask, FACE_EAST) ~= 0 then name = name .. "e" end
	if band (mask, FACE_UP) ~= 0 then name = name .. "u" end
	if band (mask, FACE_DOWN) ~= 0 then name = name .. "d" end
	return name, 0
end
sculk.vein_node_for_mask = vein_node_for_mask

-- Tag `minecraft:sculk_replaceable' (and the world generation
-- variant) mapped to Mineclonia nodes.
sculk.SCULK_REPLACEABLE = {
	-- #base_stone_overworld
	"mcl_core:stone", "mcl_core:granite", "mcl_core:diorite",
	"mcl_core:andesite", "mcl_deepslate:tuff", "mcl_deepslate:deepslate",
	-- #substrate_overworld (#dirt, #mud, #moss_blocks, #grass_blocks)
	"mcl_core:dirt", "mcl_core:coarse_dirt", "mcl_lush_caves:rooted_dirt",
	"mcl_mud:mud", "mcl_mangrove:mangrove_mud_roots",
	"mcl_lush_caves:moss", "mcl_pale_oak:pale_moss",
	"mcl_core:dirt_with_grass", "mcl_core:podzol", "mcl_core:mycelium",
	-- #terracotta
	"group:hardened_clay",
	-- #nylium
	"mcl_crimson:crimson_nylium", "mcl_crimson:warped_nylium",
	-- #base_stone_nether
	"mcl_nether:netherrack", "mcl_blackstone:basalt",
	"mcl_blackstone:blackstone",
	"mcl_core:sand", "mcl_core:redsand", "mcl_core:gravel",
	"mcl_nether:soul_sand", "mcl_blackstone:soul_soil",
	"mcl_amethyst:calcite", "mcl_blackstone:basalt_smooth",
	"mcl_core:clay", "mcl_dripstone:dripstone_block", "mcl_end:end_stone",
	"mcl_core:redsandstone", "mcl_core:sandstone",
	-- minecraft:sulfur and minecraft:cinnabar do not exist in Mineclonia.
}

sculk.SCULK_REPLACEABLE_WORLD_GEN_EXTRA = {
	"mcl_deepslate:deepslate_bricks",
	"mcl_deepslate:deepslate_tiles",
	"mcl_deepslate:deepslate_cobbled",
	"mcl_deepslate:deepslate_bricks_cracked",
	"mcl_deepslate:deepslate_tiles_cracked",
	"mcl_deepslate:deepslate_polished",
}

function sculk.initialize ()
	if initialized then
		return
	end
	initialized = true
	cid_sculk = cid_of ("mcl_sculk:sculk")
	cid_vein = cid_of ("mcl_sculk:vein")
	cid_sensor = cid_of ("mcl_sculk:sensor")
	cid_shrieker_summon = cid_of ("mcl_sculk:shrieker_can_summon")
	mark (is_catalyst, { "mcl_sculk:catalyst", "mcl_sculk:catalyst_bloom", })
	-- #sculk_growth_inhibitors: sculk_sensor, sculk_shrieker.
	mark (is_inhibitor, {
		"mcl_sculk:sensor", "mcl_sculk:sensor_active",
		"mcl_sculk:sensor_cooldown", "mcl_sculk:shrieker",
		"mcl_sculk:shrieker_can_summon",
	})
	mark (is_moving_piston, {
		"mcl_pistons:moving_piston", "mcl_pistons:moving_piston_end",
		"mcl_pistons:moving_piston_half",
	})
	mark (is_water_source, { "mcl_core:water_source", "mclx_core:river_water_source", })
	mark (is_water, {
		"mcl_core:water_source", "mclx_core:river_water_source",
		"mcl_core:water_flowing", "mclx_core:river_water_flowing",
	})
	mark (is_other_fluid, {
		"mcl_core:lava_source", "mcl_core:lava_flowing",
		"mcl_nether:nether_lava_source", "mcl_nether:nether_lava_flowing",
	})
	mark (is_fire, { "mcl_fire:fire", "mcl_fire:eternal_fire",
			 "mcl_blackstone:soul_fire", })
	for name, def in pairs (core.registered_nodes) do
		if def.buildable_to then
			is_replaceable[core.get_content_id (name)] = true
		end
	end
	is_replaceable[cid_air] = true
	mark (sculk_replaceable, sculk.SCULK_REPLACEABLE)
	mark (sculk_replaceable_world_gen, sculk.SCULK_REPLACEABLE)
	mark (sculk_replaceable_world_gen, sculk.SCULK_REPLACEABLE_WORLD_GEN_EXTRA)
	for mask = 1, 63 do
		local name, param2 = vein_node_for_mask (mask)
		local cid = cid_of (name)
		if cid then
			vein_cids[mask] = cid
			vein_param2s[mask] = param2
			vein_masks[cid * 256 + param2] = mask
			is_vein_cid[cid] = true
		end
	end
end

local function vein_mask (cid, param2)
	if not cid or not is_vein_cid[cid] then
		return 0
	end
	return vein_masks[cid * 256 + (param2 or 0)] or 0
end
sculk.vein_mask = vein_mask

local function is_air (cid)
	return cid == cid_air
end

-- BlockState.isFaceSturdy (level, pos, direction).
local function face_sturdy_p (x, y, z, dir)
	return band (get_sturdy_faces (x, y, z), FACE_BIT[dir]) ~= 0
end

-- MultifaceBlock.canAttachTo (level, pos, directionTowardsNeighbour).
local function can_attach_to (x, y, z, dir)
	local nx, ny, nz = x + DX[dir], y + DY[dir], z + DZ[dir]
	if not get_block (nx, ny, nz) then
		return false
	end
	return face_sturdy_p (nx, ny, nz, OPPOSITE[dir])
end

local function is_full_block (x, y, z)
	if not get_block (x, y, z) then
		return false
	end
	return get_sturdy_faces (x, y, z) == 0x3f
end

local function set_vein (x, y, z, mask)
	if mask == 0 then
		set_block (x, y, z, cid_air, 0)
		return true
	end
	local cid = vein_cids[mask]
	if not cid then
		return false
	end
	set_block (x, y, z, cid, vein_param2s[mask])
	return true
end

------------------------------------------------------------------------
-- Random number generation helpers.
------------------------------------------------------------------------

local function shuffled_directions (rng)
	local list = { DOWN, UP, NORTH, SOUTH, WEST, EAST, }
	mcl_levelgen.fisher_yates (list, rng)
	return list
end

-- RandomSource.nextFloat with exact single precision results.
local function next_float (rng)
	local f = rng:next_float ()
	return f
end
sculk.next_float = next_float

local function f32 (x)
	if x == 0 then
		return 0
	end
	local m, e = math.frexp (x)
	m = floor (m * 16777216 + 0.5) / 16777216
	return math.ldexp (m, e)
end

------------------------------------------------------------------------
-- MultifaceSpreader (sculk vein configuration).
------------------------------------------------------------------------

-- SAME_POSITION, SAME_PLANE, WRAP_AROUND.
local SPREAD_DEFAULT = { 1, 2, 3, }
local SPREAD_SAME_POSITION = { 1, }

local function spread_pos (kind, x, y, z, spread_dir, from_face)
	if kind == 1 then
		return x, y, z, spread_dir
	elseif kind == 2 then
		return x + DX[spread_dir], y + DY[spread_dir], z + DZ[spread_dir],
			from_face
	else
		return x + DX[spread_dir] + DX[from_face],
			y + DY[spread_dir] + DY[from_face],
			z + DZ[spread_dir] + DZ[from_face],
			OPPOSITE[spread_dir]
	end
end

-- MultifaceBlock.isValidStateForPlacement.
local function valid_state_for_placement (cid, param2, x, y, z, dir)
	local mask = vein_mask (cid, param2)
	if mask ~= 0 and band (mask, FACE_BIT[dir]) ~= 0 then
		return false
	end
	return can_attach_to (x, y, z, dir)
end

-- SculkVeinSpreaderConfig.stateCanBeReplaced.
local function vein_state_can_be_replaced (sx, sy, sz, x, y, z, dir, cid, param2)
	local acid = get_block (x + DX[dir], y + DY[dir], z + DZ[dir])
	if acid == cid_sculk or is_catalyst[acid] or is_moving_piston[acid] then
		return false
	end
	if math.abs (sx - x) + math.abs (sy - y) + math.abs (sz - z) == 2 then
		local o = OPPOSITE[dir]
		local nx, ny, nz = sx + DX[o], sy + DY[o], sz + DZ[o]
		if get_block (nx, ny, nz) and face_sturdy_p (nx, ny, nz, dir) then
			return false
		end
	end
	-- A fluid other than (still) water.
	if is_other_fluid[cid] or (is_water[cid] and not is_water_source[cid]) then
		return false
	end
	if is_fire[cid] then
		return false
	end
	-- existingState.canBeReplaced () || DefaultSpreaderConfig's test
	-- (air, the vein itself, or a water source).
	return is_replaceable[cid] or is_air (cid) or is_vein_cid[cid]
		or is_water_source[cid] or false
end

-- DefaultSpreaderConfig.canSpreadInto.
local function can_spread_into (sx, sy, sz, x, y, z, face)
	local cid, param2 = get_block (x, y, z)
	if not cid then
		return false
	end
	return vein_state_can_be_replaced (sx, sy, sz, x, y, z, face, cid, param2)
		and valid_state_for_placement (cid, param2, x, y, z, face)
end

-- MultifaceBlock.getStateForPlacement -> face mask or nil.
local function state_for_placement (cid, param2, x, y, z, dir)
	if not valid_state_for_placement (cid, param2, x, y, z, dir) then
		return nil
	end
	return bor (vein_mask (cid, param2), FACE_BIT[dir])
end

-- SpreadConfig.placeBlock.
local function spread_to_face (x, y, z, face)
	local cid, param2 = get_block (x, y, z)
	if not cid then
		return false
	end
	local mask = state_for_placement (cid, param2, x, y, z, face)
	if mask then
		return set_vein (x, y, z, mask)
	end
	return false
end

-- STATE_MASK: face mask of the state being spread from (0 if it is
-- not a vein); OTHER_SOURCE: config.isOtherBlockValidAsSource (state).
local function spread_from_face_toward_direction (state_mask, other_source, x, y, z,
						  from_face, spread_dir, types)
	if AXIS[spread_dir] == AXIS[from_face] then
		return false
	end
	if other_source
		or (band (state_mask, FACE_BIT[from_face]) ~= 0
		    and band (state_mask, FACE_BIT[spread_dir]) == 0) then
		for _, kind in ipairs (types) do
			local px, py, pz, face = spread_pos (kind, x, y, z, spread_dir, from_face)
			if can_spread_into (x, y, z, px, py, pz, face) then
				return spread_to_face (px, py, pz, face)
			end
		end
	end
	return false
end

-- MultifaceSpreader.spreadAll.
local function spread_all (cid, param2, x, y, z, types)
	local state_mask = vein_mask (cid, param2)
	local other_source = not is_vein_cid[cid]
	local n = 0
	for _, face in ipairs (DIRECTIONS) do
		if other_source or band (state_mask, FACE_BIT[face]) ~= 0 then
			for _, spread_dir in ipairs (DIRECTIONS) do
				if spread_from_face_toward_direction (state_mask, other_source,
								      x, y, z, face, spread_dir,
								      types) then
					n = n + 1
				end
			end
		end
	end
	return n
end

-- MultifaceSpreader.spreadFromFaceTowardRandomDirection.
local function spread_from_face_toward_random_direction (mask, x, y, z, face, rng)
	local dirs = shuffled_directions (rng)
	for _, spread_dir in ipairs (dirs) do
		if spread_from_face_toward_direction (mask, false, x, y, z, face,
						      spread_dir, SPREAD_DEFAULT) then
			return true
		end
	end
	return false
end

------------------------------------------------------------------------
-- Sculk behaviours.
------------------------------------------------------------------------

local KIND_DEFAULT, KIND_SCULK, KIND_VEIN = 0, 1, 2

local function behaviour_of (cid)
	if cid == cid_sculk then
		return KIND_SCULK
	elseif cid and is_vein_cid[cid] then
		return KIND_VEIN
	end
	return KIND_DEFAULT
end

-- SculkVeinBlock.regrow.
local function vein_regrow (x, y, z, facings)
	local mask = 0
	for _, face in ipairs (DIRECTIONS) do
		if band (facings, FACE_BIT[face]) ~= 0 and can_attach_to (x, y, z, face) then
			mask = bor (mask, FACE_BIT[face])
		end
	end
	if mask == 0 then
		return false
	end
	return set_vein (x, y, z, mask)
end

-- SculkBehaviour.attemptSpreadVein (and DEFAULT's override).
local function attempt_spread_vein (kind, x, y, z, cid, param2, facings)
	if kind == KIND_DEFAULT then
		if facings == nil then
			local c, p = get_block (x, y, z)
			return spread_all (c, p, x, y, z, SPREAD_SAME_POSITION) > 0
		elseif facings ~= 0 then
			if not is_air (cid) and not is_water_source[cid] then
				return false
			end
			return vein_regrow (x, y, z, facings)
		end
	end
	return spread_all (cid, param2, x, y, z, SPREAD_DEFAULT) > 0
end

-- SculkVeinBlock.onDischarged.
local function vein_on_discharged (cid, param2, x, y, z)
	local mask = vein_mask (cid, param2)
	if mask == 0 then
		return
	end
	for _, dir in ipairs (DIRECTIONS) do
		if band (mask, FACE_BIT[dir]) ~= 0
			and get_block (x + DX[dir], y + DY[dir], z + DZ[dir]) == cid_sculk then
			mask = band (mask, bnot (FACE_BIT[dir]))
		end
	end
	if mask == 0 then
		local c = get_block (x, y, z)
		if is_water[c] then
			set_block (x, y, z, c, 0)
		else
			set_block (x, y, z, cid_air, 0)
		end
	else
		set_vein (x, y, z, mask)
	end
end

local function on_discharged (kind, cid, param2, x, y, z)
	if kind == KIND_VEIN then
		vein_on_discharged (cid, param2, x, y, z)
	end
end

-- SculkSpreader.createWorldGenSpreader ().
local GROWTH_SPAWN_COST = 50
local NO_GROWTH_RADIUS = 1
local CHARGE_DECAY_RATE = 5
local ADDITIONAL_DECAY_RATE = 10

local function sculk_can_place_growth (x, y, z)
	local cid = get_block (x, y + 1, z)
	if not (is_air (cid) or is_water_source[cid]) then
		return false
	end
	local n = 0
	for bx = x - 4, x + 4 do
		for by = y, y + 2 do
			for bz = z - 4, z + 4 do
				local c = get_block (bx, by, bz)
				if c and is_inhibitor[c] then
					n = n + 1
					if n > 2 then
						return false
					end
				end
			end
		end
	end
	return true
end

local function decay_penalty (x, y, z, ox, oy, oz, charge)
	local dx, dy, dz = x - ox, y - oy, z - oz
	local d = f32 (sqrt (dx * dx + dy * dy + dz * dz)) - NO_GROWTH_RADIUS
	local outer = f32 (d * d)
	local max_reach = (24 - NO_GROWTH_RADIUS) * (24 - NO_GROWTH_RADIUS)
	local factor = mathmin (1.0, f32 (outer / max_reach))
	local v = f32 (f32 (charge * factor) * 0.5)
	local t = v < 0 and -floor (-v) or floor (v)
	return mathmax (1, t)
end

-- SculkBlock.attemptUseCharge.
local function sculk_attempt_use_charge (cursor, ox, oy, oz, rng)
	local charge = cursor.charge
	if charge ~= 0 and rng:next_within (CHARGE_DECAY_RATE) == 0 then
		local x, y, z = cursor.x, cursor.y, cursor.z
		local dx, dy, dz = x - ox, y - oy, z - oz
		local close = dx * dx + dy * dy + dz * dz < NO_GROWTH_RADIUS * NO_GROWTH_RADIUS
		if not close and sculk_can_place_growth (x, y, z) then
			if rng:next_within (GROWTH_SPAWN_COST) < charge then
				local cid
				if rng:next_within (11) == 0 then
					cid = cid_shrieker_summon
				else
					cid = cid_sensor
				end
				if cid then
					set_block (x, y + 1, z, cid, 0)
				end
			end
			return mathmax (0, charge - GROWTH_SPAWN_COST)
		else
			if rng:next_within (ADDITIONAL_DECAY_RATE) ~= 0 then
				return charge
			end
			return charge - (close and 1
					 or decay_penalty (x, y, z, ox, oy, oz, charge))
		end
	end
	return charge
end

-- SculkVeinBlock.attemptPlaceSculk.
local function vein_attempt_place_sculk (x, y, z, rng)
	local cid, param2 = get_block (x, y, z)
	local mask = vein_mask (cid, param2)
	local dirs = shuffled_directions (rng)
	for _, support in ipairs (dirs) do
		if band (mask, FACE_BIT[support]) ~= 0 then
			local sx, sy, sz = x + DX[support], y + DY[support], z + DZ[support]
			local scid = get_block (sx, sy, sz)
			if scid and sculk_replaceable_world_gen[scid] then
				set_block (sx, sy, sz, cid_sculk, 0)
				spread_all (cid_sculk, 0, sx, sy, sz, SPREAD_DEFAULT)
				local skip = OPPOSITE[support]
				for _, d in ipairs (DIRECTIONS) do
					if d ~= skip then
						local vx, vy, vz = sx + DX[d], sy + DY[d], sz + DZ[d]
						local vcid, vparam2 = get_block (vx, vy, vz)
						if vcid and is_vein_cid[vcid] then
							vein_on_discharged (vcid, vparam2, vx, vy, vz)
						end
					end
				end
				return true
			end
		end
	end
	return false
end

-- SculkVeinBlock.attemptUseCharge.
local function vein_attempt_use_charge (cursor, rng, spread_veins)
	if spread_veins and vein_attempt_place_sculk (cursor.x, cursor.y, cursor.z, rng) then
		return cursor.charge - 1
	end
	if rng:next_within (CHARGE_DECAY_RATE) == 0 then
		return floor (cursor.charge * 0.5)
	end
	return cursor.charge
end

local function attempt_use_charge (kind, cursor, ox, oy, oz, rng, spread_veins)
	if kind == KIND_SCULK then
		return sculk_attempt_use_charge (cursor, ox, oy, oz, rng)
	elseif kind == KIND_VEIN then
		return vein_attempt_use_charge (cursor, rng, spread_veins)
	else
		return cursor.decay_delay > 0 and cursor.charge or 0
	end
end

local function update_decay_delay (kind, age)
	if kind == KIND_DEFAULT then
		return mathmax (age - 1, 0)
	end
	return 1
end

------------------------------------------------------------------------
-- ChargeCursor.
------------------------------------------------------------------------

-- ChargeCursor.NON_CORNER_NEIGHBOURS: BlockPos.betweenClosed (-1, -1,
-- -1, 1, 1, 1) (X fastest, then Y, then Z) without corners or the
-- origin.
local NON_CORNER_NEIGHBOURS = {}
for z = -1, 1 do
	for y = -1, 1 do
		for x = -1, 1 do
			if (x == 0 or y == 0 or z == 0)
				and not (x == 0 and y == 0 and z == 0) then
				table.insert (NON_CORNER_NEIGHBOURS, { x, y, z, })
			end
		end
	end
end

-- SculkVeinBlock.hasSubstrateAccess.
local function has_substrate_access (cid, param2, x, y, z)
	local mask = vein_mask (cid, param2)
	if mask == 0 then
		return false
	end
	for _, dir in ipairs (DIRECTIONS) do
		if band (mask, FACE_BIT[dir]) ~= 0 then
			local c = get_block (x + DX[dir], y + DY[dir], z + DZ[dir])
			if c and sculk_replaceable[c] then
				return true
			end
		end
	end
	return false
end

local function is_unobstructed (x, y, z, dir)
	local tx, ty, tz = x + DX[dir], y + DY[dir], z + DZ[dir]
	if not get_block (tx, ty, tz) then
		return true
	end
	return not face_sturdy_p (tx, ty, tz, OPPOSITE[dir])
end

local function movement_unobstructed_p (x, y, z, dx, dy, dz)
	if math.abs (dx) + math.abs (dy) + math.abs (dz) == 1 then
		return true
	end
	local dir_x = dx < 0 and WEST or EAST
	local dir_y = dy < 0 and DOWN or UP
	local dir_z = dz < 0 and NORTH or SOUTH
	if dx == 0 then
		return is_unobstructed (x, y, z, dir_y)
			or is_unobstructed (x, y, z, dir_z)
	elseif dy == 0 then
		return is_unobstructed (x, y, z, dir_x)
			or is_unobstructed (x, y, z, dir_z)
	else
		return is_unobstructed (x, y, z, dir_x)
			or is_unobstructed (x, y, z, dir_y)
	end
end

local function valid_movement_pos (x, y, z, rng, ox, oz)
	local offsets = {}
	for i = 1, #NON_CORNER_NEIGHBOURS do
		offsets[i] = NON_CORNER_NEIGHBOURS[i]
	end
	mcl_levelgen.fisher_yates (offsets, rng)
	local rx, ry, rz = x, y, z
	for _, offset in ipairs (offsets) do
		local nx, ny, nz = x + offset[1], y + offset[2], z + offset[3]
		local ddx, ddz = ox - nx, oz - nz
		if ddx * ddx + ddz * ddz <= 144 then
			local cid, param2 = get_block (nx, ny, nz)
			if cid and (cid == cid_sculk or is_vein_cid[cid])
				and movement_unobstructed_p (x, y, z, offset[1],
							     offset[2], offset[3]) then
				rx, ry, rz = nx, ny, nz
				if has_substrate_access (cid, param2, nx, ny, nz) then
					break
				end
			end
		end
	end
	if rx == x and ry == y and rz == z then
		return nil
	end
	return rx, ry, rz
end

-- ChargeCursor.update (world generation spreader).
local function cursor_update (cursor, ox, oy, oz, rng, spread_veins)
	if cursor.charge <= 0 then
		return
	end
	if cursor.update_delay > 0 then
		cursor.update_delay = cursor.update_delay - 1
		return
	end
	local x, y, z = cursor.x, cursor.y, cursor.z
	local cid, param2 = get_block (x, y, z)
	if not cid then
		cursor.charge = 0
		return
	end
	local kind = behaviour_of (cid)
	if spread_veins and attempt_spread_vein (kind, x, y, z, cid, param2,
						 cursor.facings) then
		if kind ~= KIND_SCULK then
			cid, param2 = get_block (x, y, z)
			kind = behaviour_of (cid)
		end
	end
	cursor.charge = attempt_use_charge (kind, cursor, ox, oy, oz, rng, spread_veins)
	if cursor.charge <= 0 then
		on_discharged (kind, cid, param2, x, y, z)
	else
		local tx, ty, tz = valid_movement_pos (x, y, z, rng, ox, oz)
		if tx then
			on_discharged (kind, cid, param2, x, y, z)
			cursor.x, cursor.y, cursor.z = tx, ty, tz
			cid, param2 = get_block (tx, ty, tz)
		else
			on_discharged (kind, cid, param2, x, y, z)
			cursor.charge = 0
			return
		end
		if cid == cid_sculk then
			-- MultifaceBlock.availableFaces of a non-multiface
			-- block: the empty set.
			cursor.facings = 0
		elseif cid and is_vein_cid[cid] then
			cursor.facings = vein_mask (cid, param2)
		end
		cursor.decay_delay = update_decay_delay (kind, cursor.decay_delay)
		cursor.update_delay = 1
	end
end

-- SculkSpreader.updateCursors.
local function update_cursors (cursors, ox, oy, oz, rng, spread_veins)
	local processed = {}
	local mergeable = {}
	for _, cursor in ipairs (cursors) do
		if mathmax (math.abs (cursor.x - ox), math.abs (cursor.y - oy),
			    math.abs (cursor.z - oz)) <= 1024 then
			cursor_update (cursor, ox, oy, oz, rng, spread_veins)
			if cursor.charge > 0 then
				local key = cursor.x .. "," .. cursor.y .. "," .. cursor.z
				local existing = mergeable[key]
				if not existing then
					mergeable[key] = cursor
					table.insert (processed, cursor)
				else
					table.insert (processed, cursor)
					if cursor.charge < existing.charge then
						mergeable[key] = cursor
					end
				end
			end
		end
	end
	return processed
end

local function add_cursors (cursors, x, y, z, charge)
	while charge > 0 do
		local current = mathmin (charge, 1000)
		if #cursors < 32 then
			table.insert (cursors, {
				x = x, y = y, z = z,
				charge = current,
				decay_delay = 1,
				update_delay = 0,
				facings = nil,
			})
		end
		charge = charge - current
	end
end

------------------------------------------------------------------------
-- SculkPatchFeature.
------------------------------------------------------------------------

local function can_spread_from (x, y, z)
	local cid = get_block (x, y, z)
	if not cid then
		return false
	end
	if cid == cid_sculk or is_vein_cid[cid] then
		return true
	end
	if not is_air (cid) and not is_water_source[cid] then
		return false
	end
	for _, dir in ipairs (DIRECTIONS) do
		if is_full_block (x + DX[dir], y + DY[dir], z + DZ[dir]) then
			return true
		end
	end
	return false
end

-- CFG = { charge_count, amount_per_charge, spread_attempts,
-- growth_rounds, spread_rounds, }.
function sculk.place_sculk_patch (x, y, z, cfg, rng)
	sculk.initialize ()
	if not cid_sculk or not can_spread_from (x, y, z) then
		return false
	end
	local cursors = {}
	local total_rounds = cfg.spread_rounds + cfg.growth_rounds
	for round = 0, total_rounds - 1 do
		for _ = 1, cfg.charge_count do
			add_cursors (cursors, x, y, z, cfg.amount_per_charge)
		end
		local spread_veins = round < cfg.spread_rounds
		for _ = 1, cfg.spread_attempts do
			if #cursors > 0 then
				cursors = update_cursors (cursors, x, y, z, rng, spread_veins)
			end
		end
		cursors = {}
	end
	return true
end

------------------------------------------------------------------------
-- MultifaceGrowthFeature (sculk veins).
------------------------------------------------------------------------

-- CFG = { search_range, can_place_on_floor, can_place_on_ceiling,
-- can_place_on_wall, chance_of_spreading, can_be_placed_on = { [cid]
-- = true, ... }, }.

local function valid_directions (cfg)
	local list = {}
	if cfg.can_place_on_ceiling then
		table.insert (list, UP)
	end
	if cfg.can_place_on_floor then
		table.insert (list, DOWN)
	end
	if cfg.can_place_on_wall then
		-- Direction.Plane.HORIZONTAL.
		table.insert (list, NORTH)
		table.insert (list, EAST)
		table.insert (list, SOUTH)
		table.insert (list, WEST)
	end
	return list
end

local function air_or_water_p (cid)
	return is_air (cid) or is_water[cid] or false
end

local function place_growth_if_possible (cfg, x, y, z, cid, param2, rng, dirs)
	for _, dir in ipairs (dirs) do
		local ncid = get_block (x + DX[dir], y + DY[dir], z + DZ[dir])
		if ncid and cfg.can_be_placed_on[ncid] then
			local mask = state_for_placement (cid, param2, x, y, z, dir)
			if not mask then
				return false
			end
			if not set_vein (x, y, z, mask) then
				return false
			end
			if rng:next_float () < cfg.chance_of_spreading then
				spread_from_face_toward_random_direction (mask, x, y, z, dir, rng)
			end
			return true
		end
	end
	return false
end

function sculk.place_multiface_growth (x, y, z, cfg, rng)
	sculk.initialize ()
	local cid, param2 = get_block (x, y, z)
	if not cid or not air_or_water_p (cid) or not cid_vein then
		return false
	end
	local dirs = valid_directions (cfg)
	mcl_levelgen.fisher_yates (dirs, rng)
	if place_growth_if_possible (cfg, x, y, z, cid, param2, rng, dirs) then
		return true
	end
	for _, search_dir in ipairs (dirs) do
		local placement = {}
		local except = OPPOSITE[search_dir]
		for _, d in ipairs (valid_directions (cfg)) do
			if d ~= except then
				table.insert (placement, d)
			end
		end
		mcl_levelgen.fisher_yates (placement, rng)
		-- MultifaceGrowthFeature only ever probes the block
		-- adjacent to the origin (pos.setWithOffset (origin, ...)).
		local px, py, pz = x + DX[search_dir], y + DY[search_dir],
			z + DZ[search_dir]
		for _ = 1, cfg.search_range do
			local c, p = get_block (px, py, pz)
			if not c or (not air_or_water_p (c) and not is_vein_cid[c]) then
				break
			end
			if place_growth_if_possible (cfg, px, py, pz, c, p, rng, placement) then
				return true
			end
		end
	end
	return false
end

------------------------------------------------------------------------
-- Miscellaneous.
------------------------------------------------------------------------

-- BlockPredicate has_sturdy_face (direction = up, offset = 0, -1, 0).
function sculk.has_sturdy_face_below (x, y, z)
	if not get_block (x, y - 1, z) then
		return false
	end
	return band (get_sturdy_faces (x, y - 1, z), FACE_UP) ~= 0
end

function sculk.is_air_at (x, y, z)
	local cid = get_block (x, y, z)
	return cid == cid_air
end

-- The configured features sculk_patch_deep_dark (CFG.shriekers false)
-- and sculk_patch_ancient_city (CFG.shriekers true): a sequence of the
-- sculk patch and, if it was placed, the catalyst (and shriekers),
-- whose placement modifiers are evaluated depth first as in
-- FeaturePlacer.
function sculk.place_sculk_patch_sequence (x, y, z, cfg, rng)
	if not sculk.place_sculk_patch (x, y, z, cfg, rng) then
		return false
	end
	local catalyst = cid_of ("mcl_sculk:catalyst")
	local placed_any = false
	-- random_chance 0.5, block_predicate_filter has_sturdy_face.
	if rng:next_float () < cfg.catalyst_chance
		and sculk.has_sturdy_face_below (x, y, z) and catalyst then
		set_block (x, y, z, catalyst, 0)
		placed_any = true
	end
	if not cfg.shriekers then
		return placed_any
	end
	-- count uniform 1..3, offset uniform -2..2 (x, y, z),
	-- block_predicate_filter (air, has_sturdy_face up below).
	local n = 1 + rng:next_within (3)
	for _ = 1, n do
		local px = x + rng:next_within (5) - 2
		local py = y + rng:next_within (5) - 2
		local pz = z + rng:next_within (5) - 2
		if cid_shrieker_summon and sculk.is_air_at (px, py, pz)
			and sculk.has_sturdy_face_below (px, py, pz) then
			set_block (px, py, pz, cid_shrieker_summon, 0)
			placed_any = true
		end
	end
	return placed_any
end

function sculk.get_cids ()
	sculk.initialize ()
	return {
		sculk = cid_sculk,
		vein = cid_vein,
		sensor = cid_sensor,
		shrieker_can_summon = cid_shrieker_summon,
	}
end

return sculk
