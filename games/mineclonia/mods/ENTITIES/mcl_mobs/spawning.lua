local pairs = pairs
local ipairs = ipairs

--lua locals
local mob_class = mcl_mobs.mob_class

-- MobCategory.despawnDistance (default) and noDespawnDistance.
local instant_despawn_range = 128
local random_despawn_range = 32

--do mobs spawn?
local mobs_spawn = core.settings:get_bool("mobs_spawn", true) ~= false
local logging = core.settings:get_bool("mcl_logging_mobs_spawn", false)
local only_peaceful_mobs = core.settings:get_bool ("only_peaceful_mobs", false)

local function count_mobs_total(mob_type)
	local num = 0
	for _,l in pairs(core.luaentities) do
		if l.is_mob then
			if mob_type == nil or l.type == mob_type then
				num = num + 1
			end
		end
	end
	return num
end

local function count_mobs_all()
	local mobs_found = {}
	local num = 0
	for _,entity in pairs(core.luaentities) do
		if entity.is_mob then
			local mob_name = entity.name
			if entity._reloaded then
				mob_name = mob_name .. " (reloaded)"
			end
			if mobs_found[mob_name] then
				mobs_found[mob_name] = mobs_found[mob_name] + 1
			else
				mobs_found[mob_name] = 1
			end
			num = num + 1
		end
	end
	return mobs_found, num
end

function mcl_mobs.spawn_setup (def)
	mcl_util.log_deprecated_call ("error", string.format (
		"[mcl_mobs] `%s' will not spawn naturally until its spawning configuration is updated to conform to the modern spawning API.",
		def.name)
	)
end

function mcl_mobs.spawn (pos, id, staticdata)
	mcl_util.log_deprecated_call ("error", "[mcl_mobs] use `core.add_entity' or `mcl_mobs.spawn_abnormally' instead.")
	return core.add_entity (pos, id, staticdata)
end

local S = core.get_translator ("mcl_mobs")

------------------------------------------------------------------------
-- Minecraft light levels.
------------------------------------------------------------------------

-- These assume the game's `separate_sky_light' layout, in which the
-- day bank of param1 holds sky light alone and the night bank block
-- light, so that `core.get_natural_light (pos, 0.5)' is the raw sky
-- light (LightLayer.SKY) and the night bank the block light
-- (LightLayer.BLOCK).

-- Timeline day.json: minecraft:gameplay/sky_light_level, a
-- multiplier of the attribute's default value of 15, keyed by
-- Minecraft day tick (0 = sunrise).
local sky_light_keyframes = {
	{ 133, 1.0, },
	{ 11867, 1.0, },
	{ 13670, 4 / 15, }, -- 0.26666668 (float32), i.e. a level of 4.
	{ 22330, 4 / 15, },
	{ 24133, 1.0, },
}

local function sky_light_factor (tick)
	if tick < sky_light_keyframes[1][1] then
		tick = tick + 24000
	end
	for i = 1, #sky_light_keyframes - 1 do
		local k0, k1 = sky_light_keyframes[i], sky_light_keyframes[i + 1]
		if tick >= k0[1] and tick < k1[1] then
			local progress = (tick - k0[1]) / (k1[1] - k0[1])
			return k0[2] + (k1[2] - k0[2]) * progress
		end
	end
	return 1.0
end

-- Level.updateSkyBrightness: skyDarken = 15 - SKY_LIGHT_LEVEL, where
-- WeatherAttributes.RAIN and THUNDER alpha-blend the level towards 4
-- by 0.3125 and 0.52734375 respectively.

function mcl_mobs.get_sky_darken ()
	local tick = (core.get_timeofday () * 24000 - 6000) % 24000
	local level = 15 * sky_light_factor (tick)
	local weather = mcl_weather and mcl_weather.state
	if weather == "thunder" then
		level = level + (4 - level) * 0.52734375
	elseif weather == "rain" or weather == "snow" then
		level = level + (4 - level) * 0.3125
	end
	-- (int) truncation; the epsilon absorbs rounding that float32
	-- arithmetic would not exhibit.
	return math.floor (15 - level + 1e-6)
end

function mcl_mobs.is_thundering ()
	return mcl_weather and mcl_weather.state == "thunder" or false
end

-- LightLayer.SKY.  Dimensions without sky light (DimensionType
-- has_skylight) always report 0.
local skyless_dimensions = {
	nether = true,
	["end"] = true,
	void = true,
}

function mcl_mobs.get_sky_light (pos)
	if skyless_dimensions[mcl_worlds.pos_to_dimension (pos)] then
		return 0
	end
	return core.get_natural_light (pos, 0.5) or 0
end

-- LightLayer.BLOCK, including the node's own light emission.
function mcl_mobs.get_block_light (pos, node)
	node = node or core.get_node (pos)
	local def = core.registered_nodes[node.name]
	if not def then
		return 0
	end
	local light = def.paramtype == "light"
		and core.get_artificial_light (node.param1) or 0
	return math.max (light, def.light_source or 0)
end

-- LevelReader.getRawBrightness (pos, darken): the greater of the sky
-- light diminished by DARKEN and the block light.  DARKEN defaults
-- to the current sky darkening (getMaxLocalRawBrightness (pos)).
function mcl_mobs.get_raw_brightness (pos, darken, node)
	darken = darken or mcl_mobs.get_sky_darken ()
	local sky = mcl_mobs.get_sky_light (pos) - darken
	return math.max (sky, mcl_mobs.get_block_light (pos, node))
end

-- Monster spawning light rules of each dimension type
-- (monster_spawn_block_light_limit, monster_spawn_light_level).
mcl_mobs.monster_spawn_light = {
	overworld = {
		block_light_limit = 0,
		light_test_min = 0,
		light_test_max = 7,
	},
	nether = {
		block_light_limit = 15,
		light_test_min = 7,
		light_test_max = 7,
	},
	["end"] = {
		block_light_limit = 0,
		light_test_min = 15,
		light_test_max = 15,
	},
}

-- Monster.isDarkEnoughToSpawn.
function mcl_mobs.is_dark_enough_to_spawn (pos, node)
	local rules = mcl_mobs.monster_spawn_light[mcl_worlds.pos_to_dimension (pos)]
		or mcl_mobs.monster_spawn_light.overworld
	local sky = mcl_mobs.get_sky_light (pos)
	if sky > math.random (0, 31) then
		return false
	end
	local block = mcl_mobs.get_block_light (pos, node)
	if rules.block_light_limit < 15 and block > rules.block_light_limit then
		return false
	end
	local darken = mcl_mobs.is_thundering () and 10
		or mcl_mobs.get_sky_darken ()
	local brightness = math.max (sky - darken, block)
	return brightness <= math.random (rules.light_test_min,
					  rules.light_test_max)
end

------------------------------------------------------------------------
-- Despawning.
------------------------------------------------------------------------

-- Positions of players who are not spectators (EntitySelector.NO_SPECTATORS),
-- refreshed every server step.
local despawn_player_positions = {}

core.register_globalstep (function (_)
	local n = 0
	for player in mcl_util.connected_players () do
		if not mcl_gamemode.is_spectator (player) then
			n = n + 1
			despawn_player_positions[n] = player:get_pos ()
		end
	end
	for i = n + 1, #despawn_player_positions do
		despawn_player_positions[i] = nil
	end
end)

local function nearest_player_distance (pos)
	local min_dist = math.huge
	for _, player_pos in ipairs (despawn_player_positions) do
		local d = vector.distance (player_pos, pos)
		if d < min_dist then
			min_dist = d
		end
	end
	return min_dist
end

-- Mob.removeWhenFarAway.  D_TO_CLOSEST_PLAYER is the distance to the
-- nearest player.
function mob_class:despawn_ok (d_to_closest_player)
	return true
end

-- Not Mob.isPersistenceRequired or Mob.requiresCustomPersistence.
function mob_class:despawn_allowed ()
	local nametag = self.nametag and self.nametag ~= ""
	if self.can_despawn == true then
		if not nametag and not self.tamed
			and not self.persistent
		-- _just_portaled mobs should not despawn to allow
		-- mapblocks containing them to be unloaded if no
		-- players are nearby.
			and not self._just_portaled
		-- Mobs that are attached to other objects should
		-- never despawn.
			and not self.object:get_attach () then
			return true
		end
	end
	return false
end

-- MobCategory.getDespawnDistance.
function mob_class:get_despawn_distance ()
	local category = mcl_mobs.spawn_categories[self._spawn_category]
	return category and category.despawn_distance or instant_despawn_range
end

local scale_chance = mcl_mobs.scale_chance
local eye_pos = vector.zero ()

-- Mob.checkDespawn, with the noActionTime bookkeeping of
-- Mob.serverAiStep and Monster.updateNoActionTime.
-- `_inactivity_timer' is noActionTime in seconds.
--
-- Mobs may set `_light_hastens_despawn' (default: true for mobs of
-- type "monster") to mirror Monster.updateNoActionTime, which ages
-- noActionTime three times as fast at eye level brightness above 12;
-- it should be false for mobs that are not Monster subclasses in
-- Minecraft (e.g. hoglins, slimes, magma cubes, ghasts, phantoms,
-- shulkers).

function mob_class:check_despawn (pos, dtime)
	-- Mobs not allowed in peaceful are discarded irrespective of
	-- persistence.
	if (mcl_vars.difficulty <= 0 or only_peaceful_mobs)
		and not self.persist_in_peaceful then
		self:kill_me ("peaceful difficulty")
		return true
	end

	local t = self._inactivity_timer + dtime
	if not self:despawn_allowed () then
		self._inactivity_timer = t
		return false
	end

	local light_hastens_despawn = self._light_hastens_despawn
	if light_hastens_despawn == nil then
		light_hastens_despawn = self.type == "monster"
	end
	if light_hastens_despawn then
		-- getLightLevelDependentMagicValue () > 0.5.
		eye_pos.x = pos.x
		eye_pos.y = pos.y + (self.head_eye_height or 0)
		eye_pos.z = pos.z
		if mcl_mobs.get_raw_brightness (eye_pos) > 12 then
			t = t + 2 * dtime
		end
	end
	self._inactivity_timer = t
	-- Recorded so that the period for which this mob is frozen in
	-- an inactive mapblock may be established when it is reloaded.
	self._despawn_stamp = core.get_gametime ()

	local min_dist = nearest_player_distance (pos)
	if min_dist == math.huge then
		return false
	end
	local remove_when_far_away = self:despawn_ok (min_dist)
	if remove_when_far_away and min_dist > self:get_despawn_distance () then
		self:kill_me ("no players within distance "
			      .. self:get_despawn_distance ())
		return true
	end
	if remove_when_far_away and t > 30.0
		and min_dist > random_despawn_range
		and math.random (1, scale_chance (800, dtime)) == 1 then
		self:kill_me ("random chance at distance " .. math.round(min_dist))
		return true
	elseif min_dist < random_despawn_range then
		self._inactivity_timer = 0
	end
	return false
end

function mob_class:kill_me(msg)
	if logging then
		core.log("action", "[mcl_mobs] Mob " .. self.name .. " despawns at " .. core.pos_to_string(self.object:get_pos(), 1) .. ": " .. msg)
	end
	if self._jockey_rider then
		if self._jockey_rider:is_valid () then
			-- Detach this rider.
			local entity = self._jockey_rider:get_luaentity ()
			entity:unjock ()
			entity.jockey_vehicle = nil
		end
		self._jockey_rider = nil
	end
	self:safe_remove()
end

core.register_chatcommand("spawn_mob",{
	privs = { debug = true },
	description=S("spawn_mob is a chatcommand that allows you to type in the name of a mob without 'typing mobs_mc:' all the time like so; 'spawn_mob spider'. however, there is more you can do with this special command, currently you can edit any number, boolean, and string variable you choose with this format: spawn_mob 'any_mob:var<mobs_variable=variable_value>:'. any_mob being your mob of choice, mobs_variable being the variable, and variable value being the value of the chosen variable. and example of this format: \n spawn_mob skeleton:var<passive=true>:\n this would spawn a skeleton that wouldn't attack you. REMEMBER-THIS> when changing a number value always prefix it with 'NUM', example: \n spawn_mob skeleton:var<jump_height=NUM10>:\n this setting the skelly's jump height to 10. if you want to make multiple changes to a mob, you can, example: \n spawn_mob skeleton:var<passive=true>::var<jump_height=NUM10>::var<fly_in=air>::var<fly=true>:\n etc."),
	func = function(n,param)
		local pos = core.get_player_by_name(n):get_pos()

		local modifiers = {}
		for capture in string.gmatch(param, "%:(.-)%:") do
			table.insert(modifiers, ":"..capture)
		end

		local mod1 = string.find(param, ":")



		local mobname = param
		if mod1 then
			mobname = string.sub(param, 1, mod1-1)
		end

		local staticdata = core.serialize ({ persist_in_peaceful = true })
		local mob = core.add_entity (pos, mobname, staticdata)

		if mob then
			for c=1, #modifiers do
				local modifs = modifiers[c]

				local mod1 = string.find(modifs, ":")
				local mod_start = string.find(modifs, "<")
				local mod_vals = string.find(modifs, "=")
				local mod_end = string.find(modifs, ">")
				local mob_entity = mob:get_luaentity()
				if string.sub(modifs, mod1+1, mod1+3) == "var" then
					if mod1 and mod_start and mod_vals and mod_end then
						local variable = string.sub(modifs, mod_start+1, mod_vals-1)
						local value = string.sub(modifs, mod_vals+1, mod_end-1)

						local number_tag = string.find(value, "NUM")
						if number_tag then
							value = tonumber(string.sub(value, 4, -1)) ---@diagnostic disable-line: cast-local-type
						end

						if value == "true" then
							value = true ---@diagnostic disable-line: cast-local-type
						elseif value == "false" then
							value = false ---@diagnostic disable-line: cast-local-type
						end

						if not mob_entity[variable] then
							core.log("warning", n.." mob variable "..variable.." previously unset")
						end

						mob_entity[variable] = value

					else
						core.log("warning", n.." couldn't modify "..mobname.." at "..core.pos_to_string(pos).. ", missing paramaters")
					end
				else
					core.log("warning", n.." couldn't modify "..mobname.." at "..core.pos_to_string(pos).. ", missing modification type")
				end
			end

			core.log("action", n.." spawned "..mobname.." at "..core.pos_to_string(pos))
			return true, mobname.." spawned at "..core.pos_to_string(pos)
		else
			return false, "Couldn't spawn "..mobname
		end
	end
})

local SPAWN_DISTANCE = tonumber (core.settings:get ("active_block_range")) or 4
local MOB_CAP_DIVISOR = 289 -- NaturalSpawner.MAGIC_NUMBER (17^2)
local MOB_CAP_RECIPROCAL = 1 / MOB_CAP_DIVISOR
local OVERWORLD_CEILING_MARGIN = 64
local OVERWORLD_DEFAULT_CEILING = 256
local LEVELS = { "overworld", "nether", "end", }

-- Return a range of positions along the vertical axes in which to
-- spawn mobs around a player at POS in the dimension LEVEL.

local function level_y_range (level, pos)
	if level == "overworld" then
		local nodepos = math.floor (pos.y + 0.5)
		-- Spawn mobs between the bottom of the overworld and
		-- OVERWORLD_DEFAULT_CEILING.
		if nodepos < OVERWORLD_DEFAULT_CEILING - OVERWORLD_CEILING_MARGIN then
			return mcl_vars.mg_overworld_min, OVERWORLD_DEFAULT_CEILING
		else
			-- Otherwise spawn between nodepos - 236 and
			-- nodepos + 64.
			return nodepos
				- OVERWORLD_DEFAULT_CEILING
				+ OVERWORLD_CEILING_MARGIN
				+ mcl_vars.mg_overworld_min,
				nodepos + OVERWORLD_CEILING_MARGIN
		end
	elseif level == "nether" then
		return mcl_vars.mg_nether_min,
			mcl_vars.mg_nether_max + 128
	elseif level == "end" then
		return mcl_vars.mg_end_min,
			mcl_vars.mg_end_max_official - 1
	end
end

-- Return a list of the chunks (16x16 node columns) in which to spawn
-- mobs in LEVEL, the positions of the players in LEVEL who are not
-- spectators, data describing the vertical extent of each chunk, and
-- the number of such players.

local function collect_unique_chunks (level)
	local chunk_data, chunks, players = {}, {}, {}
	local n_players = 0
	for player in mcl_util.connected_players () do
		-- Players outside any dimension should not be
		-- considered for spawning.  Neither are spectators.
		local pos = player:get_pos ()
		if not mcl_gamemode.is_spectator (player)
			and mcl_worlds.pos_to_dimension (pos) == level then
			local chunk_x = math.floor (pos.x / 16.0)
			local chunk_z = math.floor (pos.z / 16.0)
			players[player] = pos
			n_players = n_players + 1

			local start, fin = level_y_range (level, pos)

			for x = chunk_x - SPAWN_DISTANCE, chunk_x + SPAWN_DISTANCE do
				for z = chunk_z - SPAWN_DISTANCE, chunk_z + SPAWN_DISTANCE do
					local hash = ((x + 2048) * 4096) + (z + 2048)
					local data = chunk_data[hash]
					if not data then
						table.insert (chunks, hash)
						chunk_data[hash] = {
							y_min = start,
							y_max = fin,
						}
					else
						data.y_min = math.min (data.y_min, start)
						data.y_max = math.max (data.y_max, fin)
					end
				end
			end
		end
	end
	return chunks, players, chunk_data, n_players
end

local function collect_all_unique_chunks ()
	local chunks = {}
	for _, level in ipairs (LEVELS) do
		chunks[level] = { collect_unique_chunks (level) }
	end
	return chunks
end

-- Chunk count (per level) from which to derive a number of mobs
-- which, if exceeded by overfulfillment of the mob caps, will induce
-- reloaded mobs immediately to despawn.
local spawn_border_chunks = {}
-- Mob caps per level and category, as computed by the last spawning
-- cycle.
local current_mob_caps = {}

-- Number of mobs counted towards the mob caps per level and category.
local active_mobs_by_category = {}
mcl_mobs.active_mobs_by_category = active_mobs_by_category

local spawn_categories

-- NaturalSpawner.SpawnState.canSpawnForCategoryGlobal's limit,
-- floored at `min_chunk_mob_cap' to compensate for the smaller number
-- of chunks loaded around players.

local function update_mob_caps (chunks)
	for _, level in ipairs (LEVELS) do
		local n_chunks = #chunks[level][1]
		local caps = current_mob_caps[level] or {}
		for category, data in pairs (spawn_categories) do
			local global_max
				= math.floor ((n_chunks * data.chunk_mob_cap)
					* MOB_CAP_RECIPROCAL)
			caps[category] = math.max (global_max, data.min_chunk_mob_cap)
		end
		current_mob_caps[level] = caps
		-- Calculate the number of chunks bordering this list
		-- of chunks as if it were a single rectangle.
		spawn_border_chunks[level]
			= (math.floor (math.sqrt (n_chunks)) + 1) * 4
	end
end

core.register_chatcommand("mobstats",{
	privs = { debug = true },
	func = function(n, _)
		local pos = core.get_player_by_name (n):get_pos ()
		local level = mcl_worlds.pos_to_dimension (pos)

		if level == "void" then
			local blurb = "No spawning data is available in the Void"
			core.chat_send_player (n, blurb)
			return
		end

		local chunks = collect_all_unique_chunks ()
		update_mob_caps (chunks)
		core.chat_send_player (n, table.concat ({
			"Currently active mobs by category: ",
			dump (active_mobs_by_category[level] or {}),
			"\n",
			"Chunk-derived mob caps: ",
			dump (current_mob_caps[level]), "\n",
			"Chunk count: ", tostring (#chunks[level][1]), "\n",
			"Mob cap overfulfillment theshold: ",
			tostring (spawn_border_chunks[level]), "\n",
			"No. active mobs in total: ",
			tostring (count_mobs_total ()), "\n"
		}))

		local mob_counts, _ = count_mobs_all ()
		for k, v1 in pairs (mob_counts) do
			core.chat_send_player (n, table.concat ({
				"  ", k, ": ", tostring (v1),
			}))
		end
	end
})

------------------------------------------------------------------------
-- Modern spawning mechanics.
------------------------------------------------------------------------

local MAX_PACK_SIZE = 8

function mob_class:check_despawn_on_activation (self_pos)
	if not self:despawn_allowed ()
	-- New spawns (e.g. from infested blocks or mob spawners)
	-- should always be permitted.
		or not self._reloaded then
		return false
	end

	-- A Minecraft mob that is out of sight of every player keeps
	-- ticking (and despawning) as far as 128 blocks away, whereas
	-- this mob was frozen in an inactive MapBlock.  Apply the
	-- random despawning (1/800 per tick once noActionTime exceeds
	-- 600) that it would have undergone in the meantime.
	local stamp = self._despawn_stamp
	if stamp then
		local elapsed = core.get_gametime () - stamp
		if elapsed > 0 then
			local before = self._inactivity_timer or 0
			local after = before + elapsed
			local eligible = after - math.max (before, 30.0)
			self._inactivity_timer = after
			self._despawn_stamp = nil
			if eligible > 0
				and self:despawn_ok (random_despawn_range + 1)
				and math.random () > (799 / 800) ^ (eligible * 20) then
				if logging then
					core.log ("action", table.concat ({
						"[mcl_mobs] ", self.name, " at ",
						vector.to_string (self_pos),
						" is despawning after ",
						tostring (math.round (elapsed)),
						" seconds in an inactive MapBlock",
					}))
				end
				self.object:remove ()
				return true
			end
		end
	end

	local category = self._spawn_category
	local caps = spawn_categories[category]

	-- Have mob caps been exceeded by a greater number of mobs
	-- than the previously established number of border blocks
	-- permit?

	if caps then
		local level = mcl_worlds.pos_to_dimension (self_pos)
		if level == "void" then
			return false
		end

		-- Mobs loaded before mob caps were first initialized.
		local global = current_mob_caps[level]
		local border = spawn_border_chunks[level]
		if not global or not border then
			core.log ("warning", self.name .. " was loaded before spawning "
				  .. "was initialized.")
			return false
		end

		local counts = active_mobs_by_category[level]
		local active = counts and counts[category]
		if active and active > global[category] then
			local buffer
				= math.floor ((caps.chunk_mob_cap * border)
					* MOB_CAP_RECIPROCAL)
			buffer = buffer + MAX_PACK_SIZE
			if active > buffer then
				if logging then
					core.log ("action", table.concat ({
						"[mcl_mobs] ", self.name,
						" at ", vector.to_string (self_pos),
						" is despawning as it is more than ",
						tostring (buffer), " mobs over the",
						" mob cap for `", category, "' (",
						tostring (global[category]), ")",
					}))
				end
				self.object:remove ()
				return true
			end
		end
	end
	return false
end

function mob_class:announce_for_spawning ()
	local category = self._spawn_category
	local self_pos = self.object:get_pos ()
	local level = mcl_worlds.pos_to_dimension (self_pos)
	local counts = active_mobs_by_category[level]
	if not counts then
		counts = {}
		active_mobs_by_category[level] = counts
	end
	counts[category] = (counts[category] or 0) + 1
	self._spawn_level = level
	self._activated = true
	return self:check_despawn_on_activation (self_pos)
end

function mob_class:remove_for_spawning ()
	self._activated = nil

	-- Record this mob's absence.
	local category = self._spawn_category
	local counts = active_mobs_by_category[self._spawn_level]
	local n_active = counts and counts[category]
	if not n_active or n_active <= 0 then
		return
	end
	counts[category] = n_active - 1
end

-- NaturalSpawner.createState counts every mob that is neither
-- persistent (Mob.isPersistenceRequired) nor a passenger
-- (Mob.requiresCustomPersistence); tamed mobs are counted.

function mob_class:update_mob_caps ()
	local persistent = self.persistent
		or self.object:get_attach () ~= nil
	if self._activated and persistent then
		self:remove_for_spawning ()
	elseif not self._activated and not persistent then
		-- Value is whether this process prompted the mob to
		-- be deleted.
		return self:announce_for_spawning ()
	end
	return false
end

local registered_spawners = {}
local registered_structure_spawners = {}

-- This map between spawner lists and their total weight is rather
-- contrived but avoids the creation of combined hash tables/arrays,
-- which are NYIs in Luajit...
local total_weight = {}

mcl_mobs.registered_spawners = registered_spawners
mcl_mobs.registered_structure_spawners = registered_structure_spawners

-- MobCategory: chunk_mob_cap is `max', is_friendly `isFriendly', and
-- is_animal `isPersistent' (categories spawned once every 400 ticks).
-- despawn_distance is `despawnDistance'.

spawn_categories = {
	["monster"] = {
		chunk_mob_cap = 70,
		min_chunk_mob_cap = 16,
		is_friendly = false,
		is_animal = false,
		despawn_distance = 128,
	},
	["creature"] = {
		chunk_mob_cap = 10,
		min_chunk_mob_cap = 10,
		is_friendly = true,
		is_animal = true,
		despawn_distance = 128,
	},
	["ambient"] = {
		chunk_mob_cap = 15,
		min_chunk_mob_cap = 5,
		is_friendly = true,
		is_animal = false,
		despawn_distance = 128,
	},
	["axolotl"] = {
		chunk_mob_cap = 5,
		min_chunk_mob_cap = 5,
		is_friendly = true,
		is_animal = false,
		despawn_distance = 128,
	},
	["underground_water_creature"] = {
		chunk_mob_cap = 5,
		min_chunk_mob_cap = 5,
		is_friendly = true,
		is_animal = false,
		despawn_distance = 128,
	},
	["water_creature"] = {
		chunk_mob_cap = 5,
		min_chunk_mob_cap = 5,
		is_friendly = true,
		is_animal = false,
		despawn_distance = 128,
	},
	["water_ambient"] = {
		chunk_mob_cap = 20,
		min_chunk_mob_cap = 5,
		is_friendly = true,
		is_animal = false,
		despawn_distance = 64,
	},
}
mcl_mobs.spawn_categories = spawn_categories

-- NaturalSpawner.SPAWNING_CATEGORIES, in MobCategory order.
local SPAWNING_CATEGORIES = {
	"monster",
	"creature",
	"ambient",
	"axolotl",
	"underground_water_creature",
	"water_creature",
	"water_ambient",
}

local function dist_sqr (a, b)
	local dx = b.x - a.x
	local dy = b.y - a.y
	local dz = b.z - a.z
	return dx * dx + dy * dy + dz * dz
end

local function get_nearest_player (pos, list)
	local dist, pos_nearest, player = nil

	for player_1, test_pos in pairs (list) do
		local d = dist_sqr (test_pos, pos)
		if not dist or dist > d then
			dist = d
			pos_nearest = test_pos
			player = player_1
		end
	end

	return player, pos_nearest
end

local function get_weighted_value (mob_types)
	if total_weight[mob_types] > 0 then
		local weight = math.random (total_weight[mob_types])
		for _, spawner in ipairs (mob_types) do
			weight = weight - spawner.weight
			if weight <= 0 then
				return spawner
			end
		end
	end
	return nil
end

local get_biome_name_nosample = mcl_biome_dispatch.get_biome_name_nosample
local get_structures_at = mcl_levelgen.get_structures_at

local function structure_override (pos, category)
	local structures = get_structures_at (pos, false)
	for _, structure in pairs (structures) do
		local list = registered_structure_spawners[structure.data]
		if list and list[category] then
			return list[category]
		end
	end
	return nil
end

-- NaturalSpawner.mobsAt.
local function spawners_at (pos, category)
	local override = structure_override (pos, category)
	if override then
		return override
	end
	local spawners = registered_spawners[get_biome_name_nosample (pos)]
	return spawners and spawners[category]
end

-- Biome test for the biome tag minecraft:reduce_water_ambient_spawns
-- (#minecraft:is_river).
local reduced_water_ambient_spawns_p

-- NaturalSpawner.getRandomSpawnMobAt.
local function get_eligible_spawn_type (pos, category)
	if category == "water_ambient"
		and reduced_water_ambient_spawns_p
		and reduced_water_ambient_spawns_p (get_biome_name_nosample (pos))
		and math.random () < 0.98 then
		return nil
	end
	local list = spawners_at (pos, category)
	return list and get_weighted_value (list)
end

-- NaturalSpawner.canSpawnMobAt.
local function can_spawn_mob_at (mob_def, pos, category)
	local list = spawners_at (pos, category)
	return list and table.indexof (list, mob_def) ~= -1
end

local function test_spawn_position (mob_def, spawn_pos, node_pos, sdata, node_cache,
				    spawn_flag)
	local value = mob_def:test_spawn_position (spawn_pos, node_pos, sdata,
						   node_cache, spawn_flag)
	return value
end

local function test_spawn_clearance (mob_def, spawn_pos, sdata)
	local value = mob_def:test_spawn_clearance (spawn_pos, sdata)
	return value
end

local is_position_completely_generated = mcl_mobs.is_position_completely_generated
local spawn_proto_chunk_blurb
	= "[mcl_mobs] Declining to spawn mob %s in proto-chunk at (%d,%d,%d)"

local function test_generation (pos, mob_def)
	if not core.compare_block_status (pos, "active") then
		return false
	elseif is_position_completely_generated (pos) then
		return true
	elseif logging then
		local msg = string.format (spawn_proto_chunk_blurb,
					   mob_def.name, pos.x, pos.y, pos.z)
		core.log ("action", msg)
	end
	return false
end

------------------------------------------------------------------------
-- Column heights (Heightmap.Types.WORLD_SURFACE).
------------------------------------------------------------------------

-- The Y position of the highest node that is not air in the column
-- X, Z between Y_MIN and Y_MAX, or Y_MIN - 1.  Unloaded MapBlocks are
-- treated as air.  Values are cached for SURFACE_CACHE_TIME seconds
-- and invalidated when nodes are placed or dug.

local SURFACE_CACHE_TIME = 10.0
local surface_cache_y = {}
local surface_cache_time = {}
local surface_cache_size = 0
local v_top, v_bottom = vector.zero (), vector.zero ()

local function column_hash (x, z)
	return (x + 32768) * 65536 + (z + 32768)
end

local function scan_column_surface (x, z, y_min, y_max)
	v_top.x, v_top.y, v_top.z = x, y_max, z
	v_bottom.x, v_bottom.y, v_bottom.z = x, y_min, z
	while true do
		local clear, hit = core.line_of_sight (v_top, v_bottom)
		if clear or not hit then
			return y_min - 1
		end
		if core.get_node (hit).name ~= "ignore" then
			return hit.y
		end
		-- Skip the remainder of this unloaded MapBlock.
		local next_y = math.floor (hit.y / 16) * 16 - 1
		if next_y < y_min then
			return y_min - 1
		end
		v_top.y = next_y
	end
end

local function column_surface (x, z, y_min, y_max)
	local hash = column_hash (x, z)
	local now = core.get_us_time () / 1000000
	local cached = surface_cache_y[hash]
	if cached and now - surface_cache_time[hash] < SURFACE_CACHE_TIME
		and cached >= y_min - 1 and cached <= y_max then
		return cached
	end
	if not cached then
		surface_cache_size = surface_cache_size + 1
		if surface_cache_size > 65536 then
			surface_cache_y = {}
			surface_cache_time = {}
			surface_cache_size = 1
		end
	end
	local y = scan_column_surface (x, z, y_min, y_max)
	surface_cache_y[hash] = y
	surface_cache_time[hash] = now
	return y
end

local function invalidate_column (pos)
	local hash = column_hash (pos.x, pos.z)
	if surface_cache_y[hash] then
		surface_cache_y[hash] = nil
		surface_cache_time[hash] = nil
		surface_cache_size = surface_cache_size - 1
	end
end

core.register_on_placenode (invalidate_column)
core.register_on_dignode (invalidate_column)

------------------------------------------------------------------------
-- World spawn exclusion zone.
------------------------------------------------------------------------

local world_spawn

-- Position of the world spawn block (LevelData.RespawnData), or a
-- position whose Y coordinate is nil if the surface there is not yet
-- loaded.
local function get_world_spawn ()
	if world_spawn and world_spawn.y then
		return world_spawn
	end
	local xz = mcl_biome_dispatch.get_spawn_point_2d ()
	world_spawn = { x = math.floor (xz.x + 0.5), z = math.floor (xz.z + 0.5), }
	local y = scan_column_surface (world_spawn.x, world_spawn.z,
				       mcl_vars.mg_overworld_min,
				       OVERWORLD_DEFAULT_CEILING)
	if y >= mcl_vars.mg_overworld_min
		and core.compare_block_status ({x = world_spawn.x, y = y,
						z = world_spawn.z}, "loaded") then
		world_spawn.y = y + 1
	end
	return world_spawn
end

-- NaturalSpawner.isRightDistanceToPlayerAndSpawnPoint.  SPAWN_POS is
-- the position of the mob's feet.
local function is_right_distance_to_player_and_spawn_point (level, spawn_pos,
							    player_dist_sqr)
	if player_dist_sqr <= 576.0 then
		return false
	end
	if level == "overworld" then
		local spawn = get_world_spawn ()
		local dx = spawn_pos.x - spawn.x
		local dz = spawn_pos.z - spawn.z
		local dy = spawn.y and (spawn_pos.y - spawn.y) or 0
		if dx * dx + dy * dy + dz * dz < 576.0 then
			return false
		end
	end
	return true
end

------------------------------------------------------------------------
-- Spawning state (NaturalSpawner.SpawnState).
------------------------------------------------------------------------

-- Spawn costs (MobSpawnSettings.MobSpawnCost) by biome name and mob
-- name, and the set of mob names with spawn costs.
local spawn_costs = {}
local spawn_cost_mobs = {}

local function get_spawn_cost (name, pos)
	if not spawn_cost_mobs[name] then
		return nil
	end
	local costs = spawn_costs[get_biome_name_nosample (pos)]
	return costs and costs[name]
end

local function chunk_center_dist_sqr (cx, cz, pos)
	local dx = cx * 16 + 7.5 - pos.x
	local dz = cz * 16 + 7.5 - pos.z
	return dx * dx + dz * dz
end

-- ChunkMap.getPlayersCloseForSpawning.
local function players_near_chunk (state, cx, cz)
	local hash = ((cx + 2048) * 4096) + (cz + 2048)
	local list = state.players_near[hash]
	if not list then
		list = {}
		for player, pos in pairs (state.players) do
			if chunk_center_dist_sqr (cx, cz, pos) < 16384.0 then
				table.insert (list, player)
			end
		end
		state.players_near[hash] = list
	end
	return list
end

-- LocalMobCapCalculator.addMob.
local function local_add_mob (state, pos, category)
	local cx = math.floor (pos.x / 16)
	local cz = math.floor (pos.z / 16)
	for _, player in ipairs (players_near_chunk (state, cx, cz)) do
		local counts = state.local_counts[player]
		if not counts then
			counts = {}
			state.local_counts[player] = counts
		end
		counts[category] = (counts[category] or 0) + 1
	end
end

-- LocalMobCapCalculator.canSpawn.
local function local_can_spawn (state, category, cx, cz)
	if not state.local_counts then
		-- With a single player the local mob cap never binds
		-- before the global cap.
		return true
	end
	local cap = spawn_categories[category].chunk_mob_cap
	for _, player in ipairs (players_near_chunk (state, cx, cz)) do
		local counts = state.local_counts[player]
		if not counts or (counts[category] or 0) < cap then
			return true
		end
	end
	return false
end

local function add_charge (state, pos, charge)
	if charge ~= 0 then
		table.insert (state.charges, {
			x = pos.x, y = pos.y, z = pos.z, charge = charge,
		})
	end
end

-- NaturalSpawner.createState.
local function create_spawn_state (level, players, n_players)
	local state = {
		level = level,
		players = players,
		players_near = {},
		charges = {},
		local_counts = n_players > 1 and {} or nil,
	}
	local need_charges = next (spawn_cost_mobs) ~= nil
	if state.local_counts or need_charges then
		for _, entity in pairs (core.luaentities) do
			if entity.is_mob and entity._activated
				and entity._spawn_level == level then
				local pos = entity.object:get_pos ()
				if pos then
					if need_charges then
						local cost = get_spawn_cost (entity.name, pos)
						if cost then
							add_charge (state, pos, cost.charge)
						end
					end
					if state.local_counts then
						local_add_mob (state, pos,
							       entity._spawn_category)
					end
				end
			end
		end
	end
	return state
end

-- SpawnState.canSpawn: the potential energy change of placing a mob
-- with a spawn cost must not exceed its energy budget.
local function state_can_spawn (state, mob_def, pos)
	local cost = get_spawn_cost (mob_def.name, pos)
	state.last_charge = cost and cost.charge or 0
	if not cost then
		return true
	end
	local potential = 0
	for _, point in ipairs (state.charges) do
		local dx = point.x - pos.x
		local dy = point.y - pos.y
		local dz = point.z - pos.z
		local d = dx * dx + dy * dy + dz * dz
		if d == 0 then
			return false
		end
		potential = potential + point.charge / math.sqrt (d)
	end
	return potential * cost.charge <= cost.budget
end

-- SpawnState.afterSpawn.
local function state_after_spawn (state, pos, category)
	add_charge (state, pos, state.last_charge)
	if state.local_counts then
		local_add_mob (state, pos, category)
	end
end

------------------------------------------------------------------------
-- Natural spawning (NaturalSpawner.spawnCategoryForPosition).
------------------------------------------------------------------------

local function log_group (mob_def, n_spawned, pos, category)
	if not logging or n_spawned == 0 then
		return
	end
	local counts = active_mobs_by_category[mcl_worlds.pos_to_dimension (pos)]
	core.log ("action", table.concat ({
		"[mcl_mobs] Spawned ", tostring (n_spawned), " ",
		mob_def.name, " around ", vector.to_string (pos),
		" (", tostring (counts and counts[category] or 0),
		"; category = ", category, ")",
	}))
end

local function finish_group (mob_def, spawned, sdata, n_spawned, pos, category)
	if not mob_def then
		return
	end
	log_group (mob_def, n_spawned, pos, category)
	if n_spawned > 0 and mob_def.init_group then
		mob_def:init_group (spawned, sdata)
	end
end

-- NaturalSpawner.isValidSpawnPostitionForType and
-- isValidPositionForMob.
local function is_valid_spawn_position_for_type (mob_def, category, spawn_pos,
						 node_pos, sdata, player_dist_sqr)
	if category == "misc" then
		return false
	elseif player_dist_sqr > mob_def.despawn_distance_sqr then
		return false
	elseif not can_spawn_mob_at (mob_def, node_pos, category) then
		return false
	end
	return test_spawn_position (mob_def, spawn_pos, node_pos, sdata, {}, nil)
		and test_spawn_clearance (mob_def, spawn_pos, sdata)
		and test_generation (node_pos, mob_def)
end

local function spawn_category_for_position (category, start, state)
	local y = start.y
	local cluster_size = 0
	for _ = 1, 3 do
		local x, z = start.x, start.z
		local mob_def, sdata, spawned = nil, nil, nil
		local max = math.ceil (math.random () * 4)
		local group_size = 0
		local group_pos
		local ll = 0
		while ll < max do
			ll = ll + 1
			x = x + math.random (0, 5) - math.random (0, 5)
			z = z + math.random (0, 5) - math.random (0, 5)
			local node_pos = vector.new (x, y, z)
			local spawn_pos = vector.new (x, y - 0.5, z)
			local _, player_pos = get_nearest_player (spawn_pos, state.players)
			if player_pos then
				local d = dist_sqr (player_pos, spawn_pos)
				if is_right_distance_to_player_and_spawn_point (state.level,
										spawn_pos, d) then
					if not mob_def then
						mob_def = get_eligible_spawn_type (node_pos, category)
						if not mob_def then
							break
						end
						max = math.random (mob_def.pack_min, mob_def.pack_max)
						sdata = mob_def:prepare_to_spawn (max, node_pos)
						spawned = {}
						group_pos = node_pos
					end

					if is_valid_spawn_position_for_type (mob_def, category,
									     spawn_pos, node_pos,
									     sdata, d)
						and state_can_spawn (state, mob_def, node_pos) then
						local object = mob_def:spawn (spawn_pos, group_size + 1,
									      sdata, max)
						if object then
							cluster_size = cluster_size + 1
							group_size = group_size + 1
							spawned[group_size] = object
							state_after_spawn (state, node_pos, category)
							if cluster_size >= mob_def.max_cluster then
								finish_group (mob_def, spawned, sdata,
									      group_size, group_pos,
									      category)
								return
							end
							if mob_def.is_max_group_size_reached
								and mob_def:is_max_group_size_reached (group_size,
												       object,
												       sdata) then
								break
							end
						end
					end
				end
			end
		end
		finish_group (mob_def, spawned, sdata, group_size, group_pos, category)
	end
end

local function is_redstone_conductor (node)
	local def = core.registered_nodes[node.name]
	return def and def.walkable and def.groups.opaque
		and def.groups.opaque > 0
end

-- NaturalSpawner.spawnCategoryForChunk and getRandomPosWithin.
local function spawn_category_for_chunk (category, cx, cz, data, state)
	local x = math.random (cx * 16, cx * 16 + 15)
	local z = math.random (cz * 16, cz * 16 + 15)
	local y_min = data.y_min
	local top = column_surface (x, z, y_min, data.y_max)
	local top_empty = math.min (top + 1, data.y_max)
	if top_empty < y_min + 1 then
		return
	end
	local y = math.random (y_min, top_empty)
	if y < y_min + 1 then
		return
	end
	local start = vector.new (x, y, z)
	if is_redstone_conductor (core.get_node (start)) then
		return
	end
	spawn_category_for_position (category, start, state)
end

-- ServerChunkCache.tickChunks: spawn mobs of every eligible category
-- in every chunk near a player in LEVEL.  SPAWN_ANIMALS selects the
-- categories which Minecraft spawns once every 400 ticks
-- (MobCategory.isPersistent) rather than the remainder.

function mcl_mobs.spawn_cycle (level, chunks, spawn_animals)
	local chunk_list, players, chunk_data, n_players = unpack (chunks[level])
	if #chunk_list == 0 then
		return
	end

	-- NaturalSpawner.getFilteredSpawningCategories.
	local caps = current_mob_caps[level]
	local counts = active_mobs_by_category[level] or {}
	local spawn_enemies = mcl_vars.difficulty > 0 and not only_peaceful_mobs
	local categories = {}
	for _, category in ipairs (SPAWNING_CATEGORIES) do
		local data = spawn_categories[category]
		if (spawn_enemies or data.is_friendly)
			and data.is_animal == (spawn_animals and true or false)
			and (counts[category] or 0) < caps[category] then
			table.insert (categories, category)
		end
	end
	if #categories == 0 then
		return
	end

	local state = create_spawn_state (level, players, n_players)
	table.shuffle (chunk_list)

	for _, chunk in ipairs (chunk_list) do
		local cx = math.floor (chunk / 4096) - 2048
		local cz = chunk % 4096 - 2048

		-- ChunkMap.anyPlayerCloseEnoughForSpawning.
		if #players_near_chunk (state, cx, cz) > 0 then
			for _, category in ipairs (categories) do
				if local_can_spawn (state, category, cx, cz) then
					spawn_category_for_chunk (category, cx, cz,
								  chunk_data[chunk], state)
				end
			end
		end
	end
end

-- Spawner fields:
--
--   max_cluster: Mob.getMaxSpawnClusterSize, the most mobs placed by
--   one spawning attempt (across its three groups).  4 by default;
--   Minecraft uses 8 for wolves and fish, 6 for horses, 5 for salmon,
--   1 for ghasts and pillagers.
--
--   is_max_group_size_reached: optional method (self, group_size,
--   object, sdata) mirroring Mob.isMaxGroupSizeReached, which ends a
--   group early (tropical fish that are not schooling).
--
--   can_spawn_far_from_player: EntityType.canSpawnFarFromPlayer;
--   true by default for the creature and misc categories.  Other
--   spawners do not spawn mobs beyond their category's despawn
--   distance from the nearest player.
--
--   spawn_cost: { charge = C, budget = B, }
--   (MobSpawnSettings.MobSpawnCost), which applies to mobs of this
--   spawner's `name' in its `biomes' (e.g. charge 0.7, budget 0.15
--   for endermen, ghasts, skeletons and striders in soul sand
--   valleys; charge 1.0, budget 0.12 for endermen in warped
--   forests).  Before such a mob is spawned, the sum of the charges
--   of mobs with spawn costs already present divided by their
--   distances, multiplied by its own charge, must not exceed its
--   budget.

local default_spawner = {
	weight = 100,
	biomes = {},
	structures = {},
	despawn_distance_sqr = nil, -- Derived from spawn_category.
	spawn_placement = "ground", -- misc, ground, aquatic, lava
	spawn_category = "misc", -- Should be identical to that of the
				 -- mob def.
	fire_immune = false,
	pack_min = 4,
	pack_max = 4,
	max_cluster = 4,
	can_spawn_far_from_player = nil,
	spawn_cost = nil,
	is_canonical = false, 	-- If true, this is the only spawner
				-- that will be invoked by
				-- `mcl_mobs.spawn_abnormally'.
}

local spawners_initialized = false
local canonical_spawners = {}
local ordinary_spawners = {}

function mcl_mobs.register_spawner (spawner)
	if spawners_initialized then
		error ("mcl_mobs.register_spawner mustn't be called "
		       .. "after mod initialization")
	end
	local spawner = table.merge (default_spawner, spawner)
	if not spawner.despawn_distance_sqr then
		local category = spawner.spawn_category
		local far = spawner.can_spawn_far_from_player
		if far == nil then
			far = category == "creature" or category == "misc"
		end
		if far then
			spawner.despawn_distance_sqr = math.huge
		else
			local data = spawn_categories[category]
			local d = data and data.despawn_distance
				or instant_despawn_range
			spawner.despawn_distance_sqr = d * d
		end
	end
	table.insert (registered_spawners, spawner)

	if spawner.is_canonical then
		canonical_spawners[spawner.name] = spawner
	else
		if not ordinary_spawners[spawner.name] then
			ordinary_spawners[spawner.name] = {}
		end
		table.insert (ordinary_spawners[spawner.name], spawner)
	end
end

function mcl_mobs.suppress_spawning_in_structure (structure, category)
	if not registered_structure_spawners[structure] then
		registered_structure_spawners[structure] = {}
	end
	local data = registered_structure_spawners[structure]
	if not data[category] then
		data[category] = {}
		total_weight[data[category]] = 0
	end
end

mcl_mobs.default_spawner = default_spawner

-- Convert this table into a map between biome IDs, structures, and
-- spawners once all biomes are registered.

core.register_on_mods_loaded (function ()
	local output = {}
	local n = #registered_spawners
	for i = 1, n do
		local spawner = registered_spawners[i]
		local biomes = mcl_biome_dispatch.build_biome_list (spawner.biomes)
		local biome_test = mcl_biome_dispatch.make_biome_test (spawner.biomes)
		spawner.internal_biome_dest = biome_test
		for _, id in ipairs (biomes) do
			if not output[id] then
				output[id] = {}
			end

			if not output[id][spawner.spawn_category] then
				output[id][spawner.spawn_category] = {}
			end

			local list = output[id][spawner.spawn_category]
			total_weight[list] = (total_weight[list] or 0) + spawner.weight
			table.insert (list, spawner)

			if spawner.spawn_cost then
				if not spawn_costs[id] then
					spawn_costs[id] = {}
				end
				spawn_costs[id][spawner.name] = spawner.spawn_cost
				spawn_cost_mobs[spawner.name] = true
			end
		end

		for _, structure in ipairs (spawner.structures) do
			if not registered_structure_spawners[structure] then
				registered_structure_spawners[structure] = {}
			end
			local data = registered_structure_spawners[structure]
			if not data[spawner.spawn_category] then
				data[spawner.spawn_category] = {}
			end
			local list = data[spawner.spawn_category]
			total_weight[list] = (total_weight[list] or 0) + spawner.weight
			table.insert (list, spawner)
		end
	end

	reduced_water_ambient_spawns_p
		= mcl_biome_dispatch.make_biome_test ({"#is_river",})

	spawners_initialized = true
	registered_spawners = output
	mcl_mobs.registered_spawners = registered_spawners
end)

------------------------------------------------------------------------
-- Default spawning criteria.
------------------------------------------------------------------------

function mob_class:is_up_face_sturdy (pos)
	local node = core.get_node (pos)
	return mcl_mobs.is_up_face_sturdy (pos, node)
end

local cube = mcl_util.decompose_AABBs ({{
	-0.5, -0.5, -0.5,
	0.5, 0.5, 0.5,
}})
local up_face_sturdy = {}

core.register_on_mods_loaded (function ()
	for node, def in pairs (core.registered_nodes) do
		local node_type = def.paramtype2
		if not def.walkable
			or node_type == "flowingliquid" then
			up_face_sturdy[node] = false
		elseif node_type == "4dir"
			or node_type == "degrotate"
			or node_type == "color4dir"
			or node_type == "color"
			or node_type == "colordegrotate"
			or node_type == "none" then
			local boxes = def.node_box

			if not boxes or boxes.type == "regular" then
				up_face_sturdy[node] = true
			elseif boxes.type == "fixed" then
				-- Since these node types can only
				-- rotate around the Y axis, it is
				-- only necessary to verify that their
				-- up faces are full cubes.

				local fixed = boxes.fixed
				if fixed and type (fixed[1]) == "number" then
					fixed = {fixed}
				end
				local shape = mcl_util.decompose_AABBs (fixed)
				local face = shape:select_face ("y", 0.5)
				up_face_sturdy[node] = face:equal_p (cube)
			end
		else
			-- Only full cubes can be sturdy once rotation
			-- around other axes is involved.
			local boxes = def.node_box

			if not boxes or boxes.type == "regular" then
				up_face_sturdy[node] = true
			elseif boxes.type == "fixed" then
				-- Since these node types can only
				-- rotate around the Y axis, it is
				-- only necessary to verify that their
				-- up faces are full cubes.

				local fixed = boxes.fixed
				if fixed and type (fixed[1]) == "number" then
					fixed = {fixed}
				end
				local shape = mcl_util.decompose_AABBs (fixed)
				if shape:equal_p (cube) then
					up_face_sturdy[node] = true
				end
			end
		end
	end
end)

function mcl_mobs.is_up_face_sturdy (node, node_data)
	local sturdy = up_face_sturdy[node_data.name]
	if sturdy ~= nil then
		return sturdy
	end
	local boxes = core.get_node_boxes ("collision_box", node)
	local shape = mcl_util.decompose_AABBs (boxes)
	local up_face = shape and shape:select_face ("y", 0.5)
	return up_face and up_face:equal_p (cube)
end

function default_spawner:is_valid_spawn_ceiling (name)
	local def = core.registered_nodes[name]
	if name == "ignore"
		or not def
		or (def.walkable or def.liquidtype ~= "none")
		or (def.groups.no_spawning_inside
			and def.groups.no_spawning_inside ~= 0)
		or (def.damage_per_second > 0)
		or (not self.fire_immune
			and def.groups.fire
			and def.groups.fire ~= 0)
		or (not self.fire_immune
			and def.groups.lava
			and def.groups.lava ~= 0) then
		return false
	end
	return true
end

function default_spawner:get_node (node_cache, y_offset, base)
	local cache = node_cache[y_offset]
	if not cache then
		base.y = base.y + y_offset
		cache = core.get_node (base)
		node_cache[y_offset] = cache
		base.y = base.y - y_offset
	end
	return cache
end

-- Implementors may modified and/or reuse node_pos as a scratch value,
-- provided that they restore its original values before calling the
-- default test_spawn_position implementation.

function default_spawner:test_spawn_position (spawn_pos, node_pos, sdata, node_cache,
					      spawn_flag)
	local spawn_placement = self.spawn_placement
	if spawn_placement == "misc"
		or (spawn_placement == "ground" and spawn_flag == "spawner") then
		-- Just test that the position is loaded.
		return core.compare_block_status (node_pos, "active")
	elseif spawn_placement == "ground" then
		local node_below = self:get_node (node_cache, -1, node_pos)
		if core.get_item_group (node_below.name, "opaque") == 0
			or node_below.name == "mcl_core:bedrock" then
			return false
		end
		-- The up face of the supporting node must be sturdy.
		if node_below.name == "mcl_nether:soul_sand"
			or mcl_mobs.is_up_face_sturdy (node_pos, node_below) then
			-- The block here and the block above must not
			-- be opaque nor deal damage.
			local node_here = self:get_node (node_cache, 0, node_pos)
			local node_above = self:get_node (node_cache, 1, node_pos)

			return self:is_valid_spawn_ceiling (node_here.name)
				and self:is_valid_spawn_ceiling (node_above.name)
		end
		return false
	elseif spawn_placement == "aquatic" then
		local node = self:get_node (node_cache, 0, node_pos)
		if core.get_item_group (node.name, "water") > 0 then
			local above = self:get_node (node_cache, 1, node_pos)
			return core.get_item_group (above.name, "opaque") == 0
		end
		return false
	elseif spawn_placement == "lava" then
		local node = self:get_node (node_cache, 0, node_pos)
		if core.get_item_group (node.name, "lava") > 0 then
			return true
		end
	end
	return false
end

local function box_intersection (box, other_box)
	for index = 1, 3 do
		if box[index] > other_box[index + 3]
			or other_box[index] > box[index + 3] then
			return false
		end
	end
	return true
end

function default_spawner:test_collision (node, cbox)
	local node_data = core.get_node (node)
	if node_data.name == "ignore" then
		return true
	end
	local def = core.registered_nodes[node_data.name]

	if def and not def.walkable
		and ((self.spawn_placement == "aquatic"
			or self.spawn_placement == "lava")
			or def.liquidtype == "none"
			-- Cobwebs are defined as liquids solely in
			-- order to retard player movement.
			or node.name == "mcl_core:cobweb") then
		return false
	end

	local boxes
		= core.get_node_boxes ("collision_box", node, node_data)
	for _, box in pairs (boxes) do
		box[1] = box[1] + node.x
		box[2] = box[2] + node.y
		box[3] = box[3] + node.z
		box[4] = box[4] + node.x
		box[5] = box[5] + node.y
		box[6] = box[6] + node.z

		if box_intersection (box, cbox) then
			return true
		end
	end
	return false
end

function default_spawner:test_spawn_clearance (spawn_pos, sdata)
	local mob_def = core.registered_entities[self.name]
	if not mob_def then
		return false
	end
	local cbox = mob_def.initial_properties.collisionbox
	if not cbox then
		return false
	end

	local cbox_1 = {
		cbox[1] + spawn_pos.x + 0.01,
		cbox[2] + spawn_pos.y + 0.01,
		cbox[3] + spawn_pos.z + 0.01,
		cbox[4] + spawn_pos.x - 0.01,
		cbox[5] + spawn_pos.y - 0.01,
		cbox[6] + spawn_pos.z - 0.01,
	}
	local xmin = math.floor (cbox_1[1] + 0.5)
	local ymin = math.floor (cbox_1[2] + 0.5)
	local zmin = math.floor (cbox_1[3] + 0.5)
	local xmax = math.floor (cbox_1[4] + 0.5)
	local ymax = math.floor (cbox_1[5] + 0.5)
	local zmax = math.floor (cbox_1[6] + 0.5)
	local v = vector.zero ()

	for z = zmin, zmax do
		v.z = z
		for x = xmin, xmax do
			v.x = x
			for y = ymin, ymax do
				v.y = y
				if self:test_collision (v, cbox_1) then
					return false
				end
			end
		end
	end
	return true
end

-- Mobs whose Minecraft counterparts spawn babies among the members
-- of a group (AgeableMob.AgeableMobGroupData) define
-- `_group_baby_chance' (0.05 for most animals); the first member of
-- a group is always an adult.
function mcl_mobs.group_member_is_baby (name, idx)
	local def = core.registered_entities[name]
	local chance = def and def._group_baby_chance
	return chance and idx and idx > 1 and math.random () < chance
end

function default_spawner:spawn (spawn_pos, idx, sdata, pack_size)
	if mcl_mobs.group_member_is_baby (self.name, idx) then
		sdata = table.merge (sdata or {}, { child = true, })
	end
	local staticdata = sdata and core.serialize (sdata)
	return core.add_entity (spawn_pos, self.name, staticdata)
end

function default_spawner:prepare_to_spawn (pack_size, center)
	return nil
end

function default_spawner:describe_mob_collision_box ()
	local mob_def = core.registered_entities[self.name]
	if not mob_def then
		return false
	end
	local cbox = mob_def.initial_properties.collisionbox
	if not cbox then
		return false
	end
	return string.format ("%.2f,%.2f,%.2f", cbox[4] - cbox[1],
			      cbox[5] - cbox[2], cbox[6] - cbox[3])
end

function default_spawner:get_misc_spawning_description ()
	return nil
end

function default_spawner:describe_additional_spawning_criteria ()
	return nil
end

function default_spawner:describe_criteria (tbl, omit_group_details)
	local tbl1 = {}
	local desc = self:get_misc_spawning_description ()
	if desc then
		tbl1[1] = desc
	elseif self.spawn_placement == "ground" then
		tbl1[1] = S ("This mob will spawn on solid and opaque nodes with a surface occupying a full node when no obstructions exist within a volume @1 nodes in size around the center of such a node's upper surface.",
			     self:describe_mob_collision_box ())
	elseif self.spawn_placement == "aquatic" then
		tbl1[1] = S ("This mob will spawn in water when the node above is not opaque and no obstructions exist within a volume @1 nodes in size around the center of the base of the fluid node in question.",
			     self:describe_mob_collision_box ())
	elseif self.spawn_placement == "lava" then
		tbl1[1] = S ("This mob will spawn on flowing lava and lava sources when no liquid or solid obstructions exist within a volume @1 nodes in size.",
			     self:describe_mob_collision_box ())
	else
		tbl1[1] = S ("This mob does not document its spawning requirements.")
	end
	local addendum = self:describe_additional_spawning_criteria ()
	if addendum then
		table.insert (tbl1, addendum)
	end
	if not omit_group_details then
		if self.pack_min == 1 and self.pack_max == 1 then
			tbl1[#tbl1 + 1] = S ("Mobs will spawn in individual groups of 1.")
		elseif self.pack_min == self.pack_max then
			tbl1[#tbl1 + 1] = S ("Up to @1 mobs will spawn as a single group upon each spawning attempt.", self.pack_min)
		else
			tbl1[#tbl1 + 1] = S ("A group of @1 to @2 mobs will attempt to be spawned upon each spawning attempt.", self.pack_min, self.pack_max)
		end
	end
	table.insert (tbl, table.concat (tbl1, "  "))
end

if mobs_spawn then

local spawn_timer = 0
local passive_spawn_timer = 0

core.register_globalstep (function (dtime)
	spawn_timer = spawn_timer - dtime
	passive_spawn_timer = passive_spawn_timer - dtime
	local chunks = collect_all_unique_chunks ()
	update_mob_caps (chunks)

	if spawn_timer <= 0 then
		for _, level in ipairs (LEVELS) do
			mcl_mobs.spawn_cycle (level, chunks, false)
		end
		spawn_timer = 0.05
	end
	-- ServerChunkCache.tickChunks: persistent categories (creatures)
	-- spawn once every 400 ticks.
	if passive_spawn_timer <= 0 then
		for _, level in ipairs (LEVELS) do
			mcl_mobs.spawn_cycle (level, chunks, true)
		end
		passive_spawn_timer = 20.0
	end
end)

end

------------------------------------------------------------------------
-- Spawn testing utilities.
------------------------------------------------------------------------

local function evaluate_node_properties (itemstack, user, pointed_thing)
	if not (user and user:is_player ()) then
		return
	end
	local playername = user:get_player_name ()
	if pointed_thing.type == "node" then
		local node = core.get_node (pointed_thing.under)
		core.chat_send_player (playername, table.concat ({
			"Node: ", node.name, "\n",
			"Up face sturdy: ",
			tostring (mcl_mobs.is_up_face_sturdy (pointed_thing.under, node)),
		}))

		local spawn_pos = vector.offset (pointed_thing.under, 0, 0.5, 0)
		local zombie_spawner = table.merge (default_spawner, {
			name = "mobs_mc:zombie",
		})
		core.chat_send_player (playername, table.concat ({
			"Zombie clearance tests pass? ",
			tostring (zombie_spawner:test_spawn_clearance (spawn_pos, {})),
			"\n",
		}))
	end
end

core.register_tool ("mcl_mobs:spawn_stick", {
	description = "Evaluate node properties",
	inventory_image = "default_stick.png^[colorize:purple:50",
	groups = { testtool = 1, disable_repair = 1,
		   not_in_creative_inventory = 1, },
	on_use = evaluate_node_properties,
})

core.register_chatcommand ("spawn_cycle", {
	privs = { server = true, },
	params = "[ end | overworld | nether ]",
	func = function (n, param)
		if table.indexof (LEVELS, param) == -1 then
			return false
		end
		local chunks = collect_all_unique_chunks ()
		update_mob_caps (chunks)
		mcl_mobs.spawn_cycle (param, chunks, false)
		mcl_mobs.spawn_cycle (param, chunks, true)
		return true
	end,
})

local function sort_by_weight_dsc (a, b)
	if b.weight < a.weight then
		return true
	elseif b.weight > a.weight then
		return false
	else
		return b.name < a.name
	end
end

core.register_chatcommand ("dump_spawners", {
	privs = { debug = true, },
	params = "[<biome>]",
	func = function (player, param)
		local player = core.get_player_by_name (player)
		if not player then
			return false
		end

		local pos = mcl_util.get_nodepos (player:get_pos ())
		local param = param:trim ()
		local biome_name = #param > 0 and param
			or mcl_biome_dispatch.get_biome_name (pos)
		local tbl = registered_spawners[biome_name]

		if not tbl then
			return false
		end

		print (";; Registered spawners in biome `" .. biome_name .. "'")
		for category, list in pairs (tbl) do
			local total_weight = total_weight[list] or -1
			local mobs_by_weight = {}
			local entry_by_mob = {}

			for _, spawner in ipairs (list) do
				local mob = spawner.name

				if not entry_by_mob[mob] then
					entry_by_mob[mob] = {
						name = mob,
						weight = spawner.weight,
						spawners = {spawner},
					}
					table.insert (mobs_by_weight, entry_by_mob[mob])
				else
					local entry = entry_by_mob[mob]
					entry.weight = entry.weight + spawner.weight
					table.insert (entry.spawners, spawner)
				end
			end

			print (string.format ("  ;; Category: %s, total weight: %d",
					      category, total_weight))
			table.sort (mobs_by_weight, sort_by_weight_dsc)
			for _, entry in ipairs (mobs_by_weight) do
				print (string.format ("    ;; Mob: %s: weight: %d", entry.name,
						      entry.weight))
				table.sort (entry.spawners, sort_by_weight_dsc)
				for _, spawner in ipairs (entry.spawners) do
					print (string.format ("    ;;  weight: %d pack_min, pack_max: %d, %d",
							      spawner.weight, spawner.pack_min,
							      spawner.pack_max))
				end
				print ("")
			end
		end
		return true, S ("Dumped spawners for biome: @1", biome_name)
	end,
})

------------------------------------------------------------------------
-- Manual spawning API.
------------------------------------------------------------------------

local function get_mob_spawner_at_pos (mob, pos)
	if canonical_spawners[mob] then
		return canonical_spawners[mob]
	end

	local spawners = ordinary_spawners[mob]
	if spawners then
		-- First search for an overriding structure spawner.
		local structures = get_structures_at (pos, false)
		for _, structure in pairs (structures) do
			for _, spawner in ipairs (spawners) do
				if table.indexof (spawner.structures, structure) ~= -1 then
					return spawner
				end
			end
		end

		-- Next, search for a spawner which applies to the biome at
		-- POS.
		local biome = get_biome_name_nosample (pos)
		for _, spawner in ipairs (spawners) do
			if spawner.internal_biome_dest (biome) then
				return spawner
			end
		end

		-- And in extremis, just return the first registered
		-- spawner.
		return spawners[1]
	end
end

-- Spawn an instance of MOB at POS (a node position) independently of
-- the ordinary course of environmental mob spawning, applying
-- spawning criteria enforced by its mob spawning definitions, such as
-- the absence of collisions, and minimum or maximum light level
-- requirements.  Value is the object if spawning is successful, nil
-- otherwise.  SDATA is a table of parameters which is provided to the
-- mob's spawning procedure.  SPAWN_FLAG is nil, or a string
-- designating the source from which this mob is spawning, which is
-- provided to each spawning definition's `test_spawn_position'
-- method.

local warned = {}
function mcl_mobs.spawn_abnormally (pos, mob, sdata, spawn_flag)
	local spawner = get_mob_spawner_at_pos (mob, pos)
	if not spawner then
		if not warned[mob] then
			local spawner = "[mcl_mobs]: Can't decide how to spawn "
				.. mob .. " at " .. vector.to_string (pos)
			core.log ("warning", spawner)
			warned[mob] = true
		end
		return nil
	end

	local spawn_pos = vector.new (pos.x, pos.y - 0.5, pos.z)
	if test_spawn_position (spawner, spawn_pos, pos, sdata, {},
				spawn_flag)
		and test_spawn_clearance (spawner, spawn_pos, sdata)
		and test_generation (pos, spawner) then
		local object = spawner:spawn (spawn_pos, 0, sdata)
		return object
	end

	return nil
end

function mcl_mobs.spawning_possible (pos, mob, sdata, spawn_flag)
	local spawner = get_mob_spawner_at_pos (mob, pos)
	if not spawner then
		if not warned[mob] then
			local spawner = "[mcl_mobs]: Can't decide how to spawn "
				.. mob .. " at " .. vector.to_string (pos)
			core.log ("warning", spawner)
			warned[mob] = true
		end
		return nil
	end

	local spawn_pos = vector.new (pos.x, pos.y - 0.5, pos.z)
	return test_spawn_position (spawner, spawn_pos, pos, sdata, {},
				    spawn_flag)
		and test_spawn_clearance (spawner, spawn_pos, sdata)
		and test_generation (pos, spawner)
end

function mcl_mobs.describe_spawning (mob)
	local tbl = {
		S ("Environmental spawning requirements and mechanics:"),
	}

	if canonical_spawners[mob] then
		table.insert (tbl, S ("\nWhen spawned from spawner:"))
		canonical_spawners[mob]:describe_criteria (tbl, true)
	elseif ordinary_spawners[mob]and ordinary_spawners[mob][1] then
		table.insert (tbl, S ("\nWhen spawned from spawner:"))
		ordinary_spawners[mob][1]:describe_criteria (tbl, true)
	else
		table.insert (tbl, S ("\nMob does not spawn environmentally."))
	end

	if ordinary_spawners[mob] then
		for _, spawner in ipairs (ordinary_spawners[mob]) do
			if #spawner.biomes > 0 then
				table.insert (tbl, S ("\nWhen spawned in biome(s): "))
				table.insert (tbl, table.concat (spawner.biomes, ", "))
			end

			if #spawner.structures > 0 then
				if #spawner.biomes > 0 then
					table.insert (tbl, S ("and when spawned in structure(s): "))
				else
					table.insert (tbl, S ("\nWhen spawned in structure(s): "))
				end
				table.insert (tbl, table.concat (spawner.structures, ", "))
			end

			spawner:describe_criteria (tbl, false)
		end
	end

	return table.concat (tbl, "\n")
end
