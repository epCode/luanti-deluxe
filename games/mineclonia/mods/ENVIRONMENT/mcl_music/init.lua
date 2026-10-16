------------------------------------------------------------------------
-- Biome background music like Minecraft's MusicManager (Java 26.3): the
-- situational music of the biome at the player (environment attribute
-- audio/background_music) plays after a random delay of min_delay ..
-- max_delay ticks following the previous song. Only biomes listed here
-- have music.
------------------------------------------------------------------------

mcl_music = {}

-- Biome name -> MusicInfo (worldgen/biome/*.json background_music)
mcl_music.biomes = {
	DeepDark = {event = "music.overworld.deep_dark", min_delay = 12000, max_delay = 24000,
		replace_current_music = false},
}

local states = {}
local tick_time = 0

local function situational_music(player)
	local pos = vector.offset(player:get_pos(), 0, 1.62, 0)
	local biome = mcl_biome_dispatch.get_biome_name(pos)
	return biome and mcl_music.biomes[biome]
end

-- MusicManager.tick
local function tick(player, st, now)
	local music = situational_music(player)
	if st.current then
		if music and music.event ~= st.current.event and music.replace_current_music then
			core.sound_fade(st.current.handle, 1, 0)
			st.next = math.random(0, math.floor(music.min_delay / 2))
			st.current = nil
		elseif now >= st.current.ends then
			-- The song is over
			st.current = nil
			if music then
				st.next = math.min(st.next, math.random(music.min_delay, music.max_delay))
			end
		end
	end
	if not music then
		return
	end
	st.next = math.min(st.next, music.max_delay)
	if not st.current then
		st.next = st.next - 1
		if st.next <= 0 then
			-- MusicManager.startPlaying
			local handle, variant = mcl_mcsounds.play(music.event,
				{to_player = player:get_player_name()}, 1.0, 1.0)
			if handle and variant then
				st.current = {handle = handle, event = music.event,
					ends = now + (variant.length or 180) * 20}
			end
			st.next = math.huge
		end
	end
end

core.register_on_joinplayer(function(player)
	-- MusicManager.nextSongDelay starts at 100 ticks
	states[player:get_player_name()] = {next = 100, current = nil}
end)

core.register_on_leaveplayer(function(player)
	states[player:get_player_name()] = nil
end)

local now = 0
core.register_globalstep(function(dtime)
	tick_time = tick_time + dtime
	while tick_time >= 0.05 do
		tick_time = tick_time - 0.05
		now = now + 1
		for _, player in ipairs(core.get_connected_players()) do
			local st = states[player:get_player_name()]
			if st then
				tick(player, st, now)
			end
		end
	end
end)
