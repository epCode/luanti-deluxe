local S = core.get_translator(core.get_current_modname())

mcl_lightning = {
	interval_low = 17,
	interval_high = 503,
	range_h = 100,
	range_v = 50,
	size = 100,
	on_strike_functions = {},
}

local rng = PcgRandom(32321123312123)

local ps = {}
local ttl = -1

local function revertsky(dtime)
	if ttl == 0 then
		return
	end
	ttl = ttl - dtime
	if ttl > 0 then
		return
	end

	mcl_weather.skycolor.remove_layer("lightning")

	ps = {}
end

core.register_globalstep(revertsky)

-- mcl_lightning strike API

-- See API.md
--[[
	mcl_lightning.register_on_strike(function(pos, pos2, objects)
		-- code
	end)
]]
function mcl_lightning.register_on_strike(func)
	table.insert(mcl_lightning.on_strike_functions, func)
end

-- select a random strike point, midpoint
local function choose_pos(pos)
	if not pos then
		local playerlist = core.get_connected_players()
		local playercount = #playerlist

		-- nobody on
		if playercount == 0 then
			return nil, nil
		end

		local r = rng:next(1, playercount)
		local randomplayer = playerlist[r]
		pos = randomplayer:get_pos()

		-- avoid striking underground
		if pos.y < -20 then
			return nil, nil
		end

		pos.x = math.floor(pos.x - (mcl_lightning.range_h / 2) + rng:next(1, mcl_lightning.range_h))
		pos.y = pos.y + (mcl_lightning.range_v / 2)
		pos.z = math.floor(pos.z - (mcl_lightning.range_h / 2) + rng:next(1, mcl_lightning.range_h))
	end

	local b, pos2 = core.line_of_sight(pos, { x = pos.x, y = pos.y - mcl_lightning.range_v, z = pos.z }, 1)

	-- nothing but air found
	if b then
		return nil, nil
	end

	local n = core.get_node({ x = pos2.x, y = pos2.y - 1/2, z = pos2.z })
	if n.name == "air" or n.name == "ignore" then
		return nil, nil
	end

	return pos, pos2
end

local is_mushroom_islands

core.register_on_mods_loaded (function ()
	is_mushroom_islands = mcl_biome_dispatch.make_biome_test ({
		"MushroomIslands",
	})
end)

function mcl_lightning.strike_func(pos, pos2, objects, for_trap)
	local particle_pos = vector.offset(pos2, 0, (mcl_lightning.size / 2) + 0.5, 0)
	local particle_size = mcl_lightning.size * 10
	local time = 0.2
	core.add_particlespawner({
		amount = 1,
		time = time,
		-- make it hit the top of a block exactly with the bottom
		minpos = particle_pos,
		maxpos = particle_pos,
		minexptime = time,
		maxexptime = time,
		minsize = particle_size,
		maxsize = particle_size,
		collisiondetection = true,
		vertical = true,
		-- to make it appear hitting the node that will get set on fire, make sure
		-- to make the texture mcl_lightning bolt hit exactly in the middle of the
		-- texture (e.g. 127/128 on a 256x wide texture)
		texture = "lightning_lightning_" .. rng:next(1,3) .. ".png",
		glow = core.LIGHT_MAX,
	})

	core.sound_play({ name = "lightning_thunder", gain = 10 }, { pos = pos, max_hear_distance = 500 }, true)

	-- Low chance for a lightning to spawn skeleton trap horse.
	-- ServerLevel.tickThunder: such a bolt, like those summoned by
	-- the trap itself, is visual only (no damage and no fire).
	local trap_pos
	local fire_pos = vector.offset(pos2, 0, 1/2, 0)
	if not for_trap
		and core.get_item_group(core.get_node(vector.offset(fire_pos, 0, -1, 0)).name, "liquid") < 1
		and core.get_node(fire_pos).name == "air" then
		local difficulty = mcl_worlds.get_regional_difficulty (fire_pos)
		local random = rng:next (0, 26000) / 26000
		if random <= difficulty * 0.01 then
			local name = mcl_biome_dispatch.get_biome_name (mcl_util.get_nodepos (fire_pos))
			if not is_mushroom_islands (name) then
				trap_pos = fire_pos
			end
		end
	end
	local visual_only = for_trap or trap_pos ~= nil
	-- LightningBolt.tick: only real bolts, at the bolt (the bottom of
	-- the node above the one struck); the bolt entity is the source
	if mcl_gameevent and not visual_only then
		mcl_gameevent.emit("lightning_strike", fire_pos, {})
	end

	-- damage nearby objects, transform mobs
	for _, obj in pairs(visual_only and {} or objects) do
		local lua = obj:get_luaentity()
		if not lua or not lua._on_lightning_strike
			or lua._on_lightning_strike(lua, pos, pos2, objects) ~= true then
			-- Entity.thunderHit: set on fire for 8 seconds
			-- unless already burning.
			if not mcl_burning.is_burning(obj) then
				mcl_burning.set_on_fire(obj, 8)
			end
			mcl_util.deal_damage(obj, 5, { type = "lightning_bolt" })
		end
	end

	--Affect nearby nodes if they define a "_on_lightning_strike" callback
	for _, npos in pairs(core.find_nodes_in_area(vector.offset(pos2, -5,-5,-5), vector.offset(pos2, 5, 5, 5), {"group:affected_by_lightning"})) do
		local def = core.registered_nodes[core.get_node(npos).name]
		if def and def._on_lightning_strike then
			def._on_lightning_strike(npos, pos, pos2)
		end
	end

	local strike_dim = mcl_worlds.pos_to_dimension(pos2)
	for player in mcl_util.connected_players() do
		-- Lightning bolts light up the sky of players tracking them
		-- (LightningBolt.tick: setSkyFlashTime(2), 16 chunk tracking range)
		local ppos = player:get_pos()
		if player.get_lighting and mcl_worlds.pos_to_dimension(ppos) == strike_dim
				and vector.distance(vector.new(ppos.x, 0, ppos.z),
					vector.new(pos2.x, 0, pos2.z)) <= 256 then
			player:set_lighting({lightmap = {sky_flash = 0.15}})
		end

		local sky = {}
		local sky_table = player:get_sky(true)

		sky.bgcolor, sky.type, sky.textures = sky_table.base_color, sky_table.type, sky_table.textures

		local name = player:get_player_name()
		if ps[name] == nil then
			ps[name] = {p = player, sky = sky}
			mcl_weather.skycolor.add_layer("lightning", { { r = 255, g = 255, b = 255 } }, true)
			mcl_weather.skycolor.active = true
		end
	end

	-- trigger revert of skybox
	ttl = 0.1

	-- Events caused by the lightning strike: Fire and skeleton trap spawning
	pos2.y = pos2.y + 1/2
	if trap_pos then
		local entity
			= core.add_entity(trap_pos, "mobs_mc:skeleton_horse")
		if entity then
			local luaentity = entity:get_luaentity ()
			luaentity._is_trap = true
			-- Mark this object as
			-- persistent; it will despawn
			-- of itself in 900 seconds.
			luaentity.persistent = true
		end
	elseif not visual_only
		and core.get_item_group(core.get_node({ x = pos2.x, y = pos2.y - 1, z = pos2.z }).name, "liquid") < 1
		and core.get_node(pos2).name == "air" then
		-- Cause a fire
		core.set_node(pos2, { name = "mcl_fire:fire" })
	end
end

-- * pos: optional, if not given a random pos will be chosen
-- * returns: bool - success if a strike happened
function mcl_lightning.strike(pos, for_trap)
	local pos2
	pos, pos2 = choose_pos(pos)

	if not pos then
		return false
	end
	local do_strike = true
	if mcl_lightning.on_strike_functions then
		for _, func in pairs(mcl_lightning.on_strike_functions) do
			-- allow on_strike callbacks to destroy entities by re-obtaining objects for each callback
			local objects = core.get_objects_inside_radius(pos2, 3.5)
			local p,stop = func(pos, pos2, objects, for_trap)
			if p then
				pos = p
				pos2 = choose_pos(p)
			end
			do_strike = do_strike and not stop
		end
	end
	if do_strike and pos and pos2 then
		mcl_lightning.strike_func(pos, pos2, core.get_objects_inside_radius (pos2, 3.5), for_trap)
	end
end

core.register_chatcommand("lightning", {
	params = "[<X> <Y> <Z> | <player name>]",
	description = S("Let lightning strike at the specified position or player. No parameter will strike yourself."),
	privs = { maphack = true },
	func = function(name, param)
		local pos = {}
		pos.x, pos.y, pos.z = string.match(param, "^([%d.-]+)[, ] *([%d.-]+)[, ] *([%d.-]+)$")
		pos.x = tonumber(pos.x)
		pos.y = tonumber(pos.y)
		pos.z = tonumber(pos.z)
		local player_to_strike
		if not (pos.x and pos.y and pos.z) then
			pos = nil
			player_to_strike = core.get_player_by_name(param)
			if not player_to_strike and param == "" then
				player_to_strike = core.get_player_by_name(name)
			end
		end
		if not player_to_strike and pos == nil then
			return false, "No position specified and unknown player"
		end
		if pos then
			mcl_lightning.strike(pos)
		elseif player_to_strike then
			mcl_lightning.strike(player_to_strike:get_pos())
		end
		return true
	end,
})
