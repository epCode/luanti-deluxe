local S = core.get_translator(core.get_current_modname())
local C = core.colorize

mcl_jukebox = {}
mcl_jukebox.registered_records = {}

local HEAR_DISTANCE = 65

-- Player name-indexed table containing the currently heard track
local active_tracks = {}
mcl_jukebox.active_tracks = active_tracks

-- Player name-indexed table containing the current used HUD ID for the “Now playing” message.
local active_huds = {}

-- Player name-indexed table for the “Now playing” message.
-- Used to make sure that core.after only applies to the latest HUD change event
local hud_sequence_numbers = {}

-- get random disc itemstring that is obtainable as creeper loot
function mcl_jukebox.get_random_creeper_loot()
	local _, key = table.random_element(mcl_jukebox.registered_records, function(_, v) return v.id and not v.exclude_from_creeperdrop end)
	return key
end

function mcl_jukebox.register_record_definition(def)
	local itemstring = "mcl_jukebox:record_"..def.id
	mcl_jukebox.registered_records[itemstring] = def
	local entryname = S("Music Disc")
	local longdesc = S("A music disc holds a single music track which can be used in a jukebox to play music.")
	local usagehelp = S("Place a music disc into an empty jukebox to play the music. Use the jukebox again to retrieve the music disc. The music can only be heard by you, not by other players.")
	core.register_craftitem(":"..itemstring, {
		description = S("Music Disc"),
		_tt_help = C(mcl_colors.GRAY, S("@1—@2", def.author, def.title)),
		_doc_items_create_entry = true,
		_doc_items_entry_name = entryname,
		_doc_items_longdesc = longdesc,
		_doc_items_usagehelp = usagehelp,
		inventory_image = def.texture,
		stack_max = 1,
		groups = { music_record = 1, rarity = def.rarity or 1 },
	})
end

-- Old function, for backwards compatibility reasons still allows the old multi argument way of calling it.
function mcl_jukebox.register_record(title, author, identifier, image, sound, nocreeper)
	if type(title) == "table" then
		return mcl_jukebox.register_record_definition(title)
	end
	mcl_util.log_deprecated_call("warning", "[mcl_jukebox] please read mcl_jukebox/API.md for updated calling conventions!")
	return mcl_jukebox.register_record_definition({
		title = title,
		author = author,
		id = identifier,
		texture = image,
		sound = sound,
		exclude_from_creeperdrop = nocreeper
	})
end

local function now_playing(player, name)
	local playername = player:get_player_name()
	local hud = active_huds[playername]
	local text = S("Now playing: @1—@2", mcl_jukebox.registered_records[name].author, mcl_jukebox.registered_records[name].title)

	if not hud_sequence_numbers[playername] then
		hud_sequence_numbers[playername] = 1
	else
		hud_sequence_numbers[playername] = hud_sequence_numbers[playername] + 1
	end

	local id
	if hud then
		id = hud
		player:hud_change(id, "text", text)
	else
		id = player:hud_add({
			type = "text",
			position = { x=0.5, y=0.8 },
			offset = { x=0, y = 0 },
			number = 0x55FFFF,
			text = text,
			z_index = 100,
		})
		active_huds[playername] = id
	end
	core.after(5, function(tab)
		local playername = tab[1]
		local player = core.get_player_by_name(playername)
		local id = tab[2]
		local seq = tab[3]
		if not player or not player:is_player() or not active_huds[playername] or not hud_sequence_numbers[playername] or seq ~= hud_sequence_numbers[playername] then
			return
		end
		if id and id == active_huds[playername] then
			player:hud_remove(active_huds[playername])
			active_huds[playername] = nil
		end
	end, {playername, id, hud_sequence_numbers[playername]})
end

local function check_active_tracks()
	for k,v in pairs(active_tracks) do
		local pos = core.get_position_from_hash(k)
		local player_near = false
		for _ in mcl_util.connected_players(pos, HEAR_DISTANCE) do
			player_near = true
			break
		end
		if not player_near then
			core.sound_stop(v)
			active_tracks[k] = nil
		end
	end

end

core.register_on_leaveplayer(function(player)
	check_active_tracks()
	active_huds[player:get_player_name()] = nil
	hud_sequence_numbers[player:get_player_name()] = nil
end)

-- Jukebox crafting
core.register_craft({
	output = "mcl_jukebox:jukebox",
	recipe = {
		{"group:wood", "group:wood", "group:wood"},
		{"group:wood", "mcl_core:diamond", "group:wood"},
		{"group:wood", "group:wood", "group:wood"},
	}
})

local function play_record(pos, itemstack, player)
	local item_name = itemstack:get_name()
	-- ensure the jukebox uses the new record names for old records
	local name = core.registered_aliases[item_name] or item_name
	local ph = core.hash_node_position(pos)
	if mcl_jukebox.registered_records[name] then
		if active_tracks[ph] then
			core.sound_stop(active_tracks[ph])
			active_tracks[ph] = nil
		end
		active_tracks[ph] = core.sound_play(mcl_jukebox.registered_records[name].sound, {
			gain = 1,
			pos = pos,
			max_hear_distance = HEAR_DISTANCE,
		})
		if player then
			now_playing(player, name)
		end
		return true
	end
	return false
end

local function stop_record_sound(pos)
	local ph = core.hash_node_position(pos)
	if active_tracks[ph] then
		core.sound_stop(active_tracks[ph])
		active_tracks[ph] = nil
	end
end

-- Port of Minecraft's JukeboxBlock, JukeboxBlockEntity and JukeboxSongPlayer.
-- The record is kept in the node inventory.  HAS_RECORD is not a node state:
-- its change (setBlock with flag 2) is sent as shape updates.
local BLOCK = "mcl_jukebox:jukebox"
local TICKS_KEY = "ticks_since_song_started"

-- JukeboxSongPlayer by position hash: {def = record definition,
-- ticks = ticksSinceSongStarted, ticker = block entity ticker}
local song_players = {}

local function get_record(pos)
	return core.get_meta(pos):get_inventory():get_stack("main", 1)
end

local function get_record_def(stack)
	local name = stack:get_name()
	return mcl_jukebox.registered_records[core.registered_aliases[name] or name]
end

-- JukeboxSong.hasFinished.  Records without a length play until removed.
local function has_finished(def, ticks)
	return def.length ~= nil and ticks >= math.ceil(def.length * 20) + 20
end

-- JukeboxSongPlayer.isPlaying
function mcl_jukebox.is_playing(pos)
	return song_players[core.hash_node_position(pos)] ~= nil
end

-- JukeboxBlockEntity.onSongChanged: updateNeighborsAt, then setChanged
local function on_song_changed(pos)
	mcl_redstone.update_neighbors_at(pos, BLOCK)
	mcl_redstone.update_neighbour_for_output_signal(pos, BLOCK)
end

-- JukeboxSongPlayer.spawnMusicParticles
local function spawn_music_particles(pos)
	local v = math.random(0, 3) / 24
	local function c(o)
		return math.floor(math.max(0, math.sin((v + o) * math.pi * 2) * 0.65 + 0.35) * 255 + 0.5)
	end
	core.add_particle({
		texture = ("mcl_particles_note.png^[multiply:#%02x%02x%02x"):format(c(0), c(1 / 3), c(2 / 3)),
		pos = vector.offset(pos, 0, 0.7, 0),
		velocity = vector.new(0, 0.2, 0),
		expirationtime = 1.2,
		collisiondetection = false,
		size = 2,
	})
end

local function start_song_player(pos, def, ticks)
	local h = core.hash_node_position(pos)
	local old = song_players[h]
	if old then
		old.ticker.removed = true
	end
	local sp = {def = def, ticks = ticks}
	song_players[h] = sp
	sp.ticker = mcl_redstone.add_ticker({pos = vector.copy(pos), tick = function(ticker)
		if song_players[h] ~= sp or core.get_node(ticker.pos).name ~= BLOCK then
			ticker.removed = true
			return
		end
		-- JukeboxSongPlayer.tick
		if has_finished(sp.def, sp.ticks) then
			mcl_jukebox.stop(ticker.pos)
		else
			if sp.ticks % 20 == 0 then
				if mcl_gameevent then
					mcl_gameevent.emit("jukebox_play", ticker.pos, {node = core.get_node(ticker.pos)})
				end
				spawn_music_particles(ticker.pos)
				core.get_meta(ticker.pos):set_int(TICKS_KEY, sp.ticks)
			end
			sp.ticks = sp.ticks + 1
		end
	end})
	core.get_meta(pos):set_int(TICKS_KEY, ticks)
end

-- JukeboxSongPlayer.play
function mcl_jukebox.play(pos, def)
	start_song_player(pos, def, 0)
	on_song_changed(pos)
end

-- JukeboxSongPlayer.stop
function mcl_jukebox.stop(pos)
	local h = core.hash_node_position(pos)
	local sp = song_players[h]
	if sp then
		song_players[h] = nil
		sp.ticker.removed = true
		core.get_meta(pos):set_string(TICKS_KEY, "")
		if mcl_gameevent then
			mcl_gameevent.emit("jukebox_stop_play", pos, {node = core.get_node(pos)})
		end
		stop_record_sound(pos)
		on_song_changed(pos)
	end
end

-- JukeboxBlockEntity.setTheItem
local function set_the_item(pos, stack)
	core.get_meta(pos):get_inventory():set_stack("main", 1, stack)
	-- notifyItemChangedInJukebox: setBlock(HAS_RECORD, 2)
	mcl_redstone.update_neighbour_shapes(pos, core.get_node(pos), 2)
	if mcl_gameevent then
		mcl_gameevent.emit("block_change", pos, {node = core.get_node(pos)})
	end
	local def = not stack:is_empty() and get_record_def(stack)
	if def then
		mcl_jukebox.play(pos, def)
	else
		mcl_jukebox.stop(pos)
	end
end

-- JukeboxBlockEntity.popOutTheItem
local function pop_out_the_item(pos)
	local record = get_record(pos)
	if record:is_empty() then
		return
	end
	set_the_item(pos, ItemStack(""))
	local p = vector.offset(pos, (math.random() - 0.5) * 0.7, 0.51, (math.random() - 0.5) * 0.7)
	local dropped_item = core.add_item(p, record)
	-- Rotate record to match with “slot” texture
	if dropped_item then
		dropped_item:set_yaw(math.pi/2)
	end
	on_song_changed(pos)
end

local function own_signal(pos)
	return mcl_jukebox.is_playing(pos) and 15 or 0
end

-- Jukebox
core.register_node("mcl_jukebox:jukebox", {
	description = S("Jukebox"),
	_tt_help = S("Uses music discs to play music"),
	_doc_items_longdesc = S("Jukeboxes play music when they're supplied with a music disc."),
	_doc_items_usagehelp = S("Place a music disc into an empty jukebox to insert the music disc and play music. If the jukebox already has a music disc, you will retrieve this music disc first. The music can only be heard by you, not by other players."),
	tiles = {"mcl_jukebox_top.png", "mcl_jukebox_side.png", "mcl_jukebox_side.png"},
	sounds = mcl_sounds.node_sound_wood_defaults(),
	groups = {handy=1,axey=1, container=7, deco_block=1, material_wood=1, flammable=-1, unmovable_by_piston = 1},
	is_ground_content = false,
	on_construct = function(pos)
		local meta = core.get_meta(pos)
		local inv = meta:get_inventory()
		inv:set_size("main", 1)
	end,
	on_rightclick= function(pos, _, clicker, itemstack, _)
		if not clicker then return itemstack end
		local cname = clicker:get_player_name()
		if core.is_protected(pos, cname) then
			core.record_protection_violation(pos, cname)
			return itemstack
		end
		local meta = core.get_meta(pos)
		local inv = meta:get_inventory()
		if not inv:is_empty("main") then
			-- Jukebox contains a disc: Stop music and remove disc
			pop_out_the_item(pos)
			stop_record_sound(pos)
			if active_huds[cname] then
				clicker:hud_remove(active_huds[cname])
				active_huds[cname] = nil
			end
		else
			inv:set_size("main", 1) -- if the inventory isn't initialized it registers as empty - initialize it to be sure so discs are not "swallowed" by the jukebox
			-- Jukebox is empty: Play track if player holds music record
			local playing = play_record(pos, itemstack, clicker)
			if playing then
				local put_itemstack = ItemStack(itemstack)
				put_itemstack:set_count(1)
				itemstack:take_item()
				local state = core.get_node(pos)
				set_the_item(pos, put_itemstack)
				-- JukeboxPlayable.tryInsertIntoJukebox
				if mcl_gameevent then
					mcl_gameevent.emit("block_change", pos, {source = core.is_player(clicker) and clicker or nil, node = state})
				end
			end
		end
		return itemstack
	end,
	allow_metadata_inventory_move = function(pos, _, _, _, _, count, player)
		local name = player:get_player_name()
		if core.is_protected(pos, name) then
			core.record_protection_violation(pos, name)
			return 0
		else
			return count
		end
	end,
	allow_metadata_inventory_take = function(pos, _, _, stack, player)
		local name = player:get_player_name()
		if core.is_protected(pos, name) then
			core.record_protection_violation(pos, name)
			return 0
		else
			return stack:get_count()
		end
	end,
	allow_metadata_inventory_put = function(pos, _, _, stack, player)
		local name = player:get_player_name()
		if core.is_protected(pos, name) then
			core.record_protection_violation(pos, name)
			return 0
		else
			return stack:get_count()
		end
	end,
	-- JukeboxBlockEntity.preRemoveSideEffects
	on_destruct = function(pos)
		pop_out_the_item(pos)
		stop_record_sound(pos)
		-- JukeboxBlockEntity.setRemoved
		if mcl_gameevent then
			mcl_gameevent.emit("jukebox_stop_play", pos, {node = core.get_node(pos)})
		end
	end,
	after_dig_node = function(_, _, _, digger)
		local name = digger and digger:is_player() and digger:get_player_name()
		if name and active_huds[name] then
			digger:hud_remove(active_huds[name])
			active_huds[name] = nil
		end
	end,
	_mcl_redstone = {
		block = BLOCK,
		signal_source = true,
		own_signal = own_signal,
		get_signal = own_signal,
		-- JukeboxBlockEntity.getComparatorOutput
		analog_output = function(pos)
			local def = get_record_def(get_record(pos))
			return def and def.comparator_signal or 0
		end,
		-- Containers.updateNeighboursAfterDestroy
		affect_neighbors_after_removal = function(pos)
			mcl_redstone.update_neighbour_for_output_signal(pos, BLOCK)
		end,
	},
	_mcl_blast_resistance = 6,
	_mcl_hardness = 2,
	_mcl_burntime = 15
})

-- JukeboxBlockEntity.loadAdditional: setSongWithoutPlaying
core.register_lbm({
	label = "Resume jukebox song players",
	name = "mcl_jukebox:resume_song_players",
	nodenames = {BLOCK},
	run_at_every_load = true,
	action = function(pos)
		if song_players[core.hash_node_position(pos)] then
			return
		end
		local meta = core.get_meta(pos)
		if not meta:contains(TICKS_KEY) then
			return
		end
		local def = get_record_def(get_record(pos))
		local ticks = meta:get_int(TICKS_KEY)
		if def and not has_finished(def, ticks) then
			start_song_player(pos, def, ticks)
		else
			meta:set_string(TICKS_KEY, "")
		end
	end,
})

mcl_jukebox.register_record({
	title = "The Evil Sister (Jordach's Mix)",
	author = "SoundHelix",
	id = "13",
	length = 288.76,
	texture = "mcl_jukebox_record_13.png",
	sound = "mcl_jukebox_track_1",
	exclude_from_creeperdrop = false,
	comparator_signal = 1,
})
mcl_jukebox.register_record({
	title = "The Energetic Rat (Jordach's Mix)",
	author = "SoundHelix",
	id = "wait",
	length = 197.67,
	texture = "mcl_jukebox_record_wait.png",
	sound = "mcl_jukebox_track_2",
	comparator_signal = 12,
})
mcl_jukebox.register_record({
	title = "Eastern Feeling",
	author = "Jordach",
	id = "blocks",
	length = 230.64,
	texture = "mcl_jukebox_record_blocks.png",
	sound = "mcl_jukebox_track_3",
	comparator_signal = 3,
})
mcl_jukebox.register_record({
	title = "Minetest",
	author = "Jordach",
	id = "far",
	length = 271.33,
	texture = "mcl_jukebox_record_far.png",
	sound = "mcl_jukebox_track_4",
	comparator_signal = 5,
})
mcl_jukebox.register_record({
	title =  "Soaring over the sea",
	author =  "mactonite",
	id = "chirp",
	length = 205.99,
	texture = "mcl_jukebox_record_chirp.png",
	sound = "mcl_jukebox_track_5",
	exclude_from_creeperdrop = true,
	comparator_signal = 4,
})
mcl_jukebox.register_record({
	title = "Winter Feeling",
	author = "Tom Peter",
	id = "strad",
	length = 236.38,
	texture = "mcl_jukebox_record_strad.png",
	sound = "mcl_jukebox_track_6",
	comparator_signal = 9,
})
mcl_jukebox.register_record({
	title = "Synthgroove (Jordach's Mix)",
	author = "HeroOfTheWinds",
	id = "mellohi",
	length = 125.90,
	texture = "mcl_jukebox_record_mellohi.png",
	sound = "mcl_jukebox_track_7",
	comparator_signal = 7,
})
mcl_jukebox.register_record({
	title = "The Clueless Frog (Jordach's Mix)",
	author = "SoundHelix",
	id = "mall",
	length = 643.65,
	texture = "mcl_jukebox_record_mall.png",
	sound = "mcl_jukebox_track_8",
	exclude_from_creeperdrop = true,
	comparator_signal = 6,
})
-- jukebox_song/5.json; crafted from nine disc fragments found in ancient
-- cities. The sound is Minecraft's (a local asset, see mcl_mcsounds).
mcl_jukebox.register_record({
	title = "5",
	author = "Samuel Åberg",
	id = "5",
	length = 178.0,
	texture = "mcl_jukebox_record_5.png",
	sound = "mcl_mc_music_disc_5_1",
	exclude_from_creeperdrop = true,
	comparator_signal = 15,
	rarity = 2,
})

core.register_craftitem("mcl_jukebox:disc_fragment_5", {
	description = S("Disc Fragment"),
	_tt_help = C(mcl_colors.GRAY, S("Music Disc - 5")),
	_doc_items_longdesc = S("Nine disc fragments make the music disc \"5\". They are found in ancient cities."),
	inventory_image = "mcl_jukebox_disc_fragment_5.png",
	groups = {craftitem = 1, rarity = 2},
})

core.register_craft({
	type = "shapeless",
	output = "mcl_jukebox:record_5",
	recipe = {
		"mcl_jukebox:disc_fragment_5", "mcl_jukebox:disc_fragment_5", "mcl_jukebox:disc_fragment_5",
		"mcl_jukebox:disc_fragment_5", "mcl_jukebox:disc_fragment_5", "mcl_jukebox:disc_fragment_5",
		"mcl_jukebox:disc_fragment_5", "mcl_jukebox:disc_fragment_5", "mcl_jukebox:disc_fragment_5",
	},
})

--add backward compatibility
