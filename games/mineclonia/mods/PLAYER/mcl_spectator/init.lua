local S = core.get_translator(core.get_current_modname())

mcl_spectator = {}

local is_spectator = mcl_gamemode.is_spectator

-- Flying speed in nodes per second, as in Minecraft.
local BASE_SPEED = 10.9
local SPRINT_FACTOR = 2
local MIN_SPEED_FACTOR = 0.2
local MAX_SPEED_FACTOR = 5
local SPEED_STEP = 1.25
-- How quickly the camera reaches its target velocity (per second).
local RESPONSIVENESS = 8
local WORLD_LIMIT = 30900

-- Attached players use the riding eye height; raise them so the view
-- sits at standing eye height above the camera's position.
local RIDING_EYE_HEIGHT = mcl_player.player_props_riding.eye_height
local ATTACH_OFFSET = vector.new(0, (mcl_player.player_props_normal.eye_height - RIDING_EYE_HEIGHT) * 10, 0)

-- The engine always forces is_visible on for players, so spectators are
-- hidden by shrinking their model (armor included) to nothing.
local spectator_props = {
	visual_size = vector.zero(),
	pointable = false,
	show_on_minimap = false,
	makes_footstep_sound = false,
}
local default_props = {
	visual_size = vector.new(1, 1, 1),
	pointable = true,
	show_on_minimap = true,
	makes_footstep_sound = true,
}
local hidden_nametag = {
	text = " ",
	color = { r = 255, g = 255, b = 255, a = 0 },
	bgcolor = { r = 0, g = 0, b = 0, a = 0 },
}

-- player -> {camera, frozen, speed, wield_index, props, nametag, hud_flags, immortal}
local states = {}
-- player name -> set of hudbar identifiers to show again after spectating
local restore_bars = {}

------------------------------------------------------------------------
-- HUD.
------------------------------------------------------------------------

local hb_init_hudbar = hb.init_hudbar
local hb_hide_hudbar = hb.hide_hudbar
local hb_unhide_hudbar = hb.unhide_hudbar

local function bars_for(player)
	local name = player:get_player_name()
	restore_bars[name] = restore_bars[name] or {}
	return restore_bars[name]
end

-- Keep status bars hidden while spectating, remembering which ones other
-- mods want visible so they can be restored afterwards.
function hb.init_hudbar(player, identifier, start_value, start_max, start_hidden)
	if player and player:is_player() and is_spectator(player) then
		if not start_hidden then
			bars_for(player)[identifier] = true
		end
		start_hidden = true
	end
	return hb_init_hudbar(player, identifier, start_value, start_max, start_hidden)
end

function hb.hide_hudbar(player, identifier)
	if player and player:is_player() and is_spectator(player) then
		bars_for(player)[identifier] = nil
	end
	return hb_hide_hudbar(player, identifier)
end

function hb.unhide_hudbar(player, identifier)
	if player and player:is_player() and is_spectator(player) then
		bars_for(player)[identifier] = true
		return true
	end
	return hb_unhide_hudbar(player, identifier)
end

local function hide_hud(player, state)
	local flags = player:hud_get_flags()
	state.hud_flags = { hotbar = flags.hotbar, wielditem = flags.wielditem }
	player:hud_set_flags({ hotbar = false, wielditem = false })

	local bars = bars_for(player)
	for _, identifier in ipairs(hb.get_hudbar_identifiers()) do
		local bar = hb.get_hudbar_state(player, identifier)
		if bar and not bar.hidden then
			bars[identifier] = true
			hb_hide_hudbar(player, identifier)
		end
	end
	-- Inventory key does nothing for spectators.
	mcl_player.set_inventory_formspec(player, "", 1000)
end

local function restore_hud(player, state)
	local flags = state.hud_flags or {}
	player:hud_set_flags({
		hotbar = flags.hotbar ~= false,
		wielditem = flags.wielditem ~= false,
	})

	local name = player:get_player_name()
	for identifier in pairs(restore_bars[name] or {}) do
		hb_unhide_hudbar(player, identifier)
	end
	restore_bars[name] = nil
	mcl_player.set_inventory_formspec(player, nil, 1000)
end

------------------------------------------------------------------------
-- Appearance and invulnerability.
------------------------------------------------------------------------

local function hide_player(player, state)
	local props = player:get_properties()
	state.props = {}
	for k in pairs(spectator_props) do
		state.props[k] = props[k]
	end
	player:set_properties(spectator_props)

	state.nametag = player:get_nametag_attributes()
	player:set_nametag_attributes(hidden_nametag)

	local groups = player:get_armor_groups()
	state.immortal = groups.immortal
	groups.immortal = 1
	player:set_armor_groups(groups)
end

local function show_player(player, state)
	player:set_properties(state.props or default_props)

	local nametag = state.nametag
	if not nametag or nametag.text == hidden_nametag.text then
		nametag = {
			text = player:get_player_name(),
			color = { r = 255, g = 255, b = 255, a = 255 },
			bgcolor = false,
		}
	end
	player:set_nametag_attributes(nametag)
	if mcl_potions and mcl_potions.has_effect(player, "invisibility") then
		mcl_potions.make_invisible(player, true)
	end

	local groups = player:get_armor_groups()
	groups.immortal = state.immortal
	player:set_armor_groups(groups)
end

-- Spectators take no damage of any kind.
mcl_damage.register_modifier(function(obj, damage)
	if obj:is_player() and is_spectator(obj) then
		return 0
	end
	return damage
end, -100000)

-- ... nor get hungry.
local exhaust = mcl_hunger.exhaust
function mcl_hunger.exhaust(playername, increase)
	local player = core.get_player_by_name(playername)
	if player and is_spectator(player) then
		return false
	end
	return exhaust(playername, increase)
end

-- ... nor age the chunks they look at (regional difficulty).
local tick_chunk_inhabited_time = mcl_worlds.tick_chunk_inhabited_time
function mcl_worlds.tick_chunk_inhabited_time(pos, player, dtime)
	if player and player:is_player() and is_spectator(player) then
		return
	end
	return tick_chunk_inhabited_time(pos, player, dtime)
end

------------------------------------------------------------------------
-- Camera.
------------------------------------------------------------------------

local function attach(player, camera)
	mcl_util.set_properties(player, mcl_player.player_props_riding)
	player:set_attach(camera, "", ATTACH_OFFSET, vector.zero())
end

local function clamp(v, lo, hi)
	return math.max(lo, math.min(hi, v))
end

local function get_move_dir(player)
	local ctrl = player:get_player_control()
	local forward = ctrl.movement_y
	local sideways = ctrl.movement_x
	if not forward then
		forward = (ctrl.up and 1 or 0) - (ctrl.down and 1 or 0)
		sideways = (ctrl.right and 1 or 0) - (ctrl.left and 1 or 0)
	end
	local yaw = player:get_look_horizontal()
	local right = vector.new(math.cos(yaw), 0, math.sin(yaw))
	local dir = player:get_look_dir() * forward + right * sideways
	dir.y = dir.y + (ctrl.jump and 1 or 0) - (ctrl.sneak and 1 or 0)
	if vector.length(dir) > 1 then
		dir = vector.normalize(dir)
	end
	return dir, ctrl.aux1
end

-- The hotbar is hidden while spectating, so scrolling adjusts the flying
-- speed instead, like in Minecraft.
local function update_speed(player, state)
	local index = player:get_wield_index()
	local last = state.wield_index
	state.wield_index = index
	if not last or index == last then
		return
	end
	local size = player:hud_get_hotbar_itemcount()
	local delta = index - last
	if delta > size / 2 then
		delta = delta - size
	elseif delta < -size / 2 then
		delta = delta + size
	end
	if math.abs(delta) ~= 1 then
		return
	end
	-- Scrolling up selects the previous slot and speeds up.
	state.speed = clamp(state.speed * SPEED_STEP ^ -delta, MIN_SPEED_FACTOR, MAX_SPEED_FACTOR)
	mcl_title.set(player, "actionbar", {
		text = S("Flying speed: @1%", math.floor(state.speed * 100 + 0.5)),
		color = "white",
		stay = 30,
	})
end

core.register_entity("mcl_spectator:camera", {
	initial_properties = {
		physical = false,
		collide_with_objects = false,
		pointable = false,
		visual = "sprite",
		textures = { "blank.png" },
		visual_size = { x = 0, y = 0 },
		is_visible = false,
		static_save = false,
		collisionbox = { 0, 0, 0, 0, 0, 0 },
		selectionbox = { 0, 0, 0, 0, 0, 0 },
	},
	on_step = function(self, dtime)
		local player = self._player and core.get_player_by_name(self._player)
		local state = player and states[player]
		if not state or state.camera ~= self.object then
			self.object:remove()
			return
		end
		if player:get_attach() ~= self.object then
			attach(player, self.object)
		end
		if state.frozen then
			self.object:set_velocity(vector.zero())
			return
		end

		update_speed(player, state)
		local dir, sprinting = get_move_dir(player)
		local speed = BASE_SPEED * state.speed * (sprinting and SPRINT_FACTOR or 1)
		local target = dir * speed

		-- Never leave the world.
		local pos = self.object:get_pos()
		for _, axis in ipairs({ "x", "y", "z" }) do
			if (pos[axis] >= WORLD_LIMIT and target[axis] > 0)
				or (pos[axis] <= -WORLD_LIMIT and target[axis] < 0) then
				target[axis] = 0
			end
		end

		local velocity = self.object:get_velocity()
		local blend = math.min(1, dtime * RESPONSIVENESS)
		self.object:set_velocity(velocity + (target - velocity) * blend)
	end,
})

local function spawn_camera(player, state, pos)
	local camera = core.add_entity(pos or player:get_pos(), "mcl_spectator:camera")
	if not camera then
		return
	end
	camera:get_luaentity()._player = player:get_player_name()
	camera:set_yaw(player:get_look_horizontal())
	state.camera = camera
	attach(player, camera)
end

------------------------------------------------------------------------
-- Entering and leaving.
------------------------------------------------------------------------

local function enter(player)
	if states[player] then
		return
	end
	local state = { speed = 1, frozen = false }
	states[player] = state
	hide_player(player, state)
	hide_hud(player, state)
	-- The previous parent (e.g. a boat) is left behind.
	player:set_detach()
	spawn_camera(player, state)
end

local function leave(player)
	local state = states[player]
	if not state then
		return
	end
	states[player] = nil

	local camera = state.camera
	local pos = camera and camera:is_valid() and camera:get_pos()
	player:set_detach()
	if camera and camera:is_valid() then
		camera:remove()
	end
	if pos then
		player:set_pos(pos)
	end
	mcl_util.set_properties(player, mcl_player.player_props_normal)
	show_player(player, state)
	restore_hud(player, state)
end

mcl_gamemode.register_on_gamemode_change(function(player, old_gm, new_gm)
	if new_gm == "spectator" and old_gm ~= "spectator" then
		enter(player)
	elseif old_gm == "spectator" and new_gm ~= "spectator" then
		leave(player)
	end
end)

core.register_on_joinplayer(function(player)
	if is_spectator(player) then
		enter(player)
	end
end)

core.register_on_leaveplayer(function(player)
	local state = states[player]
	if state and state.camera and state.camera:is_valid() then
		state.camera:remove()
	end
	states[player] = nil
	restore_bars[player:get_player_name()] = nil
end)

-- Entities can fail to spawn at join time or get unloaded; respawn the
-- camera whenever it goes missing.
mcl_player.register_globalstep(function(player)
	local state = states[player]
	if state and not (state.camera and state.camera:is_valid()) then
		spawn_camera(player, state)
	end
end)

------------------------------------------------------------------------
-- API.
------------------------------------------------------------------------

function mcl_spectator.is_spectating(player)
	return states[player] ~= nil
end

-- A frozen spectator's camera does not move at all.
function mcl_spectator.set_frozen(player, frozen)
	local state = states[player]
	if not state then
		return false
	end
	state.frozen = frozen and true or false
	if state.camera and state.camera:is_valid() then
		state.camera:set_velocity(vector.zero())
	end
	return true
end

function mcl_spectator.teleport(player, pos)
	local state = states[player]
	if not state then
		return false
	end
	if state.camera and state.camera:is_valid() then
		state.camera:set_velocity(vector.zero())
		state.camera:set_pos(pos)
	else
		spawn_camera(player, state, pos)
	end
	return true
end

core.register_chatcommand("spectate", {
	params = S("<player>"),
	description = S("Teleport to another player while in spectator mode"),
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player or not is_spectator(player) then
			return false, S("You must be in spectator mode to use this command.")
		end
		local target_name = param:trim()
		local target = core.get_player_by_name(target_name)
		if target_name == "" or not target then
			return false, S("Player @1 is not online.", target_name)
		end
		if target == player then
			return false, S("You cannot spectate yourself.")
		end
		mcl_spectator.teleport(player, target:get_pos())
		return true, S("Now spectating @1.", target_name)
	end,
})
