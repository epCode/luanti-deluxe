------------------------------------------------------------------------
-- Game events and vibrations: a port of Minecraft Java Edition 26.3's
-- GameEvent, GameEventDispatcher, EuclideanGameEventListenerRegistry,
-- DynamicGameEventListener and VibrationSystem (with VibrationSelector,
-- VibrationInfo and the vibration particle).
--
-- Coordinates are Luanti's: a node at integer position p is Minecraft's
-- block containing the point p, so Minecraft's BlockPos.containing(v) is
-- vector.round(v) and Vec3.atCenterOf(pos) is the node position itself.
-- Game time is mcl_redstone's game tick counter (20 per second).
------------------------------------------------------------------------

mcl_gameevent = {}
local G = mcl_gameevent

local floor = math.floor
local sqrt = math.sqrt
local min = math.min
local max = math.max
local insert = table.insert
local vector_new = vector.new

local function round(x)
	return floor(x + 0.5)
end

local function containing(v)
	return vector_new(round(v.x), round(v.y), round(v.z))
end
G.containing = containing

------------------------------------------------------------------------
-- GameEvent: notification radius of every event.
------------------------------------------------------------------------

G.DEFAULT_NOTIFICATION_RADIUS = 16

local EVENTS = {}
for _, name in ipairs({
	"block_activate", "block_attach", "block_change", "block_close",
	"block_deactivate", "block_destroy", "block_detach", "block_open",
	"block_place", "bounce", "container_close", "container_open", "drink",
	"eat", "elytra_glide", "entity_damage", "entity_die", "entity_dismount",
	"entity_interact", "entity_mount", "entity_place", "entity_action",
	"equip", "explode", "flap", "fluid_pickup", "fluid_place", "hit_ground",
	"instrument_play", "item_interact_finish", "item_interact_start",
	"lightning_strike", "note_block_play", "prime_fuse", "projectile_land",
	"projectile_shoot", "sculk_sensor_tendrils_clicking", "shear", "splash",
	"step", "swim", "teleport", "unequip",
}) do
	EVENTS[name] = 16
end
EVENTS.jukebox_play = 10
EVENTS.jukebox_stop_play = 10
EVENTS.shriek = 32
for i = 1, 15 do
	EVENTS["resonate_" .. i] = 16
end
G.events = EVENTS

------------------------------------------------------------------------
-- VibrationSystem.VIBRATION_FREQUENCY_FOR_EVENT
------------------------------------------------------------------------

local FREQUENCY = {
	step = 1, swim = 1, flap = 1,
	projectile_land = 2, hit_ground = 2, splash = 2, bounce = 2,
	item_interact_finish = 3, projectile_shoot = 3, instrument_play = 3,
	entity_action = 4, elytra_glide = 4, unequip = 4,
	entity_dismount = 5, equip = 5,
	entity_interact = 6, shear = 6, entity_mount = 6,
	entity_damage = 7,
	drink = 8, eat = 8,
	container_close = 9, block_close = 9, block_deactivate = 9, block_detach = 9,
	container_open = 10, block_open = 10, block_activate = 10, block_attach = 10,
	prime_fuse = 10, note_block_play = 10,
	block_change = 11,
	block_destroy = 12, fluid_pickup = 12,
	block_place = 13, fluid_place = 13,
	entity_place = 14, lightning_strike = 14, teleport = 14,
	entity_die = 15, explode = 15,
}
for i = 1, 15 do
	FREQUENCY["resonate_" .. i] = i
end
G.frequency = FREQUENCY

function G.get_frequency(event)
	return FREQUENCY[event] or 0
end

function G.resonance_event(frequency)
	return "resonate_" .. frequency
end

-- VibrationSystem.getRedstoneStrengthForDistance
function G.redstone_strength_for_distance(distance, radius)
	local scale = 15.0 / radius
	return max(1, 15 - floor(scale * distance))
end

------------------------------------------------------------------------
-- Game event tags (data/minecraft/tags/game_event).
------------------------------------------------------------------------

local function set(list)
	local s = {}
	for _, v in ipairs(list) do
		s[v] = true
	end
	return s
end

local VIBRATIONS = {
	"block_attach", "block_change", "block_close", "block_destroy",
	"block_detach", "block_open", "block_place", "block_activate",
	"block_deactivate", "bounce", "container_close", "container_open",
	"drink", "eat", "elytra_glide", "entity_damage", "entity_die",
	"entity_dismount", "entity_interact", "entity_mount", "entity_place",
	"entity_action", "equip", "explode", "fluid_pickup", "fluid_place",
	"hit_ground", "instrument_play", "item_interact_finish",
	"lightning_strike", "note_block_play", "prime_fuse", "projectile_land",
	"projectile_shoot", "shear", "splash", "step", "swim", "teleport",
	"unequip",
}
for i = 1, 15 do
	insert(VIBRATIONS, "resonate_" .. i)
end
insert(VIBRATIONS, "flap")

local WARDEN_CAN_LISTEN = table.copy(VIBRATIONS)
table.remove(WARDEN_CAN_LISTEN) -- flap is not in warden_can_listen
insert(WARDEN_CAN_LISTEN, "shriek")
insert(WARDEN_CAN_LISTEN, "sculk_sensor_tendrils_clicking")

G.tags = {
	vibrations = set(VIBRATIONS),
	warden_can_listen = set(WARDEN_CAN_LISTEN),
	shrieker_can_listen = set({"sculk_sensor_tendrils_clicking"}),
	allay_can_listen = set({"note_block_play"}),
	ignore_vibrations_sneaking = set({
		"hit_ground", "projectile_shoot", "step", "swim",
		"item_interact_start", "item_interact_finish",
	}),
}

------------------------------------------------------------------------
-- Entities (the source of an event).
------------------------------------------------------------------------

local function is_valid(obj)
	return obj ~= nil and obj:get_pos() ~= nil
end
G.is_valid = is_valid

function G.is_spectator(obj)
	return obj:is_player() and mcl_gamemode ~= nil
		and mcl_gamemode.get_gamemode(obj) == "spectator"
end

-- Entity.isSteppingCarefully (= isShiftKeyDown)
function G.is_stepping_carefully(obj)
	if obj:is_player() then
		return obj:get_player_control().sneak
	end
	local le = obj:get_luaentity()
	return le ~= nil and le._stepping_carefully == true
end

local function item_dampens(stack)
	local name = ItemStack(stack):get_name()
	return core.get_item_group(name, "wool") > 0
		or core.get_item_group(name, "carpet") > 0
end

-- Entity.dampensVibrations: wardens; item entities with an item in
-- #dampens_vibrations (wool and carpets)
function G.dampens_vibrations(obj)
	local le = obj:get_luaentity()
	if not le then
		return false
	end
	if le._dampens_vibrations then
		return true
	end
	if le.name == "__builtin:item" then
		return item_dampens(le.itemstring)
	end
	return false
end

local function to_object(v)
	if type(v) == "string" then
		return core.get_player_by_name(v)
	elseif type(v) == "userdata" and is_valid(v) then
		return v
	end
	return nil
end

-- Projectile.getOwner: the shooter of an arrow, snowball, trident...
function G.get_projectile_owner(obj)
	local le = obj and obj:get_luaentity()
	if not le then
		return nil
	end
	if le._is_projectile == false then
		return nil
	end
	return to_object(le._shooter) or to_object(le._thrower)
		or to_object(le._owner) or to_object(le.shooter)
end

-- ItemEntity.getOwner (the player who dropped it)
function G.get_item_owner(obj)
	local le = obj and obj:get_luaentity()
	if not le or le.name ~= "__builtin:item" then
		return nil
	end
	return to_object(le._dropped_by) or to_object(le.dropped_by)
end

-- The nearest wool and carpet test (BlockTags.DAMPENS_VIBRATIONS)
local function dampens_node(node)
	local name = node.name
	return core.get_item_group(name, "wool") > 0
		or core.get_item_group(name, "carpet") > 0
		or core.get_item_group(name, "wool_stair") > 0
		or core.get_item_group(name, "wool_slab") > 0
end
G.node_dampens_vibrations = dampens_node

-- BlockTags.OCCLUDES_VIBRATION_SIGNALS (#wool)
local function occludes(name)
	return core.get_item_group(name, "wool") > 0
end

------------------------------------------------------------------------
-- Listener registry, by 16x16x16 section (chunk sections in Minecraft).
------------------------------------------------------------------------

local sections = {}

local function section_key(x, y, z)
	return floor(x / 16) .. "," .. floor(y / 16) .. "," .. floor(z / 16)
end

local function registry_add(key, listener)
	local list = sections[key]
	if not list then
		list = {}
		sections[key] = list
	end
	insert(list, listener)
	listener._section = key
end

local function registry_remove(listener)
	local key = listener._section
	if not key then
		return
	end
	local list = sections[key]
	listener._section = nil
	if not list then
		return
	end
	for i = 1, #list do
		if list[i] == listener then
			table.remove(list, i)
			break
		end
	end
	if #list == 0 then
		sections[key] = nil
	end
end

-- A listener is a table with:
--   get_position(self): the listener position (vector) or nil
--   radius: getListenerRadius()
--   delivery_mode: "unspecified" (default) or "by_distance"
--   handle_game_event(self, event, ctx, source_pos): returns true if handled
function G.register_listener(listener)
	local pos = listener:get_position()
	if not pos then
		return false
	end
	local p = containing(pos)
	registry_remove(listener)
	registry_add(section_key(p.x, p.y, p.z), listener)
	return true
end

function G.unregister_listener(listener)
	registry_remove(listener)
end

-- DynamicGameEventListener.move: follows a moving listener into other sections
function G.update_listener(listener)
	local pos = listener:get_position()
	if not pos then
		registry_remove(listener)
		return
	end
	local p = containing(pos)
	local key = section_key(p.x, p.y, p.z)
	if listener._section ~= key then
		registry_remove(listener)
		registry_add(key, listener)
	end
end

-- Block listeners (block entities: sculk sensors, shriekers, catalysts),
-- one per position. `node_check(node)` tells whether the node at the
-- position still owns the listener; when it doesn't (the node was replaced
-- or its map block unloaded) the listener goes away.
local block_listeners = {}

local function pos_key(p)
	return p.x .. "," .. p.y .. "," .. p.z
end

function G.add_block_listener(pos, listener)
	local key = pos_key(pos)
	local old = block_listeners[key]
	if old then
		registry_remove(old)
	end
	listener.pos = vector.copy(pos)
	listener._block_key = key
	block_listeners[key] = listener
	G.register_listener(listener)
	return listener
end

function G.get_block_listener(pos)
	return block_listeners[pos_key(pos)]
end

function G.remove_block_listener(pos)
	local key = pos_key(pos)
	local old = block_listeners[key]
	if old then
		registry_remove(old)
		block_listeners[key] = nil
		old.removed = true
	end
end

------------------------------------------------------------------------
-- GameEventDispatcher.post
------------------------------------------------------------------------

local function dist_sqr_blocks(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

local function dist_sqr(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

local function listener_alive(listener)
	if listener.removed then
		return false
	end
	if listener.node_check then
		local node = core.get_node(listener.pos)
		if not listener.node_check(node) then
			G.remove_block_listener(listener.pos)
			return false
		end
	end
	return true
end

local posting_callbacks = {}

-- Called for every posted event: func(event, pos, ctx)
function G.register_on_event(func)
	insert(posting_callbacks, func)
end

-- Level.gameEvent(event, position, context): `ctx` is {source = ObjectRef
-- or nil, node = node table or nil} (GameEvent.Context sourceEntity and
-- affectedState). `pos` is a vector (an exact position, e.g. an entity's
-- feet, or a node position for block events).
function G.emit(event, pos, ctx)
	local radius = EVENTS[event]
	if not radius then
		error("[mcl_gameevent] unknown game event " .. tostring(event), 2)
	end
	if not pos then
		return
	end
	ctx = ctx or {}
	pos = vector.copy(pos)
	for _, cb in ipairs(posting_callbacks) do
		cb(event, pos, ctx)
	end
	local center = containing(pos)
	local sx1, sx2 = floor((center.x - radius) / 16), floor((center.x + radius) / 16)
	local sy1, sy2 = floor((center.y - radius) / 16), floor((center.y + radius) / 16)
	local sz1, sz2 = floor((center.z - radius) / 16), floor((center.z + radius) / 16)
	local by_distance = {}
	-- Minecraft visits chunks by x, then by its z (= -Luanti z), then
	-- the sections of a chunk upwards
	for sx = sx1, sx2 do
		for sz = sz2, sz1, -1 do
			for sy = sy1, sy2 do
				local list = sections[sx .. "," .. sy .. "," .. sz]
				if list then
					local copy = {}
					for i = 1, #list do
						copy[i] = list[i]
					end
					for _, listener in ipairs(copy) do
						if listener_alive(listener) then
							local lpos = listener:get_position()
							if lpos then
								local r = listener.radius
								if dist_sqr_blocks(containing(lpos), center) <= r * r then
									if listener.delivery_mode == "by_distance" then
										insert(by_distance, {
											listener = listener,
											d = dist_sqr(pos, lpos),
											i = #by_distance + 1,
										})
									else
										listener:handle_game_event(event, ctx, pos)
									end
								end
							end
						end
					end
				end
			end
		end
	end
	if #by_distance > 0 then
		-- Collections.sort (stable)
		table.sort(by_distance, function(a, b)
			if a.d ~= b.d then
				return a.d < b.d
			end
			return a.i < b.i
		end)
		for _, item in ipairs(by_distance) do
			item.listener:handle_game_event(event, ctx, pos)
		end
	end
end

-- Entity.gameEvent(event [, sourceEntity]): at the entity's position
function G.emit_entity(obj, event, source)
	if not is_valid(obj) then
		return
	end
	G.emit(event, obj:get_pos(), {source = source == nil and obj or source or nil})
end

------------------------------------------------------------------------
-- Occlusion (VibrationSystem.Listener.isOccluded): six rays nudged off the
-- source block center towards the listener block center; the vibration is
-- occluded when each of them hits wool (BlockGetter.isBlockInLine /
-- traverseBlocks with ClipBlockStateContext).
------------------------------------------------------------------------

local function sign(x)
	return x > 0 and 1 or (x < 0 and -1 or 0)
end

local function frac(x)
	return x - floor(x)
end

-- BlockGetter.traverseBlocks in node space (node centers at integers);
-- returns true if a block on the segment satisfies `pred(name)`
local function traverse_hits(from, to, pred)
	if from.x == to.x and from.y == to.y and from.z == to.z then
		return false
	end
	-- Minecraft's blocks have their corners at integers: shifted by 0.5,
	-- floor() of a coordinate is the Luanti node position
	local EPS = 1.0E-7
	local fx, fy, fz = from.x + 0.5, from.y + 0.5, from.z + 0.5
	local ex, ey, ez = to.x + 0.5, to.y + 0.5, to.z + 0.5
	-- Mth.lerp(-1e-7, to, from) and Mth.lerp(-1e-7, from, to)
	local x1 = ex + (fx - ex) * -EPS
	local y1 = ey + (fy - ey) * -EPS
	local z1 = ez + (fz - ez) * -EPS
	local x0 = fx + (ex - fx) * -EPS
	local y0 = fy + (ey - fy) * -EPS
	local z0 = fz + (ez - fz) * -EPS
	local bx, by, bz = floor(x0), floor(y0), floor(z0)
	local function test(x, y, z)
		return pred(core.get_node(vector_new(x, y, z)).name)
	end
	if test(bx, by, bz) then
		return true
	end
	local dx, dy, dz = x1 - x0, y1 - y0, z1 - z0
	local sxs, sys, szs = sign(dx), sign(dy), sign(dz)
	local tdx = sxs == 0 and math.huge or sxs / dx
	local tdy = sys == 0 and math.huge or sys / dy
	local tdz = szs == 0 and math.huge or szs / dz
	local tmx = tdx * (sxs > 0 and 1 - frac(x0) or frac(x0))
	local tmy = tdy * (sys > 0 and 1 - frac(y0) or frac(y0))
	local tmz = tdz * (szs > 0 and 1 - frac(z0) or frac(z0))
	while tmx <= 1 or tmy <= 1 or tmz <= 1 do
		if tmx < tmy then
			if tmx < tmz then
				bx = bx + sxs
				tmx = tmx + tdx
			else
				bz = bz + szs
				tmz = tmz + tdz
			end
		elseif tmy < tmz then
			by = by + sys
			tmy = tmy + tdy
		else
			bz = bz + szs
			tmz = tmz + tdz
		end
		if test(bx, by, bz) then
			return true
		end
	end
	return false
end

local NUDGE = 1.0E-5
local DIRS = {
	{0, -1, 0}, {0, 1, 0}, {0, 0, 1}, {0, 0, -1}, {-1, 0, 0}, {1, 0, 0},
}

function G.is_occluded(origin, dest)
	local from = containing(origin)
	local to = containing(dest)
	for _, d in ipairs(DIRS) do
		local nudged = vector_new(from.x + d[1] * NUDGE, from.y + d[2] * NUDGE,
			from.z + d[3] * NUDGE)
		if not traverse_hits(nudged, to, occludes) then
			return false
		end
	end
	return true
end

------------------------------------------------------------------------
-- VibrationSystem
------------------------------------------------------------------------

local function game_time()
	return mcl_redstone.get_game_time()
end

-- VibrationSystem.Data
function G.new_vibration_data()
	return {
		current = nil,  -- VibrationInfo
		travel = 0,     -- travelTimeInTicks
		selector = nil, -- VibrationSelector: {info = VibrationInfo, tick = n}
		reload_particle = false,
	}
end

-- A VibrationInfo: {event, distance, pos, source (ObjectRef or nil),
-- source_name (player name), projectile_owner (ObjectRef or nil)}
local function new_vibration_info(event, distance, pos, source)
	local owner = source and G.get_projectile_owner(source)
	return {
		event = event,
		distance = distance,
		pos = pos,
		source = source,
		source_name = source and source:is_player() and source:get_player_name() or nil,
		projectile_owner = owner,
	}
end

local function info_entity(info)
	if is_valid(info.source) then
		return info.source
	end
	if info.source_name then
		return core.get_player_by_name(info.source_name)
	end
	return nil
end

local function info_projectile_owner(info)
	local e = info_entity(info)
	if e then
		local owner = G.get_projectile_owner(e)
		if owner then
			return owner
		end
	end
	if is_valid(info.projectile_owner) then
		return info.projectile_owner
	end
	return nil
end

-- VibrationSelector.shouldReplaceVibration
local function should_replace(selector, info, tick)
	if not selector then
		return true
	end
	if tick ~= selector.tick then
		return false
	end
	local prev = selector.info
	if info.distance < prev.distance then
		return true
	elseif info.distance > prev.distance then
		return false
	end
	return G.get_frequency(info.event) > G.get_frequency(prev.event)
end

local function add_candidate(data, info, tick)
	if should_replace(data.selector, info, tick) then
		data.selector = {info = info, tick = tick}
	end
end

local function chosen_candidate(data, time)
	local s = data.selector
	if s and s.tick < time then
		return s.info
	end
	return nil
end

-- VibrationSystem.User.isValidVibration
local function is_valid_vibration(user, event, ctx)
	local listenable = user.listenable or G.tags.vibrations
	if not listenable[event] then
		return false
	end
	local source = ctx.source
	if is_valid(source) then
		if G.is_spectator(source) then
			return false
		end
		if G.is_stepping_carefully(source) and G.tags.ignore_vibrations_sneaking[event] then
			-- CriteriaTriggers.AVOID_VIBRATION
			if user.can_trigger_avoid_vibration and source:is_player()
					and awards and awards.unlock then
				awards.unlock(source:get_player_name(), "mcl:avoid_vibration")
			end
			return false
		end
		if G.dampens_vibrations(source) then
			return false
		end
	end
	if ctx.node then
		return not dampens_node(ctx.node)
	end
	return true
end

local function travel_time(user, distance)
	if user.travel_time then
		return user:travel_time(distance)
	end
	return floor(distance)
end

------------------------------------------------------------------------
-- Minecraft particle quads with a fixed rotation (SingleQuadParticle.
-- extractRotatedQuad): `steps` is a list of {"x"|"y", angle} applied
-- right to left like JOML's rotationY(a).rotateX(b)... to the quad lying
-- in the X-Y plane, in Minecraft's coordinates. Returns the Luanti particle
-- `rotation` (z is mirrored between the two games).
------------------------------------------------------------------------

local function mc_rotate(v, axis, a)
	local c, s = math.cos(a), math.sin(a)
	if axis == "y" then
		return vector_new(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
	end
	return vector_new(v.x, v.y * c - v.z * s, v.y * s + v.z * c)
end

function G.mc_quad_rotation(steps)
	local function apply(v)
		for i = #steps, 1, -1 do
			v = mc_rotate(v, steps[i][1], steps[i][2])
		end
		return vector_new(v.x, v.y, -v.z)
	end
	return vector.dir_to_rotation(apply(vector_new(0, 0, 1)), apply(vector_new(0, 1, 0)))
end

-- VibrationParticleOption: the vibration flies from `pos` to the
-- listener in `ticks` ticks (VibrationSignalParticle), turned towards it
-- and swaying slowly. Sent like ServerLevel.sendParticles to the players
-- within 32 blocks.
function G.vibration_particle(pos, user, ticks)
	if ticks <= 0 then
		return
	end
	local dest = user:get_position()
	if not dest then
		return
	end
	local secs = ticks / 20
	local vel = vector.divide(vector.subtract(dest, pos), secs)
	-- In Minecraft coordinates: rot = atan2(dx, dz), pitch = atan2(dy,
	-- horizontal), with d = particle - destination
	local dx, dy, dz = pos.x - dest.x, pos.y - dest.y, -(pos.z - dest.z)
	local rot = math.atan2(dx, dz)
	local pitch = math.atan2(dy, sqrt(dx * dx + dz * dz)) + math.pi / 2
	local function at(age)
		local sway = math.sin((age - math.pi * 2) * 0.05) * 2.0
		return G.mc_quad_rotation({{"y", rot}, {"x", -pitch}, {"y", sway}})
	end
	local r0, r1 = at(0), at(ticks)
	for _, player in ipairs(core.get_connected_players()) do
		local ppos = player:get_pos()
		if vector.distance(ppos, pos) <= 32 then
			core.add_particle({
				playername = player:get_player_name(),
				pos = pos,
				velocity = vel,
				expirationtime = secs,
				-- quadSize 0.3
				size = 6,
				rotation_tween = {r0, r1},
				texture = "mcl_sculk_vibration.png",
				animation = {type = "vertical_frames", aspect_w = 18, aspect_h = 18, length = 0.35},
				glow = 15,
			})
		end
	end
end

local function try_reload_particle(data, user)
	if not data.reload_particle then
		return
	end
	if not data.current then
		data.reload_particle = false
		return
	end
	local origin = data.current.pos
	local dest = user:get_position() or origin
	local ticks = data.travel
	local initial = travel_time(user, data.current.distance)
	local alpha = initial > 0 and 1.0 - ticks / initial or 1
	local p = vector_new(origin.x + (dest.x - origin.x) * alpha,
		origin.y + (dest.y - origin.y) * alpha,
		origin.z + (dest.z - origin.z) * alpha)
	G.vibration_particle(p, user, ticks)
	data.reload_particle = false
end

local function adjacent_loaded(pos)
	for dx = -16, 16, 16 do
		for dz = -16, 16, 16 do
			local p = vector_new(pos.x + dx, pos.y, pos.z + dz)
			if core.get_node_or_nil(p) == nil then
				return false
			end
		end
	end
	return true
end

local function receive_vibration(data, user, info)
	local origin = containing(info.pos)
	local lpos = user:get_position()
	local dest = lpos and containing(lpos) or origin
	if user.requires_adjacent_chunks and not adjacent_loaded(dest) then
		return false
	end
	user:on_receive(origin, info.event, info_entity(info), info_projectile_owner(info),
		sqrt(dist_sqr_blocks(origin, dest)))
	data.current = nil
	return true
end

-- VibrationSystem.Ticker.tick: run every game tick for each vibration user
function G.vibration_tick(data, user)
	if not data.current then
		local info = chosen_candidate(data, game_time())
		if info then
			data.current = info
			data.travel = travel_time(user, info.distance)
			G.vibration_particle(info.pos, user, data.travel)
			if user.on_data_changed then
				user:on_data_changed()
			end
			data.selector = nil
		end
	end
	if data.current then
		local changed = data.travel > 0
		try_reload_particle(data, user)
		data.travel = max(0, data.travel - 1)
		if data.travel <= 0 then
			changed = receive_vibration(data, user, data.current)
		end
		if changed and user.on_data_changed then
			user:on_data_changed()
		end
	end
end

-- VibrationSystem.Listener: a game event listener for a vibration user.
-- `user` has: radius, get_position(self), listenable (tag set, default
-- vibrations), can_receive(self, node_pos, event, ctx),
-- on_receive(self, node_pos, event, source, projectile_owner, distance),
-- optional can_trigger_avoid_vibration, requires_adjacent_chunks,
-- travel_time(self, distance), on_data_changed(self).
function G.new_vibration_listener(data, user)
	local listener = {
		radius = user.radius,
		data = data,
		user = user,
	}
	function listener:get_position()
		return user:get_position()
	end
	function listener:handle_game_event(event, ctx, source_pos)
		if data.current then
			return false
		end
		if not is_valid_vibration(user, event, ctx) then
			return false
		end
		local dest = user:get_position()
		if not dest then
			return false
		end
		if not user:can_receive(containing(source_pos), event, ctx) then
			return false
		end
		if G.is_occluded(source_pos, dest) then
			return false
		end
		add_candidate(data, new_vibration_info(event, vector.distance(source_pos, dest),
			vector.copy(source_pos), is_valid(ctx.source) and ctx.source or nil), game_time())
		return true
	end
	-- Listener.forceScheduleVibration
	function listener:force_schedule(event, ctx, origin)
		local dest = user:get_position()
		if dest then
			add_candidate(data, new_vibration_info(event, vector.distance(origin, dest),
				vector.copy(origin), is_valid(ctx.source) and ctx.source or nil), game_time())
		end
	end
	return listener
end

-- VibrationSystem.Data codec (node metadata / staticdata): the pending
-- vibration and its travel time; entities are kept by player name only
function G.serialize_vibration_data(data)
	local function info_tbl(info)
		if not info then
			return nil
		end
		return {
			event = info.event, distance = info.distance, pos = info.pos,
			source_name = info.source_name,
		}
	end
	return core.serialize({
		current = info_tbl(data.current),
		travel = data.travel,
		selector = data.selector and {info = info_tbl(data.selector.info), tick = data.selector.tick},
	})
end

function G.deserialize_vibration_data(str)
	local data = G.new_vibration_data()
	local t = str and str ~= "" and core.deserialize(str)
	if type(t) == "table" then
		data.current = t.current
		data.travel = t.travel or 0
		data.selector = t.selector and t.selector.info and t.selector or nil
		-- Data(...) from the codec: reload the particle
		data.reload_particle = data.current ~= nil
	end
	return data
end

------------------------------------------------------------------------
-- Events that Luanti reports to every mod.
------------------------------------------------------------------------

dofile(core.get_modpath(core.get_current_modname()) .. "/emitters.lua")
