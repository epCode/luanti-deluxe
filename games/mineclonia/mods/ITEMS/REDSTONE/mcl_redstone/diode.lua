-- Port of Minecraft's DiodeBlock, the base of repeaters and comparators.
--
-- mcl_redstone.diode_behaviour(spec) returns a `_mcl_redstone` table.  spec:
--   block         block id
--   facing(node)  Minecraft FACING: the direction towards the input
--   powered(node) POWERED state
--   set_powered(node, powered) node with POWERED changed
--   delay(node)   delay in game ticks
--   output(pos, node)       output signal while powered (default 15)
--   side_input_diodes_only  repeaters only take side inputs from diodes
--   is_locked(pos, node)    default false
--   should_turn_on(pos, node, diode)
--   get_input_signal(pos, node, diode)
--   check_tick_on_neighbor(pos, node, diode)
--   tick(pos, node, diode)
-- The defaults are DiodeBlock's; overrides get the diode table to call them.

local DOWN, UP = mcl_redstone.DOWN, mcl_redstone.UP
local rel = mcl_redstone.rel
local opposite = mcl_redstone.opposite
local get_node = mcl_redstone.get_node

local PRIORITY_EXTREMELY_HIGH = -3
local PRIORITY_VERY_HIGH = -2
local PRIORITY_HIGH = -1

-- DiodeBlock.canSurviveOn
function mcl_redstone.diode_can_survive_on(pos, node)
	return mcl_redstone.is_face_sturdy(pos, node, UP, "rigid")
end

function mcl_redstone.diode_behaviour(spec)
	local block = spec.block
	local facing = spec.facing
	local powered = spec.powered
	local diode = {}

	local function output(pos, node)
		return spec.output and spec.output(pos, node) or 15
	end

	function diode.own_signal(pos, node)
		return powered(node) and output(pos, node) or 0
	end

	function diode.is_locked(pos, node)
		return spec.is_locked and spec.is_locked(pos, node) or false
	end

	function diode.get_input_signal(pos, node)
		local d = facing(node)
		local target = rel(pos, d)
		local input = mcl_redstone.get_signal(target, d)
		if input >= 15 then
			return input
		end
		local tnode = get_node(target)
		if mcl_redstone.block_id(tnode.name) == "mcl_redstone:redstone" then
			return math.max(input, tnode.param2 % 16)
		end
		return input
	end
	if spec.get_input_signal then
		local base = diode.get_input_signal
		diode.base_get_input_signal = base
		diode.get_input_signal = function(pos, node)
			return spec.get_input_signal(pos, node, diode)
		end
	end

	function diode.get_alternate_signal(pos, node)
		local d = facing(node)
		local cw, ccw = mcl_redstone.clockwise[d], mcl_redstone.counter_clockwise[d]
		local only = spec.side_input_diodes_only or false
		return math.max(
			mcl_redstone.get_control_input_signal(rel(pos, cw), cw, only),
			mcl_redstone.get_control_input_signal(rel(pos, ccw), ccw, only))
	end

	function diode.should_turn_on(pos, node)
		if spec.should_turn_on then
			return spec.should_turn_on(pos, node, diode)
		end
		return diode.get_input_signal(pos, node) > 0
	end

	-- DiodeBlock.shouldPrioritize: the diode in front does not point back here
	function diode.should_prioritize(pos, node)
		local d = opposite[facing(node)]
		local front = get_node(rel(pos, d))
		local fb = mcl_redstone.get_block(front.name)
		return fb.is_diode and fb.facing and fb.facing(front) ~= d or false
	end

	function diode.check_tick_on_neighbor(pos, node)
		if spec.check_tick_on_neighbor then
			return spec.check_tick_on_neighbor(pos, node, diode)
		end
		if diode.is_locked(pos, node) then
			return
		end
		local on = powered(node)
		local should = diode.should_turn_on(pos, node)
		if on ~= should and not mcl_redstone.will_tick_this_tick(pos, block) then
			local priority = PRIORITY_HIGH
			if diode.should_prioritize(pos, node) then
				priority = PRIORITY_EXTREMELY_HIGH
			elseif on then
				priority = PRIORITY_VERY_HIGH
			end
			mcl_redstone.schedule_tick(pos, block, spec.delay(node), priority)
		end
	end

	-- DiodeBlock.updateNeighborsInFront
	function diode.update_neighbors_in_front(pos, node)
		local d = facing(node)
		local front = rel(pos, opposite[d])
		mcl_redstone.neighbor_changed(front, block, pos)
		mcl_redstone.update_neighbors_at_except(front, block, d)
	end

	local function can_survive(pos)
		local below = rel(pos, DOWN)
		return mcl_redstone.diode_can_survive_on(below, get_node(below))
	end

	local b = {
		block = block,
		is_diode = true,
		facing = facing,
		signal_source = true,
		push_reaction = "destroy",
		own_signal = diode.own_signal,
		get_signal = function(pos, node, d)
			return facing(node) == d and diode.own_signal(pos, node) or 0
		end,
		on_place = function(pos, node)
			diode.update_neighbors_in_front(pos, node)
		end,
		affect_neighbors_after_removal = function(pos, node, moved)
			if not moved then
				diode.update_neighbors_in_front(pos, node)
			end
		end,
		neighbor_changed = function(pos, node)
			if mcl_redstone.block_id(get_node(pos).name) ~= block then
				return
			end
			if can_survive(pos) then
				diode.check_tick_on_neighbor(pos, node)
			else
				mcl_redstone.drop_resources(pos, node)
				mcl_redstone.remove_block(pos, false)
				for d = 0, 5 do
					mcl_redstone.update_neighbors_at(rel(pos, d), block)
				end
			end
		end,
		tick = function(pos, node)
			if spec.tick then
				return spec.tick(pos, node, diode)
			end
			if diode.is_locked(pos, node) then
				return
			end
			local on = powered(node)
			local should = diode.should_turn_on(pos, node)
			if on and not should then
				mcl_redstone.set_block(pos, spec.set_powered(node, false), 2)
			elseif not on then
				mcl_redstone.set_block(pos, spec.set_powered(node, true), 2)
				if not should then
					mcl_redstone.schedule_tick(pos, block, spec.delay(node), PRIORITY_VERY_HIGH)
				end
			end
		end,
		-- DiodeBlock.setPlacedBy, called from after_place_node
		placed_by = function(pos, node)
			if diode.should_turn_on(pos, node) then
				mcl_redstone.schedule_tick(pos, block, 1)
			end
		end,
		diode = diode,
	}
	b.get_direct_signal = b.get_signal
	return b
end

-- after_place_node for diodes (BlockItem.place calls Block.setPlacedBy)
function mcl_redstone.diode_after_place_node(pos)
	mcl_redstone._begin()
	local node = get_node(pos)
	local b = mcl_redstone.get_block(node.name)
	if b.placed_by then
		b.placed_by(pos, node)
	end
	mcl_redstone._end()
end

-- on_place for diodes: BlockItem.place checks canSurvive (rigid support)
function mcl_redstone.diode_on_place(itemstack, placer, pointed_thing)
	if pointed_thing.type ~= "node" then
		return itemstack
	end
	local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
	if rc then return rc end
	local under = core.get_node(pointed_thing.under)
	local udef = core.registered_nodes[under.name]
	local pos = udef and udef.buildable_to and pointed_thing.under or pointed_thing.above
	local below = vector.offset(pos, 0, -1, 0)
	if not mcl_redstone.diode_can_survive_on(below, core.get_node(below)) then
		return itemstack
	end
	return core.item_place_node(itemstack, placer, pointed_thing)
end
