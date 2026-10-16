local S = core.get_translator(core.get_current_modname())
local F = core.formspec_escape

local FORMNAME = "mcl_hardcore:death"

-- Minecraft-like death screen.  In hardcore worlds there is no respawning:
-- the player can only go on as a spectator.

local H = core.hypertext_escape

-- A line of centered white text; `markup` is hypertext.
local function centered_text(y, h, markup)
	return ("hypertext[0,%s;11.75,%s;;%s]"):format(y, h, F(
		"<global halign=center valign=middle color=#FFFFFF>" .. markup))
end

local function get_death_formspec(player)
	local hardcore = mcl_hardcore.is_hardcore()
	local message = core.strip_colors(mcl_death_messages.get_last_message(player))
	local score = player:get_meta():get_int("mcl_hardcore:score")
	local leave_label = core.is_singleplayer() and S("Title Screen") or S("Disconnect")

	local fs = {
		"formspec_version[6]",
		"size[11.75,8]",
		"no_prepend[]",
		"allow_close[false]",
		"bgcolor[#00000000;true;#600000A0]",
		"style_type[button;border=false;bgimg=mcl_inventory_button9.png;",
			"bgimg_pressed=mcl_inventory_button9_pressed.png;bgimg_middle=2,2;textcolor=#FFFFFF]",
		centered_text(0.6, 1.2, "<style size=40>"
			.. H(hardcore and S("Game Over!") or S("You Died!")) .. "</style>"),
	}
	if message ~= "" then
		table.insert(fs, centered_text(2, 0.6, H(message)))
	end
	table.insert(fs, centered_text(2.6, 0.6, H(S("Score:"))
		.. " <style color=#FFFF55>" .. score .. "</style>"))
	if hardcore then
		table.insert(fs, "button[3.125,4.4;5.5,0.8;spectate;" .. F(S("Spectate World")) .. "]")
	else
		table.insert(fs, "button[3.125,4.4;5.5,0.8;respawn;" .. F(S("Respawn")) .. "]")
	end
	table.insert(fs, "button[3.125,5.4;5.5,0.8;leave;" .. F(leave_label) .. "]")
	return table.concat(fs)
end

local function show_death_screen(player)
	core.show_formspec(player:get_player_name(), FORMNAME, get_death_formspec(player))
end

-- Replaces the engine's death screen.  `reason` is nil when the screen is
-- shown again to a player who is still dead.
function core.show_death_screen(player, reason)
	if reason == nil then
		show_death_screen(player)
		return
	end
	-- Death callbacks registered after the engine's still have to run:
	-- note the score now, before experience is lost, and wait for the
	-- death message.
	player:get_meta():set_int("mcl_hardcore:score", mcl_experience.get_xp(player))
	core.after(0, function()
		if player:is_valid() and player:get_hp() <= 0 then
			show_death_screen(player)
		end
	end)
end

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORMNAME then
		return
	end
	local name = player:get_player_name()
	if player:get_hp() > 0 then
		core.close_formspec(name, FORMNAME)
		return true
	end

	if fields.respawn and not mcl_hardcore.is_hardcore() then
		core.close_formspec(name, FORMNAME)
		player:respawn()
		core.log("action", name .. " respawns at " .. player:get_pos():to_string())
	elseif fields.spectate and mcl_hardcore.is_hardcore() then
		core.close_formspec(name, FORMNAME)
		-- Spectating starts where the player died.
		mcl_gamemode.set_gamemode(player, "spectator")
		player:respawn()
		core.log("action", name .. " died in hardcore mode and is now spectating")
	elseif fields.leave then
		if mcl_hardcore.is_hardcore() then
			core.disconnect_player(name, S("Game over! You can return to spectate this world."))
		else
			core.disconnect_player(name, S("You left the world while dead. You will respawn when you return."))
		end
	end
	return true
end)
