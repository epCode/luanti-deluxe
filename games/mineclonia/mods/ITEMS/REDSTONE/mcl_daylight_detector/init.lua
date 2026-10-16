local S = core.get_translator(core.get_current_modname())

local boxes = { -8/16, -8/16, -8/16,  8/16, -2/16, 8/16 }
local toggle_inverted = {
	["mcl_daylight_detector:daylight_detector"] = "mcl_daylight_detector:daylight_detector_inverted",
	["mcl_daylight_detector:daylight_detector_inverted"] = "mcl_daylight_detector:daylight_detector",
}

-- Port of Minecraft's DaylightDetectorBlock. param2 is the output power.

local BLOCK = "mcl_daylight_detector:daylight_detector"

local function is_inverted(node)
	return node.name == "mcl_daylight_detector:daylight_detector_inverted"
end

-- Minecraft's time of day (0 at noon) from Luanti's (0.5 at noon)
local function mc_time_of_day()
	local day_time = (core.get_timeofday() * 24000 - 6000) % 24000
	local d = (day_time / 24000 - 0.25) % 1
	local e = 0.5 - math.cos(d * math.pi) / 2
	return (d * 2 + e) / 3
end

-- Level.updateSkyBrightness
local function sky_darken()
	local state = rawget(_G, "mcl_weather") and mcl_weather.state or "none"
	local rain = (state == "rain" or state == "thunder" or state == "snow") and 1 or 0
	local thunder = state == "thunder" and 1 or 0
	local r = 1 - rain * 5 / 16
	local t = 1 - thunder * 5 / 16
	local sky = 0.5 + 2 * math.max(-0.25, math.min(0.25, math.cos(mc_time_of_day() * math.pi * 2)))
	return math.floor((1 - sky * r * t) * 11)
end

-- DaylightDetectorBlock.updateSignalStrength
local function update_signal_strength(pos, node)
	local sky = core.get_natural_light(pos, 0.5) or 0
	local target = sky - sky_darken()
	local sun_angle = mc_time_of_day() * math.pi * 2
	if is_inverted(node) then
		target = 15 - target
	elseif target > 0 then
		local offset = sun_angle < math.pi and 0 or math.pi * 2
		sun_angle = sun_angle + (offset - sun_angle) * 0.2
		local v = target * math.cos(sun_angle)
		target = math.floor(v + 0.5)
	end
	target = math.max(0, math.min(15, target))
	if node.param2 ~= target then
		mcl_redstone.set_block(pos, {name = node.name, param2 = target}, 3)
	end
end

local tickers = {}

-- DaylightDetectorBlock.getTicker: only in dimensions with sky light
local function add_ticker(pos)
	local h = core.hash_node_position(pos)
	if tickers[h] or mcl_worlds.pos_to_dimension(pos) ~= "overworld" then
		return
	end
	tickers[h] = mcl_redstone.add_ticker({
		pos = vector.copy(pos),
		tick = function(t)
			local node = mcl_redstone.get_node(t.pos)
			if mcl_redstone.block_id(node.name) ~= BLOCK then
				t.removed = true
				tickers[h] = nil
				return
			end
			if mcl_redstone.get_game_time() % 20 == 0 then
				update_signal_strength(t.pos, node)
			end
		end,
	})
end

local function own_signal(pos, node)
	return node.param2
end

local commdef = {
	drawtype = "nodebox",
	wield_scale = { x=1, y=1, z=3 },
	paramtype = "light",
	is_ground_content = false,
	selection_box = {
		type = "fixed",
		fixed = boxes
	},
	node_box = {
		type = "fixed",
		fixed = boxes
	},
	groups = {handy=1,axey=1, material_wood=1, flammable=-1, daylight_detector=1, unmovable_by_piston = 1},
	sounds = mcl_sounds.node_sound_glass_defaults(),
	on_construct = function(pos)
		add_ticker(pos)
	end,
	on_rightclick = function(pos, node, clicker, pointed_thing)
		local protname = clicker:get_player_name()
		if core.is_protected(pos, protname) then
			core.record_protection_violation(pos, protname)
			return
		end
		-- DaylightDetectorBlock.useWithoutItem
		mcl_redstone._begin()
		local new = {name = toggle_inverted[node.name], param2 = node.param2}
		mcl_redstone.set_block(pos, new, 2)
		if mcl_gameevent then
			mcl_gameevent.emit("block_change", pos, {source = core.is_player(clicker) and clicker or nil, node = new})
		end
		update_signal_strength(pos, new)
		mcl_redstone._end()
	end,
	_mcl_hardness = 0.2,
	_mcl_redstone = {
		block = BLOCK,
		signal_source = true,
		own_signal = own_signal,
		get_signal = own_signal,
	},
}

core.register_node("mcl_daylight_detector:daylight_detector", table.merge(commdef, {
	tiles = { "jeija_solar_panel.png","jeija_solar_panel.png","jeija_solar_panel_side.png",
		"jeija_solar_panel_side.png","jeija_solar_panel_side.png","jeija_solar_panel_side.png", },
	wield_image = "jeija_solar_panel.png",
	description=S("Daylight Sensor"),
	_tt_help = S("Provides redstone power when in sunlight") .. "\n" ..S("Can be inverted"),
	_doc_items_longdesc = S("Daylight detectors are redstone components which provide redstone power when they are in sunlight and no power otherwise. They can also be inverted.").."\n"..
		S("In inverted state, they provide redstone power when they are not in sunlight and no power otherwise."),
	_doc_items_usagehelp = S("Use the daylight detector to toggle its state."),
}))


core.register_node("mcl_daylight_detector:daylight_detector_inverted", table.merge(commdef, {
	tiles = { "jeija_solar_panel_inverted.png","jeija_solar_panel_inverted.png","jeija_solar_panel_side.png",
	"jeija_solar_panel_side.png","jeija_solar_panel_side.png","jeija_solar_panel_side.png", },
	wield_image = "jeija_solar_panel_inverted.png",
	drop = "mcl_daylight_detector:daylight_detector",
	groups = table.merge(commdef.groups, {not_in_creative_inventory=1}),
	description=S("Inverted Daylight Sensor"),
	_doc_items_create_entry = false,
}))


core.register_craft({
	output = "mcl_daylight_detector:daylight_detector",
	recipe = {
		{"mcl_core:glass", "mcl_core:glass", "mcl_core:glass"},
		{"mcl_nether:quartz", "mcl_nether:quartz", "mcl_nether:quartz"},
		{"group:wood_slab", "group:wood_slab", "group:wood_slab"},
	}
})

core.register_lbm({
	label = "Tick daylight detectors",
	name = "mcl_daylight_detector:ticker",
	nodenames = {"group:daylight_detector"},
	run_at_every_load = true,
	action = function(pos)
		add_ticker(pos)
	end,
})

core.register_craft({
	type = "fuel",
	recipe = "mcl_daylight_detector:daylight_detector",
	burntime = 15
})

doc.add_entry_alias("nodes", "mcl_daylight_detector:daylight_detector", "nodes", "mcl_daylight_detector:solar_panel_on")
doc.add_entry_alias("nodes", "mcl_daylight_detector:daylight_detector", "nodes", "mcl_daylight_detector:solar_panel_inverted_off")
doc.add_entry_alias("nodes", "mcl_daylight_detector:daylight_detector", "nodes", "mcl_daylight_detector:solar_panel_inverted_on")
