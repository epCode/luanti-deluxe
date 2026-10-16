flowlib = {}

local function is_touching(realpos,nodepos,radius)
	local boarder = 0.5 - radius
	return math.abs(realpos - nodepos) > (boarder)
end

flowlib.is_touching = is_touching

local function is_water(pos)
	return core.get_item_group(core.get_node(pos).name, "water") ~= 0
end

flowlib.is_water = is_water

local function node_is_water(node)
	return core.get_item_group(node.name, "water") ~= 0
end

flowlib.node_is_water = node_is_water

local function is_lava(pos)
	return core.get_item_group(core.get_node(pos).name, "lava") ~= 0
end

flowlib.is_lava = is_lava

local function node_is_lava(node)
	return core.get_item_group(node.name, "lava") ~= 0
end

flowlib.node_is_lava = node_is_lava


local function is_liquid(pos)
	return core.get_item_group(core.get_node(pos).name, "liquid") ~= 0
end

flowlib.is_liquid = is_liquid

local function node_is_liquid(node)
	return core.get_item_group(node.name, "liquid") ~= 0
end

flowlib.node_is_liquid = node_is_liquid

-- Minecraft's FlowingFluid.getFlow: the direction a liquid pushes in,
-- from the fluid heights (amount / 9) around it.  Levels are Minecraft
-- fluid amounts (see the engine's liquid_model = "minecraft").
local HORIZONTAL = {
	vector.new(0, 0, -1), vector.new(1, 0, 0), vector.new(0, 0, 1), vector.new(-1, 0, 0),
}

-- Liquid kind (source node name) and own height of a node, or nil
local function fluid_at(node)
	local def = core.registered_nodes[node.name]
	if not def then return nil, 0 end
	-- A waterlogged block holds a source
	if (def.waterlogged_liquid or "") ~= "" then
		return def.waterlogged_liquid, 8 / 9
	end
	local liquidtype = def.liquidtype
	if liquidtype == "source" then
		return def.liquid_alternative_source, 8 / 9
	elseif liquidtype == "flowing" then
		local amount = node.param2 >= 8 and 8 or node.param2 % 8
		return def.liquid_alternative_source, amount / 9
	end
	return nil, 0
end

local function is_falling(node)
	local def = core.registered_nodes[node.name]
	return def and def.liquidtype == "flowing" and node.param2 >= 8
end

local function blocks_motion(node)
	local def = core.registered_nodes[node.name]
	return not def or def.walkable ~= false
end

-- FlowingFluid.isSolidFace for a horizontal face
local function is_solid_face(pos, kind)
	local node = core.get_node(pos)
	if fluid_at(node) == kind then
		return false
	end
	if node.name == "mcl_core:ice" or core.get_item_group(node.name, "frosted_ice") > 0 then
		return false
	end
	local def = core.registered_nodes[node.name]
	return def ~= nil and def.walkable ~= false
		and (def.drawtype == "normal" or def.drawtype == "glasslike"
			or def.drawtype == "glasslike_framed" or def.drawtype == "allfaces"
			or def.drawtype == "allfaces_optional")
end

local function quick_flow(pos, node)
	local kind, own = fluid_at(node)
	if not kind then
		return vector.zero()
	end

	local fx, fz = 0, 0
	for _, dir in ipairs(HORIZONTAL) do
		local npos = vector.add(pos, dir)
		local nnode = core.get_node(npos)
		local nkind, height = fluid_at(nnode)
		-- affectsFlow: empty or the same liquid
		if nkind == nil or nkind == kind then
			local diff = 0
			if height == 0 then
				if not blocks_motion(nnode) then
					local bkind, bheight = fluid_at(core.get_node(vector.offset(npos, 0, -1, 0)))
					if (bkind == nil or bkind == kind) and bheight > 0 then
						diff = own - (bheight - 8 / 9)
					end
				end
			else
				diff = own - height
			end
			fx = fx + dir.x * diff
			fz = fz + dir.z * diff
		end
	end

	local flow = vector.new(fx, 0, fz)
	if is_falling(node) then
		for _, dir in ipairs(HORIZONTAL) do
			local npos = vector.add(pos, dir)
			if is_solid_face(npos, kind) or is_solid_face(vector.offset(npos, 0, 1, 0), kind) then
				flow = vector.add(vector.normalize(flow), vector.new(0, -6, 0))
				break
			end
		end
	end
	return vector.normalize(flow)
end

flowlib.quick_flow = quick_flow

--if not in water but touching, move centre to touching block
--x has higher precedence than z
--if pos changes with x, it affects z

local function move_centre(pos, realpos, node, radius)
	if is_touching(realpos.x, pos.x, radius) then
		if is_liquid({x = pos.x-1, y = pos.y, z = pos.z}) then
			node = core.get_node({x=pos.x-1, y = pos.y, z = pos.z})
			pos = {x = pos.x-1, y = pos.y, z = pos.z}
		elseif is_liquid({x = pos.x+1, y = pos.y, z = pos.z}) then
			node = core.get_node({x = pos.x+1, y = pos.y, z = pos.z})
			pos = {x = pos.x+1, y = pos.y, z = pos.z}
		end
	end
	if is_touching(realpos.z, pos.z, radius) then
		if is_liquid({x = pos.x, y = pos.y, z = pos.z - 1}) then
			node = core.get_node({x = pos.x, y = pos.y, z = pos.z - 1})
			pos = {x = pos.x, y = pos.y, z = pos.z - 1}
		elseif is_liquid({x = pos.x, y = pos.y, z = pos.z + 1}) then
			node = core.get_node({x = pos.x, y = pos.y, z = pos.z + 1})
			pos = {x = pos.x, y = pos.y, z = pos.z + 1}
		end
	end
	return pos, node
end

flowlib.move_centre = move_centre
