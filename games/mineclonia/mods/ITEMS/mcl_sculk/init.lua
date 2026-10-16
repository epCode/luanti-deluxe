------------------------------------------------------------------------
-- Sculk: a port of Minecraft Java Edition 26.3's sculk blocks
-- (SculkBlock, SculkVeinBlock, SculkCatalystBlock + SculkSpreader,
-- SculkSensorBlock, CalibratedSculkSensorBlock, SculkShriekerBlock and
-- their block entities) on top of mcl_redstone (game ticks, scheduled ticks,
-- signals) and mcl_gameevent (game events, VibrationSystem).
------------------------------------------------------------------------

mcl_sculk = {}
local S = core.get_translator(core.get_current_modname())
mcl_sculk.S = S
local modpath = core.get_modpath(core.get_current_modname())

local R = mcl_redstone
local DOWN, UP, NORTH, SOUTH, WEST, EAST = R.DOWN, R.UP, R.NORTH, R.SOUTH, R.WEST, R.EAST
mcl_sculk.DIRECTIONS = {DOWN, UP, NORTH, SOUTH, WEST, EAST}

------------------------------------------------------------------------
-- Sounds (SoundType.SCULK, SCULK_VEIN, SCULK_CATALYST, SCULK_SENSOR,
-- SCULK_SHRIEKER)
------------------------------------------------------------------------

mcl_sculk.sounds = {
	sculk = mcl_mcsounds.node_sound("block.sculk"),
	vein = mcl_mcsounds.node_sound("block.sculk_vein"),
	catalyst = mcl_mcsounds.node_sound("block.sculk_catalyst"),
	sensor = mcl_mcsounds.node_sound("block.sculk_sensor"),
	shrieker = mcl_mcsounds.node_sound("block.sculk_shrieker"),
}

-- Level.playSound(null, pos, event, BLOCKS, volume, pitch)
function mcl_sculk.play(event, pos, volume, pitch)
	mcl_mcsounds.play(event, {pos = pos}, volume, pitch, true)
end

------------------------------------------------------------------------
-- Block tags
------------------------------------------------------------------------

local function name_set(names)
	local s = {}
	for _, n in ipairs(names) do
		s[n] = true
	end
	return s
end

-- BlockTags.SCULK_REPLACEABLE: #base_stone_overworld, #substrate_overworld
-- (#dirt, #mud, #moss_blocks, #grass_blocks), #terracotta, #nylium,
-- #base_stone_nether, sand, red_sand, gravel, soul_sand, soul_soil, calcite,
-- smooth_basalt, clay, dripstone_block, end_stone, red_sandstone, sandstone
local replaceable_names = {
	"mcl_core:stone", "mcl_core:granite", "mcl_core:diorite", "mcl_core:andesite",
	"mcl_deepslate:tuff", "mcl_deepslate:deepslate",
	"mcl_core:dirt", "mcl_core:coarse_dirt", "mcl_lush_caves:rooted_dirt",
	"mcl_mud:mud", "mcl_mangrove:mangrove_mud_roots", "mcl_lush_caves:moss",
	"mcl_pale_oak:pale_moss",
	"mcl_core:dirt_with_grass", "mcl_core:dirt_with_grass_snow",
	"mcl_crimson:crimson_nylium", "mcl_crimson:warped_nylium",
	"mcl_nether:netherrack", "mcl_blackstone:basalt", "mcl_blackstone:blackstone",
	"mcl_core:sand", "mcl_core:redsand", "mcl_core:gravel", "mcl_nether:soul_sand",
	"mcl_blackstone:soul_soil", "mcl_amethyst:calcite", "mcl_blackstone:basalt_smooth",
	"mcl_core:clay", "mcl_dripstone:dripstone_block", "mcl_end:end_stone",
	"mcl_core:redsandstone", "mcl_core:sandstone",
}
local replaceable = {}
mcl_sculk.replaceable = replaceable

core.register_on_mods_loaded(function()
	for _, n in ipairs(replaceable_names) do
		if core.registered_nodes[n] then
			replaceable[n] = true
		end
	end
	for name, def in pairs(core.registered_nodes) do
		local g = def.groups or {}
		-- #terracotta and #grass_blocks
		if (g.hardened_clay or 0) > 0 and not name:find("glazed") then
			replaceable[name] = true
		end
		if (g.grass_block or 0) > 0 then
			replaceable[name] = true
		end
	end
end)

function mcl_sculk.is_replaceable(name)
	return replaceable[name] == true
end

-- BlockTags.VIBRATION_RESONATORS
mcl_sculk.vibration_resonators = name_set({"mcl_amethyst:amethyst_block"})

------------------------------------------------------------------------
-- Sculk veins (MultifaceBlock). A vein is a set of faces: bit 1 << d for
-- the Minecraft direction d (DOWN=0 ... EAST=5) towards the block it lies
-- on. One face is "mcl_sculk:vein" with a wallmounted param2 (like glow
-- lichen); more faces are "mcl_sculk:vein_<n><w><s><e><u><d>".
------------------------------------------------------------------------

local band, bor, lshift = bit.band, bit.bor, bit.lshift

local WALLMOUNTED_TO_DIR = {[0] = UP, [1] = DOWN, [2] = EAST, [3] = WEST, [4] = NORTH, [5] = SOUTH}
local DIR_TO_WALLMOUNTED = {[UP] = 0, [DOWN] = 1, [EAST] = 2, [WEST] = 3, [NORTH] = 4, [SOUTH] = 5}
local LETTERS = {{NORTH, "n"}, {WEST, "w"}, {SOUTH, "s"}, {EAST, "e"}, {UP, "u"}, {DOWN, "d"}}

local vein_mask_by_name = {}

function mcl_sculk.vein_name(mask)
	local name = "mcl_sculk:vein_"
	for _, l in ipairs(LETTERS) do
		if band(mask, lshift(1, l[1])) ~= 0 then
			name = name .. l[2]
		end
	end
	return name
end

local function popcount(mask)
	local n = 0
	while mask > 0 do
		n = n + band(mask, 1)
		mask = bit.rshift(mask, 1)
	end
	return n
end
mcl_sculk.popcount = popcount

-- The node for a vein with the faces of `mask` (nil for no face)
function mcl_sculk.vein_node(mask)
	if mask == 0 then
		return nil
	end
	if popcount(mask) == 1 then
		for d = 0, 5 do
			if mask == lshift(1, d) then
				return {name = "mcl_sculk:vein", param2 = DIR_TO_WALLMOUNTED[d]}
			end
		end
	end
	return {name = mcl_sculk.vein_name(mask), param2 = 0}
end

-- The faces of a vein node (0 if the node is no vein)
function mcl_sculk.vein_mask(node)
	if node.name == "mcl_sculk:vein" then
		local d = WALLMOUNTED_TO_DIR[node.param2 % 8]
		return d and lshift(1, d) or 0
	end
	return vein_mask_by_name[node.name] or 0
end

function mcl_sculk.is_vein(node)
	return node.name == "mcl_sculk:vein" or vein_mask_by_name[node.name] ~= nil
end

function mcl_sculk.has_face(mask, d)
	return band(mask, lshift(1, d)) ~= 0
end

function mcl_sculk.with_face(mask, d)
	return bor(mask, lshift(1, d))
end

function mcl_sculk.without_face(mask, d)
	return band(mask, bit.bnot(lshift(1, d)))
end

-- MultifaceBlock.canAttachTo(level, pos, direction): the neighbour's face
-- towards pos is full (support or collision shape)
function mcl_sculk.can_attach_to(pos, d)
	local npos = R.rel(pos, d)
	local nnode = core.get_node(npos)
	if nnode.name == "ignore" then
		return false
	end
	return R.is_face_sturdy(npos, nnode, R.opposite[d], "full")
end

mcl_sculk._vein_mask_by_name = vein_mask_by_name

------------------------------------------------------------------------
-- Experience from mined blocks (DropExperienceBlock / spawnAfterBreak):
-- not with silk touch, not in creative mode.
------------------------------------------------------------------------

function mcl_sculk.drop_experience(pos, digger, amount)
	if not digger or not digger:is_player() then
		return
	end
	if core.is_creative_enabled(digger:get_player_name()) then
		return
	end
	local tool = digger:get_wielded_item()
	if mcl_enchanting.has_enchantment(tool, "silk_touch") then
		return
	end
	mcl_experience.throw_xp(pos, amount)
end

------------------------------------------------------------------------
-- Compatibility: mobs used to report their death XP here.
------------------------------------------------------------------------

function mcl_sculk.handle_death()
	return false
end

dofile(modpath .. "/particles.lua")
dofile(modpath .. "/spreader.lua")
dofile(modpath .. "/blocks.lua")
dofile(modpath .. "/sensor.lua")
dofile(modpath .. "/shrieker.lua")
dofile(modpath .. "/step_on.lua")

core.register_craftitem("mcl_sculk:echo_shard", {
	description = S("Echo Shard"),
	_doc_items_longdesc = S("Echo shards are found in ancient cities. They are used to craft recovery compasses."),
	groups = {craftitem = 1, rarity = 1},
	inventory_image = "mcl_sculk_echo_shard.png",
	wield_image = "mcl_sculk_echo_shard.png",
})

mcl_levelgen.register_levelgen_script(modpath .. "/lg_register.lua")
