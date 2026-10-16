------------------------------------------------------------------------
-- Block.stepOn (Entity.applyEffectsFromBlocks): every game tick, an
-- entity on the ground steps on the block at getOnPosLegacy (0.2 below its
-- feet). Nodes define _mcl_sculk_step_on(pos, node, object).
------------------------------------------------------------------------

local function on_ground(obj, pos, node_pos, node)
	local vel = obj:get_velocity()
	if not vel or math.abs(vel.y) > 0.01 then
		return false
	end
	local boxes = core.get_node_boxes("collision_box", node_pos, node)
	for _, b in ipairs(boxes) do
		local top = node_pos.y + b[5]
		if pos.y - top >= -0.05 and pos.y - top <= 0.06 then
			return true
		end
	end
	return false
end

local function step(obj)
	local pos = obj:get_pos()
	if not pos then
		return
	end
	local np = vector.round(vector.new(pos.x, pos.y - 0.2, pos.z))
	local node = core.get_node(np)
	local def = core.registered_nodes[node.name]
	if def and def._mcl_sculk_step_on and on_ground(obj, pos, np, node) then
		def._mcl_sculk_step_on(np, node, obj)
	end
end

mcl_redstone.register_on_game_tick(function()
	for _, player in ipairs(core.get_connected_players()) do
		if player:get_hp() > 0 and not mcl_gameevent.is_spectator(player) then
			step(player)
		end
	end
	for _, le in pairs(core.luaentities) do
		if le.is_mob or le.name == "__builtin:item" then
			step(le.object)
		end
	end
end)
