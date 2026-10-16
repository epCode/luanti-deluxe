local NIGHT_VISION_RATIO = 0.45
local S = core.get_translator(core.get_current_modname())

mcl_player.register_player_setting("mcl_weather:enable_clouds", {
	type = "boolean",
	section = "Graphics",
	short_desc = S("Enable clouds"),
	ui_default = "true",
})

function mcl_weather.set_sky_box_clear(player, sky, fog)
	if mcl_serverplayer.is_csm_at_least (player, 2) then
		return
	end

	local pos = player:get_pos()
	if core.get_item_group(core.get_node(vector.new(pos.x,pos.y+1.5,pos.z)).name, "water") ~= 0
			and not mcl_weather.lightmap_enabled(player) then return end
	local sc = {
			day_sky = "#7BA4FF",
			day_horizon = "#C0D8FF",
			dawn_sky = "#7BA4FF",
			dawn_horizon = "#C0D8FF",
			night_sky = "#000000",
			night_horizon = "#4A6790",
			indoors = "#C0D8FF",
			fog_sun_tint = "#ff5f33",
			fog_moon_tint = nil,
			fog_tint_type = "custom"
		}
	if sky then
		sc.day_sky = sky
		sc.dawn_sky = sky
	end
	if fog then
		sc.day_horizon = fog
		sc.dawn_horizon = fog
	end
	player:set_sky({
		type = "regular",
		sky_color = sc,
		clouds =  mcl_player.get_player_setting(player, "mcl_weather:enable_clouds", true),
	})
end

function mcl_weather.set_sky_color(player, def)
	if mcl_serverplayer.is_csm_at_least (player, 2) then
		return
	end

	local pos = player:get_pos()
	if core.get_item_group(core.get_node(vector.offset(pos, 0, 1.5, 0)).name, "water") ~= 0
			and not mcl_weather.lightmap_enabled(player) then return end
	player:set_sky({
		type = def.type,
		sky_color = def.sky_color,
		clouds = def.clouds,
	})
end

-- Lightmap lighting (engine lighting model of Minecraft, see the engine's
-- lua_api.md, set_lighting): visual/* environment attributes of the
-- dimension types (Java Edition 26.3 data/minecraft/dimension_type/*.json).
local LIGHTMAP_DIMENSIONS = {
	overworld = {
		ambient_color = "#0a0a0a", sky_light_color = "#ffffff",
		sky_light_factor = 1.0, day_cycle = true, constant_shade = false,
		fog_start = 0, fog_end = 1024,
	},
	nether = {
		ambient_color = "#302821", sky_light_color = "#7a7aff",
		sky_light_factor = 0.0, day_cycle = false, constant_shade = true,
		fog_start = 10, fog_end = 96,
	},
	["end"] = {
		ambient_color = "#3f473f", sky_light_color = "#ac60cd",
		sky_light_factor = 0.0, day_cycle = false, constant_shade = false,
		fog_start = 0, fog_end = 1024,
	},
}
LIGHTMAP_DIMENSIONS.void = LIGHTMAP_DIMENSIONS.overworld

local lightmap_sent = {}

local function lightmap_enabled(player)
	local lighting = player.get_lighting and player:get_lighting()
	return lighting and lighting.lightmap and lighting.lightmap.enabled
end
mcl_weather.lightmap_enabled = lightmap_enabled

-- Sets the cloud color for a weather. With lightmap lighting the engine
-- applies Minecraft's day cycle and weather to the clouds itself, so they
-- keep Minecraft's base color (visual/cloud_color #ccffffff).
function mcl_weather.set_cloud_color(player, color)
	if lightmap_enabled(player) then
		color = "#ffffffcc"
	end
	player:set_clouds({color = color})
end

-- Sends the lightmap parameters of the player's dimension, weather and
-- effects. The engine applies water and lava fog itself.
function mcl_weather.update_lightmap(player, dim)
	if not lightmap_enabled(player) then
		return
	end
	local d = LIGHTMAP_DIMENSIONS[dim] or LIGHTMAP_DIMENSIONS.overworld
	local meta = player:get_meta()
	-- Weather is per dimension in Minecraft: the overworld's rain and
	-- thunder darken it everywhere, regardless of the biome
	local overworld = dim == "overworld"
	local state = mcl_weather.state
	local lm = {
		ambient_color = d.ambient_color,
		sky_light_color = d.sky_light_color,
		sky_light_factor = d.sky_light_factor,
		day_cycle = d.day_cycle,
		constant_shade = d.constant_shade,
		rain = overworld and state ~= "none" and 1 or 0,
		thunder = overworld and state == "thunder" and 1 or 0,
		night_vision = meta:get_int("night_vision") == 1 and 1 or 0,
		-- Darkness effect blend factor (mcl_potions)
		darkness = math.min(1, math.max(0, meta:get_float("darkness"))),
		fog_start = d.fog_start,
		fog_end = d.fog_end,
		-- LevelData.getHorizonHeight: sea level, y = 63. Worlds from the
		-- older mapgens have their sea at the mapgen water level instead.
		horizon_height = mcl_vars.enable_mcl_levelgen and mcl_worlds.layer_to_y(127)
			or tonumber(core.get_mapgen_setting("water_level")) or 1,
	}
	local key = core.serialize(lm)
	local name = player:get_player_name()
	if lightmap_sent[name] == key then
		return
	end
	lightmap_sent[name] = key
	player:set_lighting({lightmap = lm})
end

core.register_on_leaveplayer(function(player)
	lightmap_sent[player:get_player_name()] = nil
end)

local function get_sky_color (pos)
	local nodepos = mcl_util.get_nodepos (pos)
	return mcl_biome_dispatch.get_sky_color (nodepos)
end

local function get_fog_color (pos)
	local nodepos = mcl_util.get_nodepos (pos)
	return mcl_biome_dispatch.get_fog_color (nodepos)
end

local function get_both_colors (pos)
	local nodepos = mcl_util.get_nodepos (pos)
	return mcl_biome_dispatch.get_sky_and_fog_colors (nodepos)
end

mcl_weather.skycolor = {
	-- Should be activated before do any effect.
	active = true,

	-- To skip update interval
	force_update = true,

	-- Update interval.
	update_interval = 3,

	-- Main sky colors: starts from midnight to midnight.
	-- Please do not set directly. Use add_layer instead.
	colors = {},

	-- min value which will be used in color gradient, usualy its first user given color in 'pure' color.
	min_val = 0,

	-- number of colors while constructing gradient of user given colors
	max_val = 1000,

	-- Table for tracking layer order
	layer_names = {},

	-- To layer to colors table
	add_layer = function(layer_name, layer_color, _)
		mcl_weather.skycolor.colors[layer_name] = layer_color
		table.insert(mcl_weather.skycolor.layer_names, layer_name)
		mcl_weather.skycolor.force_update = true
	end,

	current_layer_name = function()
		return mcl_weather.skycolor.layer_names[#mcl_weather.skycolor.layer_names]
	end,

	-- Retrieve layer from colors table
	retrieve_layer = function()
		local last_layer = mcl_weather.skycolor.current_layer_name()
		return mcl_weather.skycolor.colors[last_layer]
	end,

	-- Remove layer from colors table
	remove_layer = function(layer_name)
		for k, name in pairs(mcl_weather.skycolor.layer_names) do
			if name == layer_name then
				table.remove(mcl_weather.skycolor.layer_names, k)
				mcl_weather.skycolor.force_update = true
				return
			end
		end
	end,

	-- Wrapper for updating day/night ratio that respects night vision
	override_day_night_ratio = function(player, ratio)
		if not mcl_serverplayer.is_csm_at_least (player, 2) then
			local meta = player:get_meta()
			local has_night_vision = meta:get_int("night_vision") == 1
			local has_darkness = meta:get_float("darkness") > 0
			local is_visited_shepherd = meta:get_int("mcl_shepherd:special") == 1
			local arg
			if has_darkness and not is_visited_shepherd then
				if has_night_vision then arg = 0.1
				else arg = 0 end
			else
				-- Apply night vision only for dark sky
				local is_dark = core.get_timeofday() > 0.8 or core.get_timeofday() < 0.2 or mcl_weather.state ~= "none"
				local pos = player:get_pos()
				local dim = mcl_worlds.pos_to_dimension(pos)
				if (has_night_vision or is_visited_shepherd) and is_dark and dim ~= "nether" and dim ~= "end" then
					if ratio == nil then
						arg = NIGHT_VISION_RATIO
					else
						arg = math.max(ratio, NIGHT_VISION_RATIO)
					end
				else
					arg = ratio
				end
			end
			player:override_day_night_ratio(arg)
		end
	end,

	-- Update sky color. If players not specified update sky for all players.
	update_sky_color = function(players)
		-- Override day/night ratio as well
		players = mcl_weather.skycolor.utils.get_players(players)
		for _, player in ipairs(players) do
			local pos = player:get_pos()
			local dim = mcl_worlds.pos_to_dimension(pos)
			local has_weather = (mcl_worlds.has_weather(pos) and (mcl_weather.state =="rain" or mcl_weather.state == "thunder") and mcl_weather.has_snow(pos)) or ((mcl_weather.state =="rain" or mcl_weather.state == "thunder") and mcl_weather.has_rain(pos))
			local checkname = core.get_node(vector.new(pos.x,pos.y+1.5,pos.z)).name
			mcl_weather.update_lightmap(player, dim)
			if core.get_item_group(checkname, "water") ~= 0
					and not lightmap_enabled(player) then
				local water_color = "#3F76E4"
				if checkname == "mclx_core:river_water_source"
					or checkname == "mclx_core:river_water_flowing" then
					water_color = "#0084FF"
				end
				player:set_sky({ type = "regular",
					sky_color = {
						day_sky = water_color,
						day_horizon = water_color,
						dawn_sky = water_color,
						dawn_horizon = water_color,
						night_sky = water_color,
						night_horizon = water_color,
						indoors = water_color,
						fog_sun_tint = water_color,
						fog_moon_tint = water_color,
						fog_tint_type = "custom"
					},
					clouds = false,
				})
			end
			if dim == "overworld" then
				local biomesky, biomefog = get_both_colors (pos)
				-- With lightmap lighting the engine darkens the sky for
				-- the weather and time of day itself (Minecraft's
				-- environment attributes): always send the biome colors
				if mcl_weather.state == "none" or lightmap_enabled(player) then
					-- Clear weather
					mcl_weather.set_sky_box_clear(player,biomesky,biomefog)
					player:set_sun({visible = true, sunrise_visible = true})
					player:set_moon({visible = true})
					player:set_stars({visible = true})
					mcl_weather.skycolor.override_day_night_ratio(player, nil)
				elseif not has_weather then
					local day_color = mcl_weather.skycolor.get_sky_layer_color(0.15)
					local dawn_color = mcl_weather.skycolor.get_sky_layer_color(0.27)
					local night_color = mcl_weather.skycolor.get_sky_layer_color(0.1)
					mcl_weather.set_sky_color(player, {
						type = "regular",
						sky_color = {
							day_sky = day_color,
							day_horizon = day_color,
							dawn_sky = dawn_color,
							dawn_horizon = dawn_color,
							night_sky = night_color,
							night_horizon = night_color,
						},
						clouds =  mcl_player.get_player_setting(player, "mcl_weather:enable_clouds", true),
					})
					player:set_sun({visible = false, sunrise_visible = false})
					player:set_moon({visible = false})
					player:set_stars({visible = false})
				elseif has_weather then
					-- Weather skies
					local day_color = mcl_weather.skycolor.get_sky_layer_color(0.5)
					local dawn_color = mcl_weather.skycolor.get_sky_layer_color(0.75)
					local night_color = mcl_weather.skycolor.get_sky_layer_color(0)
					mcl_weather.set_sky_color(player, {
						type = "regular",
						sky_color = {
							day_sky = day_color,
							day_horizon = day_color,
							dawn_sky = dawn_color,
							dawn_horizon = dawn_color,
							night_sky = night_color,
							night_horizon = night_color,
						},
						clouds =  mcl_player.get_player_setting(player, "mcl_weather:enable_clouds", true),
					})
					player:set_sun({visible = false, sunrise_visible = false})
					player:set_moon({visible = false})
					player:set_stars({visible = false})

					local lf = mcl_weather.get_current_light_factor()
					if mcl_weather.skycolor.current_layer_name() == "lightning" then
						mcl_weather.skycolor.override_day_night_ratio(player, 1)
					elseif lf then
						-- This used to be blatantly wrong and there appears to be another
						-- fairly complex solution around so I will explain what it's doing (now):
						-- The light is basically derived by the distance of the current time to
						-- 0.5 which means midday/noon. i.e. the key here is 1 - math.abs(0.5 - w)
						-- the rest is just modifications and a minimum light level of 0.2
						local w = core.get_timeofday()
						local light = math.max(0.2,((1 - math.abs(0.5 - w)) * lf) - 0.15)
						mcl_weather.skycolor.override_day_night_ratio(player, light)
					else
						mcl_weather.skycolor.override_day_night_ratio(player, nil)
					end
				end
			elseif dim == "end" then
				local biomesky = get_sky_color (pos) or "#000000"
				local t = "mcl_playerplus_end_sky.png"
				player:set_sky({ type = "skybox",
					base_color = biomesky,
					textures = {t,t,t,t,t,t},
					clouds = false,
				})
				player:set_sun({visible = false , sunrise_visible = false})
				player:set_moon({visible = false})
				player:set_stars({visible = false})
				mcl_weather.skycolor.override_day_night_ratio(player, 0.5)
			elseif dim == "nether" then
				local biomefog = get_fog_color (pos) or "#330808"
				mcl_weather.set_sky_color(player, {
					type = "regular",
					sky_color = {
						day_sky = biomefog,
						day_horizon = biomefog,
						dawn_sky = biomefog,
						dawn_horizon = biomefog,
						night_sky = biomefog,
						night_horizon = biomefog,
						indoors = biomefog,
						fog_sun_tint = biomefog,
						fog_moon_tint = biomefog,
						fog_tint_type = "custom"
					},
					clouds = false,
				})
				player:set_sun({visible = false , sunrise_visible = false})
				player:set_moon({visible = false})
				player:set_stars({visible = false})
				mcl_weather.skycolor.override_day_night_ratio(player, nil)
			elseif dim == "void" then
				player:set_sky({ type = "plain",
					base_color = "#000000",
					clouds = false,
				})
				player:set_sun({visible = false, sunrise_visible = false})
				player:set_moon({visible = false})
				player:set_stars({visible = false})
			end
		end
	end,

	-- Returns current layer color in {r, g, b} format
	get_sky_layer_color = function(timeofday)
		if #mcl_weather.skycolor.layer_names == 0 then
			return nil
		end

		-- min timeofday value 0; max timeofday value 1. So sky color gradient range will be between 0 and 1 * mcl_weather.skycolor.max_val.
		local rounded_time = math.floor(timeofday * mcl_weather.skycolor.max_val)
		local color = mcl_weather.skycolor.utils.convert_to_rgb(mcl_weather.skycolor.min_val, mcl_weather.skycolor.max_val, rounded_time, mcl_weather.skycolor.retrieve_layer())
		return color
	end,

	utils = {
		convert_to_rgb = function(minval, maxval, current_val, colors)
			local max_index = #colors - 1
			local val = (current_val-minval) / (maxval-minval) * max_index + 1.0
			local index1 = math.floor(val)
			local index2 = math.min(math.floor(val)+1, max_index + 1)
			local f = val - index1
			local c1 = colors[index1]
			local c2 = colors[index2]
			return {r=math.floor(c1.r + f*(c2.r - c1.r)), g=math.floor(c1.g + f*(c2.g-c1.g)), b=math.floor(c1.b + f*(c2.b - c1.b))}
		end,

		-- Simply getter. Ether returns user given players list or get all connected players if none provided
		get_players = function(players_in)
			local players = {}
			if players_in == nil then
				for player in mcl_util.connected_players () do
					if not mcl_serverplayer.is_csm_at_least (player, 2) then
						table.insert (players, player)
					end
				end
			else
				for _, player in ipairs (players_in) do
					if not mcl_serverplayer.is_csm_at_least (player, 2) then
						table.insert (players, player)
					end
				end
			end
			return players
		end,

		-- Returns first player sky color. I assume that all players are in same color layout.
		get_current_bg_color = function()
			local players = mcl_weather.skycolor.utils.get_players(nil)
			if players[1] then
				return players[1]:get_sky(true).sky_color
			end
			return nil
		end
	},

}

local timer = 0
core.register_globalstep(function(dtime)
	if mcl_weather.skycolor.active ~= true or #core.get_connected_players() == 0 then
		return
	end

	if mcl_weather.skycolor.force_update then
		mcl_weather.skycolor.update_sky_color()
		mcl_weather.skycolor.force_update = false
		return
	end

	-- regular updates based on iterval
	timer = timer + dtime;
	if timer >= mcl_weather.skycolor.update_interval then
		mcl_weather.skycolor.update_sky_color()
		timer = 0
	end

end)

local function initsky(player)
	if lightmap_enabled(player) then
		-- Minecraft has no light shafts or exposure adaptation. Sun shadows
		-- (shader pack style, pixelated by the engine) only take away sky
		-- light, so this is how much of it is lost in the shade.
		player:set_lighting({
			shadows = { intensity = 0.6 },
			volumetric_light = { strength = 0 },
			exposure = {
				luminance_min = -3,
				luminance_max = -3,
				exposure_correction = 0,
				speed_dark_bright = 1000,
				speed_bright_dark = 1000,
				center_weight_power = 1,
			},
			saturation = 1.0,
		})
		lightmap_sent[player:get_player_name()] = nil
	elseif player.set_lighting then
		player:set_lighting({
			shadows = { intensity = 0.33 },
			volumetric_light = { strength = 0.2 },
			exposure = {
				luminance_min = -3.5,
				luminance_max = -2.5,
				exposure_correction = 0.35,
				speed_dark_bright = 1500,
				speed_bright_dark = 700,
			},
			saturation = 1.1,
		})
	end

	if (mcl_weather.skycolor.active) then
		mcl_weather.skycolor.force_update = true
	end

	if lightmap_enabled(player) then
		-- Minecraft clouds (CloudRenderer, visual/cloud_height 192.33):
		-- 4 nodes thick, drifting west at 0.6 nodes per second. The engine
		-- shades them like Minecraft; the color is visual/cloud_color.
		player:set_clouds({
			height = mcl_worlds.layer_to_y(256) + 0.33,
			speed = {x = -0.6, z = 0},
			thickness = 4,
			color = "#ffffffcc",
			ambient = "#000000",
		})
		-- Drawn additively like Minecraft's sun
		player:set_sun({texture = "mcl_weather_sun.png"})
	else
		player:set_clouds(mcl_worlds.get_cloud_parameters() or {height=mcl_worlds.layer_to_y(127), speed={x=-2, z=0}, thickness=4, color="#FFF0FEF"})
	end
end

core.register_on_joinplayer(initsky)
core.register_on_respawnplayer(initsky)

mcl_worlds.register_on_dimension_change(function(player)
	mcl_weather.skycolor.update_sky_color({player})
end)
