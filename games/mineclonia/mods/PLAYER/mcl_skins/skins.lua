-- Player skins: Minecraft's default skins, each with wide (Steve) or
-- slim (Alex) arms.
local S = core.get_translator(core.get_current_modname())
local F = core.formspec_escape

mcl_skins = {
	skins = {},
	player_skins = {},
	-- Skins registered by other mods (not listed in the skin screen)
	simple_skins = {},
	texture_to_simple_skin = {},
}

local NAMES = {
	{"steve", "Steve"}, {"alex", "Alex"}, {"ari", "Ari"}, {"efe", "Efe"},
	{"kai", "Kai"}, {"makena", "Makena"}, {"noor", "Noor"}, {"sunny", "Sunny"},
	{"zuri", "Zuri"},
}

-- The Minecraft skins are textures of the game's texture pack
-- (textures/mcl_skins_mc_<name>_<wide|slim>.png)
local available = {}
local game = core.get_game_info and core.get_game_info()
if game and game.path then
	for _, f in ipairs(core.get_dir_list(game.path .. "/textures", false) or {}) do
		available[f] = true
	end
end

for _, model in ipairs({"wide", "slim"}) do
	for _, n in ipairs(NAMES) do
		local texture = "mcl_skins_mc_" .. n[1] .. "_" .. model .. ".png"
		if available[texture] then
			table.insert(mcl_skins.skins, {
				id = n[1] .. "_" .. model,
				name = n[2],
				slim_arms = model == "slim",
				texture = texture,
			})
		end
	end
end

-- Without the texture pack: the game's own two skins
if #mcl_skins.skins == 0 then
	mcl_skins.skins = {
		{id = "steve_wide", name = "Steve", slim_arms = false, texture = "character.png"},
		{id = "alex_slim", name = "Alex", slim_arms = true, texture = "mcl_skins_character_1.png"},
	}
end

local by_id = {}
for i, skin in ipairs(mcl_skins.skins) do
	skin.index = i
	by_id[skin.id] = skin
end

function mcl_skins.register_simple_skin(skin)
	table.insert(mcl_skins.simple_skins, skin)
	mcl_skins.texture_to_simple_skin[skin.texture] = skin
end

-- Hand items (mcl_meshhand) and map items (mcl_maps) exist per skin and game mode
function mcl_skins.get_skin_list()
	local list = {}
	for _, game_mode in ipairs({"_crea", "_surv"}) do
		for _, skin in ipairs(mcl_skins.skins) do
			table.insert(list, {
				texture = skin.texture,
				slim_arms = skin.slim_arms,
				id = skin.id .. game_mode,
				creative = game_mode == "_crea",
			})
		end
	end
	return list
end

function mcl_skins.get_node_id_by_player(player)
	local skin = mcl_skins.player_skins[player] or mcl_skins.skins[1]
	local creative = core.is_creative_enabled(player:get_player_name())
	return skin.id .. (creative and "_crea" or "_surv")
end

function mcl_skins.save(player)
	local skin = mcl_skins.player_skins[player]
	if skin then
		player:get_meta():set_string("mcl_skins:mc_skin", skin.id)
	end
end

function mcl_skins.update_player_skin(player)
	if not player then
		return
	end
	local skin = mcl_skins.player_skins[player] or mcl_skins.skins[1]
	mcl_player.player_set_skin(player, skin.texture)
	mcl_player.player_set_model(player, skin.slim_arms and "mcl_player_slim.glb" or "mcl_player_wide.glb")
end

function mcl_skins.set_player_skin(player, id)
	local skin = by_id[id]
	if not skin then
		return false
	end
	mcl_skins.player_skins[player] = skin
	mcl_skins.save(player)
	mcl_skins.update_player_skin(player)
	return true
end

-- New players are Steve or Alex (Minecraft picks by the player's UUID)
local function default_skin(player)
	local hash = core.sha1(player:get_player_name())
	local alex = tonumber(hash:sub(-1), 16) % 2 == 1
	return by_id[alex and "alex_slim" or "steve_wide"] or mcl_skins.skins[1]
end

core.register_on_joinplayer(function(player)
	local id = player:get_meta():get_string("mcl_skins:mc_skin")
	mcl_skins.player_skins[player] = by_id[id] or default_skin(player)
	mcl_skins.save(player)
	mcl_skins.update_player_skin(player)
end)

core.register_on_leaveplayer(function(player)
	mcl_skins.player_skins[player] = nil
end)

local CELL_W, CELL_H = 1.9, 3.6

function mcl_skins.show_formspec(player)
	local current = mcl_skins.player_skins[player]
	local cols = math.min(#mcl_skins.skins, 9)
	local rows = math.ceil(#mcl_skins.skins / cols)
	local w = cols * CELL_W + 0.8
	local h = rows * CELL_H + 1.4
	local fs = {
		"formspec_version[4]",
		"size[" .. w .. "," .. h .. "]",
		"label[0.4,0.5;" .. F(S("Select player skin")) .. "]",
	}
	for i, skin in ipairs(mcl_skins.skins) do
		local x = 0.4 + ((i - 1) % cols) * CELL_W
		local y = 1.0 + math.floor((i - 1) / cols) * CELL_H
		if skin == current then
			table.insert(fs, "box[" .. x .. "," .. y .. ";" .. (CELL_W - 0.1) .. "," .. (CELL_H - 0.1) .. ";#ffffff40]")
		end
		local mesh = skin.slim_arms and "mcl_player_slim.glb" or "mcl_player_wide.glb"
		table.insert(fs, string.format("model[%s,%s;%s,%s;preview_%d;%s;%s;-10,200;false;true]",
			x + 0.1, y + 0.05, CELL_W - 0.3, CELL_H - 0.9, i, mesh,
			F(skin.texture) .. ",blank.png,blank.png,blank.png,blank.png"))
		table.insert(fs, string.format("button[%s,%s;%s,0.7;skin_%d;%s]",
			x + 0.05, y + CELL_H - 0.85, CELL_W - 0.2, i, F(skin.name)))
	end
	core.show_formspec(player:get_player_name(), "mcl_skins:skins", table.concat(fs))
end

mcl_player.register_player_settings_button({
	field = "__mcl_skins",
	icon = "mcl_skins_button.png",
	description = S("Select player skin"),
	priority = 1000,
})

core.register_on_player_receive_fields(function(player, formname, fields)
	if fields.__mcl_skins then
		mcl_skins.show_formspec(player)
		return false
	end
	if formname ~= "mcl_skins:skins" then
		return false
	end
	for field in pairs(fields) do
		local i = tonumber(field:match("^skin_(%d+)$"))
		if i and mcl_skins.skins[i] then
			mcl_skins.set_player_skin(player, mcl_skins.skins[i].id)
			mcl_skins.show_formspec(player)
			return true
		end
	end
	return true
end)

core.register_chatcommand("skin", {
	description = S("Open skin configuration screen."),
	privs = {},
	func = function(name)
		mcl_skins.show_formspec(core.get_player_by_name(name))
	end,
})
