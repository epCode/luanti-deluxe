------------------------------------------------------------------------
-- SculkSpreader (createLevelSpreader), SculkSpreader.ChargeCursor,
-- SculkBehaviour (DEFAULT, SculkBlock, SculkVeinBlock) and the
-- MultifaceSpreader of sculk veins (SculkVeinSpreaderConfig). Worldgen's
-- spreader lives in lg_register.lua.
------------------------------------------------------------------------

local R = mcl_redstone
local DOWN, UP = R.DOWN, R.UP
local floor, max, min, sqrt, random = math.floor, math.max, math.min, math.sqrt, math.random
local has_face, with_face, without_face = mcl_sculk.has_face, mcl_sculk.with_face, mcl_sculk.without_face
local vein_mask, vein_node, is_vein = mcl_sculk.vein_mask, mcl_sculk.vein_node, mcl_sculk.is_vein
local can_attach_to = mcl_sculk.can_attach_to
local ALL = mcl_sculk.DIRECTIONS

local MAX_GROWTH_RATE_RADIUS = 24
local MAX_CHARGE = 1000
local MAX_CURSORS = 32
local SHRIEKER_PLACEMENT_RATE = 11
local MAX_CURSOR_DISTANCE = 1024

local get_node = core.get_node

local function set_block(pos, node, flags)
	return R.set_block(pos, node, flags or 3)
end

local function is_air(node)
	return node.name == "air"
end

local function is_sculk(node)
	return node.name == "mcl_sculk:sculk"
end

local function is_catalyst(node)
	return node.name == "mcl_sculk:catalyst" or node.name == "mcl_sculk:catalyst_bloom"
end

-- Util.shuffledCopy / Direction.allShuffled
local function shuffled(list)
	local copy = table.copy(list)
	for i = #copy, 2, -1 do
		local j = random(1, i)
		copy[i], copy[j] = copy[j], copy[i]
	end
	return copy
end

-- BlockState.isFaceSturdy(level, pos, face)
local function face_sturdy(pos, d)
	local node = get_node(pos)
	if node.name == "ignore" then
		return true
	end
	return R.is_face_sturdy(pos, node, d)
end

------------------------------------------------------------------------
-- MultifaceBlock for sculk veins
------------------------------------------------------------------------

-- MultifaceBlock.isValidStateForPlacement
local function valid_for_placement(old, pos, d)
	if is_vein(old) and has_face(vein_mask(old), d) then
		return false
	end
	return can_attach_to(pos, d)
end

-- MultifaceBlock.getStateForPlacement(oldState, level, pos, direction)
local function state_for_placement(old, pos, d)
	if not valid_for_placement(old, pos, d) then
		return nil
	end
	local mask = is_vein(old) and vein_mask(old) or 0
	return vein_node(with_face(mask, d))
end
mcl_sculk.vein_state_for_placement = state_for_placement

------------------------------------------------------------------------
-- MultifaceSpreader with SculkVeinSpreaderConfig
------------------------------------------------------------------------

local SAME_POSITION, SAME_PLANE, WRAP_AROUND = 1, 2, 3
local DEFAULT_SPREAD_ORDER = {SAME_POSITION, SAME_PLANE, WRAP_AROUND}

local function spread_pos(t, pos, spread_d, from_face)
	if t == SAME_POSITION then
		return pos, spread_d
	elseif t == SAME_PLANE then
		return R.rel(pos, spread_d), from_face
	end
	return R.rel(R.rel(pos, spread_d), from_face), R.opposite[spread_d]
end

local function buildable_to(node)
	local def = core.registered_nodes[node.name]
	return def ~= nil and def.buildable_to == true
end

-- SculkVeinSpreaderConfig.stateCanBeReplaced
local function state_can_be_replaced(source, ppos, pd, existing)
	local against = get_node(R.rel(ppos, pd))
	if is_sculk(against) or is_catalyst(against)
			or core.get_item_group(against.name, "piston_moving") > 0 then
		return false
	end
	if math.abs(source.x - ppos.x) + math.abs(source.y - ppos.y) + math.abs(source.z - ppos.z) == 2 then
		local npos = R.rel(source, R.opposite[pd])
		if face_sturdy(npos, pd) then
			return false
		end
	end
	-- Waterlogging is not supported: a vein does not replace liquids
	if core.get_item_group(existing.name, "liquid") > 0 then
		return false
	end
	if core.get_item_group(existing.name, "fire") > 0 then
		return false
	end
	-- existingState.canBeReplaced() || DefaultSpreaderConfig.stateCanBeReplaced
	return buildable_to(existing) or is_air(existing) or is_vein(existing)
end

-- DefaultSpreaderConfig.canSpreadInto
local function can_spread_into(source, ppos, pd)
	local existing = get_node(ppos)
	if existing.name == "ignore" then
		return false
	end
	return state_can_be_replaced(source, ppos, pd, existing)
		and valid_for_placement(existing, ppos, pd)
end

-- SpreadConfig.isOtherBlockValidAsSource: everything except veins
local function other_valid_as_source(node)
	return not is_vein(node)
end

local function can_spread_from(node, face)
	return other_valid_as_source(node) or has_face(vein_mask(node), face)
end

-- getSpreadFromFaceTowardDirection
local function get_spread(node, pos, from_face, spread_d, types)
	if R.axis[spread_d] == R.axis[from_face] then
		return nil
	end
	local mask = vein_mask(node)
	if other_valid_as_source(node) or (has_face(mask, from_face) and not has_face(mask, spread_d)) then
		for _, t in ipairs(types) do
			local ppos, pd = spread_pos(t, pos, spread_d, from_face)
			if can_spread_into(pos, ppos, pd) then
				return ppos, pd
			end
		end
	end
	return nil
end

-- SpreadConfig.placeBlock (flags 2)
local function place_block(ppos, pd)
	local old = get_node(ppos)
	local new = state_for_placement(old, ppos, pd)
	if new then
		return set_block(ppos, new, 2)
	end
	return false
end

local function spread_from_face_toward_direction(node, pos, from_face, spread_d, types)
	local ppos, pd = get_spread(node, pos, from_face, spread_d, types)
	if ppos and place_block(ppos, pd) then
		return ppos, pd
	end
	return nil
end

-- MultifaceSpreader.spreadAll: the number of faces spread to
local function spread_all(node, pos, types)
	local count = 0
	for _, face in ipairs(ALL) do
		if can_spread_from(node, face) then
			for _, d in ipairs(ALL) do
				if spread_from_face_toward_direction(node, pos, face, d, types) then
					count = count + 1
				end
			end
		end
	end
	return count
end

local function vein_spread_all(node, pos)
	return spread_all(node, pos, DEFAULT_SPREAD_ORDER)
end
local function same_space_spread_all(node, pos)
	return spread_all(node, pos, {SAME_POSITION})
end
mcl_sculk.vein_spread_all = vein_spread_all

-- MultifaceSpreader.spreadFromRandomFaceTowardRandomDirection (bone meal
-- is not used by sculk veins; kept for completeness)
function mcl_sculk.vein_spread_random(node, pos)
	for _, face in ipairs(shuffled(ALL)) do
		if can_spread_from(node, face) then
			for _, d in ipairs(shuffled(ALL)) do
				local p, f = spread_from_face_toward_direction(node, pos, face, d, DEFAULT_SPREAD_ORDER)
				if p then
					return p, f
				end
			end
		end
	end
end

------------------------------------------------------------------------
-- SculkVeinBlock
------------------------------------------------------------------------

-- SculkVeinBlock.regrow
local function vein_regrow(pos, existing, faces)
	local mask = 0
	for _, d in ipairs(faces) do
		if can_attach_to(pos, d) then
			mask = with_face(mask, d)
		end
	end
	if mask == 0 then
		return false
	end
	set_block(pos, vein_node(mask), 3)
	return true
end

-- SculkVeinBlock.hasSubstrateAccess
local function has_substrate_access(node, pos)
	if not is_vein(node) then
		return false
	end
	local mask = vein_mask(node)
	for _, d in ipairs(ALL) do
		if has_face(mask, d) and mcl_sculk.is_replaceable(get_node(R.rel(pos, d)).name) then
			return true
		end
	end
	return false
end

-- Block.pushEntitiesUp: entities inside the block that became solid
local function push_entities_up(pos)
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 1.2)) do
		local p = obj:get_pos()
		if math.abs(p.x - pos.x) < 0.8 and math.abs(p.z - pos.z) < 0.8
				and p.y >= pos.y - 0.5 and p.y < pos.y + 0.5 then
			obj:set_pos(vector.new(p.x, pos.y + 0.5, p.z))
		end
	end
end

local VEIN = {}

function VEIN.on_discharged(state, pos)
	if not is_vein(state) then
		return
	end
	local mask = vein_mask(state)
	for _, d in ipairs(ALL) do
		if has_face(mask, d) and is_sculk(get_node(R.rel(pos, d))) then
			mask = without_face(mask, d)
		end
	end
	set_block(pos, vein_node(mask) or {name = "air"}, 3)
end

-- SculkVeinBlock.attemptPlaceSculk
local function attempt_place_sculk(spreader, pos)
	local state = get_node(pos)
	local mask = vein_mask(state)
	for _, support in ipairs(shuffled(ALL)) do
		if has_face(mask, support) then
			local spos = R.rel(pos, support)
			local sstate = get_node(spos)
			if spreader.replaceable(sstate.name) then
				local sculk = {name = "mcl_sculk:sculk"}
				set_block(spos, sculk, 3)
				push_entities_up(spos)
				mcl_sculk.play("block.sculk.spread", spos, 1, 1)
				vein_spread_all(sculk, spos)
				local skip = R.opposite[support]
				for _, d in ipairs(ALL) do
					if d ~= skip then
						local vpos = R.rel(spos, d)
						local v = get_node(vpos)
						if is_vein(v) then
							VEIN.on_discharged(v, vpos)
						end
					end
				end
				return true
			end
		end
	end
	return false
end

function VEIN.attempt_use_charge(cursor, origin, spreader, spread_veins)
	if spread_veins and attempt_place_sculk(spreader, cursor.pos) then
		return cursor.charge - 1
	end
	if random(0, spreader.charge_decay_rate - 1) == 0 then
		return floor(cursor.charge * 0.5)
	end
	return cursor.charge
end

-- SculkBehaviour defaults
function VEIN.attempt_spread_vein(pos, state)
	return vein_spread_all(state, pos) > 0
end
VEIN.can_change_block_state_on_spread = true
function VEIN.update_decay_delay()
	return 1
end
VEIN.spread_delay = 1

------------------------------------------------------------------------
-- SculkBlock
------------------------------------------------------------------------

local SCULK = {}

-- SculkBlock.canPlaceGrowth
local function can_place_growth(pos)
	local above = get_node(vector.offset(pos, 0, 1, 0))
	if not is_air(above) then
		return false
	end
	-- BlockTags.SCULK_GROWTH_INHIBITORS: sculk_sensor, sculk_shrieker
	local found = core.find_nodes_in_area(vector.offset(pos, -4, 0, -4), vector.offset(pos, 4, 2, 4),
		{"mcl_sculk:sensor", "mcl_sculk:sensor_active", "mcl_sculk:sensor_cooldown",
		"mcl_sculk:shrieker", "mcl_sculk:shrieker_can_summon"})
	return #found <= 2
end

-- SculkBlock.getDecayPenalty
local function decay_penalty(spreader, pos, origin, charge)
	local r = spreader.no_growth_radius
	local d = sqrt((pos.x - origin.x) ^ 2 + (pos.y - origin.y) ^ 2 + (pos.z - origin.z) ^ 2) - r
	local outer = d * d
	local reach = (MAX_GROWTH_RATE_RADIUS - r) ^ 2
	local factor = min(1, outer / reach)
	return max(1, floor(charge * factor * 0.5))
end

-- SculkBlock.getRandomGrowthState
local function random_growth_state(world_gen)
	if random(0, SHRIEKER_PLACEMENT_RATE - 1) == 0 then
		return {name = world_gen and "mcl_sculk:shrieker_can_summon" or "mcl_sculk:shrieker"}
	end
	return {name = "mcl_sculk:sensor"}
end

function SCULK.attempt_use_charge(cursor, origin, spreader)
	local charge = cursor.charge
	if charge ~= 0 and random(0, spreader.charge_decay_rate - 1) == 0 then
		local pos = cursor.pos
		local dist2 = (pos.x - origin.x) ^ 2 + (pos.y - origin.y) ^ 2 + (pos.z - origin.z) ^ 2
		-- BlockPos.closerThan: distSqr < r^2
		local close = dist2 < spreader.no_growth_radius ^ 2
		if not close and can_place_growth(pos) then
			local cost = spreader.growth_spawn_cost
			if random(0, cost - 1) < charge then
				local gpos = vector.offset(pos, 0, 1, 0)
				local growth = random_growth_state(spreader.world_gen)
				set_block(gpos, growth, 3)
				mcl_sculk.play(growth.name == "mcl_sculk:sensor" and "block.sculk_sensor.place"
					or "block.sculk_shrieker.place", pos, 1, 1)
			end
			return max(0, charge - cost)
		end
		if random(0, spreader.additional_decay_rate - 1) ~= 0 then
			return charge
		end
		return charge - (close and 1 or decay_penalty(spreader, pos, origin, charge))
	end
	return charge
end

function SCULK.attempt_spread_vein(pos, state)
	return vein_spread_all(state, pos) > 0
end
SCULK.can_change_block_state_on_spread = false
function SCULK.update_decay_delay()
	return 1
end
SCULK.spread_delay = 1
function SCULK.on_discharged() end

------------------------------------------------------------------------
-- SculkBehaviour.DEFAULT
------------------------------------------------------------------------

local DEFAULT = {}

function DEFAULT.attempt_spread_vein(pos, state, facings)
	if facings == nil then
		return same_space_spread_all(get_node(pos), pos) > 0
	elseif #facings > 0 then
		if not is_air(state) then
			return false
		end
		return vein_regrow(pos, state, facings)
	end
	return vein_spread_all(state, pos) > 0
end

function DEFAULT.attempt_use_charge(cursor)
	return cursor.decay_delay > 0 and cursor.charge or 0
end

function DEFAULT.update_decay_delay(age)
	return max(age - 1, 0)
end
DEFAULT.can_change_block_state_on_spread = true
DEFAULT.spread_delay = 1
function DEFAULT.on_discharged() end

local function behaviour(node)
	if is_sculk(node) then
		return SCULK
	elseif is_vein(node) then
		return VEIN
	end
	return DEFAULT
end

local function is_sculk_behaviour(node)
	return is_sculk(node) or is_vein(node)
end

-- MultifaceBlock.availableFaces (an empty list for non-multiface blocks)
local function available_faces(node)
	local faces = {}
	if is_vein(node) then
		local mask = vein_mask(node)
		for _, d in ipairs(ALL) do
			if has_face(mask, d) then
				table.insert(faces, d)
			end
		end
	end
	return faces
end

------------------------------------------------------------------------
-- ChargeCursor
------------------------------------------------------------------------

-- The 18 neighbours that are not corners
local NON_CORNER = {}
for x = -1, 1 do
	for y = -1, 1 do
		for z = -1, 1 do
			if (x == 0 or y == 0 or z == 0) and not (x == 0 and y == 0 and z == 0) then
				table.insert(NON_CORNER, vector.new(x, y, z))
			end
		end
	end
end

local function new_cursor(pos, charge)
	return {pos = vector.copy(pos), charge = charge, update_delay = 0, decay_delay = 1, facings = nil}
end

local function is_unobstructed(from, d)
	local test = R.rel(from, d)
	return not face_sturdy(test, R.opposite[d])
end

local function dir_of(axis, negative)
	if axis == "x" then
		return negative and R.WEST or R.EAST
	elseif axis == "y" then
		return negative and DOWN or UP
	end
	return negative and R.SOUTH or R.NORTH
end

-- ChargeCursor.isMovementUnobstructed
local function movement_unobstructed(from, to)
	local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
	if math.abs(dx) + math.abs(dy) + math.abs(dz) == 1 then
		return true
	end
	local ddx = dir_of("x", dx < 0)
	local ddy = dir_of("y", dy < 0)
	local ddz = dir_of("z", dz < 0)
	if dx == 0 then
		return is_unobstructed(from, ddy) or is_unobstructed(from, ddz)
	elseif dy == 0 then
		return is_unobstructed(from, ddx) or is_unobstructed(from, ddz)
	end
	return is_unobstructed(from, ddx) or is_unobstructed(from, ddy)
end

-- ChargeCursor.getValidMovementPos
local function valid_movement_pos(pos, origin, spreader)
	local result = pos
	for _, off in ipairs(shuffled(NON_CORNER)) do
		local n = vector.add(pos, off)
		local ok = true
		if spreader.world_gen then
			ok = (origin.x - n.x) ^ 2 + (origin.z - n.z) ^ 2 <= 144
		end
		if ok then
			local t = get_node(n)
			if is_sculk_behaviour(t) and movement_unobstructed(pos, n) then
				result = n
				if has_substrate_access(t, n) then
					break
				end
			end
		end
	end
	if vector.equals(result, pos) then
		return nil
	end
	return result
end

local function should_update(cursor, origin, spreader)
	if cursor.charge <= 0 then
		return false
	end
	if spreader.world_gen then
		return true
	end
	-- ServerLevel.shouldTickBlocksAt
	if core.compare_block_status then
		return core.compare_block_status(origin, "active")
	end
	return core.get_node_or_nil(origin) ~= nil
end

-- ChargeCursor.update
local function cursor_update(cursor, origin, spreader, spread_veins)
	if not should_update(cursor, origin, spreader) then
		return
	end
	if cursor.update_delay > 0 then
		cursor.update_delay = cursor.update_delay - 1
		return
	end
	local pos = cursor.pos
	local state = get_node(pos)
	local b = behaviour(state)
	if spread_veins and b.attempt_spread_vein(pos, state, cursor.facings) then
		if b.can_change_block_state_on_spread then
			state = get_node(pos)
			b = behaviour(state)
		end
		mcl_sculk.play("block.sculk.spread", pos, 1, 1)
	end
	cursor.charge = b.attempt_use_charge(cursor, origin, spreader, spread_veins)
	if cursor.charge <= 0 then
		b.on_discharged(state, pos)
	else
		local transfer = valid_movement_pos(pos, origin, spreader)
		if transfer then
			b.on_discharged(state, pos)
			cursor.pos = transfer
			state = get_node(transfer)
		elseif spreader.world_gen then
			b.on_discharged(state, pos)
			cursor.charge = 0
			return
		end
		if is_sculk_behaviour(state) then
			cursor.facings = available_faces(state)
		end
		cursor.decay_delay = b.update_decay_delay(cursor.decay_delay)
		cursor.update_delay = b.spread_delay
	end
end

------------------------------------------------------------------------
-- SculkSpreader
------------------------------------------------------------------------

local Spreader = {}
Spreader.__index = Spreader

-- SculkSpreader.createLevelSpreader
function mcl_sculk.new_level_spreader()
	return setmetatable({
		world_gen = false,
		replaceable = mcl_sculk.is_replaceable,
		growth_spawn_cost = 10,
		no_growth_radius = 4,
		charge_decay_rate = 10,
		additional_decay_rate = 5,
		cursors = {},
	}, Spreader)
end

function Spreader:add_cursor(cursor)
	if #self.cursors < MAX_CURSORS then
		table.insert(self.cursors, cursor)
	end
end

function Spreader:add_cursors(pos, charge)
	while charge > 0 do
		local c = min(charge, MAX_CHARGE)
		self:add_cursor(new_cursor(pos, c))
		charge = charge - c
	end
end

function Spreader:clear()
	self.cursors = {}
end

local function pack_faces(faces)
	local mask = 0
	for _, d in ipairs(faces) do
		mask = with_face(mask, d)
	end
	return mask
end

local function pos_key(p)
	return p.x .. "," .. p.y .. "," .. p.z
end

-- SculkSpreader.updateCursors
function Spreader:update_cursors(origin, spread_veins)
	if #self.cursors == 0 then
		return
	end
	local processed = {}
	local mergeable = {}
	local charges = {}
	local charge_keys = {}
	for _, cursor in ipairs(self.cursors) do
		local p = cursor.pos
		local unreasonable = max(math.abs(p.x - origin.x), math.abs(p.y - origin.y),
			math.abs(p.z - origin.z)) > MAX_CURSOR_DISTANCE
		if not unreasonable then
			cursor_update(cursor, origin, self, spread_veins)
			if cursor.charge <= 0 then
				mcl_sculk.charge_event(cursor.pos, 0)
			else
				local key = pos_key(cursor.pos)
				if not charges[key] then
					table.insert(charge_keys, key)
				end
				charges[key] = (charges[key] or 0) + cursor.charge
				local existing = mergeable[key]
				if not existing then
					mergeable[key] = cursor
					table.insert(processed, cursor)
				elseif not self.world_gen and cursor.charge + existing.charge <= MAX_CHARGE then
					-- ChargeCursor.mergeWith
					existing.charge = existing.charge + cursor.charge
					cursor.charge = 0
					existing.update_delay = min(existing.update_delay, cursor.update_delay)
				else
					table.insert(processed, cursor)
					if cursor.charge < existing.charge then
						mergeable[key] = cursor
					end
				end
			end
		end
	end
	for _, key in ipairs(charge_keys) do
		local charge = charges[key]
		local c = mergeable[key]
		local faces = c and c.facings
		if charge > 0 and faces then
			local n = floor(math.log(1 + charge) / 2.3) + 1
			mcl_sculk.charge_event(c.pos, n * 64 + pack_faces(faces))
		end
	end
	self.cursors = processed
end

-- SculkSpreader.save / load (node metadata "cursors")
function Spreader:serialize()
	local list = {}
	for _, c in ipairs(self.cursors) do
		table.insert(list, {pos = c.pos, charge = c.charge, decay_delay = c.decay_delay,
			update_delay = c.update_delay, facings = c.facings})
	end
	return core.serialize(list)
end

function Spreader:deserialize(str)
	self.cursors = {}
	local list = str and str ~= "" and core.deserialize(str)
	if type(list) == "table" then
		for _, c in ipairs(list) do
			if c.pos and c.charge then
				self:add_cursor({pos = vector.copy(c.pos), charge = min(MAX_CHARGE, max(0, c.charge)),
					decay_delay = c.decay_delay or 1, update_delay = c.update_delay or 0,
					facings = c.facings})
			end
		end
	end
end

mcl_sculk._behaviours = {DEFAULT = DEFAULT, SCULK = SCULK, VEIN = VEIN}
