local S = core.get_translator(core.get_current_modname())

local function param2_to_note_color(param2)
	local r, g, b
	if param2 < 8 then -- 0..7
		-- More red, less green
		r = param2 / 8 * 255
		g = (8-param2) / 8 * 255
		b = 0
	elseif param2 < 16 then -- 0..15
		-- More blue, less red
		r = (8-(param2 - 8)) / 8 * 255
		g = 0
		b = (param2 - 8) / 8 * 255
	else -- 16..24
		-- More green, less blue
		r = 0
		g = (param2 - 16) / 9 * 255
		b = (9-(param2 - 16)) / 9 * 255
	end
	r = math.floor(r)
	g = math.floor(g)
	b = math.floor(b)
	local color = 0x10000 * r + 0x100 * g + b
	-- Convert to ColorString
	return string.format("#%06X", color)
end

local function param2_to_pitch(param2)
	return 2^((param2-12)/12)
end

local soundnames_piano = {
	[0] = "mesecons_noteblock_c",
	"mesecons_noteblock_csharp",
	"mesecons_noteblock_d",
	"mesecons_noteblock_dsharp",
	"mesecons_noteblock_e",
	"mesecons_noteblock_f",
	"mesecons_noteblock_fsharp",
	"mesecons_noteblock_g",
	"mesecons_noteblock_gsharp",
	"mesecons_noteblock_a",
	"mesecons_noteblock_asharp",
	"mesecons_noteblock_b",
	"mesecons_noteblock_c2",
	"mesecons_noteblock_csharp2",
	"mesecons_noteblock_d2",
	"mesecons_noteblock_dsharp2",
	"mesecons_noteblock_e2",
	"mesecons_noteblock_f2",
	"mesecons_noteblock_fsharp2",
	"mesecons_noteblock_g2",
	"mesecons_noteblock_gsharp2",
	"mesecons_noteblock_a2",
	"mesecons_noteblock_asharp2",
	"mesecons_noteblock_b2",
	"mesecons_noteblock_b2",
}

local function sound_by_head(head_name)
	-- TODO: Dedicated wither skeleton sounds
	if head_name == "mcl_heads:creeper" then
		return "tnt_ignite"
	elseif head_name == "mcl_heads:dragon" then
		return "mobs_mc_ender_dragon_shoot"
	elseif head_name:find("skeleton") then
		return "mobs_mc_skeleton_random"
	elseif head_name == "mcl_heads:piglin" then
		return "mobs_mc_zombiepig_random"
	elseif head_name == "mcl_heads:zombie" then
		return "mobs_mc_zombie_growl"
	end
end

-- Port of Minecraft's NoteBlock.  param2 is NOTE (0..24) + 32 * POWERED.
-- The INSTRUMENT is not stored: it is looked up when the note plays.
local BLOCK = "mcl_noteblock:noteblock"

local function is_head(name)
	return core.get_item_group(name, "head") ~= 0
end

-- NoteBlock.triggerEvent: plays the note.  A mob head above sets the
-- instrument, else the block below does.
local function noteblock_play(pos, param2)
	local block_above_name = core.get_node({x=pos.x, y=pos.y+1, z=pos.z}).name
	if is_head(block_above_name) then
		local sound = sound_by_head(block_above_name)
		if sound then
			core.sound_play(sound, {pos = pos, max_hear_distance = 48}, true)
		end
		return
	end

	local block_below_name = core.get_node({x=pos.x, y=pos.y-1, z=pos.z}).name
	local pitched = false
	local soundname, pitch
	if block_below_name == "mcl_core:goldblock" then
		soundname="mesecons_noteblock_bell"
	elseif block_below_name == "mcl_core:clay" or block_below_name == "mcl_pale_oak:block_of_resin" then
		soundname="mesecons_noteblock_flute"
	elseif block_below_name == "mcl_core:packed_ice" then
		soundname="mesecons_noteblock_chime"
	elseif block_below_name == "mcl_core:bone_block" then
		soundname="mesecons_noteblock_xylophone_wood"
	elseif block_below_name == "mcl_core:ironblock" then
		soundname="mesecons_noteblock_xylophone_metal"
	elseif block_below_name == "mcl_nether:soul_sand" then
		soundname="mesecons_noteblock_cowbell"
	elseif block_below_name == "mcl_core:emeraldblock" then
		soundname="mesecons_noteblock_squarewave"
	elseif block_below_name == "mcl_farming:hay_block" then
		soundname="mesecons_noteblock_banjo"
	elseif block_below_name == "mcl_nether:glowstone" then
		soundname="mesecons_noteblock_piano_digital"
	elseif core.get_item_group(block_below_name, "wool") ~= 0 then
		soundname="mesecons_noteblock_guitar"
	elseif core.get_item_group(block_below_name, "pumpkin") ~= 0 then
		soundname="mesecons_noteblock_didgeridoo"
	elseif core.get_item_group(block_below_name, "material_glass") ~= 0 then
		soundname="mesecons_noteblock_hit"
	elseif core.get_item_group(block_below_name, "material_wood") ~= 0 then
		soundname="mesecons_noteblock_bass_guitar"
	elseif core.get_item_group(block_below_name, "material_sand") ~= 0 then
		soundname="mesecons_noteblock_snare"
	elseif core.get_item_group(block_below_name, "material_stone") ~= 0 then
		soundname="mesecons_noteblock_bass_drum"
	else
		-- Default: One of 25 piano notes
		soundname = soundnames_piano[param2]
		-- Workaround: Final sound gets automatic higher pitch instead
		if param2 == 24 then
			pitch = 2^(1/12)
		end
		pitched = true
	end
	if not pitched then
		pitch = param2_to_pitch(param2)
	end

	local note_color = param2_to_note_color(param2)

	core.add_particle({
		texture = "mcl_particles_note.png^[colorize:"..note_color..":92",
		pos = { x = pos.x, y = pos.y + 0.35, z = pos.z },
		velocity = { x = 0, y = 2, z = 0 },
		acceleration = { x = 0, y = -2, z = 0 },
		expirationtime = 1.0,
		collisiondetection = false,
		size = 3,
	})
	core.sound_play(soundname,
	{pos = pos, gain = 1.0, max_hear_distance = 48, pitch = pitch}, true)
end

-- NoteBlock.playNote: the note plays in the block event phase of the tick
local function play_note(pos, source)
	local above = core.get_node({x=pos.x, y=pos.y+1, z=pos.z}).name
	if is_head(above) or above == "air" then
		mcl_redstone.block_event(pos, BLOCK, 0, 0)
		if mcl_gameevent then
			mcl_gameevent.emit("note_block_play", pos, {source = core.is_player(source) and source or nil})
		end
	end
end

local function is_powered(node)
	return node.param2 >= 32
end

core.register_node("mcl_noteblock:noteblock", {
	description = S("Note Block"),
	_tt_help = S("Plays a musical note when powered by redstone power"),
	_doc_items_longdesc = S("A note block is a musical block which plays one of many musical notes and different intruments when it is punched or supplied with redstone power."),
	_doc_items_usagehelp = S("Use the note block to choose the next musical note (there are 25 semitones, or 2 octaves). The intrument played depends on the material of the block below the note block:").."\n\n"..

	S("• Glass: Sticks").."\n"..
	S("• Wood: Bass guitar").."\n"..
	S("• Stone: Bass drum").."\n"..
	S("• Sand or gravel: Snare drum").."\n"..
	S("• Block of Gold: Bell").."\n"..
	S("• Clay: Flute").."\n"..
	S("• Packed Ice: Chime").."\n"..
	S("• Wool: Guitar").."\n"..
	S("• Bone Block: Xylophne").."\n"..
	S("• Block of Iron: Iron xylophne").."\n"..
	S("• Soul Sand: Cow bell").."\n"..
	S("• Pumpkin: Didgeridoo").."\n"..
	S("• Block of Emerald: Square wave").."\n"..
	S("• Hay Bale: Banjo").."\n"..
	S("• Glowstone: Electric piano").."\n"..
	S("• Anything else: Piano").."\n\n"..

	S("The note block will only play a note when it is below air, otherwise, it stays silent."),
	tiles = {"mesecons_noteblock.png"},
	groups = {handy=1,axey=1, material_wood=1, flammable=-1},
	is_ground_content = false,
	place_param2 = 0,
	-- NoteBlock.useWithoutItem: change the note when rightclicked
	on_rightclick = function(pos, node, clicker)
		local protname = clicker:get_player_name()
		if core.is_protected(pos, protname) then
			core.record_protection_violation(pos, protname)
			return
		end
		node = core.get_node(pos)
		node.param2 = 32 * math.floor(node.param2 / 32) + (node.param2 % 32 + 1) % 25
		mcl_redstone.set_block(pos, node, 3)
		play_note(pos, clicker)
	end,
	-- NoteBlock.attack: play the current note when punched
	on_punch = function(pos, _, puncher)
		play_note(pos, puncher)
	end,
	sounds = mcl_sounds.node_sound_wood_defaults(),
	_mcl_redstone = {
		block = BLOCK,
		-- NoteBlock.neighborChanged: plays on the rising edge
		neighbor_changed = function(pos, node)
			local signal = mcl_redstone.has_neighbor_signal(pos)
			if signal ~= is_powered(node) then
				if signal then
					play_note(pos)
				end
				mcl_redstone.set_block(pos, {name = node.name, param2 = node.param2 % 32 + (signal and 32 or 0)}, 3)
			end
		end,
		trigger_event = function(pos, node)
			noteblock_play(pos, node.param2 % 32)
		end,
	},
	_mcl_hardness = 0.8,
	_mcl_burntime = 15,
})

core.register_craft({
	output = "mcl_noteblock:noteblock",
	recipe = {
		{"group:wood", "group:wood", "group:wood"},
		{"group:wood", "mcl_redstone:redstone", "group:wood"},
		{"group:wood", "group:wood", "group:wood"},
	}
})

core.register_craft({
	type = "fuel",
	recipe = "mcl_noteblock:noteblock",
	burntime = 15
})
