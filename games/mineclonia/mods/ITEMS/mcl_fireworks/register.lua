local S = core.get_translator(core.get_current_modname())

local description = S("Firework Rocket")

-- The rocket that boosts a gliding player (FireworkRocketEntity attached
-- to its owner): projectile_shoot on its first tick (Projectile.tick) and
-- explode with the owner as source when its life ends
-- (FireworkRocketEntity.explode)
local function rocket_game_events(user, duration)
	if not mcl_gameevent or type(user) ~= "userdata" then
		return
	end
	mcl_gameevent.emit_entity(user, "projectile_shoot")
	local name = user:get_player_name()
	core.after(duration, function()
		local player = core.get_player_by_name(name)
		if player then
			mcl_gameevent.emit_entity(player, "explode")
		end
	end)
end

local function use_rocket(itemstack, user, duration)
	if mcl_serverplayer.is_csm_capable (user) then
		if mcl_serverplayer.use_rocket (user, duration) then
			rocket_game_events(user, duration)
			if not core.is_creative_enabled (user:get_player_name()) then
				itemstack:take_item()
			end
			core.sound_play("mcl_fireworks_rocket", {pos = user:get_pos()})
		end
		return itemstack
	end
	local elytra = mcl_player.players[user].elytra
	if elytra.active then
		rocket_game_events(user, duration)
		elytra.rocketing = duration
		if not core.is_creative_enabled(user:get_player_name()) then
			itemstack:take_item()
		end
		core.sound_play("mcl_fireworks_rocket", {pos = user:get_pos()})
	end
	return itemstack
end


local function register_rocket(n, duration, force)
	core.register_craftitem("mcl_fireworks:rocket_" .. n, {
		description = description,
		_tt_help = S("Flight Duration: @1s", string.format("%.1f", duration)),
		inventory_image = "mcl_fireworks_rocket.png",
		on_place = function(itemstack, user, pointed_thing)
			if mcl_util.place_was_held(user) then
				return
			end
			return use_rocket(itemstack, user, duration)
		end,
		on_secondary_use = function(itemstack, user, pointed_thing)
			return use_rocket(itemstack, user, duration)
		end,
	})
end


register_rocket(1, 2.2, 10)
register_rocket(2, 4.5, 20)
register_rocket(3, 6, 30)
