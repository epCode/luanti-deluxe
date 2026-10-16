-- Luanti
-- SPDX-License-Identifier: LGPL-2.1-or-later

-- Games can replace what is inside the main menu tabs with views of their own,
-- chosen in menu/menu.conf (see doc/menu_customization.md):
--   start_tab = title    their title screen (logo, splash, big buttons),
--                        whose Singleplayer button leads to the world list
--   start_tab = worlds   the world list directly (view_worlds.lua)
--   join_tab = servers   their server list (view_servers.lua)
-- The tab row and the game bar stay the engine's.

game_menu = {}

local BUTTONS = {
	singleplayer = { label = fgettext_ne("Singleplayer") },
	multiplayer = { label = fgettext_ne("Multiplayer"), tab = "online" },
	content = { label = fgettext_ne("Content"), tab = "content" },
	about = { label = fgettext_ne("About"), tab = "about" },
	settings = { label = fgettext_ne("Settings") },
	quit = { label = fgettext_ne("Quit Game") },
}
local DEFAULT_BUTTONS = "singleplayer; multiplayer; content; settings, quit"

-- The game's choice for a tab ("start_tab" or "join_tab"), nil for the classic tab
function game_menu.view(game, key)
	if not game or not mm_game_theme.menu_file(game, "menu.conf") then
		return nil
	end
	local view = mm_game_theme.get_menu_conf(game):get(key)
	if view == "classic" then
		return nil
	end
	return view
end

-- Which view the Start Game tab shows for this game
local opened_worlds = {}
function game_menu.start_view(game)
	local view = game_menu.view(game, "start_tab")
	if view == "title" and opened_worlds[game.id] then
		return "worlds"
	end
	return view
end

-- From the world list back to the title view; false if there is none
function game_menu.back_to_title(game)
	if game_menu.view(game, "start_tab") ~= "title" then
		return false
	end
	opened_worlds[game.id] = nil
	return true
end

-- Label of a title view button, escaped
function game_menu.button_label(game, name)
	local label = mm_game_theme.get_menu_conf(game):get("label_" .. name)
	return core.formspec_escape(label or BUTTONS[name].label)
end

-- Rows of buttons filling the width w.
-- rows: { { {name, label}, ... }, ... }, labels already escaped.
-- Returns the formspec and the height taken.
function game_menu.button_rows(x, y, w, rows, button_h, gap)
	button_h = button_h or 0.8
	gap = gap or 0.2
	local fs = {}
	for r, row in ipairs(rows) do
		local bw = (w - gap * (#row - 1)) / #row
		for i, button in ipairs(row) do
			fs[#fs + 1] = ("button[%f,%f;%f,%f;%s;%s]"):format(
				x + (i - 1) * (bw + gap), y + (r - 1) * (button_h + gap), bw, button_h,
				button[1], button[2])
		end
	end
	return table.concat(fs), #rows * (button_h + gap) - gap
end

-- Darkened list with a light selection, as in Minecraft
function game_menu.tableoptions()
	return "tableoptions[background=#00000099;border=false;highlight=#ffffff40;" ..
		"highlight_text=#ffffff]"
end

--------------------------------------------------------------------------------
-- Splash text: shown with the title view only

local splash_game

local function random_splash(game)
	local conf = mm_game_theme.get_menu_conf(game)
	if conf:get_bool("splash", true) == false then
		return nil
	end
	local path = mm_game_theme.menu_file(game, "splashes.txt")
	local file = path and io.open(path, "r")
	if not file then
		return nil
	end
	local splashes = {}
	for line in file:lines() do
		line = line:trim()
		if line ~= "" and line:sub(1, 1) ~= "#" then
			splashes[#splashes + 1] = line
		end
	end
	file:close()
	return splashes[math.random(#splashes)]
end

-- game: show a new splash for it unless one already is; nil: remove it
function game_menu.set_splash(game)
	if (game and game.id) == splash_game then
		return
	end
	splash_game = game and game.id
	if game then
		core.set_splash_text(random_splash(game),
			mm_game_theme.get_menu_conf(game):get("splash_color") or "#ffff00")
	else
		core.set_splash_text(nil)
	end
end

--------------------------------------------------------------------------------
-- Title view

local function parse_rows(spec)
	local rows = {}
	for _, row_spec in ipairs(spec:split(";")) do
		local row = {}
		for _, name in ipairs(row_spec:split(",")) do
			name = name:trim()
			if BUTTONS[name] then
				row[#row + 1] = name
			else
				core.log("warning", "menu.conf: unknown title button '" .. name .. "'")
			end
		end
		if #row > 0 then
			rows[#rows + 1] = row
		end
	end
	return rows
end

function game_menu.title_formspec(tabview, game)
	local conf = mm_game_theme.get_menu_conf(game)
	local W, H = tabview.width, tabview.height

	local rows = {}
	for _, row in ipairs(parse_rows(conf:get("title_buttons") or DEFAULT_BUTTONS)) do
		local buttons = {}
		for _, name in ipairs(row) do
			buttons[#buttons + 1] = { "title_" .. name, game_menu.button_label(game, name) }
		end
		rows[#rows + 1] = buttons
	end

	local w = math.min(9, W - 1)
	local _, height = game_menu.button_rows(0, 0, w, rows)
	local fs, _ = game_menu.button_rows((W - w) / 2, (H - 0.6 - height) / 2, w, rows)

	local left = conf:get("footer_left") or game.title
	local right = conf:get("footer_right") or ""
	local color = conf:get("footer_color") or "#ffffffcc"
	local footer = {}
	for i, text in ipairs({left, right}) do
		footer[#footer + 1] = ("hypertext[%f,%f;%f,0.6;title_footer_%d;%s]"):format(
			(W - w) / 2 + (i - 1) * w / 2, H - 0.7, w / 2, i, core.formspec_escape(
				("<global halign=%s color=%s>"):format(i == 1 and "left" or "right", color) ..
				core.hypertext_escape(text)))
	end
	return fs .. table.concat(footer)
end

function game_menu.title_buttons(tabview, game, fields)
	for name, button in pairs(BUTTONS) do
		if fields["title_" .. name] then
			if name == "singleplayer" then
				opened_worlds[game.id] = true
			elseif button.tab then
				tabview:set_tab(button.tab)
			elseif name == "settings" then
				local dlg = create_settings_dlg()
				dlg:set_parent(tabview)
				tabview:hide()
				dlg:show()
			elseif name == "quit" then
				core.close()
			end
			return true
		end
	end
	return false
end
