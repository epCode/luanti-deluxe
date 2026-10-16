-- Minecraft's waterloggable blocks (SimpleWaterloggedBlock and friends in
-- 26.3). Each one gets a waterlogged twin node holding a water source; the
-- engine makes the water flow out of it and draws it, builtin handles
-- digging and placing into water, and mcl_init's node wrappers keep the
-- water through state changes (see mcl_init/waterlogging.lua).
--
-- The twins are registered by mcl_waterlogging.register_all(), which
-- _mcl_autogroup (the last mod) runs once every block is registered.

local WATER = "mcl_core:water_source"

local function group(name)
	return function(n, def)
		return (def.groups[name] or 0) > 0
	end
end

local function prefix(p)
	return function(n)
		return n:sub(1, #p) == p
	end
end

local function names(list)
	local set = {}
	for _, n in ipairs(list) do
		set[n] = true
	end
	return function(n)
		return set[n] == true
	end
end

local function pattern(p)
	return function(n)
		return n:find(p) ~= nil
	end
end

-- Lit forms that become their unlit twin's waterlogged form
-- (CandleBlock / CampfireBlock.placeLiquid put the flame out)
local extinguished = {}
for i = 1, 4 do
	extinguished["mcl_candles:candle_lit_" .. i] = "mcl_candles:candle_" .. i
end
extinguished["mcl_campfires:campfire_lit"] = "mcl_campfires:campfire"
extinguished["mcl_campfires:soul_campfire_lit"] = "mcl_campfires:soul_campfire"

-- Which blocks can be waterlogged
local waterloggable = {
	-- StairBlock, SlabBlock (not double slabs)
	function(n)
		return (n:find("^mcl_stairs:stair_") or n:find("^mcl_stairs:slab_"))
			and not n:find("_double")
	end,
	group("fence"),           -- CrossCollisionBlock (fences; not fence gates)
	group("pane"),            -- CrossCollisionBlock (panes and bars)
	group("wall"),            -- WallBlock
	group("trapdoor"),        -- TrapDoorBlock
	group("sign"),            -- SignBlock (standing, wall and hanging signs)
	group("leaves"),          -- LeavesBlock
	group("rail"),            -- BaseRailBlock
	names({"mcl_core:ladder", "mcl_core:barrier", "mcl_bamboo:scaffolding",
		"mcl_bamboo:scaffolding_horizontal", "mcl_conduits:conduit",
		"mcl_tools:heavy_core", "mcl_pottery_sherds:pot",
		"mcl_lush_caves:hanging_roots", "mcl_mangrove:propagule",
		"mcl_amethyst:amethyst_cluster", "mcl_campfires:campfire",
		"mcl_campfires:soul_campfire"}),
	-- ChestBlock, EnderChestBlock (not shulker boxes)
	function(n)
		return n:find("^mcl_chests:") and n:find("chest") ~= nil
	end,
	prefix("mcl_lanterns:"),  -- LanternBlock, ChainBlock
	prefix("mcl_core:light_"), -- LightBlock
	prefix("mcl_core:glow_lichen"), -- MultifaceBlock
	prefix("mcl_sculk:vein"), -- MultifaceBlock
	pattern("^mcl_sculk:.*sensor"), -- SculkSensorBlock
	prefix("mcl_sculk:shrieker"), -- SculkShriekerBlock
	pattern("^mcl_candles:candle_%d$"), -- CandleBlock
	pattern("^mcl_copper:.*_grate"), -- WeatheringCopperGrateBlock
	prefix("mcl_lightning_rods:"), -- LightningRodBlock
	pattern("^mcl_dripstone:dripstone_[tb][a-z]*_"), -- SpeleothemBlock
	pattern("^mcl_amethyst:.*_amethyst_bud$"), -- AmethystClusterBlock
	prefix("mcl_lush_caves:dripleaf"), -- Small/BigDripleaf(Stem)Block
	prefix("mcl_mangrove:propagule_hanging"), -- MangrovePropaguleBlock
}

local function is_waterloggable(name, def)
	if def.waterlogged_liquid or def.waterlogged_alternative or
			name:find("_waterlogged$") then
		return false
	end
	for _, test in ipairs(waterloggable) do
		if test(name, def) then
			return true
		end
	end
	return false
end

-- Everything that differs between a block and its waterlogged twin
local function twin_overrides(def)
	return {
		groups = table.merge(def.groups, {
			water = 4, liquid = 3, puts_out_fire = 1,
		}),
		-- Mobs and players are in water there
		_liquidtype = "source",
		-- Explosions: the fluid's blast resistance counts too
		-- (ExplosionDamageCalculator.getBlockExplosionResistance)
		_mcl_blast_resistance = math.max(def._mcl_blast_resistance or 0, 100),
		_doc_items_create_entry = false,
		_mcl_baseitem = def._mcl_baseitem,
	}
end

-- Callbacks of a twin see the node under its dry name, so code comparing
-- names keeps working (see mcl_waterlogging.as_dry)
local as_dry = mcl_waterlogging.as_dry
local node_callbacks = {
	"on_rightclick", "on_punch", "on_dig", "after_dig_node", "on_rotate",
	"preserve_metadata", "on_flood",
}

local function dry_callbacks(def, o)
	for _, field in ipairs(node_callbacks) do
		local f = def[field]
		if type(f) == "function" then
			o[field] = function(pos, node, ...)
				return f(pos, as_dry(node), ...)
			end
		end
	end
end

function mcl_waterlogging.register_twin(name, overrides)
	local def = core.registered_nodes[name]
	local o = twin_overrides(def)
	dry_callbacks(def, o)
	for k, v in pairs(overrides or {}) do
		o[k] = v
	end
	return core.register_waterlogged_alternative(name, WATER, o)
end

local registered = false
function mcl_waterlogging.register_all()
	if registered then
		return
	end
	registered = true

	local list = {}
	for name, def in pairs(core.registered_nodes) do
		if is_waterloggable(name, def) and not extinguished[name] then
			table.insert(list, name)
		end
	end
	table.sort(list)

	for _, name in ipairs(list) do
		mcl_waterlogging.register_twin(name)
	end

	-- Mangrove roots keep their old twin's name
	if core.registered_nodes["mcl_mangrove:mangrove_roots"] then
		mcl_waterlogging.register_twin("mcl_mangrove:mangrove_roots",
			{name = "mcl_mangrove:water_logged_roots"})
	end

	-- Leaf decay swaps leaves and orphan leaves through a VoxelManip by
	-- these names: waterlogged leaves turn into waterlogged leaves
	local function wet_of(name)
		local def = name and core.registered_nodes[name]
		return def and def.waterlogged_alternative
	end
	for _, name in ipairs(list) do
		local def = core.registered_nodes[name]
		local wet = def.waterlogged_alternative
		if def._mcl_leaves and wet_of(def._mcl_leaves) and wet_of(def._mcl_orphan_leaves) then
			core.override_item(wet, {
				_mcl_leaves = wet_of(def._mcl_leaves),
				_mcl_orphan_leaves = wet_of(def._mcl_orphan_leaves),
			})
		end
	end

	for lit, unlit in pairs(extinguished) do
		local wet = core.registered_nodes[unlit] and core.registered_nodes[unlit].waterlogged_alternative
		if core.registered_nodes[lit] and wet then
			core.override_item(lit, {waterlogged_alternative = wet})
		end
	end

	core.log("action", "[mcl_waterlogging] " .. #list .. " waterloggable blocks")
end

-- ABMs and LBMs naming dry blocks run on their twins too, and their actions
-- see twins under their dry names
local function add_twins(list)
	if type(list) == "string" then
		list = {list}
	end
	local out = table.copy(list)
	for _, n in ipairs(list) do
		local def = core.registered_nodes[n]
		local wet = def and def.waterlogged_alternative
		if wet and wet ~= "" and (def.waterlogged_liquid or "") == "" then
			table.insert(out, wet)
		end
	end
	return out
end

core.register_on_mods_loaded(function()
	for _, abm in ipairs(core.registered_abms) do
		abm.nodenames = add_twins(abm.nodenames)
		if abm.neighbors then
			abm.neighbors = add_twins(abm.neighbors)
		end
		local action = abm.action
		abm.action = function(pos, node, ...)
			return action(pos, as_dry(node), ...)
		end
	end
	for _, lbm in ipairs(core.registered_lbms) do
		lbm.nodenames = add_twins(lbm.nodenames)
		local action = lbm.action
		if action then
			lbm.action = function(pos, node, ...)
				return action(pos, as_dry(node), ...)
			end
		end
	end
end)
