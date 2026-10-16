-- Luanti
-- SPDX-License-Identifier: LGPL-2.1-or-later

-- Server list for the Join Game tab of games that ask for it in menu.conf
-- (join_tab = servers), laid out like Minecraft's "Play Multiplayer".
-- Public servers are those running the game, unless join_all_games = true.

view_servers = {}

local PING_ICONS = {"server_ping_4.png", "server_ping_3.png", "server_ping_2.png", "server_ping_1.png"}

local function same_server(a, b)
	return a and b and a.address == b.address and a.port == b.port
end

local function selected_server()
	local address = core.settings:get("address")
	local port = tonumber(core.settings:get("remote_port"))
	return address and port and { address = address, port = port }
end

local function set_selected(server)
	if server then
		core.settings:set("address", server.address)
		core.settings:set("remote_port", server.port)
	end
end

local function matches(server, search)
	if search == "" then
		return true
	end
	local text = ((server.name or "") .. " " .. (server.description or "") .. " " ..
		(server.address or "")):lower()
	return text:find(search:lower(), 1, true) ~= nil
end

-- Favorites first, then compatible public servers, then incompatible ones
local function sorted_servers(search, gameid)
	local favorites, public, incompatible = {}, {}, {}
	local favs = serverlistmgr.get_favorites()
	local listed = {}
	for _, server in ipairs(serverlistmgr.servers or {}) do
		server.is_favorite = false
		for i, fav in ipairs(favs) do
			if same_server(server, fav) then
				server.is_favorite = true
				listed[i] = true
			end
		end
		server.is_compatible = is_server_protocol_compat(server.proto_min, server.proto_max)
		if matches(server, search) and (not gameid or server.is_favorite or
				(server.gameid or ""):lower() == gameid) then
			table.insert(server.is_favorite and favorites or
				server.is_compatible and public or incompatible, server)
		end
	end
	for i, fav in ipairs(favs) do
		if not listed[i] and matches(fav, search) then
			fav.is_favorite = true
			fav.is_compatible = true
			table.insert(favorites, fav)
		end
	end
	return { favorites, public, incompatible }
end

local function ping_icon(server)
	if not (server.lag or server.ping) then
		return 0
	end
	local lag = (server.lag or 0) * 1000 + (server.ping or 0) * 250
	return lag <= 125 and 1 or lag <= 175 and 2 or lag <= 250 and 3 or 4
end

local function render_row(server)
	local name = (server.name or ""):trim()
	if name == "" then
		name = server.address .. ":" .. server.port
	end
	local description = (server.description or ""):gsub("\n.*", "")
	if #description > 80 then
		description = description:sub(1, 77) .. "..."
	end
	local players = server.clients and server.clients_max and
		(server.clients .. "/" .. server.clients_max) or ""
	local color = server.is_compatible and "#ffffff" or "#808080"
	return table.concat({
		ping_icon(server),
		color, core.formspec_escape(name),
		color, core.formspec_escape(players),
		"#a0a0a0", core.formspec_escape(description),
	}, ",")
end

function view_servers.formspec(tabview, game, tabdata)
	local W, H = tabview.width, tabview.height
	tabdata.search = tabdata.search or ""
	local all_games = mm_game_theme.get_menu_conf(game):get_bool("join_all_games", false)

	local button_h, gap = 0.7, 0.15
	local _, buttons_h = game_menu.button_rows(0, 0, 1, {{}, {}}, button_h, gap)
	local buttons_y = H - 0.2 - buttons_h
	local buttons = game_menu.button_rows(0.25, buttons_y, W - 0.5, {
		{
			{"btn_join", fgettext("Join Server")},
			{"btn_direct", fgettext("Direct Connection")},
			{"btn_add", fgettext("Add Server")},
		},
		{
			{"btn_register", fgettext("Register")},
			{"btn_remove", fgettext("Remove")},
			{"btn_refresh", fgettext("Refresh")},
		},
	}, button_h, gap)

	local list_w = W - 0.5
	local login_y = buttons_y - 0.2 - 0.7
	local list_y = 1.05
	local list_h = login_y - 0.45 - list_y

	local icons = {"0=" .. core.formspec_escape(defaulttexturedir .. "blank.png")}
	for i, icon in ipairs(PING_ICONS) do
		icons[#icons + 1] = i .. "=" .. core.formspec_escape(defaulttexturedir .. icon)
	end

	local headings = {
		fgettext_ne("Saved Servers"), fgettext_ne("Public Servers"), fgettext_ne("Incompatible Servers"),
	}
	local heading_colors = {"#ffff80", "#80ff80", "#808080"}
	tabdata.lookup = {}
	local rows = {}
	local selected = selected_server()
	local selected_row = 0
	for section, servers in ipairs(sorted_servers(tabdata.search, not all_games and game.id:lower())) do
		if #servers > 0 then
			rows[#rows + 1] = "0," .. heading_colors[section] .. "," ..
				core.formspec_escape(headings[section]) .. ",,,,"
			for _, server in ipairs(servers) do
				rows[#rows + 1] = render_row(server)
				tabdata.lookup[#rows] = server
				if selected_row == 0 and same_server(server, selected) then
					selected_row = #rows
				end
			end
		end
	end

	local fs = {
		("field[0.25,0.25;%f,0.65;te_search;;%s]"):format(list_w - 0.75, core.formspec_escape(tabdata.search)),
		("image_button[%f,0.25;0.65,0.65;%s;btn_search;]"):format(W - 0.9,
			core.formspec_escape(defaulttexturedir .. "search.png")),
		("tooltip[btn_search;%s]"):format(fgettext("Search")),
		"field_enter_after_edit[te_search;true]",
		"field_close_on_enter[te_search;false]",
		game_menu.tableoptions(),
		"tablecolumns[image,align=center,padding=0.25," .. table.concat(icons, ",") ..
			";color,span=1;text,padding=0.5,width=" .. math.floor(list_w * 0.3) ..
			";color,span=1;text,align=right,padding=0.5,width=2" ..
			";color,span=1;text,padding=1]",
		("table[0.25,%f;%f,%f;servers;%s;%d]"):format(list_y, list_w, list_h,
			table.concat(rows, ","), selected_row),
		("field[0.25,%f;%f,0.7;te_name;%s;%s]"):format(login_y, list_w / 2 - 0.1,
			fgettext("Name"), core.formspec_escape(core.settings:get("name"))),
		("pwdfield[%f,%f;%f,0.7;te_pwd;%s]"):format(0.25 + list_w / 2 + 0.1, login_y,
			list_w / 2 - 0.1, fgettext("Password")),
		buttons,
	}
	if #rows == 0 then
		fs[#fs + 1] = ("hypertext[0.25,%f;%f,1;no_servers;%s]"):format(list_y + list_h / 2 - 0.5,
			list_w, core.formspec_escape("<global halign=center valign=middle color=#a0a0a0>" ..
			(serverlistmgr.servers and fgettext_ne("No servers found") or fgettext_ne("Loading servers..."))))
	end
	return table.concat(fs)
end

-- Joins (or registers on) a server; fields carry the name and password
local function connect(tabview, server, fields, register)
	if not server then
		return true
	end
	if server.proto_min and not is_server_protocol_compat_or_error(server.proto_min, server.proto_max) then
		return true
	end
	set_selected(server)

	if register then
		local dlg = create_register_dialog(server.address, server.port, server.name and server)
		dlg:set_parent(tabview)
		tabview:hide()
		dlg:show()
		return true
	end

	gamedata.mode = "join"
	gamedata.address = server.address
	gamedata.port = server.port
	gamedata.playername = fields.te_name or core.settings:get("name")
	gamedata.password = fields.te_pwd or ""
	gamedata.selected_world = 0
	local split = core.settings:get_bool("enable_split_login_register")
	gamedata.allow_login_or_register = split and "login" or "any"
	serverlistmgr.add_favorite(server)
	core.start()
	return true
end

local function selected_row_server(tabdata)
	local idx = core.get_table_index("servers")
	return idx and tabdata.lookup and tabdata.lookup[idx]
end

function view_servers.buttons(tabview, game, fields, tabdata)
	if fields.te_name then
		core.settings:set("name", fields.te_name)
	end

	if fields.servers then
		local event = core.explode_table_event(fields.servers)
		local server = tabdata.lookup[event.row]
		if server then
			set_selected(server)
			if event.type == "DCL" then
				return connect(tabview, server, fields)
			end
		end
		return true
	end

	if fields.key_enter_field == "te_search" or fields.btn_search then
		tabdata.search = fields.te_search or ""
		return true
	end

	if fields.btn_join or (fields.key_enter and fields.key_enter_field ~= "te_search") then
		return connect(tabview, selected_row_server(tabdata), fields)
	end
	if fields.btn_register then
		return connect(tabview, selected_row_server(tabdata), fields, true)
	end

	if fields.btn_direct or fields.btn_add then
		local dlg = create_server_address_dlg(fields.btn_add and "add" or "direct", fields)
		dlg:set_parent(tabview)
		tabview:hide()
		dlg:show()
		return true
	end

	if fields.btn_remove then
		local server = selected_row_server(tabdata)
		if server and server.is_favorite then
			serverlistmgr.delete_favorite(server)
		end
		return true
	end

	if fields.btn_refresh then
		serverlistmgr.sync()
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- "Direct Connection" and "Add Server": an address and port

local function address_formspec(dialogdata)
	local add = dialogdata.mode == "add"
	local content = table.concat({
		("field[0.5,1.6;7.3,0.8;te_address;%s;%s]"):format(fgettext("Server Address"),
			core.formspec_escape(dialogdata.address)),
		("field[8,1.6;2.5,0.8;te_port;%s;%s]"):format(fgettext("Port"),
			core.formspec_escape(dialogdata.port)),
		"set_focus[te_address]",
	})
	local buttons = add and {
		{"address_ok", fgettext("Done")}, {"address_cancel", fgettext("Cancel")},
	} or {
		{"address_ok", fgettext("Join Server")}, {"address_register", fgettext("Register")},
		{"address_cancel", fgettext("Cancel")},
	}
	local W, H = 11, 3.9
	local title = add and fgettext_ne("Add Server") or fgettext_ne("Direct Connection")
	local buttons_fs = game_menu.button_rows(0.5, H - 1.2, W - 1, {buttons})
	return table.concat({
		"formspec_version[6]",
		("size[%f,%f]"):format(W, H),
		("hypertext[0,0.2;%f,0.9;dialog_title;%s]"):format(W, core.formspec_escape(
			"<global halign=center valign=middle><big>" .. core.hypertext_escape(title) .. "</big>")),
		content,
		buttons_fs,
	})
end

local function address_buttonhandler(this, fields)
	if fields.te_address then
		this.data.address = fields.te_address
		this.data.port = fields.te_port
	end
	if fields.address_cancel then
		this:delete()
		return true
	end

	local port = tonumber((this.data.port or ""):match("^%s*([1-9][0-9]*)%s*$"))
	local address = (this.data.address or ""):trim()
	if not (fields.address_ok or fields.address_register or fields.key_enter) then
		return false
	end
	if address == "" or not port then
		return true
	end

	local server = { address = address, port = port }
	if this.data.mode == "add" then
		serverlistmgr.add_favorite(server)
		set_selected(server)
		this:delete()
		return true
	end

	-- Leave the dialog first, so a register dialog returns to the server list
	local parent = this.parent
	this:delete()
	return connect(parent, server, this.data.login, fields.address_register ~= nil)
end

function create_server_address_dlg(mode, login_fields)
	local dlg = dialog_create("server_address", address_formspec, address_buttonhandler, nil)
	local selected = selected_server()
	dlg.data.mode = mode
	dlg.data.address = mode == "direct" and selected and selected.address or ""
	dlg.data.port = tostring(mode == "direct" and selected and selected.port or 30000)
	dlg.data.login = { te_name = login_fields.te_name, te_pwd = login_fields.te_pwd }
	return dlg
end

