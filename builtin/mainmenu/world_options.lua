-- Luanti
-- SPDX-License-Identifier: LGPL-2.1-or-later

-- World options: a game declares them in <game>/world_settingtypes.txt, in the
-- same format as settingtypes.txt. The Create World and Edit World dialogs show
-- them and store the values in the world's world.mt, where the game reads them.
--
-- * Options before the first [Category] are shown directly; every category
--   becomes a button opening a page of its own (e.g. "Game Rules").
-- * Supported types: bool, enum, int, float, string.
-- * A last comment line "Requires: a, !b, mode=hardcore, !mode=creative"
--   shows the option only while the other options have those values.

world_options = {}

local FILENAME = "world_settingtypes.txt"
local SUPPORTED = { bool = true, enum = true, int = true, float = true, string = true }
local ROW_H = 0.8
local GAP = 0.15

local cache = {}

-- { options = {...}, pages = { { name, options = {...} }, ... } }, or nil if the
-- game has no world options
function world_options.get(game)
	if not game then
		return nil
	end
	if cache[game.id] == nil then
		local parsed = settingtypes.parse_file(game.path .. DIR_DELIM .. FILENAME)
		local def = false
		if parsed then
			def = { options = {}, pages = {} }
			local current = def.options
			for _, entry in ipairs(parsed) do
				if entry.type == "category" then
					local page = { name = entry.name, options = {} }
					table.insert(def.pages, page)
					current = page.options
				elseif SUPPORTED[entry.type] then
					table.insert(current, entry)
				else
					core.log("warning", FILENAME .. ": unsupported type " ..
						entry.type .. " of " .. entry.name)
				end
			end
		end
		cache[game.id] = def
	end
	return cache[game.id] or nil
end

local function all_options(def)
	local list = table.copy(def.options)
	for _, page in ipairs(def.pages) do
		for _, option in ipairs(page.options) do
			list[#list + 1] = option
		end
	end
	return list
end

-- Values (strings) from the world's world.mt, or the defaults without a world
function world_options.values(game, world_path)
	local def = world_options.get(game)
	local values = {}
	if not def then
		return values
	end
	local conf = world_path and Settings(world_path .. DIR_DELIM .. "world.mt")
	for _, option in ipairs(all_options(def)) do
		values[option.name] = conf and conf:get(option.name) or option.default
	end
	return values
end

function world_options.write(world_path, values)
	local conf = Settings(world_path .. DIR_DELIM .. "world.mt")
	for name, value in pairs(values) do
		conf:set(name, tostring(value))
	end
	if not conf:write() then
		core.log("error", "Failed to write world options to " .. world_path)
	end
end

local function is_shown(option, values)
	if not option then
		return true
	end
	for key, wanted in pairs(option.requires or {}) do
		local name, value = key:match("^([^=]+)=(.*)$")
		local matches
		if name then
			matches = values[name:trim()] == value:trim()
		else
			matches = core.is_yes(values[key])
		end
		if matches ~= wanted then
			return false
		end
	end
	return true
end

-- Short text about a world from a template like "$mode, $difficulty":
-- $name is replaced by the value of that option, and comma-separated parts
-- naming options hidden by their "Requires:" are left out
function world_options.summary(game, values, template)
	local def = world_options.get(game)
	local by_name = {}
	for _, option in ipairs(def and all_options(def) or {}) do
		by_name[option.name] = option
	end
	local parts = {}
	for _, part in ipairs(template:split(",")) do
		local shown = true
		local text = part:trim():gsub("%$([%w_]+)", function(name)
			shown = shown and is_shown(by_name[name], values)
			local value = (values[name] or ""):gsub("_", " ")
			return value:sub(1, 1):upper() .. value:sub(2)
		end)
		if shown and text ~= "" then
			parts[#parts + 1] = text
		end
	end
	return table.concat(parts, ", ")
end

local function display_value(option, value)
	if option.type == "bool" then
		return core.is_yes(value) and fgettext_ne("ON") or fgettext_ne("OFF")
	end
	-- "hard_mode" -> "Hard mode"
	local text = tostring(value or ""):gsub("_", " ")
	return text:sub(1, 1):upper() .. text:sub(2)
end

-- Rows of controls for options, at (x, y) and w wide: buttons cycling through
-- the values of bool and enum options, fields for the others.
-- Returns the formspec and the height taken.
local function controls(options, values, x, y, w)
	local fs = {}
	local row_y = y
	for _, option in ipairs(options) do
		if is_shown(option, values) then
			local name = "wo_" .. option.name
			local label = option.readable_name or option.name
			if option.type == "bool" or option.type == "enum" then
				fs[#fs + 1] = ("button[%f,%f;%f,%f;%s;%s]"):format(x, row_y, w, ROW_H, name,
					core.formspec_escape(label .. ": " .. display_value(option, values[option.name])))
			else
				fs[#fs + 1] = ("label[%f,%f;%s]"):format(x, row_y + ROW_H / 2,
					core.formspec_escape(label))
				fs[#fs + 1] = ("field[%f,%f;%f,%f;%s;;%s]"):format(x + w * 0.75, row_y,
					w * 0.25, ROW_H, name, core.formspec_escape(values[option.name] or ""))
				fs[#fs + 1] = ("field_close_on_enter[%s;false]"):format(name)
			end
			if option.comment and option.comment ~= "" then
				fs[#fs + 1] = ("tooltip[%s;%s]"):format(name, core.formspec_escape(option.comment))
			end
			row_y = row_y + ROW_H + GAP
		end
	end
	return table.concat(fs), math.max(0, row_y - y - GAP)
end

-- Applies clicks and field edits; returns true if the formspec must be redrawn
local function handle(options, values, fields)
	local redraw = false
	for _, option in ipairs(options) do
		local value = fields["wo_" .. option.name]
		if value then
			if option.type == "bool" then
				values[option.name] = tostring(not core.is_yes(values[option.name]))
				redraw = true
			elseif option.type == "enum" then
				local i = table.indexof(option.values, values[option.name])
				values[option.name] = option.values[i % #option.values + 1]
				redraw = true
			elseif option.type == "string" then
				values[option.name] = value
			else
				local n = tonumber(value)
				if n and (not option.min or n >= option.min) and (not option.max or n <= option.max)
						and (option.type ~= "int" or n == math.floor(n)) then
					values[option.name] = value
				end
			end
		end
	end
	return redraw
end

--------------------------------------------------------------------------------
-- A page (category) of options in a dialog of its own

local function page_formspec(dialogdata)
	local page = dialogdata.page
	local W = 10
	local fs, h = controls(page.options, dialogdata.values, 0.5, 1.2, W - 1)
	local H = 1.2 + h + 0.4 + ROW_H + 0.4
	return table.concat({
		"formspec_version[6]",
		("size[%f,%f]"):format(W, H),
		("hypertext[0,0.2;%f,0.9;page_title;%s]"):format(W, core.formspec_escape(
			"<global halign=center valign=middle><big>" ..
			core.hypertext_escape(page.name) .. "</big>")),
		fs,
		("button[0.5,%f;%f,%f;page_defaults;%s]"):format(H - 0.4 - ROW_H, (W - 1.2) / 2,
			ROW_H, fgettext("Reset to Defaults")),
		("button[%f,%f;%f,%f;page_done;%s]"):format(W / 2 + 0.1, H - 0.4 - ROW_H,
			(W - 1.2) / 2, ROW_H, fgettext("Done")),
	})
end

local function page_buttonhandler(this, fields)
	local page = this.data.page
	if fields.page_done or fields.key_enter then
		handle(page.options, this.data.values, fields)
		this:delete()
		return true
	end
	if fields.page_defaults then
		for _, option in ipairs(page.options) do
			this.data.values[option.name] = option.default
		end
		return true
	end
	return handle(page.options, this.data.values, fields)
end

--------------------------------------------------------------------------------

-- Controls for a game's options plus a button per page, at (x, y), w wide.
-- Returns the formspec and the height taken.
function world_options.formspec(game, values, x, y, w)
	local def = world_options.get(game)
	if not def then
		return "", 0
	end
	local fs, h = controls(def.options, values, x, y, w)
	local parts = { fs }
	local row_y = y + h + (h > 0 and GAP or 0)
	for i, page in ipairs(def.pages) do
		parts[#parts + 1] = ("button[%f,%f;%f,%f;wo_page_%d;%s]"):format(x, row_y, w, ROW_H, i,
			core.formspec_escape(page.name .. "..."))
		row_y = row_y + ROW_H + GAP
	end
	return table.concat(parts), math.max(0, row_y - y - GAP)
end

-- Handles the controls made by world_options.formspec. Pages open as
-- dialogs on top of parent. Returns true if the formspec must be redrawn.
function world_options.handle(game, values, fields, parent)
	local def = world_options.get(game)
	if not def then
		return false
	end
	for i, page in ipairs(def.pages) do
		if fields["wo_page_" .. i] then
			handle(def.options, values, fields)
			local dlg = dialog_create("world_options_page", page_formspec, page_buttonhandler, nil)
			dlg.data.page = page
			dlg.data.values = values
			dlg:set_parent(parent)
			parent:hide()
			dlg:show()
			return true
		end
	end
	return handle(def.options, values, fields)
end
