local S = core.get_translator(core.get_current_modname())

------------------------------------------------------------------------
-- Per-world settings.
------------------------------------------------------------------------

-- Settings chosen for a single world (in the main menu's Create World and
-- Edit World dialogs, see world_settingtypes.txt, or with commands such as
-- /difficulty and /gamerule) live in its world.mt and take precedence over
-- minetest.conf.

local world_settings = Settings(core.get_worldpath() .. "/world.mt")
local real_settings = core.settings

local function is_empty_value(value)
	return not value or value == ""
end

function mcl_vars.get_world_setting(key)
	local value = world_settings:get(key)
	if is_empty_value(value) then
		value = real_settings:get(key)
	end
	if is_empty_value(value) then
		return nil
	end
	return value
end

function mcl_vars.get_world_setting_bool(key, default)
	local value = mcl_vars.get_world_setting(key)
	if value == nil then
		return default
	end
	return core.is_yes(value)
end

function mcl_vars.set_world_setting(key, value)
	if value == nil then
		world_settings:remove(key)
	else
		world_settings:set(key, tostring(value))
	end
	return world_settings:write()
end

function mcl_vars.is_hardcore()
	return mcl_vars.get_world_setting_bool("mcl_hardcore", false)
end

-- The main menu stores the game mode as one option, mcl_game_mode; spell it
-- out into the settings the game reads. Worlds set up before that get the
-- option filled in from those settings, so the menu shows their game mode.
do
	local mode = world_settings:get("mcl_game_mode")
	if mode then
		local hardcore = mode == "hardcore"
		world_settings:set("mcl_hardcore", tostring(hardcore))
		world_settings:set("mcl_default_gamemode", mode == "creative" and "creative" or "survival")
		if hardcore then
			world_settings:set("mcl_allow_cheats", "false")
			world_settings:set("mcl_bonus_chest", "false")
		end
	elseif mcl_vars.is_hardcore() then
		world_settings:set("mcl_game_mode", "hardcore")
	elseif mcl_vars.get_world_setting("mcl_default_gamemode") == "creative" then
		world_settings:set("mcl_game_mode", "creative")
	else
		world_settings:set("mcl_game_mode", "survival")
	end
	world_settings:write()
end

------------------------------------------------------------------------
-- Game rules.
------------------------------------------------------------------------

-- Game rules are ordinary Mineclonia settings that can be overridden per
-- world.  So that every mod reading them through core.settings sees the
-- world's value, core.settings is replaced by a thin proxy that consults
-- world.mt first for registered game rule settings only.

local overridable = {}

local function get_override(key)
	if overridable[key] then
		local value = world_settings:get(key)
		if not is_empty_value(value) then
			return value
		end
	end
end

local proxy_methods = {
	get = function(_, key)
		local value = get_override(key)
		if value ~= nil then
			return value
		end
		return real_settings:get(key)
	end,
	get_bool = function(_, key, default)
		local value = get_override(key)
		if value ~= nil then
			return core.is_yes(value)
		end
		return real_settings:get_bool(key, default)
	end,
}

local settings_proxy = {}
setmetatable(settings_proxy, {
	__index = function(t, k)
		local method = proxy_methods[k]
		if method then
			return method
		end
		local value = real_settings[k]
		if type(value) ~= "function" then
			return value
		end
		local wrapped = function(self, ...)
			if self == t then
				self = real_settings
			end
			return value(self, ...)
		end
		rawset(t, k, wrapped)
		return wrapped
	end,
})
core.settings = settings_proxy

mcl_vars.gamerules = {}
local gamerules_by_name = {}

-- def fields:
--   setting:     name of the underlying setting
--   type:        "bool" or "int"
--   default:     value used when neither world.mt nor minetest.conf set it
--   description: short translated description
--   min, max:    bounds for "int" rules
--   restart:     true if the rule is only read when the world is loaded
function mcl_vars.register_gamerule(name, def)
	def.name = name
	table.insert(mcl_vars.gamerules, def)
	gamerules_by_name[name:lower()] = def
	overridable[def.setting] = true
end

function mcl_vars.get_gamerule_def(name)
	return gamerules_by_name[name:lower()]
end

function mcl_vars.get_gamerule(name)
	local def = gamerules_by_name[name:lower()]
	if not def then
		return nil
	end
	local value = mcl_vars.get_world_setting(def.setting)
	if def.type == "bool" then
		if value == nil then
			return def.default
		end
		return core.is_yes(value)
	end
	return tonumber(value) or def.default
end

-- Returns true on success; value may be a boolean, number or string.
function mcl_vars.set_gamerule(name, value)
	local def = gamerules_by_name[name:lower()]
	if not def then
		return false
	end
	if def.type == "bool" then
		if type(value) == "string" then
			if value ~= "true" and value ~= "false" then
				return false
			end
			value = value == "true"
		elseif type(value) ~= "boolean" then
			return false
		end
	else
		value = tonumber(value)
		if not value or value ~= math.floor(value)
			or (def.min and value < def.min)
			or (def.max and value > def.max) then
			return false
		end
	end
	mcl_vars.set_world_setting(def.setting, tostring(value))
	return true
end

mcl_vars.register_gamerule("keepInventory", {
	setting = "mcl_keepInventory",
	type = "bool",
	default = false,
	description = S("Keep inventory after death"),
})
mcl_vars.register_gamerule("doTileDrops", {
	setting = "mcl_doTileDrops",
	type = "bool",
	default = true,
	description = S("Drop blocks when they are mined"),
})
mcl_vars.register_gamerule("doMobLoot", {
	setting = "mobs_drop_items",
	type = "bool",
	default = true,
	description = S("Mobs drop items when they die"),
})
mcl_vars.register_gamerule("mobGriefing", {
	setting = "mobs_griefing",
	type = "bool",
	default = true,
	description = S("Mobs can change and destroy blocks"),
})
mcl_vars.register_gamerule("explosionGriefing", {
	setting = "mcl_explosions_griefing",
	type = "bool",
	default = true,
	description = S("Explosions destroy blocks"),
})
mcl_vars.register_gamerule("doWeatherCycle", {
	setting = "mcl_doWeatherCycle",
	type = "bool",
	default = true,
	description = S("Weather changes over time"),
})
mcl_vars.register_gamerule("showDeathMessages", {
	setting = "mcl_showDeathMessages",
	type = "bool",
	default = true,
	description = S("Announce player deaths in chat"),
})
mcl_vars.register_gamerule("announceAdvancements", {
	setting = "mcl_showAdvancementMessages",
	type = "bool",
	default = true,
	description = S("Announce advancements in chat"),
})
mcl_vars.register_gamerule("playersSleepingPercentage", {
	setting = "mcl_playersSleepingPercentage",
	type = "int",
	default = 100,
	min = 0,
	max = 1000,
	description = S("Percentage of players who must sleep to skip the night"),
})
mcl_vars.register_gamerule("doFireTick", {
	setting = "enable_fire",
	type = "bool",
	default = true,
	restart = true,
	description = S("Fire spreads and burns blocks"),
})

local function format_gamerule(def)
	local value = tostring(mcl_vars.get_gamerule(def.name))
	if def.restart then
		return S("@1 = @2 (changes apply when the world is next loaded)", def.name, value)
	end
	return S("@1 = @2", def.name, value)
end

core.register_chatcommand("gamerule", {
	params = S("[<rule> [<value>]]"),
	description = S("List, query or change the game rules of this world"),
	func = function(name, param)
		local rule, value = unpack(param:split(" "))

		if not rule then
			local lines = {}
			for _, def in ipairs(mcl_vars.gamerules) do
				table.insert(lines, format_gamerule(def))
			end
			return true, table.concat(lines, "\n")
		end

		local def = mcl_vars.get_gamerule_def(rule)
		if not def then
			return false, S("Unknown game rule: @1", rule)
		end

		if not value then
			return true, def.description .. "\n" .. format_gamerule(def)
		end

		if not core.check_player_privs(name, "server") then
			return false, S("This command requires server privileges to run.")
		end

		if not mcl_vars.set_gamerule(def.name, value) then
			if def.type == "bool" then
				return false, S("Invalid value for @1. Use true or false.", def.name)
			end
			return false, S("Invalid value for @1. Use a whole number from @2 to @3.",
				def.name, def.min or 0, def.max or 0)
		end
		return true, S("Game rule updated.") .. "\n" .. format_gamerule(def)
	end,
})

------------------------------------------------------------------------
-- Difficulty.
------------------------------------------------------------------------

local difficulties = {
	"peaceful",
	"easy",
	"normal",
	"hard",
}
mcl_vars.difficulties = difficulties

local difficulty_aliases = {
	["0"] = "peaceful",
	["1"] = "easy",
	["2"] = "normal",
	["3"] = "hard",
	["p"] = "peaceful",
	["e"] = "easy",
	["n"] = "normal",
	["h"] = "hard",
}

local difficulty = mcl_vars.get_world_setting("mcl_difficulty") or "normal"
if mcl_vars.is_hardcore() then
	-- Hardcore worlds are locked at the hardest difficulty.
	difficulty = "hard"
end

local function set_mcl_vars_difficulty()
	local i = table.indexof(difficulties, difficulty)

	if i == -1 then
		mcl_vars.difficulty = 2
		core.log("warning", "mcl_difficulty is configured to an unknown value " .. difficulty)
		return
	end

	mcl_vars.difficulty = i - 1 --> peaceful is at index 1, becomes 0; easy is 2 -> 1; etc
end

set_mcl_vars_difficulty()

function mcl_vars.get_difficulty_name()
	return difficulty
end

-- Accepts a difficulty name or alias; returns true on success.
function mcl_vars.set_difficulty(d)
	if table.indexof(difficulties, d) == -1 then
		d = difficulty_aliases[d]
		if not d then
			return false
		end
	end

	mcl_vars.set_world_setting("mcl_difficulty", d)

	difficulty = d

	set_mcl_vars_difficulty()

	return true
end

local cmd_difficulties = table.copy(difficulties)
for alias in pairs(difficulty_aliases) do
	table.insert(cmd_difficulties, alias)
end
table.sort(cmd_difficulties)

core.register_chatcommand("difficulty", {
	params = S("[<difficulty>]"),
	description = S("Set or query the gameplay difficulty"),
	func = function(player, param)
		local d = unpack(param:split(" "))

		if not d then
			return true, S("Difficulty: @1", difficulty)
		end

		if not core.check_player_privs(player, "server") then
			return false, S("This command requires server privileges to run.")
		end

		if mcl_vars.is_hardcore() then
			return false, S("The difficulty of a Hardcore world is locked to hard.")
		end

		if not mcl_vars.set_difficulty(d) then
			return false, S("Failed to set difficulty @1.\nValid values: @2", d, table.concat(cmd_difficulties, ", "))
		end

		return true, S("Difficulty set to @1.", difficulty)
	end
})
