local S = core.get_translator(core.get_current_modname())

local light = core.LIGHT_MAX

-- Port of Minecraft's RedstoneLampBlock: turns on at once, off 4 game
-- ticks after losing power.
local BLOCK = "mcl_redstone_lamp:lamp"

local function is_lit(node)
	return node.name == "mcl_redstone_lamp:lamp_on"
end

local function cycled(node)
	return {name = is_lit(node) and "mcl_redstone_lamp:lamp_off" or "mcl_redstone_lamp:lamp_on"}
end

local commdef = {
	groups = {handy=1},
	is_ground_content = false,
	description = S("Redstone Lamp"),
	sounds = mcl_sounds.node_sound_glass_defaults(),
	_mcl_hardness = 0.3,
	_mcl_redstone = {
		block = BLOCK,
		conductor = true,
		-- getStateForPlacement
		placement = function(pos, node, oldnode)
			if mcl_redstone.block_id(oldnode.name) == BLOCK then
				return
			end
			local lit = mcl_redstone.has_neighbor_signal(pos)
			return {name = lit and "mcl_redstone_lamp:lamp_on" or "mcl_redstone_lamp:lamp_off"}
		end,
		neighbor_changed = function(pos, node)
			local lit = is_lit(node)
			if lit ~= mcl_redstone.has_neighbor_signal(pos) then
				if lit then
					mcl_redstone.schedule_tick(pos, BLOCK, 4)
				else
					mcl_redstone.set_block(pos, cycled(node), 2)
				end
			end
		end,
		tick = function(pos, node)
			if is_lit(node) and not mcl_redstone.has_neighbor_signal(pos) then
				mcl_redstone.set_block(pos, cycled(node), 2)
			end
		end,
	},
}

core.register_node("mcl_redstone_lamp:lamp_off", table.merge(commdef, {
	tiles = {"jeija_lightstone_gray_off.png"},
	_tt_help = S("Glows when powered by redstone power"),
	_doc_items_longdesc = S("Redstone lamps are simple redstone components which glow brightly (light level @1) when they receive redstone power.", light),
}))

core.register_node("mcl_redstone_lamp:lamp_on", table.merge(commdef, {
	tiles = {"jeija_lightstone_gray_on.png"},
	groups = table.merge(commdef.groups, {not_in_creative_inventory=1}),
	drop = "node mcl_redstone_lamp:lamp_off",
	light_source = light,
}))

core.register_craft({
	output = "mcl_redstone_lamp:lamp_off",
	recipe = {
		{"","mcl_redstone:redstone",""},
		{"mcl_redstone:redstone","mcl_nether:glowstone","mcl_redstone:redstone"},
		{"","mcl_redstone:redstone",""},
	}
})

doc.add_entry_alias("nodes", "mcl_redstone_lamp:lamp_off", "nodes", "mcl_redstone_lamp:lamp_on")
