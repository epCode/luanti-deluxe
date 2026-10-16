------------------------------------------------------------------------
-- Game events of entities and of the engine's callbacks. Other mods emit
-- theirs with mcl_gameevent.emit where Minecraft calls Level.gameEvent.
------------------------------------------------------------------------

local G = mcl_gameevent
local floor = math.floor
local sqrt = math.sqrt
local emit = G.emit

------------------------------------------------------------------------
-- Movement: Entity.applyMovementEmissionAndPlaySound (step, swim, flap),
-- Entity.checkFallDamage (hit_ground), Entity.doWaterSplashEffect (splash)
-- and LivingEntity.updateFallFlying (elytra_glide).
------------------------------------------------------------------------

local function node_def(name)
	return core.registered_nodes[name]
end

local function is_air(name)
	return name == "air" or name == "ignore" or (node_def(name) and node_def(name).drawtype == "airlike"
		and not node_def(name).walkable and not node_def(name).climbable)
end

local function is_climbable(name)
	local def = node_def(name)
	return def ~= nil and (def.climbable or name == "mcl_powder_snow:powder_snow")
end

local function is_water(name)
	return core.get_item_group(name, "water") > 0
end

-- A movement tracker per entity: create with G.new_movement_tracker() and
-- call G.track_movement once per server step (or per tick) with
--   pos: the entity's feet position
--   on_ground, in_water, swimming, crouching, passenger: booleans
--   supporting: name of the node the entity stands on (Entity.getOnPos),
--     or nil to look it up below the feet
--   next_step: function(move_dist) -> next step distance
--     (Entity.nextStep: floor(moveDist) + 1)
--   flapping: function(tracker) -> true when the entity flaps
--     (Entity.isFlapping), or nil
function G.new_movement_tracker()
	return {
		move_dist = 0,
		fly_dist = 0,
		next_step = 1,
		fall_distance = 0,
		was_in_water = nil,
	}
end

local function default_next_step(move_dist)
	return floor(move_dist) + 1
end

function G.track_movement(obj, t, s)
	local pos = s.pos
	local prev = t.prev_pos
	t.prev_pos = vector.copy(pos)
	if not prev then
		t.was_in_water = s.in_water
		return
	end
	local dx, dy, dz = pos.x - prev.x, pos.y - prev.y, pos.z - prev.z
	-- Teleports are not movement
	if dx * dx + dy * dy + dz * dz > 100 then
		t.fall_distance = 0
		t.was_in_water = s.in_water
		return
	end

	-- Entity.updateInWaterStateAndDoWaterCurrentPushing: entering water
	if s.in_water and t.was_in_water == false and not s.passenger then
		emit("splash", pos, {source = obj})
	end
	t.was_in_water = s.in_water

	-- Entity.checkFallDamage: falling and landing
	if s.on_ground then
		if t.fall_distance > 0 then
			local below = s.supporting or core.get_node(vector.new(pos.x, pos.y - 0.2, pos.z)).name
			emit("hit_ground", pos, {source = obj, node = {name = below}})
		end
		t.fall_distance = 0
	elseif s.in_water or s.climbing then
		t.fall_distance = 0
	elseif dy < 0 then
		t.fall_distance = t.fall_distance - dy
	end

	if s.passenger then
		return
	end
	-- Entity.getOnPos: the node just below the feet
	local supporting = s.supporting
		or core.get_node(vector.new(pos.x, pos.y - 1.0E-5, pos.z)).name
	local horizontal = sqrt(dx * dx + dz * dz) * 0.6
	local moved = sqrt(dx * dx + dy * dy + dz * dz) * 0.6
	local climbing = is_climbable(supporting)
	t.move_dist = t.move_dist + (climbing and moved or horizontal)
	t.fly_dist = t.fly_dist + moved
	if t.move_dist > t.next_step and not is_air(supporting) then
		local produced = false
		-- vibrationAndSoundEffectsFromBlock
		if (s.on_ground or climbing or (s.crouching and dy == 0)) and not s.swimming then
			emit("step", pos, {source = obj, node = {name = supporting}})
			produced = true
		end
		if produced or s.in_water then
			t.next_step = (s.next_step or default_next_step)(t.move_dist)
			if not produced then
				emit("swim", pos, {source = obj})
			end
		end
	elseif is_air(supporting) and s.flapping and s.flapping(t) then
		emit("flap", pos, {source = obj})
	end
end

-- Players ----------------------------------------------------------------

local trackers = {}

local function player_on_ground(player, pos)
	local vel = player:get_velocity()
	if math.abs(vel.y) > 0.01 then
		return false
	end
	local box = player:get_properties().collisionbox
	local w = math.min(math.abs(box[1]), math.abs(box[4])) - 0.01
	for _, o in ipairs({{0, 0}, {-w, -w}, {-w, w}, {w, -w}, {w, w}}) do
		local p = vector.new(pos.x + o[1], pos.y - 0.05, pos.z + o[2])
		local np = vector.round(p)
		local node = core.get_node(np)
		local def = node_def(node.name)
		if def and def.walkable then
			local boxes = core.get_node_boxes("collision_box", np, node)
			for _, b in ipairs(boxes) do
				local top = np.y + b[5]
				if pos.y - top >= -0.05 and pos.y - top <= 0.06 then
					return true, node.name
				end
			end
		end
	end
	return false
end

local function player_state(player)
	local pos = player:get_pos()
	local on_ground, standing = player_on_ground(player, pos)
	local feet = core.get_node(vector.round(vector.offset(pos, 0, 0.1, 0))).name
	local body = core.get_node(vector.round(vector.offset(pos, 0, 0.8, 0))).name
	local in_water = is_water(feet) or is_water(body)
	local ctrl = player:get_player_control()
	local pdata = mcl_player and mcl_player.players and mcl_player.players[player]
	local swimming = in_water and is_water(body) and ctrl.aux1
	return {
		pos = pos,
		on_ground = on_ground,
		in_water = in_water,
		swimming = swimming,
		climbing = is_climbable(feet),
		crouching = ctrl.sneak,
		passenger = player:get_attach() ~= nil,
		supporting = standing,
		elytra = pdata and pdata.elytra and pdata.elytra.active,
	}
end

core.register_on_joinplayer(function(player)
	trackers[player:get_player_name()] = G.new_movement_tracker()
end)

core.register_on_leaveplayer(function(player)
	trackers[player:get_player_name()] = nil
end)

local tick_time = 0
core.register_globalstep(function(dtime)
	tick_time = tick_time + dtime
	if tick_time < 0.05 then
		return
	end
	tick_time = 0
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local t = trackers[name]
		if t and player:get_hp() > 0 and not G.is_spectator(player) then
			local s = player_state(player)
			G.track_movement(player, t, s)
			-- LivingEntity.updateFallFlying: every 10 ticks of gliding
			if s.elytra then
				t.fall_fly_ticks = (t.fall_fly_ticks or 0) + 1
				if t.fall_fly_ticks % 10 == 0 then
					emit("elytra_glide", s.pos, {source = player})
				end
			else
				t.fall_fly_ticks = 0
			end
		end
	end
end)

------------------------------------------------------------------------
-- Blocks placed and dug by players (BlockItem.place,
-- Block.playerWillDestroy).
------------------------------------------------------------------------

core.register_on_placenode(function(pos, newnode, placer)
	emit("block_place", pos, {source = placer, node = newnode})
end)

core.register_on_dignode(function(pos, oldnode, digger)
	emit("block_destroy", pos, {source = digger, node = oldnode})
end)

------------------------------------------------------------------------
-- Damage and death (LivingEntity.hurtServer / die): the source of the
-- event is the entity that was hurt or died.
------------------------------------------------------------------------

-- No mod dependencies (any mod may depend on this one): hooked up later
core.register_on_mods_loaded(function()
	if mcl_damage then
		mcl_damage.register_on_damage(function(obj, damage)
			if damage > 0 and G.is_valid(obj) then
				emit("entity_damage", obj:get_pos(), {source = obj})
			end
		end)
	end
end)

-- LivingEntity.die: the game event of a death. `experience` is what the
-- entity would drop (LivingEntity.getExperienceReward; 0 for babies,
-- whose shouldDropExperience is false). Listeners (sculk catalysts) may
-- consume it: returns true if they did, and then the caller must not drop
-- the experience (LivingEntity.skipDropExperience).
function G.entity_died(obj, experience)
	if not G.is_valid(obj) then
		return false
	end
	local ctx = {source = obj, experience = experience or 0, experience_consumed = false}
	emit("entity_die", obj:get_pos(), ctx)
	return ctx.experience_consumed
end
