mcl_boats = {}
local S = core.get_translator(core.get_current_modname())

local boat_visual_size = {x = 1, y = 1, z = 1}
local boat_anim = {x=1, y=456}
local paddling_speed = (boat_anim.y - boat_anim.x) / 1 -- 1 second
local boat_y_offset = 0.35
local boat_y_offset_ground = boat_y_offset + 0.6
local boat_side_offset = 1.001
local variant = {
	BOAT = 0,
	RAFT = 1,
}
mcl_boats.variant = variant

------------------------------------------------------------------------
-- Minecraft 26.3 boats (net.minecraft.world.entity.vehicle.boat.AbstractBoat,
-- VehicleEntity).  Positions and velocities below are in Minecraft units:
-- blocks and blocks per tick.  Block-space coordinates are Luanti
-- coordinates + 0.5, so that the block with index n is the node at n.
------------------------------------------------------------------------

-- All boats and rafts are 1.375 x 0.5625 (EntityTypes).
local WIDTH = 1.375
local HEIGHT = 0.5625
local HALF_WIDTH = WIDTH / 2
local GRAVITY = 0.04
local TICK = 0.05
local MAX_TICKS_PER_STEP = 10
-- Out of control after 3 seconds under water: passengers are ejected.
local TIME_TO_EJECT = 60
-- Players' view stays within this many degrees of the boat's yaw
-- (AbstractBoat.clampRotation).
local MAX_HEAD_ROTATION = 105

local STATUS_IN_WATER = 1
local STATUS_UNDER_WATER = 2
local STATUS_UNDER_FLOWING_WATER = 3
local STATUS_ON_LAND = 4
local STATUS_IN_AIR = 5

-- Riding (getPassengerAttachmentPoint): boats seat passengers at a third
-- of their height, rafts at 8/9 of it.  A single passenger sits in the
-- middle (chest boats: 0.15 forward), two at 0.2 and -0.6, animals 0.2
-- further forward.  Players' feet are 0.6 below the seat
-- (Avatar.DEFAULT_VEHICLE_ATTACHMENT).
local RIDE_HEIGHT = {
	[variant.BOAT] = HEIGHT / 3,
	[variant.RAFT] = HEIGHT * 0.8888889,
}
local PLAYER_VEHICLE_ATTACHMENT = 0.6

local floor, ceil = math.floor, math.ceil
local max, min, abs = math.max, math.min, math.abs

-- The inside of a boat stays dry (the water patch of Minecraft's boat
-- model): the hull of mcl_boats_boat.b3d.  Rafts float on top and have none.
local BOAT_LIQUID_MASK = {-0.54, 0, -1.034, 0.54, 0.5, 0.884}
local NO_LIQUID_MASK = {0, 0, 0, 0, 0, 0}

local raft_specific_properties = {
	selectionbox = {-0.7, 0.0, -0.7, 0.7, 0.30, 0.7},
	mesh = "mcl_boats_raft.b3d",
	liquid_mask_box = NO_LIQUID_MASK,
}

-- Minecraft's raft deck spans 0.006 to 0.506 above the raft's bottom,
-- mcl_boats_raft.b3d's 0 to 0.36.
local function set_raft_model_offset(obj)
	obj:set_bone_override("boat", {
		position = {vec = vector.new(0, 1.46, 0), absolute = false},
	})
end

local scratch_pos = vector.zero()
local function node_at(x, y, z)
	scratch_pos.x, scratch_pos.y, scratch_pos.z = x, y, z
	return core.get_node(scratch_pos)
end

-- FluidState.getHeight of water at a block: 1 below more water, 8/9 for
-- sources and falling water, amount / 9 otherwise.  Also returns whether
-- the block is a source, and the node.  nil if there is no water.
local function water_at(x, y, z)
	local node = node_at(x, y, z)
	local def = core.registered_nodes[node.name]
	if not def or not def.liquidtype or def.liquidtype == "none"
		or core.get_item_group(node.name, "water") == 0 then
		return nil
	end
	local source = def.liquidtype == "source"
	local above = node_at(x, y + 1, z).name
	if above == def.liquid_alternative_source
		or above == def.liquid_alternative_flowing then
		return 1, source, node
	elseif source or node.param2 % 16 >= 8 then
		return 8 / 9, source, node
	end
	return (node.param2 % 8) / 9, source, node
end

-- Block.getFriction
local function block_friction(name)
	local slippery = core.get_item_group(name, "slippery")
	if slippery >= 4 then
		return 0.989 -- blue ice
	elseif slippery > 0 then
		return 0.98 -- ice, packed ice, frosted ice
	elseif name == "mcl_core:slimeblock" then
		return 0.8
	end
	return 0.6
end

-- Collision boxes of a block in block space, or nil
local function collision_boxes(x, y, z, node)
	local def = core.registered_nodes[node.name]
	if def and def.walkable == false then
		return nil
	end
	scratch_pos.x, scratch_pos.y, scratch_pos.z = x, y, z
	local boxes = core.get_node_boxes("collision_box", scratch_pos, node)
	for i, b in ipairs(boxes) do
		boxes[i] = {
			x + b[1] + 0.5, y + b[2] + 0.5, z + b[3] + 0.5,
			x + b[4] + 0.5, y + b[5] + 0.5, z + b[6] + 0.5,
		}
	end
	return boxes
end

local function boxes_intersect(b, minx, miny, minz, maxx, maxy, maxz)
	return b[1] < maxx and b[4] > minx
		and b[2] < maxy and b[5] > miny
		and b[3] < maxz and b[6] > minz
end

-- The boat's bounding box in block space
local function boat_box(pos)
	return {
		minX = pos.x - HALF_WIDTH + 0.5,
		minY = pos.y + 0.5,
		minZ = pos.z - HALF_WIDTH + 0.5,
		maxX = pos.x + HALF_WIDTH + 0.5,
		maxY = pos.y + HEIGHT + 0.5,
		maxZ = pos.z + HALF_WIDTH + 0.5,
	}
end

-- Level.noCollision for blocks
local function box_free(minx, miny, minz, maxx, maxy, maxz)
	for x = floor(minx), ceil(maxx) - 1 do
		for y = floor(miny) - 1, ceil(maxy) - 1 do
			for z = floor(minz), ceil(maxz) - 1 do
				local boxes = collision_boxes(x, y, z, node_at(x, y, z))
				if boxes then
					for _, b in ipairs(boxes) do
						if boxes_intersect(b, minx, miny, minz, maxx, maxy, maxz) then
							return false
						end
					end
				end
			end
		end
	end
	return true
end

-- AbstractBoat.isUnderwater
local function under_water_status(b)
	local max_y = b.maxY + 0.001
	local under = false
	for x = floor(b.minX), ceil(b.maxX) - 1 do
		for y = floor(b.maxY), ceil(max_y) - 1 do
			for z = floor(b.minZ), ceil(b.maxZ) - 1 do
				local height, source = water_at(x, y, z)
				if height and max_y < y + height then
					if not source then
						return STATUS_UNDER_FLOWING_WATER
					end
					under = true
				end
			end
		end
	end
	return under and STATUS_UNDER_WATER or nil
end

-- AbstractBoat.checkInWater: in water, water level
local function check_in_water(b)
	local in_water = false
	local level = -math.huge
	for x = floor(b.minX), ceil(b.maxX) - 1 do
		for y = floor(b.minY), ceil(b.minY + 0.001) - 1 do
			for z = floor(b.minZ), ceil(b.maxZ) - 1 do
				local height = water_at(x, y, z)
				if height then
					height = y + height
					level = max(level, height)
					in_water = in_water or b.minY < height
				end
			end
		end
	end
	return in_water, level
end

-- AbstractBoat.getWaterLevelAbove
local function water_level_above(b, last_yd)
	local x0, x1 = floor(b.minX), ceil(b.maxX)
	local y0, y1 = floor(b.maxY), ceil(b.maxY - last_yd)
	local z0, z1 = floor(b.minZ), ceil(b.maxZ)
	for y = y0, y1 - 1 do
		local block_height = 0
		for x = x0, x1 - 1 do
			for z = z0, z1 - 1 do
				local height = water_at(x, y, z)
				if height then
					block_height = max(block_height, height)
				end
				if block_height >= 1 then
					break
				end
			end
			if block_height >= 1 then
				break
			end
		end
		if block_height < 1 then
			return y + block_height
		end
	end
	return y1 + 1
end

-- AbstractBoat.getGroundFriction: average friction of the blocks touching
-- the bottom of the boat (lily pads don't count), 0 if none.
local function ground_friction(b)
	local miny, maxy = b.minY - 0.001, b.minY
	local x0, x1 = floor(b.minX) - 1, ceil(b.maxX) + 1
	local y0, y1 = floor(miny) - 1, ceil(maxy) + 1
	local z0, z1 = floor(b.minZ) - 1, ceil(b.maxZ) + 1
	local friction, count = 0, 0
	for x = x0, x1 - 1 do
		for z = z0, z1 - 1 do
			local edges = ((x == x0 or x == x1 - 1) and 1 or 0)
				+ ((z == z0 or z == z1 - 1) and 1 or 0)
			if edges ~= 2 then
				for y = y0, y1 - 1 do
					if edges <= 0 or (y ~= y0 and y ~= y1 - 1) then
						local node = node_at(x, y, z)
						if core.get_item_group(node.name, "dig_by_boat") == 0 then
							local boxes = collision_boxes(x, y, z, node)
							if boxes then
								for _, box in ipairs(boxes) do
									if boxes_intersect(box, b.minX, miny, b.minZ,
											b.maxX, maxy, b.maxZ) then
										friction = friction + block_friction(node.name)
										count = count + 1
										break
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return count > 0 and friction / count or 0
end

-- AbstractBoat.getStatus
local function get_status(self, b)
	local status = under_water_status(b)
	if status then
		self._water_level = b.maxY
		return status
	end
	local in_water, level = check_in_water(b)
	self._water_level = level
	if in_water then
		return STATUS_IN_WATER
	end
	local friction = ground_friction(b)
	if friction > 0 then
		self._land_friction = friction
		return STATUS_ON_LAND
	end
	return STATUS_IN_AIR
end

-- Entity.updateFluidInteraction: water currents push the boat by 0.014
-- blocks/tick² along the average flow of the water it touches.
local function push_by_current(v, b)
	local minx, miny, minz = b.minX + 0.001, b.minY + 0.001, b.minZ + 0.001
	local maxx, maxy, maxz = b.maxX - 0.001, b.maxY - 0.001, b.maxZ - 0.001
	local fx, fy, fz, count = 0, 0, 0, 0
	local height = 0
	for x = floor(minx), ceil(maxx) - 1 do
		for y = floor(miny), ceil(maxy) - 1 do
			for z = floor(minz), ceil(maxz) - 1 do
				local h, _, node = water_at(x, y, z)
				if h and y + h >= miny then
					height = max(height, y + h - b.minY)
					local flow = flowlib.quick_flow(vector.new(x, y, z), node)
					local scale = height < 0.4 and height or 1
					fx = fx + flow.x * scale
					fy = fy + flow.y * scale
					fz = fz + flow.z * scale
					count = count + 1
				end
			end
		end
	end
	local len_sq = fx * fx + fy * fy + fz * fz
	if count == 0 or len_sq < 1.0E-5 then
		return
	end
	local scale = 0.014 / math.sqrt(len_sq)
	v.x = v.x + fx * scale
	v.y = v.y + fy * scale
	v.z = v.z + fz * scale
end

-- Lava and fire destroy boats.
local function touches_fire(b)
	for x = floor(b.minX), ceil(b.maxX) - 1 do
		for y = floor(b.minY), ceil(b.maxY) - 1 do
			for z = floor(b.minZ), ceil(b.maxZ) - 1 do
				local name = node_at(x, y, z).name
				if core.get_item_group(name, "lava") > 0
					or core.get_item_group(name, "set_on_fire") > 0 then
					return true
				end
			end
		end
	end
	return false
end

------------------------------------------------------------------------
-- Entities (Entity.isPushable, canBeCollidedWith, AbstractBoat.canCollideWith)
------------------------------------------------------------------------

local function is_boat_entity(entity)
	return entity ~= nil and (entity.name == "mcl_boats:boat"
		or entity.name == "mcl_boats:chest_boat")
end

-- The block an entity is in (Entity.blockPosition)
local function block_pos_of(pos)
	return floor(pos.x + 0.5), floor(pos.y + 0.5), floor(pos.z + 0.5)
end

-- LivingEntity.onClimbable
local function on_climbable(pos)
	local def = core.registered_nodes[node_at(block_pos_of(pos)).name]
	return def ~= nil and def.climbable == true
end

-- Entity.isPushable: living entities (alive, not spectating, not on a
-- climbable), boats and minecarts
local function is_pushable(obj, entity)
	if obj:is_player() then
		local spectator = rawget(_G, "mcl_spectator")
		return obj:get_hp() > 0
			and not (spectator and spectator.is_spectating(obj))
			and not on_climbable(obj:get_pos())
	elseif not entity then
		return false
	elseif is_boat_entity(entity) then
		return not entity._removed
	elseif entity.is_mob then
		return entity.pushable ~= false and not entity.dead
			and (entity.health or 1) > 0 and not entity._climbing
	end
	return entity.name:sub(1, 14) == "mcl_minecarts:"
end

-- An object's bounding box in block space
local function object_box(obj, entity)
	local p = obj:get_pos()
	local cb = entity and entity.is_mob and entity.collisionbox
		or obj:get_properties().collisionbox
	return {
		p.x + cb[1] + 0.5, p.y + cb[2] + 0.5, p.z + cb[3] + 0.5,
		p.x + cb[4] + 0.5, p.y + cb[5] + 0.5, p.z + cb[6] + 0.5,
	}
end

-- AABB.intersects (strict)
local function aabb_intersects(a, x1, y1, z1, x2, y2, z2)
	return a[1] < x2 and a[4] > x1 and a[2] < y2 and a[5] > y1
		and a[3] < z2 and a[6] > z1
end

-- Has passengers (Entity.isVehicle): players or mobs riding it, not
-- cosmetic attachments such as wielded items
local function is_vehicle(obj, entity)
	if is_boat_entity(entity) then
		return entity._driver ~= nil or entity._passenger ~= nil
	end
	for _, child in ipairs(obj:get_children()) do
		local e = child:get_luaentity()
		if child:is_player() or (e and (e.is_mob or is_boat_entity(e))) then
			return true
		end
	end
	return false
end

------------------------------------------------------------------------
-- Entity.move: collision with blocks and entities, bounces, block speed
------------------------------------------------------------------------

local EPSILON = 1.0E-7
local FULL_BLOCK = {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}}

-- Block collision shapes intersecting a box (block space), with the
-- collision boxes of unloaded blocks being full blocks
local function add_block_shapes(shapes, x1, y1, z1, x2, y2, z2)
	for x = floor(x1 - EPSILON) - 1, floor(x2 + EPSILON) + 1 do
		for y = floor(y1 - EPSILON) - 1, floor(y2 + EPSILON) + 1 do
			for z = floor(z1 - EPSILON) - 1, floor(z2 + EPSILON) + 1 do
				local node = node_at(x, y, z)
				local boxes
				if node.name == "ignore" then
					boxes = {}
					for i, b in ipairs(FULL_BLOCK) do
						boxes[i] = {x + b[1] + 0.5, y + b[2] + 0.5, z + b[3] + 0.5,
							x + b[4] + 0.5, y + b[5] + 0.5, z + b[6] + 0.5}
					end
				else
					boxes = collision_boxes(x, y, z, node)
				end
				if boxes then
					for _, b in ipairs(boxes) do
						shapes[#shapes + 1] = b
					end
				end
			end
		end
	end
end

-- VoxelShape.collide for boxes: how far box MB can move by D along axis A
-- (1 = x, 2 = y, 3 = z) before it touches one of SHAPES
local function collide_axis(a, mb, shapes, d)
	local b, c = a % 3 + 1, (a + 1) % 3 + 1
	for i = 1, #shapes do
		if abs(d) < EPSILON then
			return 0
		end
		local s = shapes[i]
		if s[b] <= mb[b + 3] - EPSILON and mb[b] + EPSILON < s[b + 3]
			and s[c] <= mb[c + 3] - EPSILON and mb[c] + EPSILON < s[c + 3] then
			if d > 0 then
				if mb[a + 3] - EPSILON < s[a] then
					local nd = s[a] - mb[a + 3]
					if nd >= -EPSILON then
						d = min(d, nd)
					end
				end
			elseif mb[a] + EPSILON >= s[a + 3] then
				local nd = s[a + 3] - mb[a]
				if nd <= EPSILON then
					d = max(d, nd)
				end
			end
		end
	end
	return d
end

-- Entity.collideWithShapes: Y first, then the larger horizontal axis last
-- (Direction.axisStepOrder)
local function collide_with_shapes(m, box, shapes)
	if #shapes == 0 then
		return m
	end
	local mb = {box[1], box[2], box[3], box[4], box[5], box[6]}
	local r = {0, 0, 0}
	local order = abs(m[1]) < abs(m[3]) and {2, 3, 1} or {2, 1, 3}
	for _, a in ipairs(order) do
		if m[a] ~= 0 then
			r[a] = collide_axis(a, mb, shapes, m[a])
			mb[a] = mb[a] + r[a]
			mb[a + 3] = mb[a + 3] + r[a]
		end
	end
	return r
end

local function box_array(pos)
	return {
		pos.x - HALF_WIDTH + 0.5, pos.y + 0.5, pos.z - HALF_WIDTH + 0.5,
		pos.x + HALF_WIDTH + 0.5, pos.y + HEIGHT + 0.5, pos.z + HALF_WIDTH + 0.5,
	}
end

-- Level.findSupportingBlock: the block under the box that is nearest to
-- the entity's position
local function find_supporting_block(pos, x1, y1, z1, x2, y2, z2)
	local px, py, pz = pos.x + 0.5, pos.y + 0.5, pos.z + 0.5
	local best, best_dist
	for x = floor(x1 - EPSILON) - 1, floor(x2 + EPSILON) + 1 do
		for y = floor(y1 - EPSILON) - 1, floor(y2 + EPSILON) + 1 do
			for z = floor(z1 - EPSILON) - 1, floor(z2 + EPSILON) + 1 do
				local boxes = collision_boxes(x, y, z, node_at(x, y, z))
				if boxes then
					for _, b in ipairs(boxes) do
						if aabb_intersects(b, x1, y1, z1, x2, y2, z2) then
							local d = (x + 0.5 - px) ^ 2 + (y + 0.5 - py) ^ 2 + (z + 0.5 - pz) ^ 2
							-- ties: the larger position (BlockPos.compareTo: y, z, x)
							if not best or d < best_dist or (d == best_dist
								and (best.y < y or (best.y == y and (best.z < z
								or (best.z == z and best.x < x))))) then
								best = {x = x, y = y, z = z}
								best_dist = d
							end
							break
						end
					end
				end
			end
		end
	end
	return best
end

-- Entity.checkSupportingBlock
local function check_supporting_block(self, pos, on_ground, mx, mz)
	if not on_ground then
		self._on_ground_no_blocks = false
		self._supporting = nil
		return
	end
	local b = box_array(pos)
	local supporting = find_supporting_block(pos, b[1], b[2] - 1.0E-6, b[3], b[4], b[2], b[6])
	if supporting or self._on_ground_no_blocks then
		self._supporting = supporting
	else
		supporting = find_supporting_block(pos, b[1] - mx, b[2] - 1.0E-6, b[3] - mz,
			b[4] - mx, b[2], b[6] - mz)
		self._supporting = supporting
	end
	self._on_ground_no_blocks = supporting == nil
end

-- Entity.getOnPos
local function on_pos(self, pos, offset)
	local s = self._supporting
	local y = floor(pos.y + 0.5 - offset)
	if s then
		if offset <= 1.0E-5 then
			return s.x, s.y, s.z
		end
		local name = node_at(s.x, s.y, s.z).name
		if (offset <= 0.5 and core.get_item_group(name, "fence") > 0)
			or core.get_item_group(name, "wall") > 0
			or core.get_item_group(name, "fence_gate") > 0 then
			return s.x, s.y, s.z
		end
		return s.x, y, s.z
	end
	return floor(pos.x + 0.5), y, floor(pos.z + 0.5)
end

-- Block.getBounceRestitution: slime blocks 1, beds 0.75
local function bounce_restitution(name)
	if name == "mcl_core:slimeblock" then
		return 1
	elseif core.get_item_group(name, "bed") > 0 then
		return 0.75
	end
	return 0
end

-- Block.getSpeedFactor: soul sand and honey blocks 0.4
local function speed_factor(name)
	if name == "mcl_nether:soul_sand" or name == "mcl_honey:honey_block" then
		return 0.4
	end
	return 1
end

-- Entity.getBlockSpeedFactor
local function block_speed_factor(self, pos)
	local name = node_at(block_pos_of(pos)).name
	local f = speed_factor(name)
	if core.get_item_group(name, "water") == 0 and f == 1 then
		return speed_factor(node_at(on_pos(self, pos, 0.500001)).name)
	end
	return f
end

-- Entity.restituteMovementAfterCollisions (boats don't bounce off walls;
-- bouncy blocks bounce non-living entities with 0.8 of their restitution)
local function restitute_movement(self, effect_name, x_collision, z_collision,
		vertical_collision, below, moved_y)
	local v = self._mc_v
	local restitution = 0
	local cx, cy, cz = v.x, v.y, v.z
	if x_collision then
		v.x = -cx * restitution
	end
	if z_collision then
		v.z = -cz * restitution
	end
	if vertical_collision then
		if below then
			if -cy > GRAVITY and effect_name ~= "mcl_honey:honey_block" then
				restitution = max(restitution, bounce_restitution(effect_name) * 0.8)
			else
				restitution = 0
			end
		end
		local gravity_compensation = 0
		if restitution > 0 then
			gravity_compensation = moved_y / cy * GRAVITY
		end
		v.y = (gravity_compensation - cy) * restitution
	end
end

-- Entity.move (MoverType.SELF) with the boat's velocity, colliding with
-- blocks only.  Boats can't step up (maxUpStep 0).  Returns the position
-- before the move.
local function boat_move(self, pos)
	local v = self._mc_v
	local delta = {v.x, v.y, v.z}
	local stuck = self._stuck
	if stuck then
		delta = {delta[1] * stuck[1], delta[2] * stuck[2], delta[3] * stuck[3]}
		self._stuck = nil
		v.x, v.y, v.z = 0, 0, 0
	end
	local from = vector.copy(pos)
	local box = box_array(pos)
	local movement = delta
	local delta_len = delta[1] ^ 2 + delta[2] ^ 2 + delta[3] ^ 2
	if delta_len ~= 0 then
		local x1, y1, z1, x2, y2, z2 = box[1], box[2], box[3], box[4], box[5], box[6]
		if delta[1] < 0 then x1 = x1 + delta[1] else x2 = x2 + delta[1] end
		if delta[2] < 0 then y1 = y1 + delta[2] else y2 = y2 + delta[2] end
		if delta[3] < 0 then z1 = z1 + delta[3] else z2 = z2 + delta[3] end
		local shapes = {}
		add_block_shapes(shapes, x1, y1, z1, x2, y2, z2)
		movement = collide_with_shapes(delta, box, shapes)
	end
	local movement_len = movement[1] ^ 2 + movement[2] ^ 2 + movement[3] ^ 2
	if movement_len > 1.0E-7 or delta_len - movement_len < 1.0E-7 then
		pos.x = pos.x + movement[1]
		pos.y = pos.y + movement[2]
		pos.z = pos.z + movement[3]
	end

	-- Mth.equal: within 1e-5
	local x_collision = abs(delta[1] - movement[1]) >= 1.0E-5
	local z_collision = abs(delta[3] - movement[3]) >= 1.0E-5
	local horizontal_collision = x_collision or z_collision
	local moved_vertically = abs(delta[2]) > 0
	local vertical_collision = delta[2] ~= movement[2]
	local below = vertical_collision and delta[2] < 0
	self._on_ground = below
	check_supporting_block(self, pos, below, movement[1], movement[3])
	self._horizontal_collision = horizontal_collision

	-- getOnPosLegacy
	local effect_name = node_at(on_pos(self, pos, 0.2)).name
	if (moved_vertically and vertical_collision) or horizontal_collision then
		restitute_movement(self, effect_name, x_collision, z_collision,
			vertical_collision, below, movement[2])
	end
	local f = block_speed_factor(self, pos)
	v.x = v.x * f
	v.z = v.z * f
	return from
end

-- Entity.applyEffectsFromBlocks for the blocks the boat moved through
-- (BlockBehaviour.entityInside): lily pads break, cobwebs and powder snow
-- slow the next move down.
local function apply_effects_from_blocks(self, from, pos)
	local a, b = box_array(from), box_array(pos)
	local d = 1.0E-5
	local x1, y1, z1 = min(a[1], b[1]) + d, min(a[2], b[2]) + d, min(a[3], b[3]) + d
	local x2, y2, z2 = max(a[4], b[4]) - d, max(a[5], b[5]) - d, max(a[6], b[6]) - d
	for x = floor(x1), floor(x2) do
		for y = floor(y1), floor(y2) do
			for z = floor(z1), floor(z2) do
				local name = node_at(x, y, z).name
				if core.get_item_group(name, "dig_by_boat") > 0 then
					core.dig_node(vector.new(x, y, z))
				elseif name == "mcl_core:cobweb" then
					self._stuck = {0.25, 0.05000000074505806, 0.25}
				elseif name == "mcl_powder_snow:powder_snow" then
					self._stuck = {0.9, 1.5, 0.9}
				end
			end
		end
	end
end

-- Entity.push (Entity): pushes the boat and the other entity apart by up
-- to 0.05 blocks/tick, unless they carry passengers.
local function entity_push(self, pos, obj, entity)
	local p = obj:get_pos()
	local xa, za = p.x - pos.x, p.z - pos.z
	local dd = max(abs(xa), abs(za))
	if dd < 0.01 then
		return
	end
	dd = math.sqrt(dd)
	xa, za = xa / dd, za / dd
	local pow = min(1 / dd, 1)
	xa = xa * pow * 0.05000000074505806
	za = za * pow * 0.05000000074505806
	if not is_vehicle(self.object, self) then
		self._mc_v.x = self._mc_v.x - xa
		self._mc_v.z = self._mc_v.z - za
	end
	if not is_vehicle(obj, entity) and is_pushable(obj, entity) then
		if is_boat_entity(entity) then
			entity._mc_v.x = entity._mc_v.x + xa
			entity._mc_v.z = entity._mc_v.z + za
		else
			obj:add_velocity(vector.new(xa * 20, 0, za * 20))
		end
	end
end

-- AbstractBoat.push for other boats: while they overlap in height.
-- Boats aren't solid to players and mobs, so these push at any height.
local function boat_push(self, pos, obj, entity)
	if is_boat_entity(entity) then
		if object_box(obj, entity)[2] - 0.5 < pos.y + HEIGHT then
			entity_push(self, pos, obj, entity)
		end
	else
		entity_push(self, pos, obj, entity)
	end
end

local eject_passengers

-- One Minecraft tick (AbstractBoat.tick before the move): status, water
-- currents, AbstractBoat.floatBoat and, with a player driving,
-- AbstractBoat.controlBoat.  Updates self._mc_v (blocks/tick), self._mc_rot
-- (degrees/tick, counter-clockwise like Luanti's yaw) and pos; returns the
-- new yaw.
local function boat_tick(self, pos, yaw, input)
	local v = self._mc_v
	local b = boat_box(pos)

	self._old_status = self._status
	local status = get_status(self, b)
	self._status = status
	if status == STATUS_UNDER_WATER or status == STATUS_UNDER_FLOWING_WATER then
		self._out_of_control = self._out_of_control + 1
	else
		self._out_of_control = 0
	end
	if self._out_of_control >= TIME_TO_EJECT then
		eject_passengers(self)
		input = nil
	end

	if self._hurt_time > 0 then
		self._hurt_time = self._hurt_time - 1
	end
	if self._damage > 0 then
		self._damage = max(self._damage - 1, 0)
	end

	push_by_current(v, b)

	-- floatBoat
	local vspeed = -GRAVITY
	local buoyancy = 0
	local inv_friction = 0.05
	if self._old_status == STATUS_IN_AIR and status ~= STATUS_IN_AIR
		and status ~= STATUS_ON_LAND then
		-- Landing on water: put the boat on the surface
		self._water_level = b.maxY
		local target_y = water_level_above(b, self._last_yd) - HEIGHT + 0.101
		local dy = target_y - b.minY
		if box_free(b.minX, b.minY + dy, b.minZ, b.maxX, b.maxY + dy, b.maxZ) then
			pos.y = pos.y + dy
			v.y = 0
			self._last_yd = 0
		end
		self._status = STATUS_IN_WATER
	else
		if status == STATUS_IN_WATER then
			buoyancy = (self._water_level - b.minY) / HEIGHT
			inv_friction = 0.9
		elseif status == STATUS_UNDER_FLOWING_WATER then
			vspeed = -7.0E-4
			inv_friction = 0.9
		elseif status == STATUS_UNDER_WATER then
			buoyancy = 0.01
			inv_friction = 0.45
		elseif status == STATUS_IN_AIR then
			inv_friction = 0.9
		elseif status == STATUS_ON_LAND then
			inv_friction = self._land_friction
		end
		v.x = v.x * inv_friction
		v.y = v.y + vspeed
		v.z = v.z * inv_friction
		self._mc_rot = self._mc_rot * inv_friction
		if buoyancy > 0 then
			v.y = (v.y + buoyancy * (GRAVITY / 0.65)) * 0.75
		end
	end

	-- controlBoat: 1 degree/tick² of turning, 0.04 blocks/tick² forwards,
	-- 0.005 backwards or while only turning.
	local paddle_left, paddle_right = false, false
	if input then
		local acceleration = 0
		if input.left then
			self._mc_rot = self._mc_rot + 1
		end
		if input.right then
			self._mc_rot = self._mc_rot - 1
		end
		if input.right ~= input.left and not input.up and not input.down then
			acceleration = acceleration + 0.005
		end
		yaw = yaw + math.rad(self._mc_rot)
		if input.up then
			acceleration = acceleration + 0.04
		end
		if input.down then
			acceleration = acceleration - 0.005
		end
		v.x = v.x - math.sin(yaw) * acceleration
		v.z = v.z + math.cos(yaw) * acceleration
		paddle_left = (input.right and not input.left) or input.up
		paddle_right = (input.left and not input.right) or input.up
	end
	self._paddling = paddle_left or paddle_right

	-- Stop the endless exponential decay at invisible speeds
	if abs(v.x) < 1.0E-5 then v.x = 0 end
	if abs(v.z) < 1.0E-5 then v.z = 0 end
	if abs(self._mc_rot) < 1.0E-4 then self._mc_rot = 0 end
	self._last_yd = v.y
	return yaw
end

local function check_object(obj)
	return obj and (obj:is_player() or obj:get_luaentity()) and obj
end

-- Game event sources: only real objects (not fake player tables)
local function ge_obj(obj)
	return type(obj) == "userdata" and obj:get_pos() and obj or nil
end

local function get_visual_size(obj)
	return obj:is_player() and {x = 1, y = 1, z = 1} or obj:get_luaentity()._old_visual_size or obj:get_properties().visual_size
end

local function is_animal(obj)
	local entity = not obj:is_player() and obj:get_luaentity()
	return entity and entity.is_mob and entity.type == "animal"
end

-- Attachment offset (in 1/10 nodes) of a passenger
local function seat_offset(boat, obj, index, count)
	local z = boat._inv_id and 0.15 or 0
	if count > 1 then
		z = index == 1 and 0.2 or -0.6
		if is_animal(obj) then
			z = z + 0.2
		end
	end
	local y = RIDE_HEIGHT[boat._variant] or RIDE_HEIGHT[variant.BOAT]
	if obj:is_player() then
		y = y - PLAYER_VEHICLE_ATTACHMENT
	end
	return vector.new(0, y * 10, z * 10)
end

-- Rotation of a passenger: forwards, animals in a full boat sideways
-- (AbstractBoat.calculatePassengerBodyYRot).
local function seat_rotation(obj, count, index)
	if count > 1 and is_animal(obj) then
		return vector.new(0, index == 1 and 90 or 270, 0)
	end
	return vector.zero()
end

local function attach_driver(boat)
	local count = boat._passenger and 2 or 1
	boat._driver:set_attach(boat.object, "",
		seat_offset(boat, boat._driver, 1, count),
		seat_rotation(boat._driver, count, 1))
	mcl_attachments.spawn_attachment_entity (boat._driver)
end

local function attach_passenger(boat)
	if not boat._passenger_seat or not boat._passenger_seat:get_luaentity() then
		local pos = boat.object:get_pos()
		boat._passenger_seat = core.add_entity(pos, "mcl_boats:seat")
	end

	-- The seat carries the passenger's place, so that the camera of a
	-- passenger player follows it.
	local offset = seat_offset(boat, boat._passenger, 2, 2)
	local seat_y = offset.y
	if boat._passenger:is_player() then
		seat_y = seat_y + PLAYER_VEHICLE_ATTACHMENT * 10
	end
	boat._passenger_seat:set_attach(boat.object, "",
		vector.new(0, seat_y, offset.z), vector.zero())
	boat._passenger:set_attach(boat._passenger_seat, "",
		vector.new(0, offset.y - seat_y, 0), seat_rotation(boat._passenger, 2, 2))
	mcl_attachments.spawn_attachment_entity (boat._passenger)
end

local function attach_non_player_passenger(boat)
	boat._passenger:set_attach(boat.object, "",
		seat_offset(boat, boat._passenger, 2, 2),
		vector.add(seat_rotation(boat._passenger, 2, 2), vector.new(0, 270, 0)))
	mcl_attachments.spawn_attachment_entity (boat._passenger)
end

local function set_attach(boat)
	attach_driver(boat)
end

local function remove_seat(self)
	if self._passenger_seat and self._passenger_seat:get_luaentity() then
		self._passenger_seat:remove()
		self._passenger_seat = nil
	end
end

local function set_double_attach(boat)
	attach_driver(boat)
	if boat._passenger:is_player() then
		attach_passenger(boat)
	else
		attach_non_player_passenger(boat)
	end
end

local function set_choat_attach(boat)
	attach_driver(boat)
end

local function attach_object(self, obj)
	if self._driver and not self._inv_id then
		if self._driver:is_player() then
			self._passenger = obj
		else
			self._passenger = self._driver
			self._driver = obj
		end
		set_double_attach(self)
	else
		self._driver = obj
		if self._inv_id then
			set_choat_attach(self)
		else
			set_attach(self)
		end
	end

	local visual_size = get_visual_size(obj)
	obj:set_properties({visual_size = vector.divide(visual_size, boat_visual_size)})

	if obj:is_player() then
		local name = obj:get_player_name()
		mcl_player.players[obj].attached = true
		core.after(0.2, function(name)
			local player = core.get_player_by_name(name)
			if player then
				mcl_player.player_set_animation(player, "sit" , 30)
			end
		end, name)
		-- The view turns with the boat and stays within 105 degrees of
		-- its yaw (engine properties turn_attached_players and
		-- attached_player_yaw_limit).
		mcl_title.set(obj, "actionbar", {text=S("Sneak to dismount"), color="white", stay=60})
	else
		obj:get_luaentity()._old_visual_size = visual_size
	end
	-- Entity.startRiding: at the vehicle, with the rider as source
	if mcl_gameevent then
		mcl_gameevent.emit("entity_mount", self.object:get_pos(), {source = obj})
	end
end

local function detach_object(obj, change_pos)
	-- Entity.removeVehicle: at the old vehicle, with the rider as source
	local vehicle = mcl_gameevent and obj and obj:get_pos() and obj:get_attach()
	if vehicle then
		local ent = vehicle:get_luaentity()
		if ent and ent.name == "mcl_boats:seat" and vehicle:get_attach() then
			vehicle = vehicle:get_attach()
		end
		mcl_gameevent.emit("entity_dismount", vehicle:get_pos(), {source = obj})
	end
	if change_pos then change_pos = vector.new(0, 0.2, 0) end
	return mcl_util.detach_object(obj, change_pos)
end

-- BlockGetter.getBlockFloorHeight: top of the block's collision shape, or
-- of the shape below it minus 1; -inf if neither reaches
local function block_floor_height(x, y, z)
	local top = -math.huge
	for _, b in ipairs(collision_boxes(x, y, z, node_at(x, y, z)) or {}) do
		top = max(top, b[5] - y)
	end
	if top > -math.huge then
		return top
	end
	for _, b in ipairs(collision_boxes(x, y - 1, z, node_at(x, y - 1, z)) or {}) do
		top = max(top, b[5] - (y - 1))
	end
	return top >= 1 and top - 1 or -math.huge
end

-- DismountHelper.canDismountTo: no block in the way of the box
local function can_dismount_to(x, y, z, width, height)
	local hw = width / 2
	local x1, y1, z1, x2, y2, z2 = x - hw, y, z - hw, x + hw, y + height, z + hw
	for bx = floor(x1), floor(x2) do
		for by = floor(y1) - 1, floor(y2) do
			for bz = floor(z1), floor(z2) do
				for _, b in ipairs(collision_boxes(bx, by, bz, node_at(bx, by, bz)) or {}) do
					if aabb_intersects(b, x1, y1, z1, x2, y2, z2) then
						return false
					end
				end
			end
		end
	end
	return true
end

-- Players can dismount standing, crouching or swimming (width, height)
local PLAYER_DISMOUNT_POSES = {{0.6, 1.8}, {0.6, 1.5}, {0.6, 0.6}}

-- AbstractBoat.getDismountLocationForPassenger: beside the boat in the
-- direction the passenger faces if there is land, else on top of it.
local function dismount_location(self, obj)
	local pos = self.object:get_pos()
	local cb = obj:get_properties().collisionbox
	local width = obj:is_player() and 0.6 or cb[4] - cb[1]
	local yaw = obj:is_player() and obj:get_look_horizontal() or obj:get_yaw()
	-- Entity.getCollisionHorizontalEscapeVector
	local distance = (WIDTH * math.sqrt(2) + width + 1.0E-5) / 2
	local dx, dz = -math.sin(yaw), math.cos(yaw)
	local scale = max(abs(dx), abs(dz))
	local tx = pos.x + dx * distance / scale + 0.5
	local tz = pos.z + dz * distance / scale + 0.5
	local bx, by, bz = floor(tx), floor(pos.y + HEIGHT + 0.5), floor(tz)
	if not water_at(bx, by - 1, bz) then
		local targets = {}
		local h = block_floor_height(bx, by, bz)
		if h > -math.huge and h < 1 then
			targets[#targets + 1] = by + h
		end
		h = block_floor_height(bx, by - 1, bz)
		if h > -math.huge and h < 1 then
			targets[#targets + 1] = by - 1 + h
		end
		local poses = obj:is_player() and PLAYER_DISMOUNT_POSES
			or {{width, cb[5] - cb[2]}}
		for _, pose in ipairs(poses) do
			for _, ty in ipairs(targets) do
				if can_dismount_to(tx, ty, tz, pose[1], pose[2]) then
					return vector.new(tx - 0.5, ty - 0.5, tz - 0.5)
				end
			end
		end
	end
	return vector.new(pos.x, pos.y + HEIGHT, pos.z)
end

-- Entity.removePassenger / LivingEntity.dismountVehicle
local function dismount(self, obj)
	if not obj or not obj:get_pos() then
		return
	end
	local target = dismount_location(self, obj)
	detach_object(obj)
	obj:set_pos(target)
end

function eject_passengers(self)
	if self._passenger then
		dismount(self, self._passenger)
		self._passenger = nil
		remove_seat(self)
	end
	if self._driver then
		dismount(self, self._driver)
		self._driver = nil
		self._csm_driving = false
	end
end

--
-- Boat entity
--

local boat = {
	initial_properties = {
		-- Moved by Minecraft's Entity.move below.  Objects don't collide
		-- with boats; boats push and are pushed like mobs.
		physical = false,
		collide_with_objects = false,
		pointable = true,
		collisionbox = {-HALF_WIDTH, 0, -HALF_WIDTH, HALF_WIDTH, HEIGHT, HALF_WIDTH},
		selectionbox = {-0.7, -0.15, -0.7, 0.7, 0.55, 0.7},
		visual = "mesh",
		mesh = "mcl_boats_boat.b3d",
		textures = { "mcl_boats_texture_oak_boat.png", "blank.png" },
		visual_size = boat_visual_size,
		hp_max = 4,
		damage_texture_modifier = "^[colorize:white:0",
		-- Smooth movement and turning at Minecraft's 20 ticks per second
		transform_interpolation = true,
		turn_attached_players = true,
		attached_player_yaw_limit = MAX_HEAD_ROTATION,
		liquid_mask_box = BOAT_LIQUID_MASK,
	},

	_variant = variant.BOAT,
	_driver = nil, -- Attached driver (player) or nil if none
	_passenger = nil,
	_removed = false, -- If true, boat entity is considered removed (e.g. after punch) and should be ignored
	_itemstring = "mcl_boats:boat", -- Itemstring of the boat item (implies boat type)
	_animation = 0, -- 0: not animated; 1: paddling
	_mcl_fishing_hookable = true,
	_mcl_fishing_reelable = true,
	-- Minecraft riders' eye height (mcl_attachments)
	_rider_eye_offset = 1.62 - mcl_player.player_props_riding.eye_height,
	on_detach_child = function(self, child)
		if self._driver and core.is_player(child) and core.is_player(self._driver) and self._driver == child then
			detach_object(self._driver)
			self._driver = nil
		end
	end,
	_csm_driving = false,
}

core.register_on_respawnplayer(detach_object)

function boat.on_rightclick(self, clicker)
	if self._passenger or not clicker or clicker:get_attach() or (self.name == "mcl_boats:chest_boat" and self._driver) then
		return
	end
	-- Out of control boats can't be entered (AbstractBoat.interact)
	if self._out_of_control >= TIME_TO_EJECT then
		return
	end
	if mcl_serverplayer.is_csm_capable (clicker)
		and (not self._driver or not self._driver:is_player ()) then
		mcl_serverplayer.begin_mount (clicker, self.object, self.name, {
			bone = "",
			position = vector.zero (),
			rotation = vector.zero (),
		})
	else
		self._csm_driving = false
		attach_object (self, clicker)
	end
end

function boat:on_activate(staticdata)
	self.object:set_armor_groups({fleshy = 100})
	self._mc_v = {x = 0, y = 0, z = 0}
	self._mc_rot = 0
	self._tick_time = 0
	self._status = STATUS_IN_AIR
	self._old_status = STATUS_IN_AIR
	self._water_level = 0
	self._land_friction = 0.6
	self._last_yd = 0
	self._out_of_control = 0
	self._hurt_time = 0
	self._hurt_dir = 1
	self._damage = 0
	self._paddling = false
	local data = core.deserialize(staticdata)
	if type(data) == "table" then
		if type(data.motion) == "table" then
			self._mc_v = {
				x = tonumber(data.motion.x) or 0,
				y = tonumber(data.motion.y) or 0,
				z = tonumber(data.motion.z) or 0,
			}
		end
		self._itemstring = data.itemstring

		-- Fall back to oak boat texture if no texture is set
		if not data.textures then
			local tx = { "mcl_boats_texture_oak_boat.png", "blank.png" }
			if self.name == "mcl_boats:chest_boat" then
				tx = { "mcl_boats_texture_oak_boat.png", "mcl_chests_normal.png" }
			end
			data.textures = tx
		end

		-- Update the texutes for existing old boat entity instances.
		-- Maybe remove this in the future.
		if #data.textures >= 1 and data.textures[1] == "mcl_boats_texture_cherry_boat.png" then
			data.textures[1] = "mcl_boats_texture_cherry_blossom_boat.png"
		end
		if #data.textures ~= 2 then
			local has_chest = self._itemstring:find("chest")
			data.textures = {
				data.textures[1]:gsub("_chest", ""),
				has_chest and "mcl_chests_normal.png" or "blank.png"
			}
		end

		if data.variant then
			self._variant = data.variant
			if data.variant == variant.RAFT then
				self.object:set_properties(raft_specific_properties)
				set_raft_model_offset(self.object)
			end
		end

		self.object:set_properties({textures = data.textures})
	end
	-- Boats from before the Minecraft physics: Minecraft's size
	self.object:set_properties({
		collisionbox = {-HALF_WIDTH, 0, -HALF_WIDTH, HALF_WIDTH, HEIGHT, HALF_WIDTH},
		physical = false,
		collide_with_objects = false,
		transform_interpolation = true,
		turn_attached_players = true,
		attached_player_yaw_limit = MAX_HEAD_ROTATION,
	})
end

function boat:get_staticdata()
	local props = self.object:get_properties()
	return core.serialize({
		motion = self._mc_v,
		itemstring = self._itemstring,
		textures = props and props.textures or nil,
		variant = self._variant
	})
end

function boat:on_death(killer)
	mcl_burning.extinguish(self.object)

	-- Creative players destroy boats without drops (VehicleEntity.hurtServer)
	if not (killer and killer:is_player() and core.is_creative_enabled(killer:get_player_name())) then
		core.add_item(self.object:get_pos(), self._itemstring)
	end
	if self._driver then
		dismount(self, self._driver)
	end
	if self._passenger then
		dismount(self, self._passenger)
	end
	remove_seat(self)
	self._driver = nil
	self._passenger = nil
end

local function destroy(self, killer)
	if self._removed then
		return
	end
	self._removed = true
	self:on_death(killer)
	self.object:remove()
end

-- VehicleEntity.hurtServer: every hit adds 10 times its damage, which
-- decreases by 1 per tick; more than 40 destroys the boat.  The hit boat
-- rocks for 10 ticks.
---@diagnostic disable-next-line: unused-local
function boat:on_punch(puncher, time_from_last_punch, tool_capabilities, dir, damage)
	if self._removed then
		return true
	end
	self._hurt_dir = -self._hurt_dir
	self._hurt_time = 10
	self._damage = self._damage + (damage or 0) * 10
	local creative = puncher and puncher:is_player()
		and core.is_creative_enabled(puncher:get_player_name())
	if creative or self._damage > 40 then
		destroy(self, puncher)
	end
	return true
end

-- AbstractBoat.tick: pushable entities within 0.2 of the boat are picked
-- up (mobs, while no player drives and there is room) or pushed; players
-- and mobs that overlap the boat also push it themselves
-- (LivingEntity.pushEntities), so that each of the pair is pushed twice,
-- as mobs push each other (mcl_mobs common_collision).
local function interact_with_entities(self, pos)
	local b = box_array(pos)
	local x1, y1, z1 = b[1] - 0.2, b[2] + 0.01, b[3] - 0.2
	local x2, y2, z2 = b[4] + 0.2, b[5] - 0.01, b[6] + 0.2
	local add_new_passengers = not (self._driver and self._driver:is_player())
	local max_passengers = self._inv_id and 1 or 2
	local center = vector.new(pos.x, pos.y + HEIGHT / 2, pos.z)
	for obj in core.objects_inside_radius(center, 3) do
		if obj ~= self.object and not obj:get_attach() then
			local entity = obj:get_luaentity()
			if is_pushable(obj, entity) then
				local ob = object_box(obj, entity)
				if aabb_intersects(ob, x1, y1, z1, x2, y2, z2) then
					local passengers = (self._driver and 1 or 0) + (self._passenger and 1 or 0)
					if add_new_passengers and passengers < max_passengers
						and entity and entity.is_mob and entity.can_ride_boat
						-- hasEnoughSpaceFor
						and ob[4] - ob[1] < WIDTH then
						attach_object(self, obj)
					else
						boat_push(self, pos, obj, entity)
						if (obj:is_player() or (entity and entity.is_mob))
							and aabb_intersects(ob, b[1], b[2], b[3], b[4], b[5], b[6]) then
							boat_push(self, pos, obj, entity)
						end
					end
				end
			end
		end
	end
end

local function set_paddle_animation(self, paddling)
	local anim = paddling and 1 or 0
	if self._animation ~= anim then
		if paddling then
			self.object:set_animation(boat_anim, paddling_speed, 0, true)
		else
			self.object:set_animation(boat_anim, 0, 0, true)
		end
		self._animation = anim
	end
end

function boat:on_step(dtime, moveresult)
	mcl_burning.tick(self.object, dtime, self)
	-- mcl_burning.tick may remove object immediately
	if self._removed or not self.object:get_pos() then return end

	local pos = self.object:get_pos()

	if touches_fire(boat_box(pos)) then
		destroy(self, nil)
		return
	end

	-- Entity.move: boats emit movement events (MovementEmission.EVENTS)
	if mcl_gameevent then
		self._ge_tracker = self._ge_tracker or mcl_gameevent.new_movement_tracker()
		local status = self._status
		mcl_gameevent.track_movement(self.object, self._ge_tracker, {
			pos = pos,
			on_ground = status == STATUS_ON_LAND,
			in_water = status == STATUS_IN_WATER or status == STATUS_UNDER_WATER
				or status == STATUS_UNDER_FLOWING_WATER,
			swimming = false, climbing = false, crouching = false,
			passenger = self.object:get_attach() ~= nil,
		})
	end

	local had_passenger = self._passenger

	self._driver = check_object(self._driver)
	self._passenger = check_object(self._passenger)

	if self._passenger then
		if not self._driver then
			self._driver = self._passenger
			self._passenger = nil
			remove_seat(self)
			set_attach(self)
		else
			local ctrl = self._passenger:is_player() and self._passenger:get_player_control()
			if ctrl and ctrl.sneak then
				dismount(self, self._passenger)
				self._passenger = nil
				remove_seat(self)
			end
		end
	end

	local input
	if self._driver then
		local ctrl = self._driver:is_player() and self._driver:get_player_control()
		if ctrl and ctrl.sneak then
			dismount(self, self._driver)
			self._driver = nil
			self._csm_driving = false
			if self._passenger then
				self._driver = self._passenger
				self._passenger = nil
				remove_seat(self)
				set_attach(self)
			end
		end
	end
	if self._driver then
		if self._csm_driving then
			local v = self.object:get_velocity ()
			set_paddle_animation(self, math.sqrt (v.x * v.x + v.z * v.z) > 0)
			return
		end

		if had_passenger and not self._passenger then
			set_attach(self)
		end
		local ctrl = self._driver:is_player() and self._driver:get_player_control()
		input = ctrl and {
			up = ctrl.up, down = ctrl.down,
			left = ctrl.left, right = ctrl.right,
		}
	end
	local yaw = self.object:get_yaw()
	local start_pos = vector.copy(pos)
	local ticks = 0
	self._tick_time = self._tick_time + dtime
	while self._tick_time >= TICK and ticks < MAX_TICKS_PER_STEP do
		self._tick_time = self._tick_time - TICK
		ticks = ticks + 1
		yaw = boat_tick(self, pos, yaw, input)
		if not self._driver then
			input = nil
		end
		local from = boat_move(self, pos)
		apply_effects_from_blocks(self, from, pos)
		interact_with_entities(self, pos)
	end
	if ticks >= MAX_TICKS_PER_STEP then
		self._tick_time = 0
	end
	if ticks == 0 then
		return
	end

	if not vector.equals(pos, start_pos) then
		self.object:move_to(pos, true)
	end
	set_paddle_animation(self, input ~= nil and self._paddling)

	-- AbstractBoatRenderer: a hit boat rocks about its sideways axis
	local pitch = 0
	if self._hurt_time > 0 then
		pitch = math.rad(math.sin(self._hurt_time) * self._hurt_time
			* self._damage / 10 * self._hurt_dir)
	end
	self.object:set_rotation(vector.new(pitch, yaw, 0))
	-- Moved by setting positions (the client interpolates between them)
	self.object:set_velocity(vector.zero())
	self.object:set_acceleration(vector.zero())
end

------------------------------------------------------------------------
--- Client-side steering.
------------------------------------------------------------------------

local ZERO_VECTOR = vector.zero ()

function boat:complete_attachment (player, state)
	attach_object (self, player)
	self._csm_driving = true
	self.object:set_velocity (ZERO_VECTOR)
	self.object:set_acceleration (ZERO_VECTOR)
end

function boat:fallback_attach (player, state)
	attach_object (self, player)
	self._csm_driving = false
end

function boat:set_touching_ground (touching_ground)
end

function boat:detach_client_driver (player)
	if player == self._driver then
		self._driver = nil
		self._csm_driving = false
		detach_object (player, true)
	end
end

function boat:set_yaw (yaw)
	self.object:set_yaw (yaw)
end

function boat:max_delta_movement ()
	return 56.0
end

-- Register one entity for all boat types
core.register_entity("mcl_boats:boat", boat)

-- Boat seat intermediary object for camera positioning
core.register_entity("mcl_boats:seat", {
	initial_properties = {
		visual = "sprite",
		textures = { "blank.png" },
		collisionbox = {0,0,0,0,0,0},
		physical = false,
		pointable = false,
		static_save = false,
	},
	_rider_eye_offset = 1.62 - mcl_player.player_props_riding.eye_height,
})

local cboat = table.copy(boat)
cboat._itemstring = "mcl_boats:chest_boat"
cboat.initial_properties.textures = { "mcl_boats_texture_oak_boat.png", "mcl_chests_normal.png" }
cboat.initial_properties.selectionbox = {-0.7, -0.15, -0.7, 0.7, 0.75, 0.7}

function cboat:_on_show_entity_inv (player)
	-- AbstractChestBoat.interact
	if mcl_gameevent then
		mcl_gameevent.emit_entity (self.object, "container_open", ge_obj (player) or false)
	end
	mobs_mc.enrage_piglins (player, true)
end

-- AbstractChestBoat.stopOpen
core.register_on_player_receive_fields (function (player, formname, fields)
	if mcl_gameevent and fields.quit and formname:sub (1, 11) == "entity_inv_" then
		local ent = mcl_entity_invs.get_entity_by_invname (formname)
		if ent and ent.name == "mcl_boats:chest_boat" and ent.object:get_pos () then
			mcl_gameevent.emit ("container_close", ent.object:get_pos (), {source = player})
		end
	end
end)

function cboat:on_death (killer)
	boat.on_death (self, killer)

	if killer and killer:is_player () then
		mobs_mc.enrage_piglins (killer, true)
	end
end

core.register_entity("mcl_boats:chest_boat", cboat)
mcl_entity_invs.register_inv("mcl_boats:chest_boat","Boat",27)

local doc_itemstring_boat
local doc_itemstring_chest_boat

function mcl_boats.register_boat(name,item_def,object_properties,entity_overrides)
	local itemstring = "mcl_boats:boat_"..name
	local id = name.."_boat"

	local longdesc, usagehelp, tt_help, help, helpname
	help = false
	-- Only create one help entry for all boats
	if not doc_itemstring_boat then
		help = true
		longdesc = S("Boats are used to travel on the surface of water.")
		usagehelp = S("Rightclick on a water source to place the boat. Rightclick the boat to enter it. Use [Left] and [Right] to steer, [Forwards] to speed up and [Backwards] to slow down or move backwards. Use [Sneak] to leave the boat, punch the boat to make it drop as an item.")
		helpname = S("Boat")
		doc_itemstring_boat = itemstring
		doc.sub.identifier.register_object("mcl_boats:boat", "craftitems", itemstring)
	else
		doc.add_entry_alias("craftitems", doc_itemstring_boat, "craftitems", itemstring)
	end
	tt_help = S("Water vehicle")

	local inventory_image
	local texture
	if id:find("chest") then
		inventory_image = "mcl_boats_" .. id .. ".png"
		texture = "mcl_boats_texture_" .. id:gsub("chest_", "") .. ".png"
		if not doc_itemstring_chest_boat then
			help = true
			longdesc = S("Chest Boats are used to travel on the surface of water. And transport goods")
			usagehelp = S("Rightclick on a water source to place the boat. Rightclick the boat to enter it. Use [Left] and [Right] to steer, [Forwards] to speed up and [Backwards] to slow down or move backwards. Use [Sneak] to leave the boat, punch the boat to make it drop as an item. Use [Sneak] + [Rightclick] to open the boat's chest")
			helpname = S("Chest Boat")
			doc_itemstring_chest_boat = itemstring
			doc.sub.identifier.register_object("mcl_boats:chest_boat", "craftitems", doc_itemstring_chest_boat)
		else
			doc.add_entry_alias("craftitems", doc_itemstring_chest_boat, "craftitems", itemstring)
		end
	else
		inventory_image = "mcl_boats_" .. name .. "_boat.png"
		texture = "mcl_boats_texture_" .. name .. "_boat.png"
	end

	core.register_craftitem(":"..itemstring, table.merge({
		description = S(name.." Boat"),
		_tt_help = tt_help,
		_doc_items_create_entry = help,
		_doc_items_entry_name = helpname,
		_doc_items_longdesc = longdesc,
		_doc_items_usagehelp = usagehelp,
		_mcl_burntime = 60,
		inventory_image = inventory_image,
		pointabilities = {
			nodes = {
				["group:water"] = true,
			},
		},
		groups = { boat = 1, transport = 1},
		stack_max = 1,
		on_place = function(itemstack, placer, pointed_thing)
			if pointed_thing.type ~= "node" then
				return itemstack
			end

			local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
			if rc then return rc end

			local pos = table.copy(pointed_thing.under)
			local dir = vector.subtract(pointed_thing.above, pointed_thing.under)

			if math.abs(dir.x) > 0.9 or math.abs(dir.z) > 0.9 then
				pos = vector.add(pos, vector.multiply(dir, boat_side_offset))
			elseif flowlib.is_water(pos) then
				pos = vector.add(pos, vector.multiply(dir, boat_y_offset))
			else
				pos = vector.add(pos, vector.multiply(dir, boat_y_offset_ground))
			end
			local boat_ent = "mcl_boats:boat"
			local chest_tex = "blank.png"
			if itemstring:find("chest") then
				boat_ent = "mcl_boats:chest_boat"
				chest_tex = "mcl_chests_normal.png"
			end
			local boat = core.add_entity(pos, boat_ent)
			if boat and boat:get_pos() then
				local ent = boat:get_luaentity()
				ent._itemstring = itemstring
				local custom_properties = {textures = {texture, chest_tex}}
				if object_properties and object_properties.variant == variant.RAFT then
					custom_properties = table.merge(raft_specific_properties, custom_properties)
					ent._variant = variant.RAFT
					set_raft_model_offset(boat)
				else
					ent._variant = variant.BOAT
				end
				boat:set_properties(table.merge( custom_properties, object_properties or {}))
				boat:set_yaw(placer:get_look_horizontal())
				for k,v in pairs(entity_overrides or {}) do
					ent[k] = v
				end
				-- BoatItem.use: at the hit location
				if mcl_gameevent then
					mcl_gameevent.emit("entity_place",
						pointed_thing.intersection_point or pos, {source = ge_obj(placer)})
				end
			end
			if not core.is_creative_enabled(placer:get_player_name()) then
				itemstack:take_item()
			end
			return itemstack
		end,
		---@diagnostic disable-next-line: unused-local
		_on_dispense = function(stack, pos, droppos, dropnode, dropdir)
			local below = {x=droppos.x, y=droppos.y-1, z=droppos.z}
			local belownode = core.get_node(below)
			-- Place boat as entity on or in water
			if core.get_item_group(dropnode.name, "water") ~= 0 or (dropnode.name == "air" and core.get_item_group(belownode.name, "water") ~= 0) then
				core.add_entity(droppos, "mcl_boats:boat")
			else
				core.add_item(droppos, stack)
			end
		end,
	},item_def or {}))

	local c = "mcl_trees:wood_"..name
	if itemstring:find("chest") then
		core.register_craft({
			output = itemstring,
			recipe = {
				{"mcl_chests:chest"},
				{"mcl_boats:boat_"..name:gsub("_chest","")},
			},
		})
	elseif core.registered_nodes[c] then
		core.register_craft({
			output = itemstring,
			recipe = {
				{c, "", c},
				{c, c, c},
			},
		})
	end
end
