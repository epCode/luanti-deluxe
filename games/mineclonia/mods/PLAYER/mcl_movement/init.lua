-- Minecraft-accurate player movement on top of the engine's player physics.
--
-- Luanti moves the local player towards a target speed at a constant
-- acceleration, whereas Minecraft (20 ticks/s) adds a small acceleration every
-- tick and then multiplies the velocity by a drag factor.  The global
-- `movement_*' settings in this game's minetest.conf are fitted so that the
-- steady state values (walking, sprinting and sneaking speed, jump height and
-- duration) match.  This mod complements them at runtime with physics
-- overrides and velocity impulses for everything that the settings alone can
-- not express:
--
--   * exponential air control and momentum (air drag 0.91/tick),
--   * the sprint-jump boost and loss of speed on take-off,
--   * air drag on long falls (terminal velocity 78.4 m/s),
--   * fall damage computed from fall distance,
--   * water, lava, cobwebs, berry bushes and powder snow,
--   * ice, blue ice, slime, soul sand and honey blocks,
--   * climbing, creative flight, Depth Strider, Soul Speed, Dolphin's Grace
--     and Slow Falling,
--   * Minecraft's sprinting rules.
--
-- All constants are in nodes, seconds, nodes/s and nodes/s².  Minecraft values
-- in blocks/tick were multiplied by 20 (and by 400 for accelerations).

mcl_movement = {}

local TICK = 0.05
local K_AIR = -20 * math.log (0.91) -- Rate at which air drag acts (1/s).
local GRAVITY = 32.0
local TERMINAL_VELOCITY = 78.4
local DRAG_SPEED = 9.0 -- Vertical speed above which air drag is emulated.
local JUMP_SPEED = 8.98
local WALK_SPEED = 4.317
local FLY_SPEED = 21.78 -- 2x Minecraft (10.89)
local FLY_SPRINT_SPEED = 43.56 -- 2x Minecraft (21.78)
local FLY_VERTICAL_SPEED = 15.0 -- 2x Minecraft (7.5)
local CLIMB_SPEED = 2.352
local SAFE_FALL_DISTANCE = 3.0
-- Drag rate (1/s) used in water while swimming (see the liquid section).
local SWIM_DRAG_RATE = 3.0
-- Typical length of the engine's physics substeps at 60 FPS (s).
local ENGINE_SUBSTEP = 1 / 120
local SNEAK_FACTOR = 0.3
-- Acceleration the engine applies on ground (nodes/s²) while walking.
local GROUND_ACCELERATION = 36.4
-- Ground acceleration on ice, fitted to Minecraft's start-up and stopping
-- distances on ice (friction 0.98) and blue ice (0.989).
local ICE_ACCELERATION = 5.05
local BLUE_ICE_ACCELERATION = 4.86

local function setting (name, default)
	return tonumber (core.settings:get (name)) or default
end

-- The engine scales these settings by BS (and gravity by 2 more); express them
-- in nodes/s and nodes/s² here.
local S_ACC_DEFAULT = setting ("movement_acceleration_default", 3.64) * 10
local S_ACC_AIR = setting ("movement_acceleration_air", 1.0) * 10
local S_ACC_FAST = setting ("movement_acceleration_fast", 3.64) * 10
local S_WALK = setting ("movement_speed_walk", WALK_SPEED)
local S_FAST = setting ("movement_speed_fast", WALK_SPEED)
local S_CLIMB = setting ("movement_speed_climb", CLIMB_SPEED)
local S_JUMP = setting ("movement_speed_jump", JUMP_SPEED)
local S_GRAVITY = setting ("movement_gravity", 10.4) * 2
local S_FLUIDITY = setting ("movement_liquid_fluidity", 2.24)
local S_SINK = setting ("movement_liquid_sink", 1.12) * 2

-- `movement_gravity' is shared with dropped items, XP orbs and the like, so
-- players receive the difference as a permanent gravity factor.
local BASE_GRAVITY_FACTOR = GRAVITY / S_GRAVITY
local BASE_JUMP_FACTOR = JUMP_SPEED / S_JUMP

local STATE_ID = "mcl_movement:state"
local BLOCK_ID = "mcl_movement:block"

-- The engine reports fly mode (`flying' in the player controls) and flies at
-- absolute speeds (physics overrides `speed_fly' and `speed_fly_vertical').
local ENGINE_FLIGHT = core.features.speed_fly

-- Speed factors that represent using an item (Minecraft multiplies the
-- movement input by 0.2 while an item is in use).
local ITEM_USE_FACTORS = {
	"mcl_hunger:eat_anim",
	"mcl_bows:use_bow",
	"mcl_bows:use_crossbow",
	"shield_speed",
}

------------------------------------------------------------------------
-- Node classification.
------------------------------------------------------------------------

-- Movement-arresting blocks.  `speed' is the horizontal walking speed inside
-- and `fall' the speed at which a player sinks through the block in
-- Minecraft; the engine's own drag (from `move_resistance') is corrected to
-- produce these values.
local STUCK_NODES = {
	["mcl_core:cobweb"] = { fall = 0.078, },
	["mcl_powder_snow:powder_snow"] = { fall = 2.35, },
}
for i = 0, 3 do
	STUCK_NODES["mcl_farming:sweet_berry_bush_" .. i] = { fall = 1.18, }
end

local function node_def (pos)
	local node = core.get_node_or_nil (pos)
	if not node then
		return nil, nil
	end
	return node, core.registered_nodes[node.name]
end

local function is_walkable (pos)
	local node, def = node_def (pos)
	if not node then
		-- Unloaded terrain collides with players.
		return true
	end
	return not def or def.walkable ~= false
end

local CORNERS = {
	{ 0, 0 }, { -0.3, -0.3 }, { -0.3, 0.3 }, { 0.3, -0.3 }, { 0.3, 0.3 },
}

-- Return the position of the walkable node that supports a player at POS, if
-- any.
local function supporting_node (pos)
	local p = vector.new (0, pos.y - 0.08, 0)
	for _, c in ipairs (CORNERS) do
		p.x = pos.x + c[1]
		p.z = pos.z + c[2]
		if is_walkable (p) then
			return vector.round (p)
		end
	end
	return nil
end

-- Minecraft block friction ("slipperiness") of the node at POS.
local function block_friction (name)
	if not name then
		return 0.6
	end
	local slippery = core.get_item_group (name, "slippery")
	if slippery >= 4 then
		return 0.989
	elseif slippery > 0 then
		return 0.98
	elseif name == "mcl_core:slimeblock" then
		return 0.8
	end
	return 0.6
end

local function liquid_kind (pos)
	local node, def = node_def (pos)
	-- Waterlogged blocks hold a water source (_liquidtype)
	local liquidtype = def and (def._liquidtype or def.liquidtype)
	if not node or not def or not liquidtype or liquidtype == "none"
		or def.liquid_move_physics == false then
		return nil
	end
	if core.get_item_group (node.name, "lava") > 0 then
		return "lava", node
	end
	return "water", node
end

local function is_climbable (pos)
	local _, def = node_def (pos)
	return def and def.climbable
end

------------------------------------------------------------------------
-- Minecraft formulas.
------------------------------------------------------------------------

-- Apex of a Minecraft jump with an initial velocity of V blocks/tick.
local function mc_jump_apex (v)
	local y, apex = 0, 0
	for _ = 1, 100 do
		y = y + v
		if y < apex then
			break
		end
		apex = y
		v = (v - 0.08) * 0.98
	end
	return apex
end

local BASE_APEX = mc_jump_apex (0.42)

-- Factor by which the engine's jump speed must be multiplied to reach the
-- height of a Minecraft jump of strength POWER (0.42 being a normal jump).
function mcl_movement.jump_factor (power)
	if power <= 0 then
		return 0
	end
	return math.sqrt (mc_jump_apex (power) / BASE_APEX)
end

-- Jump factor of the Jump Boost effect at LEVEL.
function mcl_movement.jump_boost_factor (level)
	return mcl_movement.jump_factor (0.42 + 0.1 * level)
end

local HONEY_JUMP_FACTOR = mcl_movement.jump_factor (0.21)
-- Steady walking speed on blocks with a speed factor of 0.4 (soul sand,
-- honey) relative to normal ground.
local SLOW_BLOCK_FACTOR = 2.508 / WALK_SPEED
local SLIME_FACTOR = 1.17 / WALK_SPEED
local ICE_SPEED_FACTOR = 4.157 / WALK_SPEED
local BLUE_ICE_SPEED_FACTOR = 4.376 / WALK_SPEED

------------------------------------------------------------------------
-- Player state.
------------------------------------------------------------------------

local states = {}

local function new_state ()
	return {
		applied = {},
		fall_distance = 0,
		flying = false,
		sprinting = false,
		sprint_t = 0,
		up_press_t = -1,
		prev_up = false,
		stalled = 0,
		grav_like = 0,
		const_vy = 0,
		last_air_t = -1,
		fly_check_t = -1,
		has_fly = false,
	}
end

function mcl_movement.get_fall_distance (player)
	local st = states[player]
	return st and st.fall_distance or 0
end

function mcl_movement.reset_fall_distance (player)
	local st = states[player]
	if st then
		st.fall_distance = 0
		st.last_y = nil
	end
end

function mcl_movement.is_flying (player)
	if ENGINE_FLIGHT then
		return player:get_player_control ().flying and not player:get_attach ()
			and player:get_hp () > 0
	end
	local st = states[player]
	return st and st.flying or false
end

-- Apply a physics factor, skipping redundant updates.
local function apply (player, st, attr, value, id)
	id = id or STATE_ID
	local key = id .. attr
	local old = st.applied[key]
	if old then
		if old == value then
			return
		end
		local diff = math.abs (old - value)
		if diff < 0.02 * math.max (math.abs (old), math.abs (value))
			and value ~= 0 and old ~= 0 then
			return
		end
	end
	st.applied[key] = value
	if value == 1 then
		playerphysics.remove_physics_factor (player, attr, id)
	else
		playerphysics.add_physics_factor (player, attr, id, value)
	end
end

local ALL_ATTRS = {
	"acceleration_default", "acceleration_air", "acceleration_fast",
	"speed_walk", "speed_fast", "speed_climb", "gravity", "jump",
	"liquid_fluidity", "liquid_sink",
}

local function reset_factors (player, st)
	for _, attr in ipairs (ALL_ATTRS) do
		playerphysics.remove_physics_factor (player, attr, STATE_ID)
	end
	playerphysics.remove_physics_factor (player, "speed", BLOCK_ID)
	st.applied = {}
end

local function physics_data (player)
	if playerphysics.get_physics_data then
		return playerphysics.get_physics_data (player)
	end
	return core.deserialize (player:get_meta ():get_string ("playerphysics:physics"))
end

-- Product of all factors of ATTR except the one with id EXCLUDE.
local function physics_product (player, attr, exclude)
	local a = physics_data (player)
	local product = 1
	if a and type (a[attr]) == "table" then
		for id, factor in pairs (a[attr]) do
			if id ~= exclude then
				product = product * factor
			end
		end
	end
	return product
end

-- Whether PLAYER is swimming (sprinting in water, in the swimming pose).
-- mcl_player tracks the pose; fall back to sprinting with the eyes in water.
local function is_swimming (player, st, env)
	local tbl = mcl_player.players[player]
	if mcl_player.is_swimming_pose and tbl then
		return tbl.swimming and true or false
	end
	return st.sprinting and env.liquid == "water" and env.submerged
end

------------------------------------------------------------------------
-- Sprinting (Minecraft rules).
------------------------------------------------------------------------

local function using_item (player)
	for _, id in ipairs (ITEM_USE_FACTORS) do
		if playerphysics.get_physics_factor (player, "speed", id) then
			return true
		end
	end
	return false
end

-- Factor by which crouching scales the movement input (0.3, more with Swift
-- Sneak; 1 when not crouching).  mcl_player knows about forced crouching under
-- low ceilings.
local function crouch_factor (player, ctrl)
	if mcl_player.get_crouch_factor then
		return mcl_player.get_crouch_factor (player)
	end
	return ctrl.sneak and SNEAK_FACTOR or 1
end

local function has_effect (player, name)
	return mcl_potions and mcl_potions.has_effect (player, name)
end

local function enough_food (player, name, st)
	if st.flying or core.is_creative_enabled (name) then
		return true
	end
	if not mcl_hunger or not mcl_hunger.active then
		return true
	end
	return mcl_hunger.get_hunger (player) > 6
end

local function update_sprinting (player, name, st, env, ctrl, now, fresh, vel)
	local forward = ctrl.up or (ctrl.movement_y or 0) > 0.1
	local sleeping = player:get_meta ():get_string ("mcl_beds:sleeping") == "true"

	-- Flight has one speed; flying players do not sprint.
	if st.flying then
		st.sprinting = false
		st.up_press_t = -1
		st.prev_up = ctrl.up
		st.stalled = 0
		mcl_sprint.set_sprinting (name, false)
		return
	end

	-- Double-tapping forward starts sprinting (7 ticks, as in Minecraft).
	local doubletap = false
	if ctrl.sneak then
		st.up_press_t = -1
	elseif ctrl.up and not st.prev_up then
		doubletap = st.up_press_t >= 0 and now - st.up_press_t <= 0.35
		st.up_press_t = now
	end
	st.prev_up = ctrl.up

	-- Running into a wall stops sprinting.
	local hit_wall = false
	if st.sprinting and fresh and env.grounded and forward
		and now - st.sprint_t > 0.25 then
		local h = math.sqrt (vel.x * vel.x + vel.z * vel.z)
		if h < 1.0 then
			st.stalled = st.stalled + 1
		else
			st.stalled = 0
		end
		hit_wall = st.stalled >= 2
	elseif not st.sprinting then
		st.stalled = 0
	end

	local surface_water = env.liquid == "water" and not env.submerged
	local swimming = st.sprinting and is_swimming (player, st, env)
	if st.sprinting and swimming then
		-- Swimming players keep sprinting at the surface and against
		-- walls; only leaving the water, or letting go of forward (or
		-- starving) while off the ground and not sneaking stops it.
		local tbl = mcl_player.players[player]
		local in_water = (tbl and tbl.in_water) or env.liquid == "water"
		if not in_water or sleeping
			or (not env.support and not ctrl.sneak
			    and (not forward or not enough_food (player, name, st))) then
			st.sprinting = false
		end
	elseif st.sprinting then
		if not forward or hit_wall or sleeping or surface_water
			or not enough_food (player, name, st)
			or has_effect (player, "blindness") then
			st.sprinting = false
		end
	elseif (ctrl.aux1 or doubletap) and forward and not sleeping
		and not surface_water
		and (crouch_factor (player, ctrl) >= 1 or env.submerged)
		and not using_item (player)
		and not has_effect (player, "blindness")
		and enough_food (player, name, st) then
		st.sprinting = true
		st.sprint_t = now
		st.stalled = 0
	end
	mcl_sprint.set_sprinting (name, st.sprinting)
end

------------------------------------------------------------------------
-- Fall damage.
------------------------------------------------------------------------

local function fall_damage_multiplier (node_name)
	if not node_name then
		return 1
	end
	if node_name == "mcl_core:slimeblock" then
		-- Slime blocks cancel fall damage, even for sneaking players
		-- (who do not bounce).
		return 0
	end
	local percent = core.get_item_group (node_name, "fall_damage_add_percent")
	return math.max (0, 1 + percent / 100)
end

local function land (player, name, st, node_name)
	local distance = st.fall_distance
	st.fall_distance = 0
	if distance <= SAFE_FALL_DISTANCE
		or core.is_creative_enabled (name)
		or player:get_hp () <= 0 then
		return
	end
	local multiplier = fall_damage_multiplier (node_name)
	local damage = math.floor ((distance + 1e-6 - SAFE_FALL_DISTANCE) * multiplier)
	if damage > 0 then
		mcl_damage.damage_player (player, damage, { type = "fall", })
	end
end

------------------------------------------------------------------------
-- Environment sensing.
------------------------------------------------------------------------

local function sense (player, pos, vel, st)
	local env = {}
	local liquid, liquid_node = liquid_kind (vector.offset (pos, 0, 0.3, 0))
	env.liquid = liquid
	env.liquid_node = liquid_node
	env.liquid_pos = vector.round (vector.offset (pos, 0, 0.3, 0))
	env.submerged = liquid_kind (vector.offset (pos, 0, player:get_properties ().eye_height or 1.62, 0)) ~= nil
	env.climbing = not st.flying and (is_climbable (vector.offset (pos, 0, 0.5, 0))
					   or is_climbable (vector.offset (pos, 0, -0.2, 0)))
	local stuck
	for _, dy in ipairs ({ 0.1, 1.0 }) do
		local node = core.get_node_or_nil (vector.offset (pos, 0, dy, 0))
		if node and STUCK_NODES[node.name] then
			stuck = STUCK_NODES[node.name]
			break
		end
	end
	env.stuck = stuck
	local support = supporting_node (pos)
	env.support = support
	env.standon = support and core.get_node (support).name or nil
	env.grounded = vel.y == 0 and support ~= nil and not liquid
	return env
end

local function input_vector (player, ctrl)
	local mx = ctrl.movement_x
	local my = ctrl.movement_y
	if not mx or not my then
		mx = (ctrl.right and 1 or 0) - (ctrl.left and 1 or 0)
		my = (ctrl.up and 1 or 0) - (ctrl.down and 1 or 0)
	end
	local len = math.sqrt (mx * mx + my * my)
	if len > 1 then
		mx, my = mx / len, my / len
		len = 1
	end
	local yaw = player:get_look_horizontal ()
	local s, c = math.sin (yaw), math.cos (yaw)
	-- Forward is (-sin, cos); right is (cos, sin).
	return -s * my + c * mx, c * my + s * mx, len
end

------------------------------------------------------------------------
-- Take-off: sprint-jump boost and loss of speed to ground friction.
------------------------------------------------------------------------

-- When a Minecraft player leaves the ground, the velocity carried into the
-- air is the ground velocity after one more application of ground friction,
-- plus 0.2 blocks/tick in the facing direction if sprint-jumping.  The engine
-- keeps the ground speed instead, so the difference is applied as an impulse
-- once the server sees the player take off.
local AIR_TIME_CONSTANT = (1 - 0.91 ^ 10) / K_AIR
local IMPULSE_LATENCY = 0.02

local function take_off (player, st, vel, ix, iz, ctrl, jumped, tsince,
			 speed_attr, now)
	local fr = block_friction (st.prev_standon)
	local fg = fr * 0.91
	local recently_air = now - st.last_air_t < 0.16
	local carry = recently_air and 0.91 or fg
	local use = using_item (player) and 0.2 or 1
	local scale = crouch_factor (player, ctrl) * use
	local a_ground = 1.96 * speed_attr * 0.216 / (fr * fr * fr) * scale
	local a_air = (st.sprinting and 0.52 or 0.392) * scale
	local boost = (jumped and st.sprinting) and 4.0 or 0
	local yaw = player:get_look_horizontal ()
	local fx, fz = -math.sin (yaw), math.cos (yaw)

	local jx = vel.x * carry + boost * fx + a_ground * ix
	local jz = vel.z * carry + boost * fz + a_ground * iz
	local v1x = jx * fg + a_air * ix
	local v1z = jz * fg + a_air * iz
	local tx = a_air * ix / (1 - 0.91)
	local tz = a_air * iz / (1 - 0.91)
	local ticks = math.max (0, (tsince + IMPULSE_LATENCY) / TICK - 1)
	local decay = 0.91 ^ ticks
	local mx = tx + (v1x - tx) * decay
	local mz = tz + (v1z - tz) * decay
	-- Compensate for the extra distance covered during the take-off tick.
	local k = TICK / AIR_TIME_CONSTANT
	local ex = (0.2 * (jx - vel.x - boost * fx) + 0.9 * boost * fx) * k
	local ez = (0.2 * (jz - vel.z - boost * fz) + 0.9 * boost * fz) * k
	local dx = mx - vel.x + ex
	local dz = mz - vel.z + ez
	if dx * dx + dz * dz > 1e-4 then
		player:add_velocity (vector.new (dx, 0, dz))
	end
end

------------------------------------------------------------------------
-- Head hitters.
------------------------------------------------------------------------

-- Sprint-jumping under a low ceiling cuts every jump short.  Minecraft adds
-- the sprint-jump boost on each take-off, so re-pressing jump on every
-- landing makes the player much faster (9.7 nodes/s under a 2 node ceiling);
-- holding jump instead re-jumps only every 10 ticks.  The engine's own jumps
-- under a ceiling are too short for the server to see, so while a player is
-- in this situation the average Minecraft speed is simulated here and
-- applied as the target speed.

-- Lowest point of the collision box of the node named NAME, relative to
-- the node's centre.
local function node_bottom (name)
	local def = core.registered_nodes[name]
	local box = def and (def.collision_box or (def.drawtype == "nodebox" and def.node_box))
	if not box or box.type ~= "fixed" or type (box.fixed) ~= "table" then
		return -0.5
	end
	local boxes = type (box.fixed[1]) == "table" and box.fixed or { box.fixed }
	local bottom = 0.5
	for _, b in ipairs (boxes) do
		bottom = math.min (bottom, b[2])
	end
	return bottom
end

-- Distance between the top of a player of HEIGHT at POS and the ceiling
-- above, if it is close enough to cut a jump (1.25 nodes) short.
local function head_clearance (pos, height)
	local top = pos.y + height
	local best
	local p = vector.new (0, 0, 0)
	for _, c in ipairs (CORNERS) do
		p.x = pos.x + c[1]
		p.z = pos.z + c[2]
		for ny = math.floor (top + 0.5), math.floor (top + 1.25 + 0.5) do
			p.y = ny
			local node = core.get_node_or_nil (p)
			if node then
				local def = core.registered_nodes[node.name]
				if def and def.walkable ~= false then
					local bottom = ny + node_bottom (node.name)
					if bottom >= top - 0.01 then
						local clearance = bottom - top
						if not best or clearance < best then
							best = clearance
						end
					end
					break
				end
			end
		end
	end
	if best and best < 1.25 then
		return math.max (0, best)
	end
	return nil
end

local hh_cache = {}

-- Average horizontal speed (nodes/s) of a Minecraft player moving forwards
-- and jumping under a ceiling CLEARANCE above its head.  SPEED_ATTR is the
-- movement speed relative to walking (1.3 when sprinting), FR the
-- friction of the floor; SPAM tells whether jump is pressed anew on each
-- landing rather than held.
local function headhitter_speed (clearance, spam, sprinting, speed_attr, fr)
	clearance = math.floor (clearance * 20 + 0.5) / 20
	speed_attr = math.floor (speed_attr * 200 + 0.5) / 200
	local key = table.concat ({ clearance, tostring (spam), tostring (sprinting),
				    speed_attr, fr }, ":")
	local cached = hh_cache[key]
	if cached then
		return cached
	end
	local x, y, vx, vy = 0, 0, 0, 0
	local on_ground, no_jump_delay = true, 0
	local x0
	for n = 1, 400 do
		if no_jump_delay > 0 then
			no_jump_delay = no_jump_delay - 1
		end
		if math.abs (vx) < 0.003 then vx = 0 end
		if math.abs (vy) < 0.003 then vy = 0 end
		if on_ground and (spam or no_jump_delay == 0) then
			vy = 0.42
			if sprinting then
				vx = vx + 0.2
			end
			no_jump_delay = 10
		end
		local p = on_ground and fr or 1.0
		local a = on_ground and 0.1 * speed_attr * 0.216 / (p * p * p)
			or (sprinting and 0.026 or 0.02)
		vx = vx + 0.98 * a
		x = x + vx
		local ny = y + vy
		local hit_ceiling = false
		if ny > clearance then
			ny = clearance
			hit_ceiling = true
		end
		if ny <= 0 then
			ny, vy, on_ground = 0, 0, true
		else
			on_ground = false
			if hit_ceiling then
				vy = 0
			end
		end
		y = ny
		vy = (vy - 0.08) * 0.98
		vx = vx * p * 0.91
		if n == 100 then
			x0 = x
		end
	end
	local v = (x - x0) / (300 * TICK)
	hh_cache[key] = v
	return v
end

------------------------------------------------------------------------
-- Main controller.
------------------------------------------------------------------------

local function step_player (player, st)
	local name = player:get_player_name ()
	local now = core.get_us_time () / 1e6
	local pos = player:get_pos ()
	local vel = player:get_velocity ()
	local ctrl = player:get_player_control ()

	local spectator = mcl_gamemode and mcl_gamemode.get_gamemode
		and mcl_gamemode.get_gamemode (player) == "spectator"
	if player:get_attach () or player:get_hp () <= 0 or spectator then
		st.fall_distance = 0
		st.last_y = nil
		st.flying = false
		st.prev_pos = nil
		st.prev_vel = nil
		st.prev_t = nil
		st.prev_grounded = nil
		if st.sprinting and player:get_attach () then
			st.sprinting = false
			mcl_sprint.set_sprinting (name, false)
		end
		return
	end

	-- The server sees the client's position at most once per send interval;
	-- ignore steps on which nothing new arrived.
	local fresh = not (st.prev_pos and st.prev_vel
			   and vector.equals (pos, st.prev_pos)
			   and vector.equals (vel, st.prev_vel))
		or (vel.x == 0 and vel.y == 0 and vel.z == 0)
	if not fresh then
		return
	end
	local prev_vel = st.prev_vel or vel
	local dt = now - (st.prev_t or now)

	-- Flight privilege (refreshed once per second).
	if now - st.fly_check_t > 1 then
		st.fly_check_t = now
		st.has_fly = core.check_player_privs (name, "fly")
	end

	if ENGINE_FLIGHT then
		st.flying = ctrl.flying and st.has_fly or false
	end
	local env = sense (player, pos, vel, st)
	local ix, iz, ilen = input_vector (player, ctrl)
	local slow_falling = has_effect (player, "slow_falling")
	local levitating = has_effect (player, "levitation")

	-- Older engines do not report creative flight, but a flying player is
	-- not subject to gravity: its vertical speed is constant while
	-- airborne, whereas gravity changes it by at least 1.6 nodes/s between
	-- two packets.
	if ENGINE_FLIGHT then
		-- Reported by the client (see above).
	elseif not st.has_fly or env.liquid or env.climbing then
		st.flying = false
	elseif fresh and st.prev_vel then
		local dvy = vel.y - prev_vel.y
		if env.grounded or (vel.y == 0 and env.support) then
			st.flying = false
			st.const_vy = 0
		elseif not st.flying then
			if math.abs (dvy) < 0.05 and math.abs (vel.y) < 25
				and not env.stuck and not slow_falling
				and not levitating then
				st.const_vy = st.const_vy + 1
				if st.const_vy >= 2 then
					st.flying = true
				end
			else
				st.const_vy = 0
			end
		else
			-- Falling under gravity again?
			local rate = dt > 0 and dvy / dt or 0
			-- (Descending in flight accelerates at 60 nodes/s², well
			-- outside this window, even with the sneak key held.)
			if vel.y < -1
				and rate < -0.5 * GRAVITY and rate > -1.3 * GRAVITY then
				st.grav_like = st.grav_like + 1
			else
				st.grav_like = 0
			end
			if st.grav_like >= 3 or vel.y < -(FLY_SPRINT_SPEED + 5) then
				st.flying = false
				st.grav_like = 0
			end
		end
	end

	update_sprinting (player, name, st, env, ctrl, now, fresh, vel)

	-- Speed factors not set by this mod (sprinting, potions, item use...).
	local speed_other = physics_product (player, "speed", BLOCK_ID)

	-- Block speed factor (soul sand, honey, slime, ice).
	local block_factor = 1
	local jump_factor = BASE_JUMP_FACTOR
	local standon = env.standon
	if env.grounded and standon then
		local soul_speed = 0
		if core.get_item_group (standon, "soul_block") > 0 and mcl_enchanting then
			local boots = player:get_inventory ():get_stack ("armor", 5)
			soul_speed = mcl_enchanting.get_enchantment (boots, "soul_speed")
		end
		if soul_speed > 0 then
			block_factor = 1 + (0.0405 + 0.0105 * (soul_speed - 1)) / 0.1
		elseif standon == "mcl_nether:soul_sand" then
			block_factor = SLOW_BLOCK_FACTOR
		elseif standon == "mcl_honey:honey_block" then
			block_factor = SLOW_BLOCK_FACTOR
		elseif standon == "mcl_core:slimeblock" and not ctrl.sneak then
			block_factor = SLIME_FACTOR
		else
			local slippery = core.get_item_group (standon, "slippery")
			if slippery >= 4 then
				block_factor = BLUE_ICE_SPEED_FACTOR
			elseif slippery > 0 then
				block_factor = ICE_SPEED_FACTOR
			end
		end
	end
	if standon == "mcl_honey:honey_block" and env.support then
		jump_factor = jump_factor * HONEY_JUMP_FACTOR
	end
	-- More than 0.4 nodes deep in a liquid, the jump key swims upwards
	-- instead of jumping off the bottom.  Without a jump speed, the engine
	-- does exactly that.
	if env.liquid and liquid_kind (vector.offset (pos, 0, 0.4, 0)) then
		jump_factor = 0
	end
	-- Head hitters (see above).
	if not ctrl.jump then
		st.jump_release_t = now
	end
	st.headhitter = false
	if not st.flying and not env.liquid and not env.climbing and not env.stuck
		and not ctrl.sneak and ilen > 0.01
		and (ctrl.jump or now - (st.jump_release_t or -1) < 0.35) then
		local height = player:get_properties ().collisionbox[5] or 1.8
		local clearance = head_clearance (pos, height)
		if clearance and clearance > 0.03
			and (env.support or is_walkable (vector.offset (pos, 0, -clearance - 0.15, 0))) then
			local spam = now - (st.jump_release_t or -1) < 0.35
			local floor = st.prev_standon or env.standon
			local v = headhitter_speed (clearance, spam, st.sprinting,
						    speed_other, block_friction (floor)) * ilen
			-- Minecraft builds up this speed over a few jumps.
			local h = math.sqrt (vel.x * vel.x + vel.z * vel.z)
			local cur = st.hh_speed or h
			cur = cur + (v - cur) * (1 - math.exp (-dt / 0.4))
			st.hh_speed = cur
			st.headhitter = true
			block_factor = cur / (S_WALK * math.max (0.05, speed_other))
		end
	end
	if not st.headhitter then
		st.hh_speed = nil
	end
	apply (player, st, "speed", block_factor, BLOCK_ID)
	apply (player, st, "jump", jump_factor)

	local sp = math.max (0.05, speed_other * block_factor)
	-- Minecraft's movement speed attribute relative to walking, which does
	-- not include item use (that scales the input instead).
	local speed_attr = speed_other
	if using_item (player) then
		speed_attr = speed_attr / 0.2
	end

	local sneak = crouch_factor (player, ctrl)
	local use = using_item (player) and 0.2 or 1
	local vertical_key = ctrl.jump or ctrl.sneak

	local f = {
		acceleration_default = 1,
		acceleration_air = 1,
		acceleration_fast = S_ACC_DEFAULT / S_ACC_FAST,
		speed_walk = 1,
		speed_fast = S_WALK / S_FAST,
		speed_climb = CLIMB_SPEED / S_CLIMB / sp,
		gravity = BASE_GRAVITY_FACTOR,
		liquid_fluidity = 1,
		liquid_sink = 1,
	}

	-- Air control: Minecraft accelerates by 0.02 (sprinting: 0.026)
	-- blocks/tick² and applies a drag of 0.91 per tick, i.e. velocity
	-- approaches 4.36 (5.66) nodes/s exponentially.  Emulate this by
	-- limiting the engine's acceleration to the exponential rate.
	do
		local term = (st.sprinting and 5.662 or 4.356) * sneak * use
		local tx, tz = ix * term, iz * term
		local dx, dz = tx - vel.x, tz - vel.z
		local a = K_AIR * math.sqrt (dx * dx + dz * dz)
		a = math.min (25, math.max (0.6, a))
		f.acceleration_air = a / (S_ACC_AIR * sp)
	end

	if st.flying and ENGINE_FLIGHT then
		-- Creative flight (twice as fast as Minecraft): 0.1 blocks/tick² with
		-- air drag horizontally, 15 nodes/s vertically.  The engine flies at
		-- these speeds everywhere (in liquids, on ladders, sneaking, with any speed
		-- factor); only the acceleration is set here, and it is not
		-- scaled by `speed'.
		local dx, dz = ix * FLY_SPEED - vel.x, iz * FLY_SPEED - vel.z
		local a = K_AIR * math.sqrt (dx * dx + dz * dz)
		if vertical_key or math.abs (vel.y) > 0.3 then
			a = math.max (a, 60)
		end
		a = math.max (a, 1)
		f.acceleration_default = a / S_ACC_DEFAULT
	elseif st.flying then
		-- Creative flight: 0.05 (sprinting: 0.1) blocks/tick² with air
		-- drag horizontally; 7.5 nodes/s vertically.
		local horizontal = st.sprinting and FLY_SPRINT_SPEED or FLY_SPEED
		local target = horizontal
		if vertical_key and ilen < 0.01 then
			target = FLY_VERTICAL_SPEED
		end
		f.speed_walk = target / (S_WALK * sp)
		f.speed_fast = (vertical_key and ilen < 0.01 and FLY_VERTICAL_SPEED
				or FLY_SPRINT_SPEED) / (S_FAST * sp)
		local dx, dz = ix * horizontal - vel.x, iz * horizontal - vel.z
		local a = K_AIR * math.sqrt (dx * dx + dz * dz)
		if vertical_key or math.abs (vel.y) > 0.3 then
			a = math.max (a, 60)
		end
		a = math.max (a, 1)
		f.acceleration_default = a / (S_ACC_DEFAULT * sp)
		f.acceleration_fast = a / (S_ACC_FAST * sp)
	elseif env.liquid then
		local k, v_term, sink, rise
		local swimming = env.liquid == "water" and is_swimming (player, st, env)
		if env.liquid == "water" then
			local drag = swimming and 0.9 or 0.8
			local acc = 0.02
			local depth_strider = 0
			if mcl_enchanting then
				local boots = player:get_inventory ():get_stack ("armor", 5)
				depth_strider = math.min (3, mcl_enchanting.get_enchantment (boots, "depth_strider"))
			end
			if depth_strider > 0 then
				local w = depth_strider / 3
				if not env.support then
					w = w / 2
				end
				drag = drag + (0.546 - drag) * w
				acc = acc + (0.1 * speed_attr - acc) * w
			end
			if has_effect (player, "dolphin_grace") then
				drag = 0.96
			end
			k = -20 * math.log (drag)
			v_term = acc * 0.98 * 20 / (1 - drag)
			sink = swimming and 0 or 0.5
			rise = ctrl.jump and 3.5 or 4.5
			if swimming then
				-- The engine shares one drag rate between all axes;
				-- Minecraft's is 2.1/s horizontally while swimming
				-- but 4.5/s vertically.  Compromise so that steering
				-- by looking up and down stays responsive.
				k = math.max (k, SWIM_DRAG_RATE)
			end
		else
			k = -20 * math.log (0.5)
			v_term = 0.784
			sink = 0.8
			rise = 0.8
		end
		-- The engine's liquid drag rate is 10 * resistance / fluidity.
		local _, ldef = node_def (env.liquid_pos)
		-- (move_resistance defaults to liquid_viscosity.)
		local mr = ldef and (ldef.move_resistance or ldef.liquid_viscosity) or 0
		local resistance = mr * 0.3 + 0.7
		local k_base = 10 * resistance / S_FLUIDITY
		f.liquid_fluidity = math.max (1, k_base / k)
		local k_eff = k_base / f.liquid_fluidity
		-- Crouching (not swimming) also scales the input in water.
		local crouch = swimming and 1 or sneak
		local a = v_term * k_eff * use * crouch
		local needed = v_term
		if vertical_key and not swimming then
			-- The jump and sneak keys make the engine rise or sink
			-- at the same target speed as it moves horizontally, so
			-- rising (3.5 nodes/s) and moving (1.96) at once can not
			-- both be right.  At the surface the horizontal speed
			-- matters most; under water, split the difference.
			local v = rise
			if ilen > 0.01 then
				v = env.submerged and math.max (v_term, 2.6) or v_term
			end
			a = math.max (a, v * k_eff)
			needed = math.max (needed, v)
		end
		-- The engine applies drag after accelerating within each of its
		-- ~8 ms substeps, which settles at a * (1 - k * dt) / k.
		a = a / (1 - k_eff * ENGINE_SUBSTEP)
		f.acceleration_default = a / (S_ACC_DEFAULT * sp)
		f.acceleration_fast = a / (S_ACC_FAST * sp)
		f.speed_walk = math.max (1, needed * 1.05 / (S_WALK * sp))
		f.speed_fast = f.speed_walk * S_WALK / S_FAST

		-- Vertical speed without the jump or sneak keys: sinking, or
		-- while swimming, following the direction the player looks.
		local w = -sink
		if swimming then
			-- Minecraft blends the vertical velocity towards the look
			-- direction's y each tick (rate 0.085 looking down
			-- steeply, else 0.06) unless looking up with the head
			-- out of the water: 6.34 or 4.84 nodes/s at most.
			local look_y = player:get_look_dir ().y
			local head_wet = liquid_kind (vector.offset (pos, 0, 0.9, 0)) == "water"
			if look_y <= 0 or ctrl.jump or head_wet then
				w = look_y * (look_y < -0.2 and 6.34 or 4.84)
			else
				w = 0
			end
		end
		-- The engine pulls the vertical speed towards zero as hard as it
		-- accelerates (a), on top of the liquid's drag, so the sinking
		-- "gravity" must overcome both to settle at w.
		if w == 0 then
			f.liquid_sink = 0
		else
			local g = a + k_eff * math.abs (w)
			f.liquid_sink = (w < 0 and g or -g) / S_SINK
		end

		-- Water currents push players (0.014 blocks/tick²).
		if env.liquid == "water" and flowlib and env.liquid_node then
			local flow = flowlib.quick_flow (env.liquid_pos, env.liquid_node)
			if flow and (flow.x ~= 0 or flow.y ~= 0 or flow.z ~= 0) then
				local push = 0.014 * 400 * math.min (dt, 0.2)
				player:add_velocity (vector.multiply (flow, push))
			end
		end
	elseif env.grounded and standon then
		local slippery = core.get_item_group (standon, "slippery")
		if slippery > 0 then
			-- The engine divides ground acceleration on slippery nodes by
			-- (slippery + 1), or (2 * slippery + 1) without input.
			local slip = ilen > 0 and 1 / (slippery + 1) or 1 / (2 * slippery + 1)
			local target = slippery >= 4 and BLUE_ICE_ACCELERATION or ICE_ACCELERATION
			f.acceleration_default = target / (GROUND_ACCELERATION * slip)
		end
	end

	if not st.flying and not env.liquid then
		-- The engine also uses the "fast" acceleration in the air when
		-- the aux1 key is held with fast mode enabled.
		if env.grounded or env.climbing then
			f.acceleration_fast = f.acceleration_default * S_ACC_DEFAULT / S_ACC_FAST
		else
			f.acceleration_fast = f.acceleration_air * S_ACC_AIR / S_ACC_FAST
		end
	end

	-- Gravity: air drag on fast vertical movement, Slow Falling, and
	-- movement-arresting blocks.
	local gravity = 1
	if slow_falling and vel.y <= 0 then
		-- 0.01 blocks/tick² instead of 0.08, terminal velocity 9.8.
		gravity = 0.125 * math.max (0, 1 + vel.y / 9.8)
	elseif vel.y < -DRAG_SPEED then
		gravity = math.max (0, 1 - (-vel.y - DRAG_SPEED) / (TERMINAL_VELOCITY - DRAG_SPEED))
	elseif vel.y > DRAG_SPEED then
		gravity = 1 + (vel.y - DRAG_SPEED) / (TERMINAL_VELOCITY - DRAG_SPEED)
	end
	if env.stuck then
		-- Sinking speed through the block: gravity / drag rate, where the
		-- drag rate is 10 * (move_resistance * 0.3 + 0.7).
		local node = core.get_node (vector.offset (pos, 0, 0.1, 0))
		local def = core.registered_nodes[node.name]
		local mr = def and def.move_resistance or 0
		if mr > 0 then
			gravity = env.stuck.fall * 10 * (mr * 0.3 + 0.7) / GRAVITY
		end
	end
	f.gravity = BASE_GRAVITY_FACTOR * gravity

	for attr, value in pairs (f) do
		apply (player, st, attr, value)
	end

	-- Take-off impulses and fall damage only depend on new positions.
	if fresh then
		local airborne = not env.grounded and not env.liquid and not env.climbing
			and not st.flying and not env.stuck and not st.headhitter
		if airborne and st.prev_vel then
			-- Jump speed including Jump Boost and honey blocks.
			local jump_speed = S_JUMP * physics_product (player, "jump")
			local below = core.get_node (vector.offset (pos, 0, -0.5, 0)).name
			local bounce = prev_vel.y < -2 and core.get_item_group (below, "bouncy") > 0
			local jumped = vel.y > 2 and prev_vel.y <= 0.5 and not bounce
				and vel.y <= jump_speed * 1.3
			local walked_off = st.prev_grounded and vel.y <= 0 and vel.y > -4
			if jumped or walked_off then
				local g = GRAVITY * gravity
				local tsince
				if jumped then
					tsince = math.max (0, (jump_speed - vel.y) / g)
				else
					tsince = math.max (0, -vel.y / g)
				end
				take_off (player, st, vel, ix, iz, ctrl, jumped, tsince,
					  speed_attr, now)
			end
		end
		if not env.grounded then
			st.last_air_t = now
		end
		st.prev_grounded = env.grounded
		if env.grounded then
			st.prev_standon = env.standon
		end

		-- Fall distance.
		local y = pos.y
		local moved = st.prev_pos and vector.distance (pos, st.prev_pos) or 0
		local plausible = (math.sqrt (vel.x ^ 2 + vel.y ^ 2 + vel.z ^ 2)
				   + math.sqrt (prev_vel.x ^ 2 + prev_vel.y ^ 2 + prev_vel.z ^ 2))
			* math.max (dt, TICK) + 2
		if moved > plausible then
			-- Teleported.
			st.fall_distance = 0
		elseif st.flying or env.liquid or env.climbing or env.stuck
			or slow_falling or levitating then
			st.fall_distance = 0
		elseif st.last_y and y < st.last_y then
			st.fall_distance = st.fall_distance + (st.last_y - y)
		end
		st.last_y = y

		-- Bouncing off slime blocks or beds ends a fall as well.
		local bounced = prev_vel.y < -2 and vel.y > 0
		-- Entity.restituteMovementAfterCollisions: bounce
		if bounced and mcl_gameevent and core.get_item_group (core.get_node (
				vector.offset (pos, 0, -0.5, 0)).name, "bouncy") > 0 then
			mcl_gameevent.emit_entity (player, "bounce")
		end
		if (env.grounded or bounced) and st.fall_distance > 0 then
			local node = env.standon
			if bounced and not node then
				node = core.get_node (vector.offset (pos, 0, -0.5, 0)).name
			end
			land (player, name, st, node)
		end

		st.prev_pos = pos
		st.prev_vel = vel
		st.prev_t = now
	end

	if st.debug_hud then
		local h = math.sqrt (vel.x * vel.x + vel.z * vel.z)
		local state = st.flying and "flying"
			or (env.liquid and (is_swimming (player, st, env) and "swimming"
					    or "in " .. env.liquid))
			or (env.climbing and "climbing")
			or (st.headhitter and "head hitter")
			or (env.grounded and "on ground") or "in air"
		player:hud_change (st.debug_hud, "text", string.format (
			"horizontal %.2f  vertical %.2f  total %.2f nodes/s\n%s%s  fall %.1f",
			h, vel.y, math.sqrt (h * h + vel.y * vel.y), state,
			st.sprinting and ", sprinting" or "", st.fall_distance))
	end
end

core.register_chatcommand ("movement_debug", {
	description = "Toggle a display of your speed and movement state",
	func = function (name)
		local player = core.get_player_by_name (name)
		local st = player and states[player]
		if not st then
			return false
		end
		if st.debug_hud then
			player:hud_remove (st.debug_hud)
			st.debug_hud = nil
		else
			st.debug_hud = player:hud_add ({
				type = "text",
				position = { x = 0.5, y = 0.12 },
				alignment = { x = 0, y = 0 },
				number = 0xFFFFFF,
				text = "",
			})
		end
		return true
	end,
})

mcl_player.register_globalstep (function (player)
	if mcl_serverplayer.is_csm_capable (player) then
		return
	end
	local st = states[player]
	if not st then
		return
	end
	step_player (player, st)
end)

core.register_on_joinplayer (function (player)
	local st = new_state ()
	states[player] = st
	if mcl_serverplayer.is_csm_capable (player) then
		return
	end
	reset_factors (player, st)
	-- Factors that mcl_potions used to apply to players; mcl_movement
	-- handles Slow Falling and Dolphin's Grace itself now.
	playerphysics.remove_physics_factor (player, "gravity", "mcl_potions:slow_falling")
	playerphysics.remove_physics_factor (player, "speed", "mcl_potions:dolphin")
	-- Fall damage is computed by this mod; disable the engine's.
	local groups = player:get_armor_groups ()
	groups.fall_damage_add_percent = -100
	player:set_armor_groups (groups)
	apply (player, st, "gravity", BASE_GRAVITY_FACTOR)
	apply (player, st, "jump", BASE_JUMP_FACTOR)
	if ENGINE_FLIGHT then
		player:set_physics_override ({
			speed_fly = FLY_SPEED,
			speed_fly_vertical = FLY_VERTICAL_SPEED,
		})
	end
end)

core.register_on_leaveplayer (function (player)
	states[player] = nil
end)

core.register_on_respawnplayer (function (player)
	mcl_movement.reset_fall_distance (player)
end)
