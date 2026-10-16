-- Waterlogging (engine node fields `waterlogged_liquid` and
-- `waterlogged_alternative`, see mcl_waterlogging for the registrations).
--
-- Minecraft keeps the WATERLOGGED block state through every other state
-- change (stair shapes, open trapdoors, chest halves, copper ageing, ...)
-- and Level.removeBlock leaves the fluid behind. Here that state is part of
-- the node name, so node changes keep it instead. This runs in the first
-- mod so that mods caching these functions get the wrapped ones.

mcl_waterlogging = {}

-- Liquids that waterlog as another one: Minecraft has a single water
mcl_waterlogging.equivalent_liquids = {
	["mclx_core:river_water_source"] = "mcl_core:water_source",
}

local registered_nodes = core.registered_nodes

local function is_set(s)
	return s ~= nil and s ~= ""
end

-- The liquid source a node holds (as a source liquid node or waterlogged),
-- for waterlogging purposes
function mcl_waterlogging.held_source(node)
	local liquid, is_source = core.get_node_liquid(node)
	if not is_source then
		return nil
	end
	return mcl_waterlogging.equivalent_liquids[liquid] or liquid
end

-- The waterlogged form of the dry node `name` for the liquid source
-- `liquid` (equivalent liquids count), or nil
function mcl_waterlogging.get_waterlogged(name, liquid)
	liquid = mcl_waterlogging.equivalent_liquids[liquid] or liquid
	return core.get_waterlogged_node(name, liquid)
end

-- The dry form of a waterlogged node name, other names unchanged
function mcl_waterlogging.dry_name(name)
	local def = registered_nodes[name]
	if def and is_set(def.waterlogged_liquid) and is_set(def.waterlogged_alternative) then
		return def.waterlogged_alternative
	end
	return name
end

-- A copy of `node` under its dry name if it is waterlogged, else `node`.
-- Code written for dry blocks can compare names as usual; nodes it sets
-- get waterlogged again by the wrappers below.
function mcl_waterlogging.as_dry(node)
	local dry = node and mcl_waterlogging.dry_name(node.name)
	if not dry or dry == node.name then
		return node
	end
	return {name = dry, param1 = node.param1, param2 = node.param2}
end

-- Whether the node at pos can take the liquid source `liquid`
function mcl_waterlogging.can_place_liquid(pos, liquid)
	return mcl_waterlogging.get_waterlogged(core.get_node(pos).name, liquid) ~= nil
end

-- SimpleWaterloggedBlock.placeLiquid
function mcl_waterlogging.place_liquid(pos, liquid)
	liquid = mcl_waterlogging.equivalent_liquids[liquid] or liquid
	return core.place_liquid(pos, liquid)
end

-- The liquid a waterlogged node at pos holds, or nil
function mcl_waterlogging.get_waterlogged_liquid(pos)
	local def = registered_nodes[core.get_node(pos).name]
	return def and is_set(def.waterlogged_liquid) and def.waterlogged_liquid or nil
end

-- The node to put where `old` is instead of `node`: a dry liquid container
-- going where a liquid source is gets waterlogged
local function keep_waterlogged(pos, node)
	local def = registered_nodes[node.name]
	if not def or not is_set(def.waterlogged_alternative) or
			is_set(def.waterlogged_liquid) then
		return node
	end
	local liquid = mcl_waterlogging.held_source(core.get_node(pos))
	local wet = liquid and core.get_waterlogged_node(node.name, liquid)
	if not wet then
		return node
	end
	return {name = wet, param1 = node.param1, param2 = node.param2}
end

local set_node = core.set_node
function core.set_node(pos, node)
	return set_node(pos, keep_waterlogged(pos, node))
end

local add_node = core.add_node
function core.add_node(pos, node)
	return add_node(pos, keep_waterlogged(pos, node))
end

local swap_node = core.swap_node
function core.swap_node(pos, node)
	return swap_node(pos, keep_waterlogged(pos, node))
end

-- Level.removeBlock: the held liquid stays
local remove_node = core.remove_node
function core.remove_node(pos)
	local def = registered_nodes[core.get_node(pos).name]
	if def and is_set(def.waterlogged_liquid) then
		return set_node(pos, {name = def.waterlogged_liquid})
	end
	return remove_node(pos)
end
