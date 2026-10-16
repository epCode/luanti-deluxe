# API for `mcl_redstone`

`mcl_redstone` is a port of Minecraft Java Edition's redstone engine (26.3).
It reproduces Minecraft's game tick, scheduled block ticks with priorities,
block events, block entity tickers, neighbour updates (including their order),
shape updates, `Level.setBlock` and its update flags, and the signal queries
of `SignalGetter`.  Components are written like Minecraft blocks: with the
decompiled Java source next to it, a component is a line-by-line port.

## Conventions

* **Directions** are numbers like Minecraft's `Direction` enum:
  `mcl_redstone.DOWN = 0, UP = 1, NORTH = 2, SOUTH = 3, WEST = 4, EAST = 5`.
  Minecraft north is -Z, Luanti north is +Z: `NORTH` is `(0, 0, 1)`.
  `mcl_redstone.dirvec[d]`, `opposite[d]`, `clockwise[d]`,
  `counter_clockwise[d]`, `axis[d]` (0 = y, 1 = z, 2 = x), `rel(pos, d [, n])`,
  `dir_index(vector)`, `fourdir_to_dir[param2]`, `dir_to_fourdir[d]`.
  Lists in Minecraft's iteration orders: `ALL` (`Direction.values()`),
  `HORIZONTAL` (N, E, S, W), `VERTICAL` (UP, DOWN), `UPDATE_ORDER`,
  `UPDATE_SHAPE_ORDER`.
* **Signal directions** follow Minecraft: in `get_signal(pos, d)` the node at
  `pos` is the source and `d` points from the node receiving the signal
  towards it.  So a repeater whose output faces east is asked with `d = WEST`
  by the node east of it.
* **Ticks** are game ticks (20 per second).  A redstone tick is 2 game ticks.
* **Block ids**: Minecraft has one block with several states where Mineclonia
  has several node names (`repeater_on_1`, `repeater_off_locked`...).  The
  `block` field gives all of them one id (`"mcl_repeaters:repeater"`).
  Scheduled ticks, block events and "same block" checks use it.  It defaults
  to the node name.
* **Node metadata** plays the role of block entities: it is kept while a node
  changes to another state of the same block, and dropped when the block
  changes.
* Never modify a node table returned by `mcl_redstone.get_node`.

## Node definition field `_mcl_redstone`

All fields are optional.  `pos` is a position, `node` the node there.

```lua
_mcl_redstone = {
	block = "mod:block",              -- block id (see above)
	signal_source = true,             -- isSignalSource (or function(node))
	get_signal = function(pos, node, d) return 0 end,        -- getSignal (weak)
	get_direct_signal = function(pos, node, d) return 0 end, -- getDirectSignal (strong)
	own_signal = function(pos, node) return 0 end,           -- ownSignal
	conductor = nil,                  -- isRedstoneConductor override (or function(pos, node))
	wire_connects = function(pos, node, d) end, -- shouldRedstoneWireConnectTo; d may be nil
	is_diode = false,                 -- DiodeBlock.isDiode (+ facing(node))
	neighbor_changed = function(pos, node, from_block, moved_by_piston, from_pos) end,
	update_shape = function(pos, node, d, npos, nnode) end, -- return new node, {name="air"} to break, or nil
	update_indirect_neighbour_shapes = function(pos, node, flags, limit) end,
	on_place = function(pos, node, oldnode, moved_by_piston) end, -- onPlace: runs on EVERY state change
	affect_neighbors_after_removal = function(pos, oldnode, moved_by_piston) end, -- only when the block changes
	always_affect_after_removal = false, -- like BaseRailBlock: also on state changes
	tick = function(pos, node) end,   -- scheduled tick
	trigger_event = function(pos, node, b0, b1) end, -- block event
	analog_output = function(pos, node, d) return 0 end, -- getAnalogOutputSignal (presence = hasAnalogOutputSignal)
	has_analog_output = nil,          -- override (or function(node))
	push_reaction = "normal",         -- "normal", "destroy", "block", "push_only", "ignore" (or function(node))
	placement = function(pos, node, oldnode) end, -- getStateForPlacement: adjust a node another mod just placed
}
```

`neighbor_changed` is `Block.neighborChanged`.  It receives the node as it
was when the update was queued; check the current node if it matters (like
Minecraft blocks check `level.getBlockState(pos).is(this)`).

Nodes without `_mcl_redstone` still get updates: nodes in `attached_node`
drop when their support goes away, `falling_node` nodes start falling 2 ticks
after a shape update.

For `setPlacedBy`, use the node's `after_place_node`.

### Old style definitions

Definitions with `get_power`/`update`/`init`/`connects_to`/
`on_observer_neighbor_change` (the previous API) still work through a
compatibility layer: `update` runs on neighbour updates and its result is
applied `delay` redstone ticks later.  Do not use it for new code.

## The world

* `mcl_redstone.get_node(pos)` — cached `core.get_node` while redstone runs.
* `mcl_redstone.set_block(pos, node, flags [, limit])` — `Level.setBlock`.
  Flags: `UPDATE_NEIGHBORS` (1), `UPDATE_CLIENTS` (2), `UPDATE_KNOWN_SHAPE`
  (16, no shape updates), `UPDATE_SUPPRESS_DROPS` (32),
  `UPDATE_MOVE_BY_PISTON` (64), `UPDATE_SKIP_SHAPE_UPDATE_ON_WIRE` (128),
  `UPDATE_SKIP_ON_PLACE` (512); `UPDATE_ALL` = 3.  Like Minecraft, flag 2
  without 1 still sends shape updates.
* `mcl_redstone.node_changed(pos, oldnode, node [, flags])` — the updates of
  `set_block` for a change already made.
* `mcl_redstone.destroy_block(pos, drop [, limit])`, `remove_block(pos, moved)`,
  `drop_resources(pos, node)`.
* `mcl_redstone.update_neighbors_at(pos, block)`,
  `update_neighbors_at_except(pos, block, skip_d)`,
  `neighbor_changed(pos, block [, from_pos])`,
  `neighbor_changed_state(node, pos, block, moved [, from_pos])`,
  `update_neighbour_shapes(pos, node, flags)`,
  `neighbor_shape_changed(d, pos, npos, nnode, flags, limit)`,
  `update_neighbour_for_output_signal(pos, block)` (tells comparators),
  `update_from_neighbour_shapes(node, pos)`.
* Changes made with `core.set_node`, `core.swap_node`, `core.remove_node` and
  so on by any mod are reported by the engine (`core.register_on_node_change`)
  and get the updates of `set_block(pos, node, UPDATE_ALL)`.  Liquid flow is
  handled the same way.
* `mcl_redstone.block_id(name)`, `is_block(node, id)`, `same_node(a, b)`,
  `get_block(name)` (the behaviour table).

## Signals

`get_signal(pos, d)`, `has_signal(pos, d)`, `get_direct_signal(pos, d)`,
`get_direct_signal_to(pos)`, `has_neighbor_signal(pos)`,
`get_best_neighbor_signal(pos)`, `get_control_input_signal(pos, d, only_diodes)`,
`get_best_own_or_neighbour_signal(pos)`, `is_signal_source(node)`,
`has_analog_output(node)`, `get_analog_output(pos, node, d)`.

Shapes: `is_conductor(pos, node)`, `is_face_sturdy(pos, node, d [, "full" |
"center" | "rigid"])`, `can_support_rigid_block(pos, node)`,
`can_support_center(pos, node, d)`, `is_collision_full_block(pos, node)`.

## Time

* `mcl_redstone.schedule_tick(pos, block, delay [, priority])` —
  `Level.scheduleTick`; one pending tick per position and block.  Priorities:
  `PRIORITY_EXTREMELY_HIGH` (-3) ... `PRIORITY_NORMAL` (0) ...
  `PRIORITY_EXTREMELY_LOW` (3).
* `has_scheduled_tick(pos, block)`, `will_tick_this_tick(pos, block)`.
* `mcl_redstone.block_event(pos, block, b0, b1)` — `Level.blockEvent`.
* `mcl_redstone.add_ticker({pos = pos, tick = function(ticker) end})` — a block
  entity ticker; set `ticker.removed = true` to stop it.
* `mcl_redstone.after_ticks(delay, func)`; `register_on_game_tick(func(time))`;
  `get_game_time()`.
* `mcl_redstone.tick_step()` runs one game tick.  `tick_rate` (20) and
  `is_tick_frozen` are used by `/tick` (Minecraft's syntax).

Each game tick runs scheduled ticks, then block events, then tickers.

## Helpers

* `mcl_redstone.diode_behaviour(spec)` — `DiodeBlock` (see `diode.lua`).
* `mcl_redstone.java_hash_order(list)` — iteration order of a Java
  `HashSet<BlockPos>` filled with `list` (Minecraft's "locational" update
  order).
* `nearest_looking_direction(placer)`, `horizontal_looking_direction(placer)`.

## Older functions

`get_power(pos [, dir [, "direct"]])`, `swap_node(pos, node)` (=
`set_block(..., 3)`), `update_node(pos)`, `update_comparators(pos)`,
`_notify_observer_neighbours(pos)`, `after(redstone_ticks, func)`,
`get_current_tick()` (redstone ticks), `register_on_tick(func)`.
