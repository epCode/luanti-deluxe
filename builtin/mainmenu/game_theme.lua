-- Luanti
-- Copyright (C) 2013 sapier
-- SPDX-License-Identifier: LGPL-2.1-or-later

mm_game_theme = {}

local valid_image_extensions = {
	".png",
	".jpg",
	".jpeg",
}

local COLORS = {
	dark = { clouds = "#1c2a47", sky = "#090b1a" },
	light = { clouds = "#f0f0ff", sky = "#8cbafa" },
}

--------------------------------------------------------------------------------
function mm_game_theme.init()
	mm_game_theme.texturepack = core.settings:get("texture_path")

	mm_game_theme.gameid = nil

	mm_game_theme.music_handle = nil
end

--------------------------------------------------------------------------------
-- The game's fonts (game.conf font_path etc.), or the default ones for nil
local fonts_game
local function set_fonts(game)
	local id = game and next(game.fonts or {}) and game.id or nil
	if fonts_game ~= id then
		fonts_game = id
		core.set_menu_fonts(id and game.fonts or nil)
	end
end

--------------------------------------------------------------------------------
function mm_game_theme.set_engine(hide_decorations)
	-- A game with its own menu (menu/menu.conf) keeps its theme on every tab
	local game = mm_game_theme.customized_game()
	if game then
		mm_game_theme.set_game(game)
		if hide_decorations then
			mm_game_theme.clear_single("header")
			mm_game_theme.clear_single("footer")
		end
		return
	end

	mm_game_theme.gameid = nil
	mm_game_theme.stop_music()

	core.set_topleft_text("")
	core.set_panorama(nil)
	core.set_formspec_prepend("")
	set_fonts(nil)

	local have_bg = false
	local have_overlay = mm_game_theme.set_engine_single("overlay")

	if not have_overlay then
		have_bg = mm_game_theme.set_engine_single("background")
	end

	mm_game_theme.clear_single("header")
	mm_game_theme.clear_single("footer")
	core.set_clouds(false)

	if not hide_decorations then
		mm_game_theme.set_engine_single("header")
		mm_game_theme.set_engine_single("footer")
	end

	local c = COLORS[core.settings:get("menu_theme")]
	if not c then
		core.log("warning", "Invalid menu theme: " .. core.settings:get("menu_theme"))
	else
		core.set_clouds_color(c.clouds)
		core.set_sky_color(c.sky)
	end

	if not have_bg then
		core.set_clouds(core.settings:get_bool("menu_clouds"))
	end
end

--------------------------------------------------------------------------------
function mm_game_theme.set_game(gamedetails)
	assert(gamedetails ~= nil)

	if mm_game_theme.gameid == gamedetails.id then
		-- A dialog may have hidden them (see set_engine)
		mm_game_theme.set_game_decorations(gamedetails)
		return
	end
	mm_game_theme.gameid = gamedetails.id
	mm_game_theme.set_music(gamedetails)
	set_fonts(gamedetails)

	local conf = mm_game_theme.get_menu_conf(gamedetails)
	core.set_topleft_text(conf:get("topleft_text") or gamedetails.name)
	core.set_formspec_prepend(mm_game_theme.get_formspec_prepend(gamedetails, conf))

	mm_game_theme.set_game_decorations(gamedetails)

	local c = COLORS[core.settings:get("menu_theme")]
	if not c then
		core.log("warning", "Invalid menu theme: " .. core.settings:get("menu_theme"))
	else
		core.set_clouds_color(c.clouds)
		core.set_sky_color(c.sky)
	end

	mm_game_theme.set_game_backgrounds(gamedetails)
end

--------------------------------------------------------------------------------
function mm_game_theme.set_game_decorations(gamedetails)
	mm_game_theme.clear_single("header")
	mm_game_theme.clear_single("footer")
	mm_game_theme.set_game_single("header", gamedetails)
	mm_game_theme.set_game_single("footer", gamedetails)
end

--------------------------------------------------------------------------------
-- Background layers: panorama, overlay or background image, clouds
function mm_game_theme.set_game_backgrounds(gamedetails)
	local conf = mm_game_theme.get_menu_conf(gamedetails)

	core.set_panorama(nil)
	mm_game_theme.clear_single("overlay")
	mm_game_theme.clear_single("background")
	core.set_clouds(false)

	local have_bg = false
	local have_overlay = false

	if mm_game_theme.set_panorama(gamedetails, conf) then
		have_bg = true
		local overlay = mm_game_theme.menu_file(gamedetails, "panorama_overlay.png")
		if overlay then
			core.set_background("overlay", overlay)
		end
	end

	if not have_bg then
		have_overlay = mm_game_theme.set_game_single("overlay", gamedetails)
		if not have_overlay then
			have_bg = mm_game_theme.set_game_single("background", gamedetails)
		end
	end

	if not have_bg then
		core.set_clouds(core.settings:get_bool("menu_clouds"))
	end
end

--------------------------------------------------------------------------------
-- The selected game, if it has its own menu (menu/menu.conf)
function mm_game_theme.customized_game()
	local gameid = core.settings:get("menu_last_game")
	local game = gameid and pkgmgr.find_by_gameid(gameid)
	if game and mm_game_theme.menu_file(game, "menu.conf") then
		return game
	end
	return nil
end

--------------------------------------------------------------------------------
-- Settings from <game>/menu/menu.conf (see doc/menu_customization.md)
local menu_confs = {}
function mm_game_theme.get_menu_conf(gamedetails)
	local conf = menu_confs[gamedetails.id]
	if not conf then
		conf = Settings(gamedetails.path .. DIR_DELIM .. "menu" .. DIR_DELIM .. "menu.conf")
		menu_confs[gamedetails.id] = conf
	end
	return conf
end

-- Full path of a file in the game's menu folder, or nil if it doesn't exist
function mm_game_theme.menu_file(gamedetails, name)
	local dir = gamedetails.path .. DIR_DELIM .. "menu"
	if table.indexof(core.get_dir_list(dir, false), name) == -1 then
		return nil
	end
	return dir .. DIR_DELIM .. name
end

--------------------------------------------------------------------------------
-- menu/panorama_0..5: front, right, back, left, up, down (as in Minecraft)
function mm_game_theme.set_panorama(gamedetails, conf)
	if conf:get_bool("panorama", true) == false then
		return false
	end
	local faces = {}
	for i = 0, 5 do
		local face
		for _, extension in ipairs(valid_image_extensions) do
			face = face or mm_game_theme.menu_file(gamedetails, "panorama_" .. i .. extension)
		end
		if not face then
			return false
		end
		faces[#faces + 1] = face
	end
	return core.set_panorama(faces, tonumber(conf:get("panorama_speed")) or 1.5)
end

--------------------------------------------------------------------------------
-- Styles applied to every menu formspec: button textures and custom styles
function mm_game_theme.get_formspec_prepend(gamedetails, conf)
	local fs = {}

	local function tex(name)
		local path = mm_game_theme.menu_file(gamedetails, name)
		return path and core.formspec_escape(path)
	end
	local button = tex("button.png")
	if button then
		local hovered = tex("button_hovered.png") or button
		local pressed = tex("button_pressed.png") or hovered
		fs[#fs + 1] = ("style_type[button;border=false;bgimg=%s;bgimg_hovered=%s;" ..
			"bgimg_pressed=%s;bgimg_middle=%s]"):format(button, hovered, pressed,
			conf:get("button_middle") or "4")
	end
	local text_color = conf:get("button_text_color")
	if text_color then
		fs[#fs + 1] = ("style_type[button;textcolor=%s]"):format(text_color)
	end

	-- Anything else; $MENU is the game's menu folder
	local custom = conf:get("formspec_prepend")
	if custom then
		local dir = core.formspec_escape(gamedetails.path .. DIR_DELIM .. "menu" .. DIR_DELIM)
		fs[#fs + 1] = custom:gsub("%$MENU", function() return dir end)
	end

	return table.concat(fs)
end

--------------------------------------------------------------------------------
function mm_game_theme.clear_single(identifier)
	core.set_background(identifier, "")
end

--------------------------------------------------------------------------------

function mm_game_theme.set_engine_single(identifier)
	--try texture pack first
	if mm_game_theme.texturepack ~= nil then
		for _, extension in pairs(valid_image_extensions) do
			local path = mm_game_theme.texturepack .. DIR_DELIM .. "menu_" .. identifier .. extension
			if core.set_background(identifier, path) then
				return true
			end
		end
	end

	local path = defaulttexturedir .. DIR_DELIM .. "menu_" .. identifier .. ".png"
	if core.set_background(identifier, path) then
		return true
	end

	return false
end

--------------------------------------------------------------------------------
function mm_game_theme.set_game_single(identifier, gamedetails)
	local extensions_randomised = table.copy(valid_image_extensions)
	table.shuffle(extensions_randomised)
	for _, extension in pairs(extensions_randomised) do
		assert(gamedetails ~= nil)

		if mm_game_theme.texturepack ~= nil then
			local path = mm_game_theme.texturepack .. DIR_DELIM .. gamedetails.id .. "_menu_" .. identifier .. extension
			if core.set_background(identifier, path) then
				return true
			end
		end

		-- Find out how many randomized textures the game provides
		local n = 0
		local filename
		local menu_files = core.get_dir_list(gamedetails.path .. DIR_DELIM .. "menu", false)
		for i = 1, #menu_files do
			filename = identifier .. "." .. i .. extension
			if table.indexof(menu_files, filename) == -1 then
				n = i - 1
				break
			end
		end
		-- Select random texture, 0 means standard texture
		n = math.random(0, n)
		if n == 0 then
			filename = identifier .. extension
		else
			filename = identifier .. "." .. n .. extension
		end

		local path = gamedetails.path .. DIR_DELIM .. "menu" .. DIR_DELIM .. filename
		if core.set_background(identifier, path) then
			return true
		end

	end
	return false
end

--------------------------------------------------------------------------------
function mm_game_theme.stop_music()
	if mm_game_theme.music_handle ~= nil then
		core.sound_stop(mm_game_theme.music_handle)
	end
end

--------------------------------------------------------------------------------
function mm_game_theme.set_music(gamedetails)
	mm_game_theme.stop_music()

	assert(gamedetails ~= nil)

	local music_path = gamedetails.path .. DIR_DELIM .. "menu" .. DIR_DELIM .. "theme"
	mm_game_theme.music_handle = core.sound_play(music_path, true)
end
