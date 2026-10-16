------------------------------------------------------------------------
-- Sculk shrieker (SculkShriekerBlock + SculkShriekerBlockEntity) and the
-- players' WardenSpawnTracker
------------------------------------------------------------------------

local S = mcl_sculk.S
local R = mcl_redstone
local G = mcl_gameevent
local random = math.random

local SHRIEKING_TICKS = 90
local WARNING_SOUND_RADIUS = 10
local WARDEN_SPAWN_ATTEMPTS = 20
local WARDEN_SPAWN_RANGE_XZ = 5
local WARDEN_SPAWN_RANGE_Y = 6
local DARKNESS_RADIUS = 40
local SOUND_BY_LEVEL = {
	[1] = "entity.warden.nearby_close",
	[2] = "entity.warden.nearby_closer",
	[3] = "entity.warden.nearby_closest",
	[4] = "entity.warden.listening_angry",
}

------------------------------------------------------------------------
-- WardenSpawnTracker (one per player, saved in the player metadata)
------------------------------------------------------------------------

local MAX_WARNING_LEVEL = 4
local PLAYER_SEARCH_RADIUS = 16
local WARNING_CHECK_DIAMETER = 48
local DECREASE_WARNING_LEVEL_EVERY_INTERVAL = 12000
local WARNING_LEVEL_INCREASE_COOLDOWN = 200

local trackers = {}

local function load_tracker(player)
	local t = core.deserialize(player:get_meta():get_string("mcl_sculk:warden_spawn_tracker"))
	if type(t) ~= "table" then
		t = {}
	end
	return {
		ticks_since_last_warning = t.ticks_since_last_warning or 0,
		warning_level = t.warning_level or 0,
		cooldown_ticks = t.cooldown_ticks or 0,
	}
end

local function save_tracker(player, t)
	player:get_meta():set_string("mcl_sculk:warden_spawn_tracker", core.serialize(t))
end

local function get_tracker(player)
	local name = player:get_player_name()
	local t = trackers[name]
	if not t then
		t = load_tracker(player)
		trackers[name] = t
	end
	return t
end
mcl_sculk.get_warden_spawn_tracker = get_tracker

core.register_on_leaveplayer(function(player)
	local name = player:get_player_name()
	if trackers[name] then
		save_tracker(player, trackers[name])
		trackers[name] = nil
	end
end)

core.register_on_shutdown(function()
	for _, player in ipairs(core.get_connected_players()) do
		local t = trackers[player:get_player_name()]
		if t then
			save_tracker(player, t)
		end
	end
end)

local function set_warning_level(t, level)
	t.warning_level = math.max(0, math.min(MAX_WARNING_LEVEL, level))
end

-- WardenSpawnTracker.tick (ServerPlayer.tick)
R.register_on_game_tick(function(time)
	for _, player in ipairs(core.get_connected_players()) do
		local t = get_tracker(player)
		if t.ticks_since_last_warning >= DECREASE_WARNING_LEVEL_EVERY_INTERVAL then
			set_warning_level(t, t.warning_level - 1)
			t.ticks_since_last_warning = 0
		else
			t.ticks_since_last_warning = t.ticks_since_last_warning + 1
		end
		if t.cooldown_ticks > 0 then
			t.cooldown_ticks = t.cooldown_ticks - 1
		end
		if time % 600 == 0 then
			save_tracker(player, t)
		end
	end
end)

local function has_nearby_warden(pos)
	local half = WARNING_CHECK_DIAMETER / 2
	for _, obj in ipairs(core.get_objects_inside_radius(pos, half * math.sqrt(3))) do
		local le = obj:get_luaentity()
		if le and le.name == "mobs_mc:warden" then
			local p = obj:get_pos()
			if math.abs(p.x - pos.x) <= half and math.abs(p.y - pos.y) <= half
					and math.abs(p.z - pos.z) <= half then
				return true
			end
		end
	end
	return false
end

-- WardenSpawnTracker.tryWarn: the new warning level, or nil
local function try_warn(pos, trigger)
	if has_nearby_warden(pos) then
		return nil
	end
	local players = {}
	local have_trigger = false
	for _, player in ipairs(core.get_connected_players()) do
		if not G.is_spectator(player) and player:get_hp() > 0
				and vector.distance(player:get_pos(), pos) < PLAYER_SEARCH_RADIUS then
			table.insert(players, player)
			if player == trigger then
				have_trigger = true
			end
		end
	end
	if not have_trigger then
		table.insert(players, trigger)
	end
	local highest
	for _, player in ipairs(players) do
		local t = get_tracker(player)
		if t.cooldown_ticks > 0 then
			return nil
		end
		if not highest or t.warning_level > highest.warning_level then
			highest = t
		end
	end
	if not highest then
		return nil
	end
	-- increaseWarningLevel
	if highest.cooldown_ticks <= 0 then
		highest.ticks_since_last_warning = 0
		highest.cooldown_ticks = WARNING_LEVEL_INCREASE_COOLDOWN
		set_warning_level(highest, highest.warning_level + 1)
	end
	for _, player in ipairs(players) do
		local t = get_tracker(player)
		t.warning_level = highest.warning_level
		t.cooldown_ticks = highest.cooldown_ticks
		t.ticks_since_last_warning = highest.ticks_since_last_warning
		save_tracker(player, t)
	end
	return highest.warning_level
end

-- /warden_spawn_tracker (WardenSpawnTrackerCommand)
core.register_chatcommand("warden_spawn_tracker", {
	params = S("clear | set <warning_level>"),
	description = S("Show or change your warden spawn warning level"),
	privs = {server = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then
			return false
		end
		local t = get_tracker(player)
		local cmd, arg = param:match("^(%S*)%s*(%S*)$")
		if cmd == "clear" then
			t.ticks_since_last_warning, t.warning_level, t.cooldown_ticks = 0, 0, 0
		elseif cmd == "set" and tonumber(arg) then
			set_warning_level(t, tonumber(arg))
		end
		save_tracker(player, t)
		return true, S("Warning level: @1", t.warning_level)
	end,
})

------------------------------------------------------------------------
-- The shrieker
------------------------------------------------------------------------

-- SculkShriekerBlockEntity.tryGetPlayer
local function try_get_player(source)
	if not G.is_valid(source) then
		return nil
	end
	if source:is_player() then
		return source
	end
	-- getControllingPassenger
	for _, child in ipairs(source:get_children()) do
		if child:is_player() then
			return child
		end
	end
	local owner = G.get_projectile_owner(source)
	if owner and owner:is_player() then
		return owner
	end
	owner = G.get_item_owner(source)
	if owner and owner:is_player() then
		return owner
	end
	return nil
end
mcl_sculk.try_get_player = try_get_player

local function can_summon(node)
	return node.name == "mcl_sculk:shrieker_can_summon"
end

local function is_shrieking(pos)
	return core.get_meta(pos):get_int("shrieking") == 1
end

-- SculkShriekerBlockEntity.canRespond
local function can_respond(pos)
	return can_summon(core.get_node(pos))
		and mcl_vars.difficulty > 0
		and not core.settings:get_bool("only_peaceful_mobs", false)
		and core.settings:get_bool("mcl_spawn_wardens", true)
end

-- SpawnUtil.Strategy.ON_TOP_OF_COLLIDER
local function collision_empty(pos)
	local def = core.registered_nodes[core.get_node(pos).name]
	return not def or not def.walkable
end

local function on_top_of_collider(pos, above)
	local node = core.get_node(pos)
	return collision_empty(above) and node.name ~= "ignore"
		and R.is_face_sturdy(pos, node, R.UP, "full")
end

-- Mob.checkSpawnObstruction for a warden (0.9 x 2.9 x 0.9) standing on the
-- node below `feet`
local function warden_fits(feet)
	for x = -1, 1 do
		for y = 0, 3 do
			for z = -1, 1 do
				local p = vector.new(feet.x + x * 0.44, feet.y + 0.01 + y * 0.96, feet.z + z * 0.44)
				local node = core.get_node(vector.round(p))
				local def = core.registered_nodes[node.name]
				if not def or def.walkable or (def.liquidtype or "none") ~= "none" then
					return false
				end
			end
		end
	end
	return true
end

-- SpawnUtil.trySpawnMob(WARDEN, TRIGGERED, pos, 20, 5, 6, ON_TOP_OF_COLLIDER, false)
local function try_summon_warden(pos, warning_level)
	if warning_level < 4 then
		return false
	end
	if not mobs_mc or not mobs_mc.spawn_warden then
		return false
	end
	for _ = 1, WARDEN_SPAWN_ATTEMPTS do
		local dx = random(-WARDEN_SPAWN_RANGE_XZ, WARDEN_SPAWN_RANGE_XZ)
		local dz = random(-WARDEN_SPAWN_RANGE_XZ, WARDEN_SPAWN_RANGE_XZ)
		local search = vector.new(pos.x + dx, pos.y + WARDEN_SPAWN_RANGE_Y, pos.z + dz)
		local found = false
		for _ = WARDEN_SPAWN_RANGE_Y, -WARDEN_SPAWN_RANGE_Y, -1 do
			search.y = search.y - 1
			if on_top_of_collider(search, vector.offset(search, 0, 1, 0)) then
				search.y = search.y + 1
				found = true
				break
			end
		end
		if found then
			-- The feet of a mob spawned in the block: its bottom face
			local feet = vector.new(search.x, search.y - 0.5, search.z)
			if warden_fits(feet) and mobs_mc.spawn_warden(feet, "triggered") then
				return true
			end
		end
	end
	return false
end

-- Warden.applyDarknessAround (also used by the warden itself)
function mcl_sculk.apply_darkness_around(center, source, radius)
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		-- gameMode.isSurvival: survival or adventure
		local survival = not core.is_creative_enabled(name) and not G.is_spectator(player)
		if survival and vector.distance(center, player:get_pos()) < radius then
			local effect = mcl_potions.get_effect(player, "darkness")
			-- !hasEffect || endsWithin(displayEffectLimit - 1 = 199 ticks)
			if not effect or effect.dur - effect.timer <= 199 / 20 then
				mcl_potions.give_effect("darkness", player, 0, 260 / 20, true)
			end
		end
	end
end

local function play_warden_reply_sound(pos, warning_level)
	local sound = SOUND_BY_LEVEL[warning_level]
	if sound then
		local p = vector.new(pos.x + random(-WARNING_SOUND_RADIUS, WARNING_SOUND_RADIUS),
			pos.y + random(-WARNING_SOUND_RADIUS, WARNING_SOUND_RADIUS),
			pos.z + random(-WARNING_SOUND_RADIUS, WARNING_SOUND_RADIUS))
		mcl_mcsounds.play(sound, {pos = p}, 5.0, 1.0, true)
	end
end

-- SculkShriekerBlockEntity.tryRespond
local function try_respond(pos)
	local meta = core.get_meta(pos)
	local level = meta:get_int("warning_level")
	if can_respond(pos) and level > 0 then
		if not try_summon_warden(pos, level) then
			play_warden_reply_sound(pos, level)
		end
		mcl_sculk.apply_darkness_around(pos, nil, DARKNESS_RADIUS)
	end
end

-- SculkShriekerBlockEntity.shriek
local function shriek(pos, source)
	local meta = core.get_meta(pos)
	meta:set_int("shrieking", 1)
	R.schedule_tick(pos, "mcl_sculk:shrieker", SHRIEKING_TICKS)
	mcl_sculk.shriek_event(pos)
	G.emit("shriek", pos, {source = source})
end

-- SculkShriekerBlockEntity.tryShriek
local function try_shriek(pos, player)
	if not player or is_shrieking(pos) then
		return
	end
	local meta = core.get_meta(pos)
	meta:set_int("warning_level", 0)
	if not can_respond(pos) then
		shriek(pos, player)
		return
	end
	local level = try_warn(pos, player)
	if level then
		meta:set_int("warning_level", level)
		shriek(pos, player)
	end
end
mcl_sculk.shrieker_try_shriek = try_shriek

local NAMES = {"mcl_sculk:shrieker", "mcl_sculk:shrieker_can_summon"}

local shrieker_be = {
	keep_on_destruct = true,
	create = function(pos)
		local be = {pos = pos}
		be.data = G.deserialize_vibration_data(core.get_meta(pos):get_string("listener"))
		local user = {
			radius = 8,
			listenable = G.tags.shrieker_can_listen,
			requires_adjacent_chunks = true,
		}
		function user:get_position()
			return be.pos
		end
		function user:can_receive(_, _, ctx)
			return not is_shrieking(be.pos) and try_get_player(ctx.source) ~= nil
		end
		function user:on_receive(_, _, source, projectile_owner)
			try_shriek(be.pos, try_get_player(projectile_owner or source))
		end
		function user:on_data_changed()
			core.get_meta(be.pos):set_string("listener", G.serialize_vibration_data(be.data))
		end
		be.user = user
		be.listener = G.new_vibration_listener(be.data, user)
		be.listener.node_check = function(node)
			return node.name == NAMES[1] or node.name == NAMES[2]
		end
		G.add_block_listener(pos, be.listener)
		return be
	end,
	tick = function(be)
		G.vibration_tick(be.data, be.user)
	end,
}

-- SHAPE_COLLISION: Block.column(16, 0, 8); the outline is the full block
local COLLISION = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0, 0.5}}

for _, name in ipairs(NAMES) do
	local summon = name == "mcl_sculk:shrieker_can_summon"
	local inner = summon
		and {name = "mcl_sculk_shrieker_can_summon_inner_top.png", backface_culling = false,
			animation = {type = "vertical_frames", aspect_w = 16, aspect_h = 16, length = 1.5}}
		or {name = "mcl_sculk_shrieker_inner_top.png", backface_culling = false,
			animation = {type = "vertical_frames", aspect_w = 16, aspect_h = 16, length = 3.0}}
	core.register_node(name, {
		description = S("Sculk Shrieker"),
		_doc_items_longdesc = S("A sculk shrieker shrieks when a player steps on it or when a nearby sculk sensor detects a vibration caused by a player. Shriekers that were generated in the world can summon the warden after repeated warnings."),
		_doc_items_create_entry = not summon,
		drawtype = "mesh",
		mesh = "mcl_sculk_shrieker.obj",
		tiles = {
			{name = "mcl_sculk_shrieker_side.png", backface_culling = false},
			inner,
			{name = "mcl_sculk_shrieker_bottom.png", backface_culling = false},
			{name = "mcl_sculk_shrieker_top.png", backface_culling = false},
		},
		use_texture_alpha = "clip",
		paramtype = "light",
		sunlight_propagates = true,
		collision_box = COLLISION,
		selection_box = {type = "regular"},
		groups = {handy = 1, hoey = 1, sculk = 1, sculk_shrieker = summon and 2 or 1,
			not_in_creative_inventory = summon and 1 or 0},
		sounds = mcl_sculk.sounds.shrieker,
		is_ground_content = false,
		drop = "",
		_mcl_silk_touch_drop = {"mcl_sculk:shrieker"},
		after_dig_node = function(pos, _, _, digger)
			mcl_sculk.drop_experience(pos, digger, 5)
		end,
		-- SculkShriekerBlockEntity.preRemoveSideEffects
		on_destruct = function(pos)
			if is_shrieking(pos) then
				try_respond(pos)
			end
		end,
		_mcl_hardness = 3.0,
		_mcl_blast_resistance = 3.0,
		-- SculkShriekerBlock.stepOn
		_mcl_sculk_step_on = function(pos, _, obj)
			local player = try_get_player(obj)
			if player then
				try_shriek(pos, player)
			end
		end,
		_mcl_redstone = {
			block = "mcl_sculk:shrieker",
			-- SculkShriekerBlock.tick
			tick = function(pos)
				if is_shrieking(pos) then
					core.get_meta(pos):set_int("shrieking", 0)
					try_respond(pos)
				end
			end,
		},
	})
end

local get_shrieker = mcl_sculk.register_block_entity(NAMES, shrieker_be)
mcl_sculk.get_shrieker = get_shrieker
