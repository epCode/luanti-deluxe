-- Light emission levels of Minecraft (Java Edition 26.3, Blocks.java).
--
-- Mods register most light sources with Minecraft's levels already, but
-- older engines cap light sources at 14 (15 with game.conf
-- separate_sky_light). This applies the levels that need it once all node
-- definitions are in.

local MAX = core.LIGHT_SOURCE_MAX or core.LIGHT_MAX

-- Node name patterns (Lua patterns, anchored) and their light level
local levels = {
	-- 15
	{"^mcl_core:lava_source$", 15}, {"^mcl_core:lava_flowing$", 15},
	{"^mcl_nether:nether_lava_source$", 15}, {"^mcl_nether:nether_lava_flowing$", 15},
	{"^mcl_fire:fire$", 15}, {"^mcl_fire:eternal_fire$", 15},
	{"^mcl_nether:glowstone$", 15},
	{"^mcl_farming:pumpkin_face_light$", 15}, -- jack o'lantern
	{"^mcl_ocean:sea_lantern$", 15},
	{"^mcl_beacons:beacon$", 15},
	{"^mcl_conduits:conduit$", 15},
	{"^mcl_portals:portal_end$", 15}, {"^mcl_portals:portal_gateway$", 15},
	{"^mcl_lanterns:lantern_", 15}, {"^mcl_lanterns:copper_lantern_", 15},
	{"^mcl_crimson:shroomlight$", 15},
	{"^mcl_froglights:", 15},
	{"^mcl_cauldrons:cauldron_%d_lava$", 15},
	{"^mcl_campfires:campfire_lit$", 15},
	{"^mcl_redstone_lamp:lamp_on$", 15},
	{"^mcl_copper:bulb_on", 15}, -- plain copper bulb; aged ones are below 15
	{"^mcl_beds:respawn_anchor_charged_4$", 15},
	{"^mcl_ocean:sea_pickle_4_", 15},
	-- soul torch (Blocks.SOUL_TORCH: 10)
	{"^mcl_blackstone:soul_torch$", 10}, {"^mcl_blackstone:soul_torch_wall$", 10},
}

for name, def in pairs(core.registered_nodes) do
	for _, entry in ipairs(levels) do
		if name:find(entry[1]) then
			local level = math.min(entry[2], MAX)
			if def.light_source ~= level then
				core.override_item(name, {light_source = level})
			end
			break
		end
	end
end
