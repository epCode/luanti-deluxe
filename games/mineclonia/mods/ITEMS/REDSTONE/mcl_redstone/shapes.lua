-- Block shape queries used by redstone: BlockState.isFaceSturdy (support
-- types FULL, CENTER and RIGID), isCollisionShapeFullBlock and
-- isRedstoneConductor.  Collision boxes are rasterised on Minecraft's 1/16
-- grid, which is exact for all of its block shapes.

local DOWN, UP, NORTH, SOUTH, WEST, EAST = 0, 1, 2, 3, 4, 5
local floor = math.floor

local EMPTY = {full = false, faces = {}}

-- Per node name: false if the shape never depends on neighbours, so results
-- can be cached per param2.
local uncachable = {}
local cache = {}

local function px(v)
	return math.max(0, math.min(16, floor(v * 16 + 8 + 0.5)))
end

local grid = {}

-- Which support types the face of the boxes towards `d` satisfies.
local function face_support(boxes, d)
	for i = 0, 255 do grid[i] = false end
	for _, b in ipairs(boxes) do
		local x1, y1, z1, x2, y2, z2 = b[1], b[2], b[3], b[4], b[5], b[6]
		local touches, u1, u2, v1, v2
		if d == UP then touches, u1, u2, v1, v2 = y2 == 16, x1, x2, z1, z2
		elseif d == DOWN then touches, u1, u2, v1, v2 = y1 == 0, x1, x2, z1, z2
		elseif d == NORTH then touches, u1, u2, v1, v2 = z2 == 16, x1, x2, y1, y2
		elseif d == SOUTH then touches, u1, u2, v1, v2 = z1 == 0, x1, x2, y1, y2
		elseif d == EAST then touches, u1, u2, v1, v2 = x2 == 16, z1, z2, y1, y2
		else touches, u1, u2, v1, v2 = x1 == 0, z1, z2, y1, y2
		end
		if touches then
			for u = u1, u2 - 1 do
				for v = v1, v2 - 1 do
					grid[u * 16 + v] = true
				end
			end
		end
	end
	local full, center, rigid = true, true, true
	for u = 0, 15 do
		for v = 0, 15 do
			if not grid[u * 16 + v] then
				full = false
				if u >= 6 and u < 10 and v >= 6 and v < 10 then
					center = false
				end
				if u < 2 or u >= 14 or v < 2 or v >= 14 then
					rigid = false
				end
			end
		end
	end
	return {full = full, center = center, rigid = rigid}
end

local function is_full_cube(boxes)
	local filled = {}
	local count = 0
	for _, b in ipairs(boxes) do
		if b[1] == 0 and b[2] == 0 and b[3] == 0 and b[4] == 16 and b[5] == 16 and b[6] == 16 then
			return true
		end
		for x = b[1], b[4] - 1 do
			for y = b[2], b[5] - 1 do
				for z = b[3], b[6] - 1 do
					local i = (x * 16 + y) * 16 + z
					if not filled[i] then
						filled[i] = true
						count = count + 1
					end
				end
			end
		end
	end
	return count == 4096
end

local function compute(pos, node)
	local def = core.registered_nodes[node.name]
	if not def or def.walkable == false then
		return EMPTY
	end
	local raw = core.get_node_boxes("collision_box", pos, node)
	local boxes = {}
	for _, b in ipairs(raw) do
		local x1, y1, z1 = px(math.min(b[1], b[4])), px(math.min(b[2], b[5])), px(math.min(b[3], b[6]))
		local x2, y2, z2 = px(math.max(b[1], b[4])), px(math.max(b[2], b[5])), px(math.max(b[3], b[6]))
		if x2 > x1 and y2 > y1 and z2 > z1 then
			boxes[#boxes + 1] = {x1, y1, z1, x2, y2, z2}
		end
	end
	local info = {full = is_full_cube(boxes), faces = {}, boxes = boxes}
	return info
end

local function get_info(pos, node)
	local name = node.name
	if uncachable[name] then
		return compute(pos, node)
	end
	local c = cache[name]
	if not c then
		c = {}
		cache[name] = c
	end
	local info = c[node.param2]
	if not info then
		info = compute(pos, node)
		c[node.param2] = info
	end
	return info
end

-- Blocks whose support shape (getBlockSupportShape) is a full block although
-- their collision box is smaller
local full_support = {
	["mcl_nether:soul_sand"] = true,
	["mcl_mud:mud"] = true,
}
mcl_redstone._full_support = full_support

-- support: "full" (default), "center" or "rigid"
function mcl_redstone.is_face_sturdy(pos, node, d, support)
	if full_support[node.name] then
		return true
	end
	local info = get_info(pos, node)
	if not info.boxes then
		return false
	end
	local f = info.faces[d]
	if not f then
		f = face_support(info.boxes, d)
		info.faces[d] = f
	end
	return f[support or "full"]
end

-- Block.canSupportRigidBlock
function mcl_redstone.can_support_rigid_block(pos, node)
	return mcl_redstone.is_face_sturdy(pos, node, UP, "rigid")
end

-- Block.canSupportCenter
function mcl_redstone.can_support_center(pos, node, d)
	return mcl_redstone.is_face_sturdy(pos, node, d, "center")
end

function mcl_redstone.is_collision_full_block(pos, node)
	return get_info(pos, node).full
end

-- Conductivity overrides: true = always, false = never. Filled on mods loaded.
local conductor_override = {}
mcl_redstone._conductor_override = conductor_override

-- Blocks that use Blocks::never for isRedstoneConductor in Minecraft,
-- matched against Mineclonia node names (prefix match on the item part).
local never_names = {
	"mcl_core:ice", "mcl_core:frosted_ice",
	"mcl_nether:glowstone", "mcl_ocean:sea_lantern", "mcl_beacons:beacon",
	"mcl_redstone_torch:redstoneblock", "mcl_tnt:tnt", "mcl_end:chorus_flower",
	"mcl_bamboo:scaffolding", "mcl_powder_snow:powder_snow",
	"mcl_dripstone:pointed_dripstone", "mcl_lush_caves:firefly_bush",
}
local always_names = {
	"mcl_nether:soul_sand", "mcl_mud:mud",
}

core.register_on_mods_loaded(function()
	for name, def in pairs(core.registered_nodes) do
		local groups = def.groups or {}
		for _, box in pairs({def.node_box, def.collision_box}) do
			if box and box.type == "connected" then
				uncachable[name] = true
			end
		end
		if (groups.redstone_conductive or 0) ~= 0 then
			conductor_override[name] = true
		elseif (groups.redstone_not_conductive or 0) ~= 0
				or (groups.leaves or 0) ~= 0
				or (groups.glass or 0) ~= 0
				or (groups.piston or 0) ~= 0
				or def.drawtype == "glasslike" or def.drawtype == "glasslike_framed"
				or def.drawtype == "glasslike_framed_optional" then
			conductor_override[name] = false
		end
		for _, n in ipairs(never_names) do
			if name:sub(1, #n) == n then
				conductor_override[name] = false
			end
		end
		for _, n in ipairs(always_names) do
			if name == n then
				conductor_override[name] = true
			end
		end
	end
end)

-- BlockState.isRedstoneConductor
function mcl_redstone.is_conductor(pos, node)
	local b = mcl_redstone._blocks[node.name]
	if b then
		local c = b.conductor
		if c ~= nil then
			if type(c) == "function" then
				return c(pos, node)
			end
			return c
		end
	end
	local o = conductor_override[node.name]
	if o ~= nil then
		return o
	end
	return get_info(pos, node).full
end
