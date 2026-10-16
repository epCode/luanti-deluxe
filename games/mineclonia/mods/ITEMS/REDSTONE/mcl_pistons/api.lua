-- Port of Minecraft's PistonStructureResolver, PistonBaseBlock.isPushable,
-- MovingPistonBlock and PistonMovingBlockEntity.

local DOWN, UP = mcl_redstone.DOWN, mcl_redstone.UP
local dirvec = mcl_redstone.dirvec
local opposite = mcl_redstone.opposite
local axis = mcl_redstone.axis
local rel = mcl_redstone.rel
local get_node = mcl_redstone.get_node
local hash = mcl_redstone.hash

local MAX_PUSH_DEPTH = 12

mcl_pistons.MOVING_PISTON = "mcl_pistons:moving_piston"
mcl_pistons.PISTON_HEAD = "mcl_pistons:piston_head"
local MOVING_PISTON = mcl_pistons.MOVING_PISTON

local inv_nodes_movable = core.settings:get_bool("mcl_inv_nodes_movable", false)

mcl_pistons.registered_on_move = {}

-- Called with a list of {pos = new position, old_pos = old position, node =
-- node} when moved blocks arrive.
function mcl_pistons.register_on_move(callback)
	table.insert(mcl_pistons.registered_on_move, callback)
end

local function run_on_move(moved_nodes)
	for _, callback in ipairs(mcl_pistons.registered_on_move) do
		callback(moved_nodes)
	end
end

-- Push reactions ----------------------------------------------------------------

-- Blocks with PushReaction.IMMOVEABLE in Minecraft
local immovable_names = {
	"mcl_core:obsidian", "mcl_core:crying_obsidian", "mcl_beds:respawn_anchor",
	"mcl_deepslate:deepslate_reinforced", "mcl_anvils:anvil", "mcl_grindstone:grindstone",
	"mcl_lodestone:lodestone", "mcl_core:barrier", "mcl_portals:portal", "mcl_portals:portal_end",
	"mcl_portals:end_gateway",
}

local immovable = {}
local sticky = {}

core.register_on_mods_loaded(function()
	for name, def in pairs(core.registered_nodes) do
		for _, n in ipairs(immovable_names) do
			if name:sub(1, #n) == n then
				immovable[name] = true
			end
		end
		if def._mcl_pistons_sticky then
			sticky[name] = true
		end
	end
end)

-- BlockState.hasBlockEntity: nodes keeping data Minecraft keeps in a block
-- entity can not be moved.
function mcl_pistons.has_block_entity(node)
	local def = core.registered_nodes[node.name]
	if not def then
		return false
	end
	if def._mcl_pistons_unmovable then
		return true
	end
	return not inv_nodes_movable and (def.groups.container or 0) ~= 0
end

-- BlockState.getPistonPushReaction: "normal" (PUSH_PULL), "destroy"
-- (POPPED), "block" (IMMOVEABLE), "push_only" (PUSH) or "ignore"
function mcl_pistons.get_push_reaction(node)
	local b = mcl_redstone.get_block(node.name)
	local r = b.push_reaction
	if type(r) == "function" then
		r = r(node)
	end
	if r then
		return r
	end
	local def = core.registered_nodes[node.name]
	if not def then
		return "block"
	end
	local groups = def.groups
	if immovable[node.name] or (groups.unmovable_by_piston or 0) ~= 0 then
		return "block"
	elseif (groups.dig_by_piston or 0) ~= 0 or def.buildable_to then
		return "destroy"
	elseif (groups.unsticky or 0) ~= 0 then
		return "push_only"
	end
	return "normal"
end
local get_push_reaction = mcl_pistons.get_push_reaction

local function is_air(node)
	return node.name == "air"
end

local function is_piston_base(node)
	return core.get_item_group(node.name, "piston") ~= 0
end

-- PistonBaseBlock.isPushable
function mcl_pistons.is_pushable(node, pos, d, allow_destroyable, connection_d)
	if node.name == "ignore" then
		return false
	end
	if is_air(node) then
		return true
	end
	if not is_piston_base(node) then
		local def = core.registered_nodes[node.name]
		if not def or def._mcl_hardness == -1 then
			return false
		end
		local reaction = get_push_reaction(node)
		if reaction == "block" then
			return false
		elseif reaction == "destroy" then
			return allow_destroyable
		elseif reaction == "push_only" then
			return d == connection_d
		end
	elseif core.get_item_group(node.name, "piston_extended") ~= 0 then
		return false
	end
	return not mcl_pistons.has_block_entity(node)
end
local is_pushable = mcl_pistons.is_pushable

-- PistonStructureResolver -----------------------------------------------------------

local function is_sticky(node)
	return sticky[node.name] == true
end

-- PistonStructureResolver.canStickToEachOther
local function can_stick_to_each_other(a, b)
	if a.name == "mcl_honey:honey_block" and b.name == "mcl_core:slimeblock" then
		return false
	elseif a.name == "mcl_core:slimeblock" and b.name == "mcl_honey:honey_block" then
		return false
	end
	return is_sticky(a) or is_sticky(b)
end

local function index_of(list, pos)
	for i = 1, #list do
		local p = list[i]
		if p.x == pos.x and p.y == pos.y and p.z == pos.z then
			return i
		end
	end
	return nil
end

local resolver_class = {}
resolver_class.__index = resolver_class

function mcl_pistons.new_resolver(piston_pos, d, extending)
	local r = setmetatable({
		piston_pos = piston_pos,
		piston_direction = d,
		extending = extending,
		to_push = {},
		to_destroy = {},
	}, resolver_class)
	if extending then
		r.push_direction = d
		r.start_pos = rel(piston_pos, d)
	else
		r.push_direction = opposite[d]
		r.start_pos = rel(piston_pos, d, 2)
	end
	return r
end

function resolver_class:resolve()
	self.to_push = {}
	self.to_destroy = {}
	local next_node = get_node(self.start_pos)
	if not is_pushable(next_node, self.start_pos, self.push_direction, false, self.piston_direction) then
		if self.extending and get_push_reaction(next_node) == "destroy" then
			self.to_destroy[#self.to_destroy + 1] = self.start_pos
			return true
		end
		return false
	end
	if not self:add_block_line(self.start_pos, self.push_direction) then
		return false
	end
	local i = 1
	while i <= #self.to_push do
		local p = self.to_push[i]
		if is_sticky(get_node(p)) and not self:add_branching_blocks(p) then
			return false
		end
		i = i + 1
	end
	return true
end

local function pos_equals(a, b)
	return a.x == b.x and a.y == b.y and a.z == b.z
end

function resolver_class:add_block_line(start, d)
	local next_node = get_node(start)
	if is_air(next_node) then
		return true
	elseif not is_pushable(next_node, start, self.push_direction, false, d) then
		return true
	elseif pos_equals(start, self.piston_pos) then
		return true
	elseif index_of(self.to_push, start) then
		return true
	end
	local block_count = 1
	if block_count + #self.to_push > MAX_PUSH_DEPTH then
		return false
	end
	local back = opposite[self.push_direction]
	while is_sticky(next_node) do
		local p = rel(start, back, block_count)
		local previous = next_node
		next_node = get_node(p)
		if is_air(next_node) or not can_stick_to_each_other(previous, next_node)
				or not is_pushable(next_node, p, self.push_direction, false, back)
				or pos_equals(p, self.piston_pos) then
			break
		end
		block_count = block_count + 1
		if block_count + #self.to_push > MAX_PUSH_DEPTH then
			return false
		end
	end
	local blocks_added = 0
	for i = block_count - 1, 0, -1 do
		self.to_push[#self.to_push + 1] = rel(start, back, i)
		blocks_added = blocks_added + 1
	end
	local i = 1
	while true do
		local p = rel(start, self.push_direction, i)
		local collision = index_of(self.to_push, p)
		if collision then
			-- 0-based index in the Java code
			self:reorder_list_at_collision(blocks_added, collision - 1)
			for j = 0, collision - 1 + blocks_added do
				local bp = self.to_push[j + 1]
				if is_sticky(get_node(bp)) and not self:add_branching_blocks(bp) then
					return false
				end
			end
			return true
		end
		next_node = get_node(p)
		if is_air(next_node) then
			return true
		end
		if not is_pushable(next_node, p, self.push_direction, true, self.push_direction) or pos_equals(p, self.piston_pos) then
			return false
		end
		if get_push_reaction(next_node) == "destroy" then
			self.to_destroy[#self.to_destroy + 1] = p
			return true
		end
		if #self.to_push >= MAX_PUSH_DEPTH then
			return false
		end
		self.to_push[#self.to_push + 1] = p
		blocks_added = blocks_added + 1
		i = i + 1
	end
end

-- collision_pos is a 0-based index, like in the Java code
function resolver_class:reorder_list_at_collision(blocks_added, collision_pos)
	local list = self.to_push
	local n = #list
	local head, last_line, collision_to_line = {}, {}, {}
	for k = 1, collision_pos do
		head[#head + 1] = list[k]
	end
	for k = n - blocks_added + 1, n do
		last_line[#last_line + 1] = list[k]
	end
	for k = collision_pos + 1, n - blocks_added do
		collision_to_line[#collision_to_line + 1] = list[k]
	end
	local out = {}
	for _, l in ipairs({head, last_line, collision_to_line}) do
		for _, p in ipairs(l) do
			out[#out + 1] = p
		end
	end
	self.to_push = out
end

function resolver_class:add_branching_blocks(from)
	local from_node = get_node(from)
	for d = 0, 5 do
		if axis[d] ~= axis[self.push_direction] then
			local npos = rel(from, d)
			local nnode = get_node(npos)
			if can_stick_to_each_other(nnode, from_node) and not self:add_block_line(npos, d) then
				return false
			end
		end
	end
	return true
end

-- Moving blocks (PistonMovingBlockEntity) ----------------------------------------
--
-- The moving block entity lives in `entities` (by position hash) and in the
-- metadata of the moving piston node, so moving blocks survive a restart.

local entities = {}

local stage_names = {
	[1] = "mcl_pistons:moving_piston",
	[0.5] = "mcl_pistons:moving_piston_half",
	[0] = "mcl_pistons:moving_piston_end",
}

function mcl_pistons.is_moving_piston(node)
	return mcl_redstone.block_id(node.name) == MOVING_PISTON
end

function mcl_pistons.get_moving_entity(pos)
	return entities[hash(pos)]
end

local function extended_progress(be, progress)
	return be.extending and progress - 1 or 1 - progress
end

local function movement_direction(be)
	return be.extending and be.direction or opposite[be.direction]
end

-- Moving piston node for the collision box at the current progress: the box
-- trails the node by (1 - progress) against the movement.
local function stage_node(be)
	local behind = 1 - be.progress
	local name = behind >= 1 and stage_names[1] or behind > 0 and stage_names[0.5] or stage_names[0]
	if be.source and not be.extending then
		name = stage_names[0]
	end
	return {name = name, param2 = core.dir_to_facedir(dirvec[movement_direction(be)], true)}
end

local function visual_offset(be, progress)
	return vector.multiply(dirvec[be.direction], extended_progress(be, progress))
end

local function spawn_visual(pos, node, offset)
	local obj = core.add_entity(vector.add(pos, offset), "mcl_pistons:moving_block")
	if obj then
		obj:set_properties({node = {name = node.name, param2 = node.param2}})
	end
	return obj
end

local function update_visual(be)
	if be.obj and be.obj:get_pos() then
		be.obj:move_to(vector.add(be.pos, visual_offset(be, be.progress)), true)
	end
end

local function remove_visual(be)
	for _, o in ipairs({be.obj, be.base_obj}) do
		if o and o:get_pos() then
			o:remove()
		end
	end
	be.obj, be.base_obj = nil, nil
end

local function save_meta(be)
	local meta = core.get_meta(be.pos)
	meta:set_string("moved", core.serialize({
		node = be.moved, meta = be.moved_meta, timer = be.moved_timer,
		direction = be.direction, extending = be.extending, source = be.source,
		sticky = be.sticky,
	}))
end

local function remove_entity(be)
	entities[hash(be.pos)] = nil
	be.removed = true
	if be.ticker then
		be.ticker.removed = true
	end
	remove_visual(be)
end

local function restore_data(be, pos, node)
	if not mcl_redstone.same_node(get_node(pos), node) then
		return
	end
	if be.moved_meta then
		core.get_meta(pos):from_table(be.moved_meta)
	end
	if be.moved_timer then
		core.get_node_timer(pos):set(be.moved_timer[1], be.moved_timer[2])
	end
	if be.old_pos then
		run_on_move({{pos = vector.copy(pos), old_pos = be.old_pos, node = node}})
	end
end

-- Entities --------------------------------------------------------------------------

local function object_box(obj)
	local p = obj:get_pos()
	local props = obj:get_properties()
	local cb = props and props.collisionbox
	if not p or not cb then
		return nil
	end
	return {p.x + cb[1], p.y + cb[2], p.z + cb[3], p.x + cb[4], p.y + cb[5], p.z + cb[6]}
end

local function intersects(a, b)
	return a[1] < b[4] and a[4] > b[1] and a[2] < b[5] and a[5] > b[2] and a[3] < b[6] and a[6] > b[3]
end

-- PistonMath.getMovementArea
local function movement_area(box, m, delta)
	local v = dirvec[m]
	local r = {box[1], box[2], box[3], box[4], box[5], box[6]}
	if v.x > 0 then r[1], r[4] = box[4], box[4] + delta
	elseif v.x < 0 then r[1], r[4] = box[1] - delta, box[1]
	elseif v.y > 0 then r[2], r[5] = box[5], box[5] + delta
	elseif v.y < 0 then r[2], r[5] = box[2] - delta, box[2]
	elseif v.z > 0 then r[3], r[6] = box[6], box[6] + delta
	else r[3], r[6] = box[3] - delta, box[3]
	end
	return r
end

-- PistonMovingBlockEntity.getMovement
local function get_movement(outside, m, box)
	local v = dirvec[m]
	if v.x > 0 then return outside[4] - box[1]
	elseif v.x < 0 then return box[4] - outside[1]
	elseif v.y < 0 then return box[5] - outside[2]
	elseif v.z > 0 then return outside[6] - box[3]
	elseif v.z < 0 then return box[6] - outside[3]
	end
	return outside[5] - box[2]
end

local function can_be_pushed(obj)
	if obj:is_player() then
		return true
	end
	local ent = obj:get_luaentity()
	if not ent or ent.name == "mcl_pistons:moving_block" then
		return false
	end
	local def = core.registered_entities[ent.name]
	if def and def._mcl_pistons_unmovable or ent._mcl_pistons_unmovable then
		return false
	end
	if obj:get_attach() then
		return false
	end
	return true
end

local function move_entity(obj, m, delta)
	local v = dirvec[m]
	local p = obj:get_pos()
	obj:move_to(vector.new(p.x + v.x * delta, p.y + v.y * delta, p.z + v.z * delta), true)
end

local function shape_boxes(pos, node, be)
	local boxes = {}
	local def = core.registered_nodes[node.name]
	if not def or def.walkable == false then
		return boxes
	end
	local off = extended_progress(be, be.progress)
	local v = dirvec[be.direction]
	for _, b in ipairs(core.get_node_boxes("collision_box", pos, node)) do
		boxes[#boxes + 1] = {
			pos.x + math.min(b[1], b[4]) + v.x * off, pos.y + math.min(b[2], b[5]) + v.y * off, pos.z + math.min(b[3], b[6]) + v.z * off,
			pos.x + math.max(b[1], b[4]) + v.x * off, pos.y + math.max(b[2], b[5]) + v.y * off, pos.z + math.max(b[3], b[6]) + v.z * off,
		}
	end
	return boxes
end

-- The node whose shape pushes entities (getCollisionRelatedBlockState)
local function collision_node(be)
	if not be.extending and be.source and is_piston_base(be.moved) then
		return {name = be.sticky and "mcl_pistons:piston_pusher_sticky" or "mcl_pistons:piston_pusher",
			param2 = be.moved.param2}
	end
	return be.moved
end

-- PistonMovingBlockEntity.moveCollidedEntities
local function move_collided_entities(be, new_progress)
	local m = movement_direction(be)
	local delta_progress = new_progress - be.progress
	local boxes = shape_boxes(be.pos, collision_node(be), be)
	if #boxes == 0 then
		return
	end
	local bounds = {math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge}
	for _, b in ipairs(boxes) do
		for k = 1, 3 do
			bounds[k] = math.min(bounds[k], b[k])
			bounds[k + 3] = math.max(bounds[k + 3], b[k + 3])
		end
	end
	local area = movement_area(bounds, m, delta_progress)
	for k = 1, 3 do
		area[k] = math.min(area[k], bounds[k])
		area[k + 3] = math.max(area[k + 3], bounds[k + 3])
	end
	local bounce = be.moved.name == "mcl_core:slimeblock"
	local v = dirvec[m]
	for _, obj in ipairs(core.get_objects_in_area(vector.new(area[1] - 2, area[2] - 2, area[3] - 2),
			vector.new(area[4] + 2, area[5] + 2, area[6] + 2))) do
		local ebox = can_be_pushed(obj) and object_box(obj)
		if ebox and intersects(area, ebox) then
			if bounce then
				-- The slime block sets the velocity along its movement to one
				-- block per tick
				local vel = obj:get_velocity() or vector.zero()
				local target = vector.new(
					v.x ~= 0 and v.x * 20 or vel.x,
					v.y ~= 0 and v.y * 20 or vel.y,
					v.z ~= 0 and v.z * 20 or vel.z)
				if obj:is_player() then
					obj:add_velocity(vector.subtract(target, vel))
				else
					obj:set_velocity(target)
				end
			end
			local delta = 0
			for _, b in ipairs(boxes) do
				local moving = movement_area(b, m, delta_progress)
				if intersects(moving, ebox) then
					delta = math.max(delta, get_movement(moving, m, ebox))
					if delta >= delta_progress then
						break
					end
				end
			end
			if delta > 0 then
				delta = math.min(delta, delta_progress) + 0.01
				move_entity(obj, m, delta)
				if not be.extending and be.source then
					-- fixEntityWithinPistonBase
					local block = {be.pos.x - 0.5, be.pos.y - 0.5, be.pos.z - 0.5, be.pos.x + 0.5, be.pos.y + 0.5, be.pos.z + 0.5}
					local eb = object_box(obj)
					if eb and intersects(eb, block) then
						local o = opposite[m]
						local d1 = get_movement(block, o, eb) + 0.01
						local inter = {math.max(eb[1], block[1]), math.max(eb[2], block[2]), math.max(eb[3], block[3]),
							math.min(eb[4], block[4]), math.min(eb[5], block[5]), math.min(eb[6], block[6])}
						local d2 = get_movement(block, o, inter) + 0.01
						if math.abs(d1 - d2) < 0.01 then
							move_entity(obj, o, math.min(d1, delta_progress) + 0.01)
						end
					end
				end
			end
		end
	end
end

-- PistonMovingBlockEntity.moveStuckEntities: honey drags what stands on it
local function move_stuck_entities(be, new_progress)
	if be.moved.name ~= "mcl_honey:honey_block" then
		return
	end
	local m = movement_direction(be)
	if axis[m] == 0 then
		return
	end
	local off = extended_progress(be, be.progress)
	local v = dirvec[be.direction]
	local box = {be.pos.x - 0.5 + v.x * off, be.pos.y + 0.5 + v.y * off, be.pos.z - 0.5 + v.z * off,
		be.pos.x + 0.5 + v.x * off, be.pos.y + 1.000001 + v.y * off, be.pos.z + 0.5 + v.z * off}
	local delta = new_progress - be.progress
	for _, obj in ipairs(core.get_objects_in_area(vector.new(box[1], box[2], box[3]), vector.new(box[4], box[5], box[6]))) do
		if can_be_pushed(obj) and mcl_pistons.get_push_reaction_entity(obj) == "normal" then
			local p = obj:get_pos()
			if p.x >= box[1] and p.x <= box[4] and p.z >= box[3] and p.z <= box[6] then
				move_entity(obj, m, delta)
			end
		end
	end
end

function mcl_pistons.get_push_reaction_entity(obj)
	return "normal"
end

-- Ticking ------------------------------------------------------------------------

-- PistonMovingBlockEntity.finalTick
function mcl_pistons.final_tick(be)
	if be.progress_o >= 1 then
		return
	end
	be.progress = 1
	be.progress_o = 1
	remove_entity(be)
	local pos = be.pos
	if mcl_pistons.is_moving_piston(get_node(pos)) then
		local new
		if be.source then
			new = {name = "air"}
		else
			new = mcl_redstone.update_from_neighbour_shapes(be.moved, pos)
		end
		mcl_redstone.set_block(pos, new, 3)
		restore_data(be, pos, new)
		mcl_redstone.neighbor_changed(pos, mcl_redstone.block_id(new.name))
	end
end

-- PistonMovingBlockEntity.tick
local function tick(be)
	be.last_ticked = mcl_redstone.get_game_time()
	be.progress_o = be.progress
	local pos = be.pos
	if be.progress_o >= 1 then
		remove_entity(be)
		if mcl_pistons.is_moving_piston(get_node(pos)) then
			local new = mcl_redstone.update_from_neighbour_shapes(be.moved, pos)
			if new.name == "air" then
				mcl_redstone.set_block(pos, be.moved, 340)
				-- Block.updateOrDestroy
				if not mcl_redstone.same_node(be.moved, new) then
					mcl_redstone.destroy_block(pos, true)
				end
			else
				mcl_redstone.set_block(pos, new, 67)
				restore_data(be, pos, new)
				mcl_redstone.neighbor_changed(pos, mcl_redstone.block_id(new.name))
			end
		end
	else
		local new_progress = be.progress + 0.5
		move_collided_entities(be, new_progress)
		move_stuck_entities(be, new_progress)
		be.progress = math.min(1, new_progress)
		local node = get_node(pos)
		if mcl_pistons.is_moving_piston(node) then
			local s = stage_node(be)
			if not mcl_redstone.same_node(s, node) then
				mcl_redstone._raw_write(pos, s, false)
			end
		end
		update_visual(be)
	end
end

-- MovingPistonBlock.newMovingBlockEntity + Level.setBlockEntity. The moving
-- piston node must already be at pos.
function mcl_pistons.new_moving_entity(pos, moved, direction, extending, source, opts)
	opts = opts or {}
	local old = entities[hash(pos)]
	if old then
		remove_entity(old)
	end
	local be = {
		pos = vector.copy(pos),
		moved = {name = moved.name, param2 = moved.param2 or 0},
		moved_meta = opts.meta,
		moved_timer = opts.timer,
		old_pos = opts.old_pos,
		direction = direction,
		extending = extending,
		source = source,
		sticky = opts.sticky,
		progress = opts.progress or 0,
		progress_o = opts.progress or 0,
		last_ticked = 0,
	}
	entities[hash(pos)] = be
	local node = get_node(pos)
	local s = stage_node(be)
	if mcl_pistons.is_moving_piston(node) and not mcl_redstone.same_node(s, node) then
		mcl_redstone._raw_write(pos, s, false)
	end
	save_meta(be)
	be.ticker = mcl_redstone.add_ticker({pos = be.pos, tick = function()
		tick(be)
	end})
	-- What Minecraft's piston renderer draws
	if source and not extending and is_piston_base(be.moved) then
		be.base_obj = spawn_visual(pos, be.moved, vector.zero())
		be.obj = spawn_visual(pos, collision_node(be), visual_offset(be, be.progress))
	else
		be.obj = spawn_visual(pos, be.moved, visual_offset(be, be.progress))
	end
	for _, o in ipairs({be.obj, be.base_obj}) do
		local e = o and o:get_luaentity()
		if e then
			e._be = be
		end
	end
	return be
end

-- Moving pistons from before a restart finish moving at once.
core.register_lbm({
	label = "Restore moving piston blocks",
	name = "mcl_pistons:restore_moving",
	nodenames = {"group:moving_piston"},
	run_at_every_load = true,
	action = function(pos, node)
		if entities[hash(pos)] then
			return
		end
		local data = core.deserialize(core.get_meta(pos):get_string("moved"))
		if not data or not data.node then
			core.remove_node(pos)
			return
		end
		mcl_pistons.new_moving_entity(pos, data.node, data.direction, data.extending, data.source,
			{meta = data.meta, timer = data.timer, sticky = data.sticky, progress = 1})
	end,
})

core.register_entity("mcl_pistons:moving_block", {
	initial_properties = {
		visual = "node",
		physical = false,
		pointable = false,
		collide_with_objects = false,
		static_save = false,
		visual_size = {x = 1, y = 1, z = 1},
		collisionbox = {0, 0, 0, 0, 0, 0},
		selectionbox = {0, 0, 0, 0, 0, 0},
	},
	_mcl_pistons_unmovable = true,
	on_step = function(self)
		if not self._be or self._be.removed then
			self.object:remove()
		end
	end,
})
