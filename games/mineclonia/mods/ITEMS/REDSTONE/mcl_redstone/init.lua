mcl_redstone = {}

local modpath = core.get_modpath(core.get_current_modname())
dofile(modpath .. "/util.lua")
dofile(modpath .. "/shapes.lua")
dofile(modpath .. "/ticks.lua")
dofile(modpath .. "/level.lua")
dofile(modpath .. "/diode.lua")
dofile(modpath .. "/compat.lua")
dofile(modpath .. "/wire.lua")
dofile(modpath .. "/animate.lua")

local blocks = mcl_redstone._blocks

-- Fields that mark a `_mcl_redstone` table in the current format.
local NEW_FIELDS = {
	"block", "signal_source", "get_signal", "get_direct_signal", "neighbor_changed",
	"update_shape", "tick", "on_place", "affect_neighbors_after_removal",
	"trigger_event", "analog_output", "wire_connects", "conductor", "push_reaction",
	"placement", "is_diode", "own_signal", "update_indirect_neighbour_shapes",
	"has_analog_output", "animate",
}

local function is_new_format(rs)
	for _, f in ipairs(NEW_FIELDS) do
		if rs[f] ~= nil then
			return true
		end
	end
	return false
end

-- Nodes popping off without support (attached_node) or falling (falling_node)
-- react to shape updates, like their Minecraft counterparts.
local function generic_behaviour(name, def, b)
	local groups = def.groups or {}
	local attached = (groups.attached_node or 0) ~= 0
	local falling = (groups.falling_node or 0) ~= 0
	if b.update_shape or not (attached or falling) then
		return
	end
	b.update_shape = function(pos, node)
		if attached then
			core.check_single_for_falling(pos)
		elseif falling and not mcl_redstone.has_scheduled_tick(pos, name) then
			mcl_redstone.schedule_tick(pos, name, 2)
		end
	end
	if falling and not b.tick then
		b.tick = function(pos)
			core.check_single_for_falling(pos)
		end
	end
end

core.register_on_mods_loaded(function()
	for name, def in pairs(core.registered_nodes) do
		local rs = def._mcl_redstone
		local b
		if rs and is_new_format(rs) then
			b = table.copy(rs)
		elseif rs then
			b = mcl_redstone._compat_behaviour(name, rs)
		else
			b = {}
		end
		b.block = b.block or name
		generic_behaviour(name, def, b)
		blocks[name] = b
	end
end)
