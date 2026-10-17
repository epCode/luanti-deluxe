------------------------------------------------------------------------
-- Warden: a port of Minecraft Java Edition 26.3's Warden, WardenAi (its
-- Brain: memories, sensors, activities and behaviours), AngerManagement,
-- AngerLevel and the warden behaviours (Emerging, Digging, Roar, Sniffing,
-- TryToSniff, SetRoarTarget, SetWardenLookTarget, SonicBoom).
--
-- The model and its animations (WardenModel, WardenAnimation, the
-- emissive layers of WardenRenderer) are drawn by the engine's
-- procedural animation "minecraft_warden", driven by
-- ObjectRef:set_animation_state{pose, anger, head_yaw, look_pitch} and
-- ObjectRef:entity_event(id).
--
-- Time is counted in game ticks (mcl_redstone.get_game_time).
------------------------------------------------------------------------

local S = core.get_translator("mobs_mc")
local mob_class = mcl_mobs.mob_class
local G = mcl_gameevent
local floor, abs, min, max, sqrt, random = math.floor, math.abs, math.min, math.max, math.sqrt, math.random
local pi = math.pi

local VIBRATION_COOLDOWN_TICKS = 40
local DARKNESS_RADIUS = 20
local DARKNESS_INTERVAL = 120
local ANGERMANAGEMENT_TICK_DELAY = 20
local DEFAULT_ANGER = 35
local PROJECTILE_ANGER = 10
local ON_HURT_ANGER_BOOST = 20
local RECENT_PROJECTILE_TICK_THRESHOLD = 100
local TOUCH_COOLDOWN_TICKS = 20
local PROJECTILE_ANGER_DISTANCE = 30
local FOLLOW_RANGE = 24
local GAME_EVENT_LISTENER_RANGE = 16

-- WardenAi
local SPEED_MULTIPLIER_WHEN_IDLING = 0.5
local SPEED_MULTIPLIER_WHEN_INVESTIGATING = 0.7
local SPEED_MULTIPLIER_WHEN_FIGHTING = 1.2
local MELEE_ATTACK_COOLDOWN = 18
local DIGGING_DURATION = 100
local EMERGE_DURATION = 134
local ROAR_DURATION = 84
local SNIFFING_DURATION = 84
local DIGGING_COOLDOWN = 1200
local DISTURBANCE_LOCATION_EXPIRY_TIME = 100

-- SonicBoom
local SONIC_BOOM_DISTANCE_XZ = 15
local SONIC_BOOM_DISTANCE_Y = 20
local SONIC_BOOM_KNOCKBACK_VERTICAL = 0.5
local SONIC_BOOM_KNOCKBACK_HORIZONTAL = 2.5
local SONIC_BOOM_COOLDOWN = 40
local SONIC_BOOM_TICKS_BEFORE_SOUND = 34
local SONIC_BOOM_DURATION = 60

-- Roar
local TICKS_BEFORE_PLAYING_ROAR_SOUND = 25
local ROAR_ANGER_INCREASE = 20

-- Sniffing
local ANGER_FROM_SNIFFING_MAX_DISTANCE_XZ = 6
local ANGER_FROM_SNIFFING_MAX_DISTANCE_Y = 20

-- EntityTypes.WARDEN: 0.9 x 2.9, eyes at 0.85 of the height, chest at 1.6
local HEIGHT = 2.9
local EYE_HEIGHT = 0.85 * HEIGHT
local CHEST_HEIGHT = 1.6

local function game_time()
	return mcl_redstone.get_game_time()
end

-- damage_type/sonic_boom.json: #bypasses_armor, #bypasses_enchantments,
-- scaling "always"
mcl_damage.register_type("sonic_boom", {bypasses_armor = true, bypasses_magic = true, scales = true})

local function play(self, event, volume, pitch)
	mcl_mcsounds.play(event, {object = self.object}, volume, pitch, true)
end

-- Mob.getVoicePitch
local function voice_pitch()
	return (random() - random()) * 0.2 + 1.0
end

------------------------------------------------------------------------
-- AngerLevel
------------------------------------------------------------------------

local CALM, AGITATED, ANGRY = 0, 40, 80
local ANGER_SOUNDS = {
	[CALM] = {ambient = "entity.warden.ambient", listening = "entity.warden.listening"},
	[AGITATED] = {ambient = "entity.warden.agitated", listening = "entity.warden.listening_angry"},
	[ANGRY] = {ambient = "entity.warden.angry", listening = "entity.warden.listening_angry"},
}

local function anger_level(anger)
	if anger >= ANGRY then
		return ANGRY
	elseif anger >= AGITATED then
		return AGITATED
	end
	return CALM
end

------------------------------------------------------------------------
-- Entities
------------------------------------------------------------------------

local function is_valid(obj)
	return obj ~= nil and obj:get_pos() ~= nil
end

local function is_living(obj)
	if obj:is_player() then
		return true
	end
	local le = obj:get_luaentity()
	return le ~= nil and le.is_mob == true
end

local function is_dead(obj)
	if obj:is_player() then
		return obj:get_hp() <= 0
	end
	local le = obj:get_luaentity()
	return le == nil or le.dead or (le.health or 1) <= 0
end

local function entity_name(obj)
	local le = obj:get_luaentity()
	return le and le.name
end

-- The object's eyes (Entity.getEyePosition)
local function eye_pos(obj)
	local p = obj:get_pos()
	return vector.offset(p, 0, mcl_util.target_eye_height(obj), 0)
end

-- Entity.closerThan(entity, horizontal, vertical)
local function closer_than(a, b, xz, y)
	local dx, dz = a.x - b.x, a.z - b.z
	return dx * dx + dz * dz < xz * xz and abs(a.y - b.y) < y
end

------------------------------------------------------------------------
-- Brain memories: value and expiry game time (nil = no expiry)
------------------------------------------------------------------------

local function mem_has(self, name)
	local m = self._mem[name]
	if not m then
		return false
	end
	if m.expiry and m.expiry <= game_time() then
		self._mem[name] = nil
		return false
	end
	return true
end

local function mem_get(self, name)
	if mem_has(self, name) then
		return self._mem[name].value
	end
	return nil
end

local function mem_set(self, name, value, ttl)
	if value == nil then
		self._mem[name] = nil
		return
	end
	self._mem[name] = {value = value, expiry = ttl and game_time() + ttl or nil}
end

local function mem_erase(self, name)
	self._mem[name] = nil
end

-- Memories of entities forget them when they become invalid
local ENTITY_MEMORIES = {
	attack_target = true, roar_target = true, nearest_attackable = true,
}

-- Brain.forgetOutdatedMemories
local function forget_outdated(self)
	local t = game_time()
	for name, m in pairs(self._mem) do
		if (m.expiry and m.expiry <= t)
				or (ENTITY_MEMORIES[name] and not is_valid(m.value)) then
			self._mem[name] = nil
		end
	end
end

-- Memories saved with the warden (Brain codec: the ones with codecs)
local SAVED_MEMORIES = {
	dig_cooldown = true, is_emerging = true, sniff_cooldown = true,
	vibration_cooldown = true, touch_cooldown = true, recent_projectile = true,
	sonic_boom_cooldown = true, disturbance_location = true,
}

------------------------------------------------------------------------
-- AngerManagement
------------------------------------------------------------------------

local function anger_key(obj)
	if obj:is_player() then
		return "player:" .. obj:get_player_name()
	end
	local le = obj:get_luaentity()
	return le and le._uuid and ("mob:" .. le._uuid) or nil
end

local function new_anger_management()
	return {suspects = {}, anger = {}, by_key = {}, highest = 0}
end

local function sort_suspects(am)
	local anger = am.anger
	table.sort(am.suspects, function(a, b)
		local a1, a2 = anger[a] or 0, anger[b] or 0
		local angry1, angry2 = a1 >= ANGRY, a2 >= ANGRY
		if angry1 ~= angry2 then
			return angry1
		end
		local p1, p2 = a:is_player(), b:is_player()
		if p1 ~= p2 then
			return p1
		end
		return a1 > a2
	end)
	-- sortAndUpdateHighestAnger: the Sorter records the largest anger
	-- it compares; with one suspect, that suspect's anger
	local highest = 0
	for _, s in ipairs(am.suspects) do
		highest = max(highest, anger[s] or 0)
	end
	am.highest = highest
end

local function am_remove(am, obj)
	am.anger[obj] = nil
	for i, s in ipairs(am.suspects) do
		if s == obj then
			table.remove(am.suspects, i)
			break
		end
	end
end

-- AngerManagement.increaseAnger
local function increase_anger(am, obj, amount)
	local new_suspect = am.anger[obj] == nil
	local current = min(150, (am.anger[obj] or 0) + amount)
	if new_suspect then
		local key = anger_key(obj)
		if key and am.by_key[key] then
			current = current + am.by_key[key]
			am.by_key[key] = nil
		end
		table.insert(am.suspects, obj)
	end
	am.anger[obj] = current
	sort_suspects(am)
	return current
end

local function clear_anger(am, obj)
	am_remove(am, obj)
	sort_suspects(am)
end

-- AngerManagement.tick (every ANGERMANAGEMENT_TICK_DELAY ticks)
local function am_tick(am, valid)
	-- convertFromUuids: players who came back
	for key, anger in pairs(am.by_key) do
		local name = key:match("^player:(.*)$")
		local obj = name and core.get_player_by_name(name)
		if obj then
			am.anger[obj] = anger
			table.insert(am.suspects, obj)
			am.by_key[key] = nil
		end
	end
	for key, anger in pairs(am.by_key) do
		if anger <= 1 then
			am.by_key[key] = nil
		else
			am.by_key[key] = anger - 1
		end
	end
	for _, obj in ipairs(table.copy(am.suspects)) do
		local anger = am.anger[obj] or 0
		local removed = not is_valid(obj)
		if anger > 1 and not removed and valid(obj) then
			am.anger[obj] = anger - 1
		else
			am_remove(am, obj)
			-- UNLOADED_WITH_PLAYER etc.: remembered by player name
			if anger > 1 and removed then
				-- the key of an invalid ObjectRef is unknown
			elseif anger > 1 and obj:is_player() and not removed and not valid(obj) then
				-- invalid (e.g. creative), forgotten like Minecraft
			end
		end
	end
	sort_suspects(am)
end

local function am_active_anger(am, target)
	if not target then
		return am.highest
	end
	return am.anger[target] or 0
end

------------------------------------------------------------------------
-- The warden
------------------------------------------------------------------------

local warden = {
	description = S("Warden"),
	type = "monster",
	_spawn_category = "monster",
	spawn_class = "hostile",
	hp_min = 500,
	hp_max = 500,
	xp_min = 5,
	xp_max = 5,
	armor = {fleshy = 100},
	collisionbox = {-0.45, 0, -0.45, 0.45, HEIGHT, 0.45},
	visual = "mesh",
	mesh = "mobs_mc_warden.glb",
	textures = {{
		"mobs_mc_warden.png",
		"mobs_mc_warden_bioluminescent_layer.png",
		"mobs_mc_warden_pulsating_spots_1.png",
		"mobs_mc_warden_pulsating_spots_2.png",
		"mobs_mc_warden.png",
		"mobs_mc_warden_heart.png",
	}},
	visual_size = {x = 1, y = 1},
	head_eye_height = EYE_HEIGHT,
	makes_footstep_sound = false,
	sounds = {},
	animation = {},
	-- Attributes: MOVEMENT_SPEED 0.3, KNOCKBACK_RESISTANCE 1,
	-- ATTACK_DAMAGE 30, ATTACK_KNOCKBACK 1.5, FOLLOW_RANGE 24
	movement_speed = 0.3 * 20,
	knockback_resistance = 1.0,
	damage = 30,
	_attack_knockback = 1.5,
	view_range = FOLLOW_RANGE,
	tracking_distance = FOLLOW_RANGE,
	stepheight = 1.01,
	floats = 1,
	fire_resistant = true,
	can_despawn = false,
	persist_in_peaceful = false,
	can_ride_cart = false,
	can_ride_boat = false,
	_dampens_vibrations = true,
	drops = {
		{name = "mcl_sculk:catalyst", chance = 1, min = 1, max = 1},
	},
	-- Warden(): pathfinding maluses
	gwp_penalties = table.merge(mob_class.gwp_penalties, {
		UNPASSABLE_RAIL = 0.0,
		DAMAGE_OTHER = 8.0,
		POWDER_SNOW = 8.0,
		LAVA = 8.0,
		DAMAGE_FIRE = 0.0,
		DANGER_FIRE = 0.0,
	}),
}

------------------------------------------------------------------------
-- Pose and client state
------------------------------------------------------------------------

local function is_digging_or_emerging(self)
	return self._pose == "digging" or self._pose == "emerging"
end

local function send_state(self)
	local s = self._sent_state or {}
	local new = {
		pose = self._pose,
		anger = self._client_anger or 0,
		head_yaw = self._client_head_yaw or 0,
		look_pitch = self._client_pitch or 0,
		dead = self.dead or false,
	}
	if s.pose ~= new.pose or s.anger ~= new.anger or s.dead ~= new.dead
			or abs((s.head_yaw or 0) - new.head_yaw) > 0.005
			or abs((s.look_pitch or 0) - new.look_pitch) > 0.005 then
		self.object:set_animation_state(new)
		self._sent_state = new
	end
end

-- Entity.setPose; dimensions: 1.0 high while digging or emerging
local function set_pose(self, pose)
	if self._pose == pose then
		return
	end
	self._pose = pose
	local h = (pose == "digging" or pose == "emerging") and 1.0 or HEIGHT
	self.collisionbox = {-0.45, 0, -0.45, 0.45, h, 0.45}
	self.object:set_properties({
		collisionbox = self.collisionbox,
		selectionbox = self.collisionbox,
	})
	self._pose_start = game_time()
	send_state(self)
end

local function entity_event(self, id)
	-- Engines without Minecraft entity events (ObjectRef:entity_event)
	-- just don't show the animation
	if self.object.entity_event then
		self.object:entity_event(id)
	end
end

------------------------------------------------------------------------
-- Targets (Warden.canTargetEntity)
------------------------------------------------------------------------

local function can_target_entity(self, obj)
	if not is_valid(obj) or obj == self.object or not is_living(obj) then
		return false
	end
	if obj:is_player() then
		local name = obj:get_player_name()
		if core.is_creative_enabled(name) or G.is_spectator(obj) then
			return false
		end
		if mcl_mobs.invisible and mcl_mobs.invisible[name] then
			return true
		end
	else
		local n = entity_name(obj)
		if n == "mobs_mc:warden" or n == "mcl_armor_stand:armor_stand" then
			return false
		end
		-- LivingEntity.isInvulnerable (the Invulnerable flag; Mineclonia
		-- mobs all have the immortal armor group, their damage is Lua's)
		local le = obj:get_luaentity()
		if le and le._invulnerable then
			return false
		end
	end
	if is_dead(obj) then
		return false
	end
	return true
end

local function get_target(self)
	return mem_get(self, "attack_target")
end

local function active_anger(self)
	return am_active_anger(self._anger, get_target(self))
end

local function current_anger_level(self)
	return anger_level(active_anger(self))
end

-- Warden.getEntityAngryAt
local function entity_angry_at(self)
	if current_anger_level(self) == ANGRY then
		for _, s in ipairs(self._anger.suspects) do
			if can_target_entity(self, s) then
				return s
			end
		end
	end
	return nil
end

local function has_dig_cooldown(self)
	return mem_has(self, "dig_cooldown")
end

-- WardenAi.setDigCooldown
local function set_dig_cooldown(self)
	if has_dig_cooldown(self) then
		mem_set(self, "dig_cooldown", true, DIGGING_COOLDOWN)
	end
end

-- SonicBoom.setCooldown
local function set_sonic_boom_cooldown(self, ticks)
	mem_set(self, "sonic_boom_cooldown", true, ticks)
end

-- Warden.setAttackTarget
local function set_attack_target(self, target)
	mem_erase(self, "roar_target")
	mem_set(self, "attack_target", target)
	mem_erase(self, "cant_reach_walk_target_since")
	set_sonic_boom_cooldown(self, 200)
end

-- Warden.playListeningSound
local function play_listening_sound(self)
	if self._pose ~= "roaring" then
		play(self, ANGER_SOUNDS[current_anger_level(self)].listening, 10.0, voice_pitch())
	end
end

-- Warden.increaseAngerAt
local function increase_anger_at(self, obj, amount, play_sound)
	if amount == nil then
		amount, play_sound = DEFAULT_ANGER, true
	end
	if not can_target_entity(self, obj) then
		return
	end
	set_dig_cooldown(self)
	local target = get_target(self)
	local maybe_switch = not (target and target:is_player())
	local new_anger = increase_anger(self._anger, obj, amount)
	if obj:is_player() and maybe_switch and new_anger >= ANGRY then
		mem_erase(self, "attack_target")
	end
	if play_sound then
		play_listening_sound(self)
	end
end

-- WardenAi.setDisturbanceLocation
local function set_disturbance_location(self, pos)
	if entity_angry_at(self) or mem_has(self, "attack_target") then
		return
	end
	set_dig_cooldown(self)
	pos = vector.round(pos)
	mem_set(self, "sniff_cooldown", true, 100)
	mem_set(self, "look_target", {pos = pos}, 100)
	mem_set(self, "disturbance_location", pos, DISTURBANCE_LOCATION_EXPIRY_TIME)
	mem_erase(self, "walk_target")
end

------------------------------------------------------------------------
-- Vibrations (Warden.VibrationUser)
------------------------------------------------------------------------

local function make_vibration_user(self)
	local user = {
		radius = GAME_EVENT_LISTENER_RANGE,
		listenable = G.tags.warden_can_listen,
		can_trigger_avoid_vibration = true,
	}
	function user:get_position()
		if not is_valid(self.mob.object) then
			return nil
		end
		-- EntityPositionSource(warden, eye height)
		return vector.offset(self.mob.object:get_pos(), 0, EYE_HEIGHT, 0)
	end
	function user:can_receive(_, _, ctx)
		local w = self.mob
		if w.dead or mem_has(w, "vibration_cooldown") or is_digging_or_emerging(w) then
			return false
		end
		local src = ctx.source
		if src and is_valid(src) and is_living(src) and not can_target_entity(w, src) then
			return false
		end
		return true
	end
	function user:on_receive(pos, _, source, projectile_owner)
		local w = self.mob
		if w.dead then
			return
		end
		mem_set(w, "vibration_cooldown", true, VIBRATION_COOLDOWN_TICKS)
		entity_event(w, 61)
		play(w, "entity.warden.tendril_clicks", 5.0, voice_pitch())
		local suspicious = pos
		local wpos = w.object:get_pos()
		if projectile_owner then
			if vector.distance(wpos, projectile_owner:get_pos()) < PROJECTILE_ANGER_DISTANCE then
				if mem_has(w, "recent_projectile") then
					if can_target_entity(w, projectile_owner) then
						suspicious = vector.round(projectile_owner:get_pos())
					end
					increase_anger_at(w, projectile_owner)
				else
					increase_anger_at(w, projectile_owner, PROJECTILE_ANGER, true)
				end
			end
			mem_set(w, "recent_projectile", true, RECENT_PROJECTILE_TICK_THRESHOLD)
		elseif source then
			increase_anger_at(w, source)
		end
		if current_anger_level(w) ~= ANGRY then
			local active
			for _, s in ipairs(w._anger.suspects) do
				if can_target_entity(w, s) then
					active = s
					break
				end
			end
			if projectile_owner or not active or active == source then
				set_disturbance_location(w, suspicious)
			end
		end
	end
	user.mob = self
	return user
end

------------------------------------------------------------------------
-- Sensors: NearestLivingEntitySensor / WardenEntitySensor (every 20 ticks)
------------------------------------------------------------------------

local function sense(self)
	local pos = self.object:get_pos()
	local list = {}
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 16 * sqrt(2) + 1)) do
		if obj ~= self.object and is_living(obj) and not is_dead(obj) then
			local p = obj:get_pos()
			-- getBoundingBox().inflate(16, 16, 16)
			if abs(p.x - pos.x) <= 16.45 and abs(p.z - pos.z) <= 16.45
					and p.y >= pos.y - 16 and p.y <= pos.y + HEIGHT + 16 then
				table.insert(list, {obj = obj, d = vector.distance(pos, p)})
			end
		end
	end
	table.sort(list, function(a, b) return a.d < b.d end)
	local nearest, visible = {}, {}
	for _, e in ipairs(list) do
		table.insert(nearest, e.obj)
		-- Sensor.isEntityTargetable: within follow range and seen
		if e.d <= FOLLOW_RANGE and self:target_visible(pos, e.obj) then
			table.insert(visible, e.obj)
		end
	end
	mem_set(self, "nearest_living_entities", nearest)
	mem_set(self, "nearest_visible_living_entities", visible)
	-- WardenEntitySensor: the closest targetable player, else any
	local attackable
	for _, o in ipairs(nearest) do
		if o:is_player() and can_target_entity(self, o) then
			attackable = o
			break
		end
	end
	if not attackable then
		for _, o in ipairs(nearest) do
			if not o:is_player() and can_target_entity(self, o) then
				attackable = o
				break
			end
		end
	end
	if attackable then
		mem_set(self, "nearest_attackable", attackable)
	else
		mem_erase(self, "nearest_attackable")
	end
end

local function is_visible(self, obj)
	for _, o in ipairs(mem_get(self, "nearest_visible_living_entities") or {}) do
		if o == obj then
			return true
		end
	end
	return false
end

------------------------------------------------------------------------
-- Walk targets (MoveToTargetSink) and looking (LookControl)
------------------------------------------------------------------------

local function walk_target_pos(wt)
	if wt.object then
		if not is_valid(wt.object) then
			return nil
		end
		return wt.object:get_pos()
	end
	return wt.pos
end

-- BehaviorUtils.setWalkAndLookTargetMemories
local function set_walk_and_look(self, pos, speed, close_enough)
	mem_set(self, "walk_target", {pos = vector.copy(pos), speed = speed, close = close_enough})
	mem_set(self, "look_target", {pos = vector.copy(pos)})
end

local function look_target_pos(lt)
	if lt.object then
		if not is_valid(lt.object) then
			return nil
		end
		return eye_pos(lt.object)
	end
	-- BlockPosTracker: the center of the block
	return lt.pos
end

-- MoveToTargetSink.isWalkTargetSpecifiedAndReached
local function walk_target_reached(self, wt)
	local p = walk_target_pos(wt)
	if not p then
		return true
	end
	local a = vector.round(self.object:get_pos())
	local b = vector.round(p)
	return abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z) <= wt.close
end

------------------------------------------------------------------------
-- Behaviours. A behaviour is a table {name, start(self), tick(self),
-- stop(self), can_still_use(self), check(self) (start conditions incl.
-- memories), min, max (duration; nil for one-shot behaviours)}.
------------------------------------------------------------------------

local B = {}

-- SetWardenLookTarget
B.set_warden_look_target = {
	check = function(self)
		return not mem_has(self, "attack_target")
	end,
	start = function(self)
		local roar = mem_get(self, "roar_target")
		local target = roar and vector.round(roar:get_pos()) or mem_get(self, "disturbance_location")
		if target then
			mem_set(self, "look_target", {pos = target})
		end
	end,
}

-- LookAtTargetSink(45, 90)
B.look_at_target_sink = {
	min = 45, max = 90,
	check = function(self)
		return mem_has(self, "look_target")
	end,
	can_still_use = function(self)
		local lt = mem_get(self, "look_target")
		if not lt then
			return false
		end
		if lt.object then
			return is_valid(lt.object) and is_visible(self, lt.object)
		end
		return true
	end,
	tick = function(self)
		local lt = mem_get(self, "look_target")
		if lt then
			self._look_at = look_target_pos(lt)
		end
	end,
	stop = function(self)
		mem_erase(self, "look_target")
	end,
}

-- MoveToTargetSink (path navigation to WALK_TARGET)
B.move_to_target_sink = {
	min = 150, max = 250,
	check = function(self)
		if (self._move_cooldown or 0) > 0 then
			self._move_cooldown = self._move_cooldown - 1
			return false
		end
		local wt = mem_get(self, "walk_target")
		if not wt then
			return false
		end
		if walk_target_reached(self, wt) then
			mem_erase(self, "walk_target")
			mem_erase(self, "cant_reach_walk_target_since")
			return false
		end
		local p = walk_target_pos(wt)
		if p and self:gopath(p, wt.speed, nil, wt.close) then
			self._walk_last_target = vector.copy(p)
			mem_erase(self, "cant_reach_walk_target_since")
			return true
		end
		mem_erase(self, "walk_target")
		if not mem_has(self, "cant_reach_walk_target_since") then
			mem_set(self, "cant_reach_walk_target_since", game_time())
		end
		return false
	end,
	can_still_use = function(self)
		local wt = mem_get(self, "walk_target")
		return wt ~= nil and not walk_target_reached(self, wt)
			and (self:is_navigating() or self.pathfinding_context ~= nil)
	end,
	tick = function(self)
		local wt = mem_get(self, "walk_target")
		local p = wt and walk_target_pos(wt)
		if p and self._walk_last_target and vector.distance(p, self._walk_last_target) > 4.0 then
			-- The target moved: a new path
			if self:gopath(p, wt.speed, nil, wt.close) then
				self._walk_last_target = vector.copy(p)
			end
		end
	end,
	stop = function(self)
		local wt = mem_get(self, "walk_target")
		if wt and not walk_target_reached(self, wt) and not self:is_navigating() then
			self._move_cooldown = random(0, 39)
		end
		self:cancel_navigation()
		self:halt_in_tracks()
	end,
}

-- Emerging(EMERGE_DURATION)
B.emerging = {
	min = EMERGE_DURATION, max = EMERGE_DURATION,
	check = function(self)
		return mem_has(self, "is_emerging") and not mem_has(self, "walk_target")
	end,
	can_still_use = function() return true end,
	start = function(self)
		set_pose(self, "emerging")
		play(self, "entity.warden.emerge", 5.0, 1.0)
	end,
	stop = function(self)
		if self._pose == "emerging" then
			set_pose(self, "standing")
		end
	end,
}

-- ForceUnmount
B.force_unmount = {
	check = function(self)
		return self.object:get_attach() ~= nil
	end,
	start = function(self)
		self.object:set_detach()
	end,
}

-- Digging(DIGGING_DURATION)
B.digging = {
	min = DIGGING_DURATION, max = DIGGING_DURATION,
	check = function(self)
		if mem_has(self, "attack_target") or mem_has(self, "walk_target") then
			return false
		end
		return self:standing_on_walkable() or (self._immersion_depth or 0) > 0
	end,
	can_still_use = function(self)
		return not self._removed_by_digging
	end,
	start = function(self)
		if self:standing_on_walkable() then
			set_pose(self, "digging")
			play(self, "entity.warden.dig", 5.0, 1.0)
		else
			play(self, "entity.warden.agitated", 5.0, 1.0)
			self._dig_stop_now = true
		end
	end,
	stop = function(self)
		-- Entity.remove(DISCARDED)
		self._removed_by_digging = true
		self:safe_remove()
	end,
}

-- SetRoarTarget(Warden::getEntityAngryAt)
B.set_roar_target = {
	check = function(self)
		return not mem_has(self, "roar_target") and not mem_has(self, "attack_target")
	end,
	start = function(self)
		local target = entity_angry_at(self)
		if target and can_target_entity(self, target) then
			mem_set(self, "roar_target", target)
			mem_erase(self, "cant_reach_walk_target_since")
		end
	end,
}

-- TryToSniff
B.try_to_sniff = {
	check = function(self)
		return not mem_has(self, "sniff_cooldown") and mem_has(self, "nearest_attackable")
			and not mem_has(self, "disturbance_location")
	end,
	start = function(self)
		mem_set(self, "is_sniffing", true)
		mem_set(self, "sniff_cooldown", true, random(100, 200))
		mem_erase(self, "walk_target")
		set_pose(self, "sniffing")
	end,
}

-- RandomStroll.stroll(0.5): LandRandomPos.getPos(mob, 10, 7)
B.random_stroll = {
	check = function(self)
		return not mem_has(self, "walk_target")
	end,
	start = function(self)
		local pos = self:land_random_pos(self.object:get_pos(), 10, 7)
		if pos then
			mem_set(self, "walk_target", {pos = pos, speed = SPEED_MULTIPLIER_WHEN_IDLING, close = 0})
			return true
		end
		return false
	end,
}

-- DoNothing(30, 60)
B.do_nothing = {
	min = 30, max = 60,
	check = function() return true end,
	can_still_use = function() return true end,
}

-- RunOne({IS_SNIFFING absent}, [(stroll, 2), (DoNothing, 1)])
B.idle_run_one = {
	check = function(self)
		return not mem_has(self, "is_sniffing")
	end,
	start = function(self)
		-- GateBehavior with RANDOM order: weighted shuffle, the first that
		-- starts runs
		local order
		if random() * 3 < 2 then
			order = {B.random_stroll, B.do_nothing}
		else
			order = {B.do_nothing, B.random_stroll}
		end
		for _, b in ipairs(order) do
			if b.check(self) then
				if b.min then
					self._gate_child = b
					self._gate_end = game_time() + random(b.min, b.max)
					return true
				else
					if b.start(self) ~= false then
						return true
					end
				end
			end
		end
		return false
	end,
	min = 1, max = 1,
	can_still_use = function(self)
		return self._gate_child ~= nil and game_time() <= (self._gate_end or 0)
	end,
	stop = function(self)
		self._gate_child = nil
	end,
}

-- GoToTargetLocation.create(DISTURBANCE_LOCATION, 2, 0.7)
B.go_to_disturbance = {
	check = function(self)
		return not mem_has(self, "walk_target") and mem_has(self, "disturbance_location")
	end,
	start = function(self)
		local target = mem_get(self, "disturbance_location")
		local pos = vector.round(self.object:get_pos())
		-- BlockPos.closerThan: distSqr < 2^2
		local d2 = (target.x - pos.x) ^ 2 + (target.y - pos.y) ^ 2 + (target.z - pos.z) ^ 2
		if d2 >= 4 then
			local p = vector.new(target.x + random(-1, 1), target.y, target.z + random(-1, 1))
			set_walk_and_look(self, p, SPEED_MULTIPLIER_WHEN_INVESTIGATING, 2)
		end
	end,
}

-- Sniffing(SNIFFING_DURATION)
B.sniffing = {
	min = SNIFFING_DURATION, max = SNIFFING_DURATION,
	check = function(self)
		return mem_has(self, "is_sniffing") and not mem_has(self, "attack_target")
			and not mem_has(self, "walk_target")
	end,
	can_still_use = function() return true end,
	start = function(self)
		play(self, "entity.warden.sniff", 5.0, 1.0)
	end,
	stop = function(self)
		if self._pose == "sniffing" then
			set_pose(self, "standing")
		end
		mem_erase(self, "is_sniffing")
		local e = mem_get(self, "nearest_attackable")
		if e and can_target_entity(self, e) then
			if closer_than(self.object:get_pos(), e:get_pos(),
					ANGER_FROM_SNIFFING_MAX_DISTANCE_XZ, ANGER_FROM_SNIFFING_MAX_DISTANCE_Y) then
				increase_anger_at(self, e)
			end
			if not mem_has(self, "disturbance_location") then
				set_disturbance_location(self, e:get_pos())
			end
		end
	end,
}

-- Roar
B.roar = {
	min = ROAR_DURATION, max = ROAR_DURATION,
	check = function(self)
		return mem_has(self, "roar_target") and not mem_has(self, "attack_target")
	end,
	can_still_use = function() return true end,
	start = function(self)
		mem_set(self, "roar_sound_delay", true, TICKS_BEFORE_PLAYING_ROAR_SOUND)
		mem_erase(self, "walk_target")
		local target = mem_get(self, "roar_target")
		-- BehaviorUtils.lookAtEntity
		mem_set(self, "look_target", {object = target})
		set_pose(self, "roaring")
		increase_anger_at(self, target, ROAR_ANGER_INCREASE, false)
	end,
	tick = function(self)
		if not mem_has(self, "roar_sound_delay") and not mem_has(self, "roar_sound_cooldown") then
			mem_set(self, "roar_sound_cooldown", true, ROAR_DURATION - TICKS_BEFORE_PLAYING_ROAR_SOUND)
			play(self, "entity.warden.roar", 3.0, 1.0)
		end
	end,
	stop = function(self)
		if self._pose == "roaring" then
			set_pose(self, "standing")
		end
		local target = mem_get(self, "roar_target")
		if target then
			set_attack_target(self, target)
		end
		mem_erase(self, "roar_target")
	end,
}

-- WardenAi.DIG_COOLDOWN_SETTER
B.dig_cooldown_setter = {
	check = function() return true end,
	start = function(self)
		if mem_has(self, "dig_cooldown") then
			mem_set(self, "dig_cooldown", true, DIGGING_COOLDOWN)
		end
	end,
}

-- WardenAi.onTargetInvalid
local function on_target_invalid(self, target)
	if not can_target_entity(self, target) then
		clear_anger(self._anger, target)
	end
	set_dig_cooldown(self)
end

-- StopAttackingIfTargetInvalid.create(!angry || !canTarget, onTargetInvalid, false)
B.stop_attacking_if_invalid = {
	check = function(self)
		return mem_has(self, "attack_target")
	end,
	start = function(self)
		local target = mem_get(self, "attack_target")
		if not can_target_entity(self, target) or is_dead(target)
				or current_anger_level(self) ~= ANGRY then
			on_target_invalid(self, target)
			mem_erase(self, "attack_target")
		end
	end,
}

-- SetEntityLookTarget.create(isTarget, FOLLOW_RANGE)
B.set_entity_look_target = {
	check = function(self)
		return not mem_has(self, "look_target") and mem_has(self, "nearest_visible_living_entities")
	end,
	start = function(self)
		local target = mem_get(self, "attack_target")
		local pos = self.object:get_pos()
		for _, o in ipairs(mem_get(self, "nearest_visible_living_entities")) do
			if o == target and vector.distance(o:get_pos(), pos) <= FOLLOW_RANGE then
				mem_set(self, "look_target", {object = o})
				return
			end
		end
	end,
}

-- SetWalkTargetFromAttackTargetIfTargetOutOfReach.create(1.2)
B.walk_to_attack_target = {
	check = function(self)
		return mem_has(self, "attack_target")
	end,
	start = function(self)
		local target = mem_get(self, "attack_target")
		if self:within_melee_range(target) and is_visible(self, target) then
			mem_erase(self, "walk_target")
		else
			mem_set(self, "look_target", {object = target})
			mem_set(self, "walk_target", {object = target, speed = SPEED_MULTIPLIER_WHEN_FIGHTING, close = 0})
		end
	end,
}

-- Mob.doHurtTarget for the warden
local function do_hurt_target(self, target)
	entity_event(self, 4)
	play(self, "entity.warden.attack_impact", 10.0, voice_pitch())
	set_sonic_boom_cooldown(self, SONIC_BOOM_COOLDOWN)
	self.attack = target
	local hp = mcl_util.get_hp(target)
	self:custom_attack()
	-- Mob.doHurtTarget: knockback ATTACK_KNOCKBACK * 0.5 along the yaw,
	-- shields disabled for getSecondsToDisableBlocking (5 s)
	if is_valid(target) and mcl_util.get_hp(target) < hp then
		local yaw = self:get_yaw()
		local kb = self._attack_knockback * 0.5
		local resist = 0
		local tle = target:get_luaentity()
		if tle and tle.knockback_resistance then
			resist = tle.knockback_resistance
		end
		local strength = kb * (1 - resist)
		if strength > 0 then
			-- LivingEntity.knockback(strength, sin(yRot), -cos(yRot)), in
			-- blocks per tick to nodes per second
			local dir = vector.new(-math.sin(yaw), 0, math.cos(yaw))
			local v = target:get_velocity() or vector.zero()
			target:add_velocity(vector.new(dir.x * strength * 20 - v.x * 0.5, 0, dir.z * strength * 20 - v.z * 0.5))
		end
		if target:is_player() and mcl_shields and mcl_shields.disable_shield then
			mcl_shields.disable_shield(target, 5)
		end
	end
end

-- MeleeAttack.create(18)
B.melee_attack = {
	check = function(self)
		return mem_has(self, "attack_target") and not mem_has(self, "attack_cooling_down")
			and mem_has(self, "nearest_visible_living_entities")
	end,
	start = function(self)
		local target = mem_get(self, "attack_target")
		if self:within_melee_range(target) and is_visible(self, target) then
			mem_set(self, "look_target", {object = target})
			do_hurt_target(self, target)
			mem_set(self, "attack_cooling_down", true, MELEE_ATTACK_COOLDOWN)
		end
	end,
}

local function sonic_boom_particle(pos)
	for _, player in ipairs(core.get_connected_players()) do
		if vector.distance(player:get_pos(), pos) <= 32 then
			-- SonicBoomParticle (HugeExplosionParticle): 16 ticks,
			-- quadSize 1.5, full bright
			core.add_particle({
				playername = player:get_player_name(),
				pos = pos,
				expirationtime = 0.8,
				size = 1.5 * 20,
				texture = "mobs_mc_sonic_boom.png",
				animation = {type = "vertical_frames", aspect_w = 32, aspect_h = 32, length = 0.8},
				glow = 15,
			})
		end
	end
end

-- SonicBoom
B.sonic_boom = {
	min = SONIC_BOOM_DURATION, max = SONIC_BOOM_DURATION,
	check = function(self)
		local target = mem_get(self, "attack_target")
		return target ~= nil and not mem_has(self, "sonic_boom_cooldown")
			and closer_than(self.object:get_pos(), target:get_pos(),
				SONIC_BOOM_DISTANCE_XZ, SONIC_BOOM_DISTANCE_Y)
	end,
	can_still_use = function() return true end,
	start = function(self)
		mem_set(self, "attack_cooling_down", true, SONIC_BOOM_DURATION)
		mem_set(self, "sonic_boom_sound_delay", true, SONIC_BOOM_TICKS_BEFORE_SOUND)
		entity_event(self, 62)
		play(self, "entity.warden.sonic_charge", 3.0, 1.0)
	end,
	tick = function(self)
		local target = mem_get(self, "attack_target")
		if target then
			self._look_at = target:get_pos()
			self._look_at_now = true
		end
		if mem_has(self, "sonic_boom_sound_delay") or mem_has(self, "sonic_boom_sound_cooldown") then
			return
		end
		mem_set(self, "sonic_boom_sound_cooldown", true, SONIC_BOOM_DURATION - SONIC_BOOM_TICKS_BEFORE_SOUND)
		if not target or not can_target_entity(self, target)
				or not closer_than(self.object:get_pos(), target:get_pos(),
					SONIC_BOOM_DISTANCE_XZ, SONIC_BOOM_DISTANCE_Y) then
			return
		end
		local source = vector.offset(self.object:get_pos(), 0, CHEST_HEIGHT, 0)
		local delta = vector.subtract(eye_pos(target), source)
		local len = vector.length(delta)
		local dir = vector.normalize(delta)
		local steps = floor(len) + 7
		for i = 1, steps - 1 do
			sonic_boom_particle(vector.add(source, vector.multiply(dir, i)))
		end
		play(self, "entity.warden.sonic_boom", 3.0, 1.0)
		local hp = mcl_util.get_hp(target)
		mcl_util.deal_damage(target, 10, {type = "sonic_boom", source = self.object, direct = self.object})
		if is_valid(target) and mcl_util.get_hp(target) < hp then
			local resist = 0
			local tle = target:get_luaentity()
			if tle and tle.knockback_resistance then
				resist = tle.knockback_resistance
			end
			local v = SONIC_BOOM_KNOCKBACK_VERTICAL * (1 - resist)
			local h = SONIC_BOOM_KNOCKBACK_HORIZONTAL * (1 - resist)
			-- Entity.push, blocks per tick to nodes per second
			target:add_velocity(vector.new(dir.x * h * 20, dir.y * v * 20, dir.z * h * 20))
		end
	end,
	stop = function(self)
		set_sonic_boom_cooldown(self, SONIC_BOOM_COOLDOWN)
	end,
}

------------------------------------------------------------------------
-- Activities (WardenAi.getActivities) and the brain tick
------------------------------------------------------------------------

-- {name, behaviours by priority, requirement(self), memory erased when
-- the activity stops}
local CORE = {B.set_warden_look_target, B.look_at_target_sink, B.move_to_target_sink}
local ACTIVITIES = {
	emerge = {behaviours = {B.emerging}, valid = function(self) return mem_has(self, "is_emerging") end,
		erase = "is_emerging"},
	dig = {behaviours = {B.force_unmount, B.digging}, valid = function(self)
		return not mem_has(self, "roar_target") and not mem_has(self, "dig_cooldown")
	end},
	roar = {behaviours = {B.roar}, valid = function(self) return mem_has(self, "roar_target") end,
		erase = "roar_target"},
	fight = {behaviours = {B.dig_cooldown_setter, B.stop_attacking_if_invalid, B.set_entity_look_target,
		B.walk_to_attack_target, B.sonic_boom, B.melee_attack},
		valid = function(self) return mem_has(self, "attack_target") end, erase = "attack_target"},
	investigate = {behaviours = {B.set_roar_target, B.go_to_disturbance},
		valid = function(self) return mem_has(self, "disturbance_location") end,
		erase = "disturbance_location"},
	sniff = {behaviours = {B.set_roar_target, B.sniffing},
		valid = function(self) return mem_has(self, "is_sniffing") end, erase = "is_sniffing"},
	idle = {behaviours = {B.set_roar_target, B.try_to_sniff, B.idle_run_one},
		valid = function() return true end},
}
local ORDER = {"emerge", "dig", "roar", "fight", "investigate", "sniff", "idle"}

-- Brain.setActiveActivityToFirstValid
local function update_activity(self)
	for _, name in ipairs(ORDER) do
		if ACTIVITIES[name].valid(self) then
			if self._activity ~= name then
				local old = self._activity and ACTIVITIES[self._activity]
				if old and old.erase then
					mem_erase(self, old.erase)
				end
				self._activity = name
			end
			return
		end
	end
end

local function try_start(self, b, t)
	if self._running[b] then
		return
	end
	if b.check and not b.check(self) then
		return
	end
	if b.min then
		self._running[b] = t + random(b.min, b.max)
		if b.start then
			b.start(self)
		end
	else
		-- One-shot (BehaviorBuilder): runs once
		if b.start then
			b.start(self)
		end
	end
end

local function brain_tick(self)
	forget_outdated(self)
	-- Sensors: SensorType.NEAREST_PLAYERS and WARDEN_ENTITY_SENSOR
	self._sensor_timer = (self._sensor_timer or random(0, 19)) - 1
	if self._sensor_timer <= 0 then
		self._sensor_timer = 20
		sense(self)
	end
	local t = game_time()
	self._look_at = nil
	-- startEachNonRunningBehavior: core first, then the activity
	for _, b in ipairs(CORE) do
		try_start(self, b, t)
	end
	local act = ACTIVITIES[self._activity or "idle"]
	for _, b in ipairs(act.behaviours) do
		try_start(self, b, t)
	end
	-- tickEachRunningBehavior
	-- (table.copy would copy the behaviour tables used as keys)
	local running = {}
	for b, end_time in pairs(self._running) do
		running[#running + 1] = {b, end_time}
	end
	for _, r in ipairs(running) do
		local b, end_time = r[1], r[2]
		if t <= end_time and (not b.can_still_use or b.can_still_use(self)) and not self._dig_stop_now then
			if b.tick then
				b.tick(self)
			end
		else
			self._running[b] = nil
			if b.stop then
				b.stop(self)
			end
			if self._removed_by_digging then
				return
			end
		end
	end
	self._dig_stop_now = nil
end

------------------------------------------------------------------------
-- LookControl and BodyRotationControl
------------------------------------------------------------------------

local function rotate_towards(from, to, max_delta)
	local d = mcl_util.norm_radians(to - from)
	d = math.max(-max_delta, math.min(max_delta, d))
	return mcl_util.norm_radians(from + d)
end

local HEAD_Y_SPEED = math.rad(10)
local HEAD_X_SPEED = math.rad(40)
local MAX_HEAD_Y_ROT = math.rad(75)

local function look_step(self)
	local body = self:get_yaw()
	local head = self._head_yaw or body
	local pitch = self._head_pitch or 0
	local target = self._look_at
	if target then
		local pos = vector.offset(self.object:get_pos(), 0, EYE_HEIGHT, 0)
		local dx, dy, dz = target.x - pos.x, target.y - pos.y, target.z - pos.z
		if abs(dx) > 1e-5 or abs(dz) > 1e-5 then
			head = rotate_towards(head, math.atan2(dz, dx) - pi / 2, HEAD_Y_SPEED)
		end
		local sd = sqrt(dx * dx + dz * dz)
		pitch = rotate_towards(pitch, -math.atan2(dy, sd), HEAD_X_SPEED)
		if self._look_at_now then
			-- SonicBoom: the body turns to the target too
			self:set_yaw(rotate_towards(body, math.atan2(dz, dx) - pi / 2, HEAD_Y_SPEED))
			self._look_at_now = nil
		end
	else
		head = rotate_towards(head, body, HEAD_Y_SPEED)
		pitch = rotate_towards(pitch, 0, math.rad(5))
	end
	if self:is_navigating() then
		local d = mcl_util.norm_radians(head - body)
		head = mcl_util.norm_radians(body + math.max(-MAX_HEAD_Y_ROT, math.min(MAX_HEAD_Y_ROT, d)))
	end
	self._head_yaw = head
	self:body_rotation_step(self:brc_moving(self.object:get_pos()))
	head = self._head_yaw
	self._head_pitch = pitch
	local rel = mcl_util.norm_radians(head - self.object:get_yaw())
	self._client_head_yaw = math.max(-MAX_HEAD_Y_ROT, math.min(MAX_HEAD_Y_ROT, rel))
	self._client_pitch = -pitch
end

------------------------------------------------------------------------
-- Ticks
------------------------------------------------------------------------

-- Warden.getHeartBeatDelay
local function heart_beat_delay(anger)
	local f = math.max(0, math.min(1, anger / ANGRY))
	return 40 - floor(f * 30)
end

-- Entity.applyMovementEmission: WARDEN_STEP on each step
local function step_sounds(self)
	local pos = self.object:get_pos()
	local last = self._step_last_pos
	self._step_last_pos = pos
	if not last or not self:standing_on_walkable() then
		return
	end
	local dx, dz = pos.x - last.x, pos.z - last.z
	self._move_dist = (self._move_dist or 0) + sqrt(dx * dx + dz * dz) * 0.6
	if self._move_dist > (self._next_step_dist or 0) then
		-- Warden.nextStep: moveDist + 0.55
		self._next_step_dist = self._move_dist + 0.55
		play(self, "entity.warden.step", 10.0, 1.0)
	end
end

-- Mob.playAmbientSound timing (getAmbientSoundInterval 80)
local function ambient_sounds(self)
	if self._ambient_time == nil then
		self._ambient_time = -80
	end
	if random(0, 999) < self._ambient_time then
		self._ambient_time = -80
		if self._pose ~= "roaring" and not is_digging_or_emerging(self) then
			play(self, ANGER_SOUNDS[current_anger_level(self)].ambient, 4.0, voice_pitch())
		end
	else
		self._ambient_time = self._ambient_time + 1
	end
end

-- Block particles while digging or emerging (Warden.clientDiggingParticles)
local function digging_particles(self)
	local pos = self.object:get_pos()
	local below = core.get_node(vector.offset(pos, 0, -0.5, 0))
	local def = core.registered_nodes[below.name]
	if not def or def.drawtype == "airlike" then
		return
	end
	core.add_particlespawner({
		amount = 30,
		time = 0.05,
		minpos = vector.offset(pos, -0.7, 0, -0.7),
		maxpos = vector.offset(pos, 0.7, 0, 0.7),
		minvel = vector.new(-0.5, 0, -0.5),
		maxvel = vector.new(0.5, 1, 0.5),
		minacc = vector.new(0, -9.8, 0),
		maxacc = vector.new(0, -9.8, 0),
		minexptime = 0.2,
		maxexptime = 0.8,
		minsize = 1,
		maxsize = 2,
		node = below,
		collisiondetection = true,
	})
end

-- Warden.doPush: anger at entities touching it
local function touch_check(self)
	if mem_has(self, "touch_cooldown") then
		return
	end
	local pos = self.object:get_pos()
	for _, obj in ipairs(core.get_objects_inside_radius(pos, 2)) do
		if obj ~= self.object and is_living(obj) then
			local p = obj:get_pos()
			local cb = obj:get_properties().collisionbox
			if abs(p.x - pos.x) < 0.45 + cb[4] and abs(p.z - pos.z) < 0.45 + cb[6]
					and p.y + cb[2] < pos.y + HEIGHT and p.y + cb[5] > pos.y then
				mem_set(self, "touch_cooldown", true, TOUCH_COOLDOWN_TICKS)
				increase_anger_at(self, obj)
				set_disturbance_location(self, p)
				return
			end
		end
	end
end

-- Warden.tick + customServerAiStep, one game tick
local function warden_tick(self)
	self._tick_count = (self._tick_count or 0) + 1
	G.vibration_tick(self._vibration_data, self._vibration_user)
	G.update_listener(self._listener)
	if (self.nametag and self.nametag ~= "") or self.persistent then
		set_dig_cooldown(self)
	end
	-- Client part: heartbeat sound and digging particles
	if self._tick_count % heart_beat_delay(self._client_anger or 0) == 0 then
		play(self, "entity.warden.heartbeat", 5.0, voice_pitch())
	end
	if is_digging_or_emerging(self) and game_time() - (self._pose_start or 0) < 90 then
		digging_particles(self)
	end
	if not self.dead then
		brain_tick(self)
		if self._removed_by_digging then
			return
		end
		if (self._tick_count + self._id) % DARKNESS_INTERVAL == 0 then
			if mcl_sculk and mcl_sculk.apply_darkness_around then
				mcl_sculk.apply_darkness_around(self.object:get_pos(), self.object, DARKNESS_RADIUS)
			end
		end
		if self._tick_count % ANGERMANAGEMENT_TICK_DELAY == 0 then
			am_tick(self._anger, function(o) return can_target_entity(self, o) end)
			self._client_anger = active_anger(self)
		end
		update_activity(self)
		touch_check(self)
		ambient_sounds(self)
		step_sounds(self)
		look_step(self)
	end
	send_state(self)
end

------------------------------------------------------------------------
-- Mob hooks
------------------------------------------------------------------------

local next_id = 0

local function init(self, staticdata_tbl)
	self._mem = {}
	self._running = {}
	self._anger = new_anger_management()
	next_id = next_id + 1
	self._id = next_id
	self._pose = nil
	set_pose(self, "standing")
	local saved = staticdata_tbl and staticdata_tbl._warden
	if type(saved) == "table" then
		local t = game_time()
		for name, m in pairs(saved.mem or {}) do
			if SAVED_MEMORIES[name] then
				self._mem[name] = {value = m.value, expiry = m.ttl and t + m.ttl or nil}
			end
		end
		for key, anger in pairs(saved.anger or {}) do
			self._anger.by_key[key] = anger
		end
		if saved.pose == "emerging" and self._mem.is_emerging then
			set_pose(self, "emerging")
		end
		self._client_anger = saved.client_anger or 0
	end
	if type(saved) ~= "table" then
		-- Warden.finalizeSpawn (every spawn reason)
		mem_set(self, "dig_cooldown", true, DIGGING_COOLDOWN)
	end
	self._vibration_data = G.deserialize_vibration_data(saved and saved.listener)
	self._vibration_user = make_vibration_user(self)
	self._listener = G.new_vibration_listener(self._vibration_data, self._vibration_user)
	G.register_listener(self._listener)
	self.object:set_properties({procedural_animation = "minecraft_warden"})
	self._sent_state = nil
	send_state(self)
	self._last_tick = game_time()
end

function warden:after_activate(staticdata)
	local tbl = staticdata and staticdata ~= "" and core.deserialize(staticdata)
	init(self, type(tbl) == "table" and tbl or nil)
end

-- Runtime state that is not saved (it holds objects and functions)
local RUNTIME_FIELDS = {
	"_mem", "_running", "_anger", "_vibration_data", "_vibration_user",
	"_listener", "_sent_state", "_gate_child", "_look_at", "_step_last_pos",
	"_walk_last_target", "_last_tick", "_id",
}

function warden:get_staticdata_table()
	local tmp = mob_class.get_staticdata_table(self)
	if not tmp then
		return tmp
	end
	for _, k in ipairs(RUNTIME_FIELDS) do
		tmp[k] = nil
	end
	if self._mem then
		local t = game_time()
		local mem = {}
		for name, m in pairs(self._mem) do
			if SAVED_MEMORIES[name] and (not m.expiry or m.expiry > t) and type(m.value) ~= "userdata" then
				mem[name] = {value = m.value, ttl = m.expiry and m.expiry - t or nil}
			end
		end
		local anger = {}
		for _, s in ipairs(self._anger.suspects) do
			local key = is_valid(s) and anger_key(s)
			if key then
				anger[key] = self._anger.anger[s]
			end
		end
		for key, a in pairs(self._anger.by_key) do
			anger[key] = a
		end
		tmp._warden = {
			mem = mem, anger = anger, pose = self._pose,
			client_anger = self._client_anger,
			listener = G.serialize_vibration_data(self._vibration_data),
		}
	end
	return tmp
end

function warden:on_deactivate(removal)
	if self._listener then
		G.unregister_listener(self._listener)
	end
	return mob_class.on_deactivate(self, removal)
end

-- The brain replaces the goal-based AI
function warden:run_ai()
end

function warden:who_are_you_looking_at()
end

function warden:check_head_swivel()
end

function warden:set_animation()
end

function warden:set_animation_speed()
end

-- No falling to the side by the mob API: the client animates the death
function warden:check_dying()
	return self.dead
end

function warden:walk_target_value()
	-- Warden.getWalkTargetValue
	return 0.0
end

function warden:do_custom()
	if not self._mem then
		return
	end
	local t = game_time()
	local ticks = math.min(t - (self._last_tick or t), 4)
	self._last_tick = t
	for _ = 1, ticks do
		warden_tick(self)
		if self._removed_by_digging or not self.object:get_pos() then
			return false
		end
	end
end

-- Warden.isInvulnerableTo: digging and emerging, except for damage
-- that bypasses invulnerability
local BYPASS_INVULNERABILITY = {out_of_world = true, generic_kill = true}

function warden:receive_damage(mcl_reason, damage)
	if is_digging_or_emerging(self) and not BYPASS_INVULNERABILITY[mcl_reason.type] then
		return false
	end
	local hurt = mob_class.receive_damage(self, mcl_reason, damage)
	if not hurt or damage <= 0 then
		return hurt
	end
	if self.health > 0 then
		play(self, "entity.warden.hurt", 4.0, voice_pitch())
	end
	-- Warden.hurtServer
	if not self.dead and not is_digging_or_emerging(self) then
		local attacker = mcl_reason.source
		if attacker and is_valid(attacker) then
			increase_anger_at(self, attacker, ANGRY + ON_HURT_ANGER_BOOST, false)
			if not mem_has(self, "attack_target") and is_living(attacker)
					and (mcl_reason.direct == attacker
						or vector.distance(self.object:get_pos(), attacker:get_pos()) < 5) then
				set_attack_target(self, attacker)
			end
		end
	end
	return hurt
end

function warden:on_die()
	play(self, "entity.warden.death", 4.0, voice_pitch())
	send_state(self)
end

-- Warden.ignoreExplosion
function warden:on_blast()
	if is_digging_or_emerging(self) then
		return false, false, {}
	end
end

-- Warden.canRide
function warden:on_rightclick()
end

-- Warden.nextStep for the vibration movement tracker
function warden._next_step(move_dist)
	return move_dist + 0.55
end

mcl_mobs.register_mob("mobs_mc:warden", warden)

-- SpawnUtil / Warden.finalizeSpawn. reason "triggered" (sculk
-- shriekers) makes the warden emerge.
function mobs_mc.spawn_warden(feet, reason)
	local obj = core.add_entity(feet, "mobs_mc:warden")
	if not obj then
		return nil
	end
	local self = obj:get_luaentity()
	if not self or not self._mem then
		return obj
	end
	mem_set(self, "dig_cooldown", true, DIGGING_COOLDOWN)
	if reason == "triggered" then
		set_pose(self, "emerging")
		mem_set(self, "is_emerging", true, EMERGE_DURATION)
		play(self, "entity.warden.agitated", 5.0, 1.0)
	end
	-- SpawnUtil.trySpawnMob: playAmbientSound
	play(self, ANGER_SOUNDS[CALM].ambient, 4.0, voice_pitch())
	return obj
end

-- Natural spawns of wardens are not a thing: only shriekers summon them.
mcl_mobs.register_egg("mobs_mc:warden", S("Warden"), "#0f4649", "#39d6e0", 0)

mobs_mc.warden = {
	-- The behaviour tables (for tests and debugging)
	behaviours = B,
	increase_anger_at = increase_anger_at,
	set_disturbance_location = set_disturbance_location,
	get_anger = function(self, obj) return self._anger.anger[obj] or 0 end,
}
