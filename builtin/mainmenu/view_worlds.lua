-- Luanti
-- SPDX-License-Identifier: LGPL-2.1-or-later

-- World list for the Start Game tab of games that ask for it in menu.conf
-- (start_tab = worlds, or title), laid out like Minecraft's "Select World".

view_worlds = {}

-- Index of the selected world in the (filtered) world list
local function selected_index()
	return core.get_table_index("sp_worlds") or filterlist.get_current_index(menudata.worldlist,
		tonumber(core.settings:get("mainmenu_last_selected_world"))) or 0
end

local function select_world(index)
	core.settings:set("mainmenu_last_selected_world", menudata.worldlist:get_raw_index(index))
	menu_worldmt_legacy(index)
end

-- What the game's world options or the engine settings say about a world,
-- e.g. "Hardcore, Hard" or "Creative Mode"
local function world_details(game, world)
	local conf = Settings(world.path .. DIR_DELIM .. "world.mt")
	local summary = game and mm_game_theme.get_menu_conf(game):get("world_summary")
	if summary then
		return world_options.summary(game, world_options.values(game, world.path), summary)
	end
	local creative = conf:get_bool("creative_mode", core.settings:get_bool("creative_mode"))
	local damage = conf:get_bool("enable_damage", core.settings:get_bool("enable_damage"))
	local details = creative and fgettext_ne("Creative Mode") or fgettext_ne("Survival Mode")
	if not damage then
		details = details .. ", " .. fgettext_ne("no damage")
	end
	return details
end

function view_worlds.formspec(tabview, game)
	local W, H = tabview.width, tabview.height
	local hosting = core.settings:get_bool("enable_server")

	local row2 = {
		{"world_edit", fgettext("Edit")},
		{"world_delete", fgettext("Delete")},
		{"world_configure", fgettext("Mods")},
	}
	if game_menu.view(game, "start_tab") == "title" then
		row2[#row2 + 1] = {"worlds_back", fgettext("Back")}
	end
	local _, buttons_h = game_menu.button_rows(0, 0, 1, {{}, {}})
	local buttons_y = H - 0.25 - buttons_h
	local buttons = game_menu.button_rows(0.25, buttons_y, W - 0.5, {
		{
			{"play", hosting and fgettext("Host Selected World") or fgettext("Play Selected World")},
			{"world_create", fgettext("Create New World")},
		},
		row2,
	})

	local list = menudata.worldlist:get_list()
	local rows = {}
	for _, world in ipairs(list) do
		rows[#rows + 1] = "#ffffff," .. core.formspec_escape(world.name) ..
			",#a0a0a0," .. core.formspec_escape(world_details(game, world))
	end

	local list_w = W - 0.5
	local list_h = buttons_y - 0.5
	local fs = {
		game_menu.tableoptions(),
		("tablecolumns[color;text,padding=0.5,width=%f;color;text,align=right,padding=0.5,width=%f]"):format(
			list_w * 0.5, list_w * 0.45),
		("table[0.25,0.25;%f,%f;sp_worlds;%s;%d]"):format(list_w, list_h,
			table.concat(rows, ","), math.min(selected_index(), #list)),
		buttons,
	}
	if #list == 0 then
		fs[#fs + 1] = ("hypertext[0.25,%f;%f,1;no_worlds;%s]"):format(0.25 + list_h / 2 - 0.5,
			list_w, core.formspec_escape("<global halign=center valign=middle color=#a0a0a0>" ..
			fgettext_ne("No worlds yet. Create one!")))
	end
	return table.concat(fs)
end

local function play(index)
	local raw_index = menudata.worldlist:get_raw_index(index)
	local world = menudata.worldlist:get_raw_element(raw_index)
	if not world then
		return
	end
	gamedata.selected_world = raw_index

	local game = pkgmgr.find_by_gameid(world.gameid)
	if game then
		core.settings:set("menu_last_game", game.id)
	end

	-- The game may force or forbid some of these (game.conf disabled_settings)
	local disabled_settings = menu_get_disabled_settings(game)
	for k in pairs(menu_valid_disabled_settings) do
		local v = disabled_settings[k]
		if v ~= nil then
			if k == "enable_server" and v == true then
				error("Setting 'enable_server' cannot be force-enabled! The game.conf needs to be fixed.")
			end
			core.settings:set_bool(k, v)
		end
	end

	if core.settings:get_bool("enable_server") then
		gamedata.mode = "host"
		gamedata.playername = core.settings:get("name")
		gamedata.password = menudata.host_password or ""
		gamedata.port = core.settings:get("port")
		gamedata.address = ""
	else
		gamedata.mode = "singleplayer"
	end
	core.start()
end

local function open_dialog(tabview, dlg)
	if dlg then
		dlg:set_parent(tabview)
		tabview:hide()
		dlg:show()
	end
	return true
end

function view_worlds.buttons(tabview, game, fields)
	local index = selected_index()
	local list = menudata.worldlist:get_list()

	if fields.sp_worlds then
		local event = core.explode_table_event(fields.sp_worlds)
		if event.row > 0 then
			select_world(event.row)
			if event.type == "DCL" then
				play(event.row)
			end
		end
		return true
	end

	if fields.worlds_back then
		game_menu.back_to_title(game)
		return true
	end

	if fields.play or fields.key_enter then
		if list[index] then
			play(index)
		end
		return true
	end

	if fields.world_create then
		return open_dialog(tabview, create_create_world_dlg())
	end

	local world = list[index]
	if not world then
		return false
	end
	local raw_index = menudata.worldlist:get_raw_index(index)

	if fields.world_edit then
		return open_dialog(tabview, create_edit_world_dlg(index))
	end
	if fields.world_delete then
		return open_dialog(tabview, create_delete_world_dlg(world.name, raw_index))
	end
	if fields.world_configure then
		return open_dialog(tabview, create_configure_world_dlg(raw_index))
	end
	return false
end

--------------------------------------------------------------------------------
-- "Edit World": the game's world options, engine options and hosting

local function edit_formspec(dialogdata)
	local world = dialogdata.world
	local game = pkgmgr.find_by_gameid(world.gameid)
	local disabled = menu_get_disabled_settings(game)
	local hosting = core.settings:get_bool("enable_server") and disabled.enable_server == nil
	local W = 11

	local fs = {}
	local y = 1.2
	local options_fs, options_h = world_options.formspec(game, dialogdata.options, 0.5, y, W - 1)
	fs[#fs + 1] = options_fs
	if options_h > 0 then
		y = y + options_h + 0.4
	end

	local function checkbox(setting, label)
		if disabled[setting] == nil then
			fs[#fs + 1] = ("checkbox[0.5,%f;cb_%s;%s;%s]"):format(y + 0.2, setting, label,
				tostring(core.settings:get_bool(setting)))
			y = y + 0.6
		end
	end
	checkbox("creative_mode", fgettext("Creative Mode"))
	checkbox("enable_damage", fgettext("Enable Damage"))
	checkbox("enable_server", fgettext("Host Server"))
	if hosting then
		checkbox("server_announce", fgettext("Announce Server"))
		y = y + 0.6
		fs[#fs + 1] = ("field[0.5,%f;3.8,0.8;te_playername;%s;%s]"):format(y,
			fgettext("Name"), core.formspec_escape(core.settings:get("name")))
		fs[#fs + 1] = ("pwdfield[4.5,%f;3.8,0.8;te_passwd;%s]"):format(y, fgettext("Password"))
		fs[#fs + 1] = ("field[8.5,%f;2,0.8;te_serverport;%s;%s]"):format(y,
			fgettext("Port"), core.formspec_escape(core.settings:get("port")))
		y = y + 0.8
	end

	local H = y + 1.6
	return table.concat({
		"formspec_version[6]",
		("size[%f,%f]"):format(W, H),
		("hypertext[0,0.2;%f,0.9;edit_title;%s]"):format(W, core.formspec_escape(
			"<global halign=center valign=middle><big>" ..
			core.hypertext_escape(fgettext_ne("Edit World: $1", world.name)) .. "</big>")),
		table.concat(fs),
		("button[%f,%f;5,0.8;edit_done;%s]"):format((W - 5) / 2, H - 1.2, fgettext("Done")),
	})
end

local function edit_buttonhandler(this, fields)
	local index = this.data.index
	local game = pkgmgr.find_by_gameid(this.data.world.gameid)

	local function save()
		if fields.te_playername then
			core.settings:set("name", fields.te_playername)
		end
		if fields.te_passwd then
			menudata.host_password = fields.te_passwd
		end
		if fields.te_serverport and tonumber(fields.te_serverport) then
			core.settings:set("port", fields.te_serverport)
		end
		if world_options.get(game) then
			world_options.write(this.data.world.path, this.data.options)
		end
	end

	for _, setting in ipairs({"creative_mode", "enable_damage", "server_announce"}) do
		if fields["cb_" .. setting] then
			core.settings:set(setting, fields["cb_" .. setting])
			menu_worldmt(index, setting, fields["cb_" .. setting])
			return true
		end
	end
	if fields.cb_enable_server then
		save()
		core.settings:set("enable_server", fields.cb_enable_server)
		return true
	end

	if fields.edit_done or fields.key_enter or fields.quit then
		world_options.handle(game, this.data.options, fields, this)
		save()
		this:delete()
		return true
	end
	return world_options.handle(game, this.data.options, fields, this)
end

function create_edit_world_dlg(index)
	local world = menudata.worldlist:get_list()[index]
	if not world then
		return nil
	end
	local dlg = dialog_create("edit_world", edit_formspec, edit_buttonhandler, nil)
	dlg.data.index = index
	dlg.data.world = world
	dlg.data.options = world_options.values(pkgmgr.find_by_gameid(world.gameid), world.path)
	return dlg
end
