-- Waterlogging: nodes holding a liquid source, like Minecraft's waterlogged
-- block states. See `waterlogged_liquid` in lua_api.md.

local registered_nodes = core.registered_nodes
-- Games may wrap these to keep nodes waterlogged; the helpers below must
-- change exactly what they say
local swap_node = core.swap_node
local set_node = core.set_node
local remove_node = core.remove_node

local function is_set(s)
	return s ~= nil and s ~= ""
end

-- The liquid source in a node (name or node table), and whether the liquid
-- is a source: the source of a liquid node, the held liquid of a
-- waterlogged node, nil for anything else (FluidState)
function core.get_node_liquid(node)
	local name = type(node) == "table" and node.name or node
	local def = registered_nodes[name]
	if not def then
		return nil
	end
	if is_set(def.waterlogged_liquid) then
		return def.waterlogged_liquid, true
	end
	if def.liquidtype == "source" then
		return name, true
	elseif def.liquidtype == "flowing" and is_set(def.liquid_alternative_source) then
		return def.liquid_alternative_source, false
	end
	return nil
end

-- The waterlogged form of the dry node `name` holding `liquid`, or nil
-- (SimpleWaterloggedBlock.canPlaceLiquid)
function core.get_waterlogged_node(name, liquid)
	local def = registered_nodes[name]
	if not def or is_set(def.waterlogged_liquid) or
			not is_set(def.waterlogged_alternative) then
		return nil
	end
	local wet = registered_nodes[def.waterlogged_alternative]
	if not wet or wet.waterlogged_liquid ~= liquid then
		return nil
	end
	return def.waterlogged_alternative
end

-- SimpleWaterloggedBlock.placeLiquid: puts a source of `liquid` into the
-- node at pos. Returns true if the node took it.
function core.place_liquid(pos, liquid)
	local node = core.get_node(pos)
	local wet = core.get_waterlogged_node(node.name, liquid)
	if not wet then
		return false
	end
	node.name = wet
	swap_node(pos, node)
	return true
end

-- SimpleWaterloggedBlock.pickupBlock: takes the liquid out of the
-- waterlogged node at pos. Returns the liquid source name, or nil if there
-- was nothing to take.
function core.pickup_liquid(pos)
	local node = core.get_node(pos)
	local def = registered_nodes[node.name]
	if not def or not is_set(def.waterlogged_liquid) then
		return nil
	end
	local dry = def.waterlogged_alternative
	if not is_set(dry) or not registered_nodes[dry] then
		return nil
	end
	node.name = dry
	swap_node(pos, node)
	return def.waterlogged_liquid
end

-- Level.removeBlock: removes the node at pos and leaves its held liquid.
-- Returns the liquid left behind, if any.
function core.remove_node_keep_liquid(pos)
	local def = registered_nodes[core.get_node(pos).name]
	local liquid = def and def.waterlogged_liquid
	if is_set(liquid) then
		set_node(pos, {name = liquid})
		return liquid
	end
	remove_node(pos)
	return nil
end

-- Registering waterlogged forms

-- Fields that only belong to one of the two forms
local own_fields = {
	name = true, type = true, mod_origin = true,
	waterloggable = true, waterlogged_liquid = true, waterlogged_alternative = true,
	node_dig_prediction = true, liquid_move_physics = true, move_resistance = true,
	drowning = true, post_effect_color = true, post_effect_color_shaded = true,
	sunlight_propagates = true, floodable = true,
}

-- Groups a waterlogged form has on top of its dry form's, by name
local extra_groups = {}

local function wet_groups(groups, wet_name)
	groups = table.copy(groups or {})
	groups.waterlogged = 1
	groups.not_in_creative_inventory = 1
	for k, v in pairs(extra_groups[wet_name] or {}) do
		groups[k] = v
	end
	return groups
end

-- Registers the waterlogged form of the node `name` holding the liquid
-- source `liquid` and links both. `overrides` (optional) are applied to the
-- waterlogged form's definition; `overrides.name` sets its name (default
-- `name .. "_waterlogged"`). Returns the waterlogged node's name.
function core.register_waterlogged_alternative(name, liquid, overrides)
	local def = registered_nodes[name]
	if not def then
		error("Attempt to register a waterlogged form of unknown node " .. tostring(name), 2)
	end
	overrides = table.copy(overrides or {})
	local wet_name = overrides.name or name .. "_waterlogged"
	overrides.name = nil
	if wet_name:sub(1, 1) == ":" then
		wet_name = wet_name:sub(2)
	end

	local wet = {}
	for k, v in pairs(def) do
		if not own_fields[k] then
			wet[k] = type(v) == "table" and table.copy(v) or v
		end
	end
	wet.waterlogged_liquid = liquid
	wet.waterlogged_alternative = name
	wet.groups = wet_groups(def.groups, wet_name)
	if def.drop == nil then
		wet.drop = name
	end
	-- Digging leaves the liquid
	wet.node_dig_prediction = liquid

	-- Being in the node is being in the liquid
	local ldef = registered_nodes[liquid]
	if ldef then
		wet.liquid_move_physics = true
		wet.move_resistance = ldef.move_resistance or ldef.liquid_viscosity
		wet.drowning = math.max(def.drowning or 0, ldef.drowning or 0)
		wet.post_effect_color = ldef.post_effect_color
		wet.post_effect_color_shaded = ldef.post_effect_color_shaded
		wet.sunlight_propagates = def.sunlight_propagates and ldef.sunlight_propagates
	end
	wet.floodable = false

	for k, v in pairs(overrides) do
		wet[k] = v
	end
	-- Keep the groups added here when the dry form's groups change
	local extra = {}
	for k, v in pairs(wet.groups) do
		if (def.groups or {})[k] ~= v then
			extra[k] = v
		end
	end
	extra_groups[wet_name] = extra

	core.register_node(":" .. wet_name, wet)
	core.override_item(name, {waterlogged_alternative = wet_name, floodable = false})
	return wet_name
end

-- `waterloggable = "liquid source"` in a node definition registers the
-- waterlogged form right away
local register_item = core.register_item
function core.register_item(name, itemdef)
	register_item(name, itemdef)
	if itemdef.type == "node" and is_set(itemdef.waterloggable) and
			not is_set(itemdef.waterlogged_liquid) and
			not is_set(itemdef.waterlogged_alternative) then
		core.register_waterlogged_alternative(itemdef.name, itemdef.waterloggable)
	end
end

-- Overriding a dry node overrides its waterlogged form too
local override_item = core.override_item
function core.override_item(name, redefinition, del_fields)
	override_item(name, redefinition, del_fields)

	local def = registered_nodes[name]
	if not def or is_set(def.waterlogged_liquid) or
			not is_set(def.waterlogged_alternative) then
		return
	end
	local wet = registered_nodes[def.waterlogged_alternative]
	if not wet or wet.waterlogged_alternative ~= def.name then
		return
	end

	local redef, del = {}, {}
	local any = false
	for k, v in pairs(redefinition) do
		if not own_fields[k] then
			redef[k] = v
			any = true
		end
	end
	for _, k in ipairs(del_fields or {}) do
		if not own_fields[k] then
			if k == "drop" then
				redef.drop = def.name
			else
				table.insert(del, k)
			end
			any = true
		end
	end
	if not any then
		return
	end
	if redef.groups then
		redef.groups = wet_groups(redef.groups, def.waterlogged_alternative)
	end
	override_item(def.waterlogged_alternative, redef, del)
end
