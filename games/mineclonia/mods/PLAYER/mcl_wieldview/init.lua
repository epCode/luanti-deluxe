core.register_entity("mcl_wieldview:wieldview", {
	initial_properties = {
		hp_max           = 1,
		visual           = "wielditem",
		physical         = false,
		is_visible       = false,
		pointable        = false,
		collide_with_objects = false,
		static_save = false,
		collisionbox = {-0.21, -0.21, -0.21, 0.21, 0.21, 0.21},
		selectionbox = {-0.21, -0.21, -0.21, 0.21, 0.21, 0.21},
		visual_size  = {x = 0.21, y = 0.21},
	}
})

local wieldview_luaentites = {
	right = {},
	left = {},
}

-- Minecraft player models: the engine places the item models at
-- Wield_Item and Wield_Item_Left; items are attached there at full size
local ATTACH = {
	right = {bone = "Wield_Item"},
	left = {bone = "Arm_Left", position = vector.new(0, 4.5, 2), rotation = vector.new(120, 0, 0)},
}
local ATTACH_MC = {
	right = {bone = "Wield_Item"},
	left = {bone = "Wield_Item_Left"},
}

local function remove_wieldview(player)
	for bone,_ in pairs(wieldview_luaentites) do
		if wieldview_luaentites[bone][player] then
			wieldview_luaentites[bone][player].object:remove()
		end
		wieldview_luaentites[bone][player] = nil
	end
end

local function update_wieldview_entity(player, hand, get_item)
	local mc = mcl_player.is_procedural_model(player)
	local luaentity = wieldview_luaentites[hand][player]
	if luaentity and luaentity._mc ~= mc then
		luaentity.object:remove()
		luaentity = nil
		wieldview_luaentites[hand][player] = nil
	end

	if luaentity and luaentity.object:get_yaw() then
		local item = get_item(player):get_name()

		if item == luaentity._item then return end
		if core.get_item_group(item, "shield") > 0 then
			luaentity.object:remove ()
			wieldview_luaentites[hand][player] = nil
			return
		end
		luaentity._item = item

		local def = get_item(player):get_definition()
		if def and def._mcl_wieldview_item then
			item = def._mcl_wieldview_item
		end

		local item_def = core.registered_items[item]
		local props = {
			glow = item_def and item_def.light_source or 0,
			wield_item = item,
			is_visible = item ~= ""
		}
		-- Minecraft player models size items like Minecraft: undo the
		-- items' own wield scale
		if mc then
			local ws = item_def and item_def.wield_scale or {}
			local function inv(v) return (v and v > 0) and 1 / v or 1 end
			props.visual_size = {x = inv(ws.x), y = inv(ws.y), z = inv(ws.z)}
			-- Tridents: the engine expects the side view at its own size,
			-- 5/16 x 2 items (the wield scale stretches the square sprite)
			if core.get_item_group(item, "trident") > 0 then
				props.visual_size = {x = 5/16 * inv(ws.x), y = 2 * inv(ws.y), z = 0.625 * inv(ws.z)}
			end
		end
		luaentity.object:set_properties(props)
	else
		-- If the player is running through an unloaded area,
		-- the wieldview entity will sometimes get unloaded.
		-- This code path is also used to initalize the wieldview.
		-- Creating entites from core.register_on_joinplayer
		-- is unreliable as of Minetest 5.6
		local obj_ref = core.add_entity(player:get_pos(), "mcl_wieldview:wieldview")
		if not obj_ref then return end
		local at = (mc and ATTACH_MC or ATTACH)[hand]
		obj_ref:set_attach(player, at.bone, at.position, at.rotation)
		obj_ref:set_armor_groups({ immortal = 1 })
		if mc then
			obj_ref:set_properties({visual_size = {x = 1, y = 1}})
		end
		local ent = obj_ref:get_luaentity()
		ent._mc = mc
		wieldview_luaentites[hand][player] = ent
	end
end

core.register_on_leaveplayer(remove_wieldview)

mcl_player.register_globalstep(function(player)
	-- Spectators are invisible, and so is whatever they hold.
	if mcl_gamemode.is_spectator(player) then
		remove_wieldview(player)
		return
	end
	update_wieldview_entity(player, "right", mcl_serverplayer.get_visual_wielditem)
	update_wieldview_entity(player, "left", mcl_offhand.get_offhand)
end)
