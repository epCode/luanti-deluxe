mcl_hardcore = {}

local modpath = core.get_modpath(core.get_current_modname())

------------------------------------------------------------------------
-- World options.
------------------------------------------------------------------------

-- These are chosen in the main menu before the world starts, so cache
-- them: the privilege filter runs on every privilege check.
local hardcore = mcl_vars.is_hardcore()
local cheats_allowed = mcl_vars.get_world_setting_bool("mcl_allow_cheats", true)

function mcl_hardcore.is_hardcore()
	return hardcore
end

function mcl_hardcore.cheats_allowed()
	return cheats_allowed
end

------------------------------------------------------------------------
-- Cheats.
------------------------------------------------------------------------

-- Luanti gives the singleplayer and the server admin every privilege.
-- Without cheats they only get what any new player gets.
mcl_gamemode.register_privilege_filter(function(name, privs)
	if cheats_allowed then
		return
	end
	if not core.is_singleplayer() and name ~= core.settings:get("name") then
		return
	end
	for priv in pairs(privs) do
		privs[priv] = nil
	end
	local default_privs = core.settings:get("default_privs") or "interact, shout"
	for priv in pairs(core.string_to_privs(default_privs)) do
		privs[priv] = true
	end
end)

------------------------------------------------------------------------
-- New players.
------------------------------------------------------------------------

-- Players joining after the world was set up start in its game mode.
core.register_on_newplayer(function(player)
	if not hardcore and mcl_vars.get_world_setting("mcl_default_gamemode") == "creative" then
		player:get_meta():set_string("gamemode", "creative")
	end
end)

------------------------------------------------------------------------
-- Hardcore hearts.
------------------------------------------------------------------------

local HEART_OVERLAY = "^mcl_hardcore_heart_overlay.png"

-- Every heart variant (poisoned, withered, frozen...) gets the hardcore
-- look, whichever mod sets it.
local change_hudbar = hb.change_hudbar
function hb.change_hudbar(player, identifier, new_value, new_max_value, new_icon, ...)
	if hardcore and identifier == "health" and new_icon
		and not new_icon:find(HEART_OVERLAY, 1, true) then
		new_icon = new_icon .. HEART_OVERLAY
	end
	return change_hudbar(player, identifier, new_value, new_max_value, new_icon, ...)
end

-- Re-applies the current heart icon so that it gains or loses the
-- hardcore look.
function mcl_hardcore.refresh_hearts(player)
	local hudtable = hb.get_hudtable("health")
	local ids = hudtable and hudtable.hudids[player:get_player_name()]
	if not ids then
		return
	end
	local id = hb.settings.bar_type == "progress_bar" and ids.icon or ids.bar
	local hud = id and player:hud_get(id)
	if not hud or not hud.text or hud.text == "" then
		return
	end
	local icon = hud.text:gsub(HEART_OVERLAY:gsub("%p", "%%%0"), "")
	hb.change_hudbar(player, "health", nil, nil, icon)
end

core.register_on_joinplayer(function(player)
	if hardcore then
		mcl_hardcore.refresh_hearts(player)
	end
end)

dofile(modpath .. "/death_screen.lua")
