mcl_bonus_chest = {}

local storage = core.get_mod_storage()

local adj = {
	vector.new(1,0,0),
	vector.new(-1,0,0),
	vector.new(0,0,1),
	vector.new(0,0,-1),
}

mcl_bonus_chest.bonus_loot = {
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_tools:axe_wood", weight = 3 },
			{ itemstring = "mcl_tools:axe_stone", weight = 1 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_tools:pick_wood", weight = 3 },
			{ itemstring = "mcl_tools:pick_stone", weight = 1 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_core:apple", amount_min = 1, amount_max=3 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_farming:bread", amount_min = 1, amount_max=2 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_fishing:salmon_raw", amount_min = 1, amount_max=2 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_core:stick", amount_min = 1, amount_max= 12 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_trees:wood_oak", amount_min = 1, amount_max= 12 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_mushrooms:mushroom_brown", amount_min = 1, amount_max= 12 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_trees:sapling_oak", amount_min = 1, amount_max= 4 },
			{ itemstring = "mcl_trees:sapling_spruce", amount_min = 1, amount_max= 4 },
			{ itemstring = "mcl_trees:sapling_birch", amount_min = 1, amount_max= 4 },
			{ itemstring = "mcl_trees:sapling_dark_oak", amount_min = 1, amount_max= 4 },
			{ itemstring = "mcl_trees:sapling_acacia", amount_min = 1, amount_max= 4 },
			{ itemstring = "mcl_trees:sapling_jungle", amount_min = 1, amount_max= 4 },
			{ itemstring = "mcl_trees:sapling_cherry_blossom", amount_min = 1, amount_max= 4 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_trees:tree_acacia", amount_min = 1, amount_max=3 },
			{ itemstring = "mcl_trees:tree_dark_oak", amount_min = 1, amount_max=3 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_trees:tree_birch", amount_min = 1, amount_max=3 },
			{ itemstring = "mcl_trees:tree_jungle", amount_min = 1, amount_max=3 },
			{ itemstring = "mcl_trees:tree_oak", amount_min = 1, amount_max=3 },
			{ itemstring = "mcl_trees:tree_spruce", amount_min = 1, amount_max=3 },

		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_farming:potato_item", amount_min = 1, amount_max= 2 },
			{ itemstring = "mcl_farming:carrot_item", amount_min = 1, amount_max= 2 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_farming:pumpkin_seeds", amount_min = 1, amount_max= 2 },
			{ itemstring = "mcl_farming:melon_seeds", amount_min = 1, amount_max= 2 },
			{ itemstring = "mcl_farming:beetroot_seeds", amount_min = 1, amount_max= 2 },
		}
	},
	{
		stacks_min = 1,
		stacks_max = 1,
		items = {
			{ itemstring = "mcl_cocoas:cocoa_beans", amount_min = 1, amount_max= 2 },
			{ itemstring = "mcl_core:cactus", amount_min = 1, amount_max= 2 },
		}
	},
}

function mcl_bonus_chest.place_chest(pos, loot, pr)
	local pr = pr or PcgRandom(core.hash_node_position(pos) + core.get_mapgen_setting("seed"))
	local loot = loot or mcl_bonus_chest.bonus_loot
	local pp = core.find_nodes_in_area_under_air(vector.offset(pos, -5,-3,-5), vector.offset(pos, 5,3,5), {"mcl_core:dirt_with_grass", "mcl_core:stone", "group:solid"})
	if pp and #pp > 0 then
		local cpos = vector.offset(pp[pr:next(1,#pp)], 0, 1, 0)
		core.place_node(cpos, {name = "mcl_chests:chest"})
		local m = core.get_meta(cpos)
		local inv = m:get_inventory()
		local items = mcl_loot.get_multi_loot(loot, pr)
		mcl_loot.fill_inventory(inv, "main", items, pr)
		for _,v in pairs(adj) do
			local tpos = vector.add(cpos, v)
			local def = core.registered_nodes[core.get_node(tpos).name]
			if def and def.buildable_to then
				core.place_node(tpos, {name = "mcl_torches:torch"})
			end
		end
	end
end

-- Set to true to hold back the bonus chest for new players; call
-- mcl_bonus_chest.deploy once it should be placed.
mcl_bonus_chest.deferred = false

function mcl_bonus_chest.is_enabled()
	return mcl_vars.get_world_setting_bool("mcl_bonus_chest", false)
end

-- Places the world's one bonus chest near the player if it is enabled and
-- has not been placed yet.
function mcl_bonus_chest.deploy(pl, delay)
	if not mcl_bonus_chest.is_enabled() or storage:get_int("mcl_bonus_chest:deployed") == 1 then
		return
	end
	core.after(delay or 0, function()
		if pl and pl:is_valid() and storage:get_int("mcl_bonus_chest:deployed") ~= 1 then
			mcl_bonus_chest.place_chest(pl:get_pos())
			storage:set_int("mcl_bonus_chest:deployed", 1)
		end
	end)
end

core.register_on_newplayer(function(pl)
	if not mcl_bonus_chest.deferred then
		mcl_bonus_chest.deploy(pl, 5)
	end
end)

core.register_chatcommand("bonus_chest", {
	privs = { server = true, },
	func = function(pn, _)
		local pl = core.get_player_by_name(pn)
		mcl_bonus_chest.place_chest(pl:get_pos())
	end,
})
