local S = core.get_translator("mcl_gamemode")

mcl_gamemode = {
	gamemodes = {
		"survival",
		"creative",
		"spectator",
	},
	registered_on_gamemode_change = {},
	registered_privilege_filters = {},
}

local gamemode_aliases = {
	["0"] = "survival",
	["1"] = "creative",
	["3"] = "spectator",
	["s"] = "survival",
	["c"] = "creative",
	["sp"] = "spectator",
}

function mcl_gamemode.register_on_gamemode_change(func)
	table.insert(mcl_gamemode.registered_on_gamemode_change, func)
end

local old_is_creative_enabled = core.is_creative_enabled

function core.is_creative_enabled(name)
	if not name or name == "" then return old_is_creative_enabled(name) end
	assert(type(name) == "string", "core.is_creative_enabled requires a string (the playername) argument. This is likely an error in a non-mineclonia mod.")
	local p = core.get_player_by_name(name)
	local gm = p and p:get_meta():get_string("gamemode")
	-- Spectators never get creative privileges, even in a creative world.
	if gm == "spectator" then return false end
	if old_is_creative_enabled(name) then return true end
	return gm == "creative"
end

function mcl_gamemode.get_gamemode(p)
	if p:get_meta():get_string("gamemode") == "spectator" then
		return "spectator"
	end
	return core.is_creative_enabled(p:get_player_name()) and "creative" or "survival"
end

function mcl_gamemode.is_spectator(p)
	return p:get_meta():get_string("gamemode") == "spectator"
end

function mcl_gamemode.set_gamemode(p, gm)
	if table.indexof(mcl_gamemode.gamemodes, gm) == -1 then return false end
	local old_gm = mcl_gamemode.get_gamemode(p)
	p:get_meta():set_string("gamemode", gm)
	if old_gm == "spectator" or gm == "spectator" then
		-- Spectators lose "interact"; tell the engine to resend privileges.
		core.notify_authentication_modified(p:get_player_name())
	end
	for _, func in ipairs(mcl_gamemode.registered_on_gamemode_change) do
		func(p, old_gm, gm)
	end
	return true
end

-- Privilege filters adjust the effective privileges of a player without
-- touching the auth database: func(name, privs) modifies `privs` in place.
-- They run in registration order, and the gamemode adjustments run last.
function mcl_gamemode.register_privilege_filter(func)
	table.insert(mcl_gamemode.registered_privilege_filters, func)
end

local function filter_privileges(name, privs)
	for _, func in ipairs(mcl_gamemode.registered_privilege_filters) do
		func(name, privs)
	end
	local p = core.get_player_by_name(name)
	if p and mcl_gamemode.is_spectator(p) then
		privs.interact = nil
		-- Lets the client see through blocks the spectator camera flies into.
		privs.noclip = true
	end
end

core.register_on_mods_loaded(function()
	-- Wrap whichever authentication handler is active once all mods have
	-- had the chance to register their own.
	local handler = core.get_auth_handler()
	local get_auth = handler.get_auth
	handler.get_auth = function(name, ...)
		local auth = get_auth(name, ...)
		if auth and auth.privileges then
			-- Copy, as other handlers may hand out cached tables.
			auth = table.copy(auth)
			filter_privileges(name, auth.privileges)
		end
		return auth
	end
end)

core.register_chatcommand("gamemode",{
	params = S("[<gamemode>] [<player>]"),
	description = S("Change gamemode (survival/creative/spectator/0/1/3/s/c/sp) for yourself or player"),
	privs = { server = true },
	func = function(n,param)
		local p
		local args = param:split(" ")
		if args[2] ~= nil then
			p = core.get_player_by_name(args[2])
			n = args[2]
		else
			p = core.get_player_by_name(n)
		end
		if not p then
			return false, S("Player not online")
		end

		local gm = gamemode_aliases[args[1]] or args[1]
		if gm and mcl_gamemode.set_gamemode(p, gm) == false then
			return false, S("Failed to set gamemode @1 for player @2", gm, p:get_player_name())
		end

		if gm == "survival" and core.is_creative_enabled() then
			return true, S("Player @1 is still in creative mode because world is in creative mode", n)
		end

		--Result message - show effective game mode
		return true, S("Gamemode for player @1: @2", n, mcl_gamemode.get_gamemode(p))
	end
})
