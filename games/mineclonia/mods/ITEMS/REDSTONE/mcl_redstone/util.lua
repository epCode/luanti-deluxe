-- Directions, position helpers and Java collection ordering used by the
-- Minecraft redstone port.
--
-- Directions are numbered like Minecraft's Direction enum (and its 3D data
-- value): DOWN, UP, NORTH, SOUTH, WEST, EAST.  Minecraft's north is -Z, Luanti's
-- north is +Z, so a Minecraft position (x, y, z) corresponds to the Luanti
-- position (x, y, -z).  Keeping the compass the same means a build behaves the
-- same in both games when it faces the same way.

local bit = bit
local band, bxor, rshift, tobit = bit.band, bit.bxor, bit.rshift, bit.tobit

local DOWN, UP, NORTH, SOUTH, WEST, EAST = 0, 1, 2, 3, 4, 5
mcl_redstone.DOWN, mcl_redstone.UP = DOWN, UP
mcl_redstone.NORTH, mcl_redstone.SOUTH = NORTH, SOUTH
mcl_redstone.WEST, mcl_redstone.EAST = WEST, EAST

local dirvec = {
	[DOWN] = vector.new(0, -1, 0),
	[UP] = vector.new(0, 1, 0),
	[NORTH] = vector.new(0, 0, 1),
	[SOUTH] = vector.new(0, 0, -1),
	[WEST] = vector.new(-1, 0, 0),
	[EAST] = vector.new(1, 0, 0),
}
mcl_redstone.dirvec = dirvec

mcl_redstone.opposite = {[DOWN] = UP, [UP] = DOWN, [NORTH] = SOUTH, [SOUTH] = NORTH, [WEST] = EAST, [EAST] = WEST}
mcl_redstone.clockwise = {[NORTH] = EAST, [EAST] = SOUTH, [SOUTH] = WEST, [WEST] = NORTH}
mcl_redstone.counter_clockwise = {[NORTH] = WEST, [WEST] = SOUTH, [SOUTH] = EAST, [EAST] = NORTH}
-- 0 = y, 1 = z, 2 = x
mcl_redstone.axis = {[DOWN] = 0, [UP] = 0, [NORTH] = 1, [SOUTH] = 1, [WEST] = 2, [EAST] = 2}

-- Direction.values()
mcl_redstone.ALL = {DOWN, UP, NORTH, SOUTH, WEST, EAST}
-- Direction.Plane.HORIZONTAL
mcl_redstone.HORIZONTAL = {NORTH, EAST, SOUTH, WEST}
-- Direction.Plane.VERTICAL
mcl_redstone.VERTICAL = {UP, DOWN}
-- NeighborUpdater.UPDATE_ORDER
mcl_redstone.UPDATE_ORDER = {WEST, EAST, DOWN, UP, NORTH, SOUTH}
-- BlockBehaviour.UPDATE_SHAPE_ORDER
mcl_redstone.UPDATE_SHAPE_ORDER = {WEST, EAST, NORTH, SOUTH, DOWN, UP}

function mcl_redstone.rel(pos, d, n)
	local v = dirvec[d]
	n = n or 1
	return vector.new(pos.x + v.x * n, pos.y + v.y * n, pos.z + v.z * n)
end

-- Direction index of a unit vector (nil if it is not one).
function mcl_redstone.dir_index(v)
	if v.y == -1 then return DOWN
	elseif v.y == 1 then return UP
	elseif v.z == 1 then return NORTH
	elseif v.z == -1 then return SOUTH
	elseif v.x == -1 then return WEST
	elseif v.x == 1 then return EAST
	end
end

-- 4dir param2 (0 = +Z) to direction index and back.
local fourdir_to_dir = {[0] = NORTH, [1] = EAST, [2] = SOUTH, [3] = WEST}
local dir_to_fourdir = {[NORTH] = 0, [EAST] = 1, [SOUTH] = 2, [WEST] = 3}
mcl_redstone.fourdir_to_dir = fourdir_to_dir
mcl_redstone.dir_to_fourdir = dir_to_fourdir

-- Same hash as core.hash_node_position, computed in Lua.
local function hash(pos)
	return (pos.z + 32768) * 4294967296 + (pos.y + 32768) * 65536 + pos.x + 32768
end
mcl_redstone.hash = hash

-- Java's BlockPos.hashCode() spread like java.util.HashMap.hash().
local function java_hash(pos)
	local h = tobit((pos.y + (-pos.z) * 31) * 31 + pos.x)
	return bxor(h, rshift(h, 16))
end

-- Iteration order of a java.util.HashSet<BlockPos> (or the key set of a
-- HashMap) that received the positions of `list` in this order, using the
-- default capacity of 16 and growing it like Java does. Duplicates are
-- dropped.
function mcl_redstone.java_hash_order(list)
	local n = #list
	local capacity = 16
	while n > capacity * 0.75 do
		capacity = capacity * 2
	end
	local mask = capacity - 1
	local buckets = {}
	local seen = {}
	for i = 1, n do
		local pos = list[i]
		local h = hash(pos)
		if not seen[h] then
			seen[h] = true
			local b = band(java_hash(pos), mask)
			local bucket = buckets[b]
			if not bucket then
				bucket = {}
				buckets[b] = bucket
			end
			bucket[#bucket + 1] = pos
		end
	end
	local out = {}
	for b = 0, mask do
		local bucket = buckets[b]
		if bucket then
			for i = 1, #bucket do
				out[#out + 1] = bucket[i]
			end
		end
	end
	return out
end

-- Direction.orderedByNearest(entity)[1]: the axis the entity looks along most.
function mcl_redstone.nearest_looking_direction(placer)
	if not placer or not placer.get_look_dir then
		return NORTH
	end
	local look = placer:get_look_dir()
	local ax, ay, az = math.abs(look.x), math.abs(look.y), math.abs(look.z)
	local dx = look.x > 0 and EAST or WEST
	local dy = look.y > 0 and UP or DOWN
	local dz = look.z > 0 and NORTH or SOUTH
	if ax > az then
		if ay > ax then return dy end
		return dx
	elseif ay > az then
		return dy
	end
	return dz
end

-- Direction the placer faces horizontally (BlockPlaceContext.getHorizontalDirection).
function mcl_redstone.horizontal_looking_direction(placer)
	if not placer or not placer.get_look_horizontal then
		return NORTH
	end
	local yaw = placer:get_look_horizontal()
	local look = vector.new(-math.sin(yaw), 0, math.cos(yaw))
	if math.abs(look.x) > math.abs(look.z) then
		return look.x > 0 and EAST or WEST
	end
	return look.z > 0 and NORTH or SOUTH
end
