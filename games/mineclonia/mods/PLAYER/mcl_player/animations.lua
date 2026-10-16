mcl_player.registered_player_models = {}
mcl_player.registered_on_visual_change = {}

local animation_blend = 0.2

local prev_yaw, current_roll

local player_props_elytra = {
	collisionbox = { -0.35, 0, -0.35, 0.35, 0.8, 0.35 },
	eye_height = 0.4
}
local player_props_riding = {
	collisionbox = { -0.312, 0, -0.312, 0.312, 1.795, 0.312 },
	eye_height = 1.0
}
local player_props_sneaking = {
	collisionbox = { -0.312, 0, -0.312, 0.312, 1.495, 0.312 },
	eye_height = 1.27
}
local player_props_swimming = {
	collisionbox = { -0.312, 0, -0.312, 0.312, 0.6, 0.312 },
	eye_height = 0.4
}
local player_props_normal = {
	collisionbox = { -0.312, 0, -0.312, 0.312, 1.795, 0.312 },
	eye_height = 1.62
}
-- A sneaking player's nametag is faint, hidden behind blocks and beyond 32
-- blocks.  Engines that can not hide nametags behind blocks hide it entirely.
local nametag_props_normal = {
	nametag_color = { r = 225, g = 225, b = 225, a = 225 },
}
local nametag_props_sneaking = {
	nametag_color = { r = 225, g = 225, b = 225, a = 0 },
}
if core.has_feature ("nametag_occlusion") then
	nametag_props_normal.nametag_see_through = true
	nametag_props_normal.nametag_range = 0
	nametag_props_sneaking.nametag_color.a = 32
	nametag_props_sneaking.nametag_see_through = false
	nametag_props_sneaking.nametag_range = 32
end

mcl_player.player_props_elytra = player_props_elytra
mcl_player.player_props_riding = player_props_riding
mcl_player.player_props_sneaking = player_props_sneaking
mcl_player.player_props_swimming = player_props_swimming
mcl_player.player_props_normal = player_props_normal

-- HACK work around https://github.com/luanti-org/luanti/issues/15692
-- Scales corresponding to default perfect 180° rotations in the character b3d model
local bone_workaround_scales = {
	Body_Control = vector.new(-1, 1, -1),
	Leg_Right = vector.new(1, -1, -1),
	Leg_Left = vector.new(1, -1, -1),
	Cape = vector.new(1, -1, 1),
	Arm_Right_Pitch_Control = vector.new(1, -1, -1),
	Arm_Left_Pitch_Control = vector.new(1, -1, -1),
}

local function set_bone_pos(player, bonename, pos, rot)
	return mcl_util.set_bone_position(player, bonename, pos, rot, bone_workaround_scales[bonename])
end

function mcl_player.player_register_model(name, def)
	mcl_player.registered_player_models[name] = def
end

function mcl_player.register_on_visual_change(func)
	table.insert(mcl_player.registered_on_visual_change, func)
end

local function player_collision (player)
	local cbox = player:get_properties ().collisionbox
	return mcl_mobs.common_collision (cbox, player, player:get_pos ())
end

local function dir_to_pitch(dir)
	local xz = math.abs(dir.x) + math.abs(dir.z)
	return -math.atan2(-dir.y, xz)
end

local function limit_vel_yaw(player_vel_yaw, yaw)
	if player_vel_yaw < 0 then
		player_vel_yaw = player_vel_yaw + 360
	end

	if yaw < 0 then
		yaw = yaw + 360
	end

	if math.abs(player_vel_yaw - yaw) > 40 then
		local player_vel_yaw_nm, yaw_nm = player_vel_yaw, yaw
		if player_vel_yaw > yaw then
			player_vel_yaw_nm = player_vel_yaw - 360
		else
			yaw_nm = yaw - 360
		end
		if math.abs(player_vel_yaw_nm - yaw_nm) > 40 then
			local diff = math.abs(player_vel_yaw - yaw)
			if diff > 180 and diff < 185 or diff < 180 and diff > 175 then
				player_vel_yaw = yaw
			elseif diff < 180 then
				if player_vel_yaw < yaw then
					player_vel_yaw = yaw - 40
				else
					player_vel_yaw = yaw + 40
				end
			else
				if player_vel_yaw < yaw then
					player_vel_yaw = yaw + 40
				else
					player_vel_yaw = yaw - 40
				end
			end
		end
	end

	if player_vel_yaw < 0 then
		player_vel_yaw = player_vel_yaw + 360
	elseif player_vel_yaw > 360 then
		player_vel_yaw = player_vel_yaw - 360
	end

	return player_vel_yaw
end

local function get_mouse_button(player)
	local controls = player:get_player_control()
	local get_wielded_item_name = player:get_wielded_item():get_name()
	if controls.RMB and core.get_item_group(get_wielded_item_name, "bow") == 0 and
		core.get_item_group(get_wielded_item_name, "crossbow") == 0 and
		not mcl_shields.wielding_shield(player, 1) and not mcl_shields.wielding_shield(player, 2) or controls.LMB then
		return true
	else
		return false
	end
end


function mcl_player.player_get_animation(player)
	local textures = mcl_player.players[player].textures

	if not mcl_player.players[player].visible then
		textures = table.copy(textures)
		textures[1] = "blank.png"
	end

	return {
		model = mcl_player.players[player].model,
		textures =  mcl_player.players[player].textures,
		animation =  mcl_player.players[player].animation,
		visibility = mcl_player.players[player].visibility
	}
end

local function update_player_textures(player)
	local textures = mcl_player.players[player].textures

	if not mcl_player.players[player].visible then
		textures = table.copy(textures)
		textures[1] = "blank.png"
	end

	player:set_properties({ textures = textures })

	-- Delay calling the callbacks because mods (including mcl_player)
	-- need to fully initialize player data from core.register_on_joinplayer
	-- before callbacks run
	core.after(0.1, function()
		if player:is_player() then
			for _, func in ipairs(mcl_player.registered_on_visual_change) do
				func(player)
			end
		end
	end)
end

-- Called when a player's appearance needs to be updated
function mcl_player.player_set_model(player, model_name)
	local model = mcl_player.registered_player_models[model_name]
	if model then
		if mcl_player.players[player].model == model_name then
			return
		end
		mcl_player.players[player].model = model_name
		player:set_properties({
			mesh = model_name,
			visual = "mesh",
			visual_size = model.visual_size or { x = 1, y = 1 },
			damage_texture_modifier = "^[colorize:red:130",
			-- Animated by the engine like Minecraft's player model
			procedural_animation = model.procedural_animation or "",
			backface_culling = not model.procedural_animation,
		})
		update_player_textures(player)
		mcl_player.player_set_animation(player, "stand")
		mcl_serverplayer.post_load_model (player, model)
	end
end

function mcl_player.player_set_visibility(player, visible)
	if mcl_player.players[player].visible == visible then return end
	mcl_player.players[player].visible = visible
	update_player_textures(player)
end

function mcl_player.player_set_skin(player, texture)
	mcl_player.players[player].textures[1] = texture
	update_player_textures(player)
end

function mcl_player.player_set_armor(player, texture)
	mcl_player.players[player].textures[2] = texture
	update_player_textures(player)
end

-- Armor of the Minecraft player models: LAYERS = {armor = helmet, chestplate
-- and boots, leggings = leggings, elytra = elytra wings}
function mcl_player.player_set_armor_layers(player, layers)
	local textures = mcl_player.players[player].textures
	textures[2] = layers.armor or "blank.png"
	textures[3] = layers.leggings or "blank.png"
	textures[5] = layers.elytra or "blank.png"
	update_player_textures(player)
end

function mcl_player.player_set_cape(player, texture)
	mcl_player.players[player].textures[4] = texture or "blank.png"
	update_player_textures(player)
end

function mcl_player.is_procedural_model(player)
	local tbl = mcl_player.players[player]
	local model = tbl and mcl_player.registered_player_models[tbl.model]
	return model and model.procedural_animation and true or false
end

function mcl_player.get_player_formspec_model(player, x, y, w, h, fsname)
	local model = mcl_player.players[player].model
	local anim = mcl_player.registered_player_models[model].animations["stand"]
		or {x = 0, y = 0}
	local textures = table.copy(mcl_player.players[player].textures)
	if not mcl_player.players[player].visible then
		textures[1] = "blank.png"
	end
	for k,v in pairs(textures) do
		textures[k] = core.formspec_escape(v)
	end
	local procedural = mcl_player.registered_player_models[model].procedural_animation
	if procedural then
		-- Posed by the engine like in the world, facing the cursor like in
		-- Minecraft's inventory
		fsname = fsname ~= "" and fsname or "mcl_player_model"
		return string.format("style[%s;procedural_animation=%s;look_at_cursor=true]", fsname, procedural) ..
			string.format("model[%s,%s;%s,%s;%s;%s;%s;0,180;false;false]",
			x, y, w, h, fsname, model, table.concat(textures, ","))
	end
	return string.format("model[%s,%s;%s,%s;%s;%s;%s;-10,200;false;false;%s,%s]",
		x, y, w, h, fsname, model, table.concat(textures, ","),
		anim.x, anim.y)
end

function mcl_player.player_set_animation(player, anim_name, speed)
	-- Minecraft player models: only lying in bed matters
	if mcl_player.is_procedural_model(player) then
		mcl_player.players[player].animation = anim_name
		return
	end
	if mcl_player.players[player].animation == anim_name then
		return
	end
	local model = mcl_player.players[player].model and mcl_player.registered_player_models[mcl_player.players[player].model]
	if not (model and model.animations[anim_name]) then
		return
	end
	local anim = model.animations[anim_name]
	mcl_player.players[player].animation = anim_name
	player:set_animation(anim, speed or model.animation_speed, animation_blend)
end

-- Swimming players face the direction they look at, crawling players lie flat.
local function set_swimming(player, anim, anim_speed, crawling)
	local pitch = - math.deg(player:get_look_vertical())
	local yaw = math.deg(player:get_look_horizontal())
	local body_pitch = crawling and 0 or pitch
	mcl_player.players[player].is_swimming = true
	anim = anim or "swim_stand"
	mcl_player.player_set_animation(player, anim, anim_speed)
	set_bone_pos(player, "Head_Control", nil, vector.new(pitch - body_pitch + 20, mcl_player.players[player].vel_yaw - yaw, 0))
	set_bone_pos(player,"Body_Control", nil, vector.new(75 + body_pitch, mcl_player.players[player].vel_yaw - yaw, 0))
	mcl_util.set_properties(player, player_props_swimming)
end

function mcl_player.position_wielditem (wielded_itemname, wielded_def, player)
	-- Specific wielditem positions according to item
	if wielded_def and wielded_def._mcl_toollike_wield then
		set_bone_pos(player, "Wield_Item", vector.new(0, 4.7, 3.1), vector.new(-90, 225, 90))
	elseif core.get_item_group(wielded_itemname, "bow") > 0 then
		set_bone_pos(player, "Wield_Item", vector.new(1, 4, 0), vector.new(90, 130, 115))
	elseif core.get_item_group(wielded_itemname, "crossbow") > 4 then
		set_bone_pos(player, "Wield_Item", vector.new(0, 5.2, 1.2), vector.new(0, 180, 73))
	elseif core.get_item_group(wielded_itemname, "crossbow") > 0 then
		set_bone_pos(player, "Wield_Item", vector.new(0, 5.2, 1.2), vector.new(0, 180, 45))
	elseif wielded_def and wielded_def.inventory_image == "" then
		set_bone_pos(player,"Wield_Item", vector.new(0, 6, 2), vector.new(180, -45, 0))
	else
		set_bone_pos(player, "Wield_Item", vector.new(0, 5.3, 2), vector.new(90, 0, 0))
	end
end

------------------------------------------------------------------------
-- Player poses (standing, crouching, swimming and crawling), as in
-- Minecraft Java Edition.
------------------------------------------------------------------------

local CROUCH_FACTOR = 0.3
local SWIFT_SNEAK_BONUS = 0.15
local CLIMB_SLIDE_SPEED = 3.0

local function box_intersects_nodes (x1, y1, z1, x2, y2, z2)
	local p = vector.zero ()
	for x = math.floor (x1 + 0.5), math.floor (x2 + 0.5) do
		for z = math.floor (z1 + 0.5), math.floor (z2 + 0.5) do
			-- Collision boxes of nodes below may be taller than a node.
			for y = math.floor (y1 + 0.5) - 1, math.floor (y2 + 0.5) do
				p.x, p.y, p.z = x, y, z
				local node = core.get_node_or_nil (p)
				local def = node and core.registered_nodes[node.name]
				if def and def.walkable ~= false then
					for _, b in ipairs (core.get_node_boxes ("collision_box", p, node)) do
						if x + b[1] < x2 and x + b[4] > x1
							and y + b[2] < y2 and y + b[5] > y1
							and z + b[3] < z2 and z + b[6] > z1 then
							return true
						end
					end
				end
			end
		end
	end
	return false
end

-- Whether the part of the collision box CBOX between heights Y1 and Y2
-- would collide with nodes at POS.
local function cbox_collides (pos, cbox, y1, y2)
	local eps = 0.001
	return box_intersects_nodes (pos.x + cbox[1] + eps, pos.y + y1 + eps,
		pos.z + cbox[3] + eps, pos.x + cbox[4] - eps,
		pos.y + y2 - eps, pos.z + cbox[6] - eps)
end

local pose_props = {
	stand = player_props_normal,
	crouch = player_props_sneaking,
	swim = player_props_swimming,
}
local smaller_pose = {
	stand = "crouch",
	crouch = "swim",
}

-- Whether the player fits into POSE at POS; checked from the top down as
-- the room above the head is usually what decides.
local function pose_fits (pos, pose)
	local cbox = pose_props[pose].collisionbox
	local smaller = smaller_pose[pose]
	local y1 = smaller and pose_props[smaller].collisionbox[5] or cbox[2]
	if cbox_collides (pos, cbox, y1, cbox[5]) then
		return false
	end
	return not smaller or pose_fits (pos, smaller)
end

local function is_flying (player)
	local mcl_movement = rawget (_G, "mcl_movement")
	return mcl_movement and mcl_movement.is_flying
		and mcl_movement.is_flying (player) or false
end

local function is_water (pos)
	return core.get_item_group (core.get_node (pos).name, "water") ~= 0
end

-- Sprinting players start to swim with their eyes and feet in water, and
-- swim on as long as they touch water.
local function update_swimming (player, tbl, pos, sprinting)
	local props = player:get_properties ()
	local cbox = props.collisionbox
	local in_water = is_water (pos)
		or is_water (vector.offset (pos, 0, cbox[5] / 2, 0))
		or is_water (vector.offset (pos, 0, cbox[5] - 0.1, 0))
	tbl.in_water = in_water
	if tbl.swimming then
		tbl.swimming = sprinting and in_water
	else
		tbl.swimming = sprinting and is_water (pos)
			and is_water (vector.offset (pos, 0, props.eye_height, 0))
	end
end

-- Selects the pose of a player that is neither dead, gliding nor riding
-- (POSE_OVERRIDE), which is "stand", "crouch" or "swim" (also crawling).
local function update_pose (player, tbl, control, pose_override)
	local pose
	local pos = player:get_pos ()
	if pose_override or player:get_hp () <= 0 then
		tbl.swimming = false
		tbl.in_water = false
		pose = pose_override or "stand"
	elseif is_flying (player) then
		-- Flying players never crouch, swim or crawl, even where they do
		-- not fit standing up.
		tbl.swimming = false
		tbl.in_water = false
		pose = "stand"
	else
		update_swimming (player, tbl, pos,
				 mcl_sprint.is_sprinting (player:get_player_name ()))
		if tbl.swimming then
			pose = "swim"
		elseif control.sneak then
			pose = "crouch"
		else
			pose = "stand"
		end
		-- Players that do not fit crouch, or else crawl.
		if not pose_fits (pos, pose) then
			if pose ~= "crouch" and pose ~= "swim" and pose_fits (pos, "crouch") then
				pose = "crouch"
			elseif pose_fits (pos, "swim") then
				pose = "swim"
			end
		end
	end
	tbl.pose = pose
	tbl.crouching = pose == "crouch"
	-- Crouching and crawling (out of water) slow players down.
	tbl.moving_slowly = pose == "crouch" or (pose == "swim" and not tbl.in_water)

	local playerphysics = rawget (_G, "playerphysics")
	if playerphysics then
		local factor = tbl.crouch_factor or CROUCH_FACTOR
		-- Swift Sneak; the engine applies this while the sneak key is held.
		local speed_crouch = factor / CROUCH_FACTOR
		if tbl.applied_speed_crouch ~= speed_crouch then
			tbl.applied_speed_crouch = speed_crouch
			if speed_crouch == 1 then
				playerphysics.remove_physics_factor (player, "speed_crouch", "mcl_player:swift_sneak")
			else
				playerphysics.add_physics_factor (player, "speed_crouch", "mcl_player:swift_sneak", speed_crouch)
			end
		end
		-- Moving slowly without the sneak key (low ceilings, crawling).
		local speed = tbl.moving_slowly and not control.sneak and factor or 1
		if tbl.applied_crouch_speed ~= speed then
			tbl.applied_crouch_speed = speed
			if speed == 1 then
				playerphysics.remove_physics_factor (player, "speed", "mcl_player:crouch")
			else
				playerphysics.add_physics_factor (player, "speed", "mcl_player:crouch", speed)
			end
		end
	end
	return pose
end

-- Whether PLAYER is in the crouching pose.
function mcl_player.is_crouching (player)
	local tbl = mcl_player.players[player]
	return tbl and tbl.crouching or false
end

-- Whether PLAYER is in the swimming pose (in water) or crawling.
function mcl_player.is_swimming_pose (player)
	local tbl = mcl_player.players[player]
	return tbl and tbl.pose == "swim" or false
end

-- Factor by which crouching or crawling scales PLAYER's horizontal movement
-- (1 if not moving slowly); 0.3, plus 0.15 per level of Swift Sneak.
function mcl_player.get_crouch_factor (player)
	local tbl = mcl_player.players[player]
	if not (tbl and tbl.moving_slowly) then
		return 1
	end
	return tbl.crouch_factor or CROUCH_FACTOR
end

mcl_player.register_globalstep_slow (function (player)
	local tbl = mcl_player.players[player]
	local level = 0
	local mcl_enchanting = rawget (_G, "mcl_enchanting")
	if mcl_enchanting then
		local legs = player:get_inventory ():get_stack ("armor", 4)
		level = mcl_enchanting.get_enchantment (legs, "swift_sneak")
	end
	tbl.crouch_factor = math.min (1, CROUCH_FACTOR + SWIFT_SNEAK_BONUS * level)
end)

core.register_on_joinplayer (function (player)
	-- Sneaking does not let players walk off edges, cancels bouncing and
	-- silences their own steps; players hold on to ladders by sneaking and
	-- slide down otherwise.  (Requires a recent engine, ignored otherwise.)
	player:set_physics_override ({
		new_sneak = true,
		climb_slide = CLIMB_SLIDE_SPEED,
	})
end)

-- Minecraft player models (procedural_animation = "minecraft_player"): the
-- engine animates them from this state, as Minecraft does.
local function arm_pose(player, stack, control, blocking, main_hand)
	if blocking then
		return "block"
	end
	local name = stack:get_name()
	if name == "" then
		return "empty"
	end
	-- The hand whose item is being used (either hand can use items)
	local use = mcl_util.get_item_use(player)
	local using
	if use then
		using = use.hand == (main_hand and "main" or "offhand")
	else
		using = control.RMB and main_hand
	end
	if core.get_item_group(name, "bow") > 0 then
		return using and "bow" or "item"
	end
	local crossbow = core.get_item_group(name, "crossbow")
	if crossbow == 5 then
		return "crossbow_hold"
	elseif crossbow > 1 then
		return "crossbow_charge"
	end
	if using then
		if core.get_item_group(name, "trident") > 0 then
			return "throw_spear"
		elseif name == "mcl_spyglass:spyglass" then
			return "spyglass"
		end
	end
	return "item"
end

-- How the item shows in hand (Minecraft's item model display types)
local FLAT_DRAWTYPES = {plantlike = true, torchlike = true, signlike = true,
	raillike = true, plantlike_rooted = true, flowingliquid = true}
local ROD_ITEMS = {["mcl_fishing:fishing_rod"] = true,
	["mcl_mobitems:carrot_on_a_stick"] = true,
	["mcl_mobitems:warped_fungus_on_a_stick"] = true}
local function item_display(stack)
	local name = stack:get_name()
	if name == "" then
		return "none"
	end
	local def = stack:get_definition()
	if def and def._mcl_wieldview_item then
		def = core.registered_items[def._mcl_wieldview_item] or def
	end
	if not def then
		return "generated"
	end
	if core.get_item_group(name, "bow") > 0 then
		return "bow"
	elseif core.get_item_group(name, "crossbow") > 0 then
		return "crossbow"
	elseif core.get_item_group(name, "trident") > 0 then
		return "trident"
	elseif name == "mcl_spyglass:spyglass" then
		return "spyglass"
	elseif ROD_ITEMS[def.name] then
		return "handheld_rod"
	elseif def._mcl_toollike_wield then
		return "handheld"
	elseif def.type == "node" and (def.inventory_image or "") == ""
			and not FLAT_DRAWTYPES[def.drawtype] then
		return "block"
	end
	return "generated"
end

-- Display types older engines don't know, and what to show instead
local DISPLAY_FALLBACK = {crossbow = "generated", handheld_rod = "handheld",
	trident = "handheld", spyglass = "handheld"}
local display_fallback = false

local function set_animation_state(player, state)
	if display_fallback then
		state.right_item = DISPLAY_FALLBACK[state.right_item] or state.right_item
		state.left_item = DISPLAY_FALLBACK[state.left_item] or state.left_item
	end
	local ok, err = pcall(player.set_animation_state, player, state)
	if ok then
		return
	elseif display_fallback or not tostring(err):find("Unknown item display") then
		error(err, 0)
	end
	core.log("warning", "[mcl_player] The engine lacks newer held item displays: " .. tostring(err))
	display_fallback = true
	set_animation_state(player, state)
end

local function effect_level(player, effect)
	local mcl_potions = rawget(_G, "mcl_potions")
	local level = mcl_potions and mcl_potions.get_effect_level
		and mcl_potions.get_effect_level(player, effect)
	return tonumber(level) or 0
end

local function update_procedural(player, tbl, pose, control, parent, elytra, wielded)
	local dead = player:get_hp() <= 0
	local riptide = mcl_tridents.obj_attached_to_riptide_trident_p (player)
	local riding = not elytra and not riptide and (parent ~= nil or tbl.attached)
	local sleeping = tbl.animation == "lay"
	-- In bed the player looks along the bed (mcl_beds)
	if sleeping and not tbl.sleep_yaw then
		tbl.sleep_yaw = math.deg(player:get_look_horizontal())
	elseif not sleeping then
		tbl.sleep_yaw = nil
	end

	if dead then
		mcl_util.set_properties(player, player_props_normal)
	elseif elytra then
		mcl_util.set_properties(player, player_props_elytra)
	elseif riptide then
		mcl_util.set_properties(player, player_props_swimming)
	elseif riding then
		mcl_util.set_properties(player, player_props_riding)
	elseif pose == "swim" then
		mcl_util.set_properties(player, player_props_swimming)
	elseif pose == "crouch" then
		mcl_util.set_properties(player, player_props_sneaking)
	else
		mcl_util.set_properties(player, player_props_normal)
	end
	tbl.is_swimming = pose == "swim"

	local blocking = mcl_shields.is_blocking(player)
	local mcl_offhand = rawget(_G, "mcl_offhand")
	local offhand = mcl_offhand and mcl_offhand.get_offhand(player) or ItemStack()
	-- Swing length: 6 ticks, shorter with haste, longer with mining fatigue
	local haste, fatigue = effect_level(player, "haste"), effect_level(player, "fatigue")
	local swing = 6
	if haste > 0 then
		swing = 6 - haste
	elseif fatigue > 0 then
		swing = 6 + fatigue * 2
	end
	-- Crossbows charge in 1.25 s, 0.25 s less per level of Quick Charge
	local use_duration = 1.25
	local crossbow = wielded
	if core.get_item_group(wielded:get_name(), "crossbow") == 0 then
		crossbow = offhand
	end
	if core.get_item_group(crossbow:get_name(), "crossbow") > 0 and mcl_enchanting then
		use_duration = math.max(0.05, 1.25 - 0.25 *
			mcl_enchanting.get_enchantment(crossbow, "quick_charge"))
	end

	set_animation_state(player, {
		sneaking = pose == "crouch" and not riding and not sleeping,
		riding = riding and not sleeping,
		sleeping = sleeping,
		sleep_yaw = sleeping and tbl.sleep_yaw or 0,
		swimming = pose == "swim" and not riding,
		in_water = tbl.in_water or false,
		fall_flying = elytra or false,
		spin_attack = riptide or false,
		dead = dead,
		right_arm = arm_pose(player, wielded, control, blocking == 2, true),
		left_arm = arm_pose(player, offhand, control, blocking == 1, false),
		right_item = item_display(wielded),
		left_item = item_display(offhand),
		swing_duration = math.max(1, swing),
		use_duration = use_duration,
	})
end

local ENTITY_CRAMMING_MAX = 24

mcl_player.register_globalstep (function (player, dtime)
	local tbl = mcl_player.players[player]
	local cx, cz, count = player_collision (player)
	local self_pos = player:get_pos ()

	if tbl.cram_timer then
		local t = tbl.cram_timer - dtime
		tbl.cram_timer = t > 0 and t or nil
	end

	if count > ENTITY_CRAMMING_MAX
		and not tbl.cram_timer
		and math.random (mcl_mobs.scale_chance (4, dtime)) == 1 then
		tbl.cram_timer = 0.5
		local reason = {
			type = "cramming",
		}
		mcl_damage.finish_reason (reason)
		mcl_util.deal_damage (player, 6.0, reason)
		if player:get_hp () == 0 then
			return
		end
	end

	if tbl._has_impulse
		and not vector.equals (self_pos, tbl._has_impulse) then
		tbl._has_impulse = nil
	end

	if mcl_serverplayer.is_csm_capable (player) then
		local mag = math.sqrt (cx * cx + cz * cz)
		if not tbl._has_impulse and mag > 0.01 then
			player:add_velocity (vector.new (cx, 0, cz))
			-- Don't apply velocity adjustments unless the
			-- client has already responded to the
			-- previous one by moving.
			tbl._has_impulse = self_pos
		end
		return
	end

	local mag = math.sqrt (cx * cx + cz * cz)
	if mag > 0.01 then
		local mag1 = math.min (mag, 4.0)
		local f = mag1 / mag
		if not tbl._has_impulse then
			player:add_velocity (vector.new (cx * f, 0, cz * f))
			tbl._has_impulse = self_pos
		end
	end
	local name = player:get_player_name()
	local model_name = tbl.model
	local model = model_name and mcl_player.registered_player_models[model_name]
	local control = player:get_player_control()
	local parent = player:get_attach()
	local wielded = player:get_wielded_item()
	local wielded_def = wielded:get_definition()
	local wielded_itemname = player:get_wielded_item():get_name()
	local player_velocity = player:get_velocity()
	local elytra = tbl.elytra and tbl.elytra.active
	local pose = update_pose (player, tbl, control,
		(elytra and "elytra") or ((parent or tbl.attached) and "riding") or nil)
	local crouching = pose == "crouch"
	-- (Minecraft hides nametags by the sneak key, not by the pose.)
	mcl_util.set_properties (player, control.sneak and not is_flying (player)
				 and nametag_props_sneaking or nametag_props_normal)

	if model and model.procedural_animation then
		update_procedural(player, tbl, pose, control, parent, elytra, wielded)
		return
	end

	if player_velocity.x + player_velocity.y < .5 then
		player_velocity = player:get_velocity()
	end

	-- control head bone
	local pitch = - math.deg(player:get_look_vertical())
	local yaw = math.deg(player:get_look_horizontal())

	local player_vel_yaw = math.deg(core.dir_to_yaw(player_velocity))
	if player_vel_yaw == 0 then
		player_vel_yaw = tbl.vel_yaw or yaw
	end
	player_vel_yaw = limit_vel_yaw(player_vel_yaw, yaw)
	tbl.vel_yaw = player_vel_yaw

	if not elytra and (parent or tbl.attached) then
		if mcl_tridents.obj_attached_to_riptide_trident_p (player) then
			mcl_player.player_set_animation (player, "spin_attack")
			set_bone_pos (player, "Body_Control", nil, vector.new (90, 0, 0))
			set_bone_pos (player, "Head_Control", nil, vector.zero ())
			mcl_util.set_properties (player, player_props_swimming)
		else
			local hyaw = player_vel_yaw - yaw
			if parent then
				mcl_util.set_properties(player, player_props_riding)
				local parent_yaw = math.deg(parent:get_yaw())
				set_bone_pos(player,"Body_Control", nil, vector.zero())
				hyaw = -limit_vel_yaw(yaw, parent_yaw) + parent_yaw
			else
				set_bone_pos(player,"Body_Control", nil, vector.new(0, -player_vel_yaw + yaw, 0))
			end

			set_bone_pos(player, "Head_Control", nil, vector.new(pitch, hyaw, 0))
		end
	else
		local walking = control.up or control.down or control.left or control.right
		local animation_speed_mod = model and model.animation_speed or 30

		-- Determine if the player is crouching, and reduce animation speed if so
		if crouching then
			animation_speed_mod = animation_speed_mod / 2
		end

		if mcl_shields.is_blocking(player) then
			animation_speed_mod = animation_speed_mod / 2
		end

		local head_in_water = core.get_item_group(tbl.nodes.head, "water") ~= 0
		-- ask if player is sprinting
		local is_sprinting = mcl_sprint.is_sprinting(name)

		local velocity = player:get_velocity()
		local moving = walking and (math.abs(velocity.x) > 0.35 or math.abs(velocity.z) > 0.35)
		tbl.is_swimming = pose == "swim"

		-- Apply animations based on what the player is doing
		if player:get_hp() == 0 then --dead
			mcl_player.player_set_animation(player, "die")
		elseif elytra then --using elytra
			prev_yaw = prev_yaw or yaw
			local yaw_diff = yaw - prev_yaw
			local clamped_roll = math.max(-45, math.min(45, yaw_diff * 45))
			current_roll = current_roll or 0
			current_roll = current_roll + (clamped_roll - current_roll) * animation_blend
			local roll = current_roll
			prev_yaw = yaw
			mcl_player.player_set_animation(player, "fly")
			set_bone_pos(player,"Head_Control", nil, vector.new(-math.rad(pitch) + 50, math.rad(yaw), 0))
			set_bone_pos(player, "Body_Control", nil, vector.new(-math.rad(pitch) + 85, math.rad(yaw) - math.pi, roll))
			-- sets eye height accordingly
			mcl_util.set_properties(player, player_props_elytra)
		elseif pose == "swim" then -- swimming, or crawling out of water
			local crawling = not tbl.in_water
			if moving then
				if get_mouse_button(player) then
					set_swimming(player, "swim_walk_mine", animation_speed_mod, crawling)
				else
					set_swimming(player, "swim_walk", animation_speed_mod, crawling)
				end
			elseif get_mouse_button(player) then
				set_swimming(player, "swim_mine", nil, crawling)
			else
				set_swimming(player, "swim_stand", nil, crawling)
			end
		elseif moving then --walking
			if crouching then -- sneak-walking
				mcl_util.set_properties(player, player_props_sneaking)
			else
				mcl_util.set_properties(player, player_props_normal)
			end

			set_bone_pos(player,"Head_Control", nil, vector.new(pitch, player_vel_yaw - yaw, 0))
			set_bone_pos(player,"Body_Control", nil, vector.new(0, -player_vel_yaw + yaw, 0))
			local no_arm_moving = core.get_item_group(wielded_itemname, "bow") > 0 or
				core.get_item_group(wielded_itemname, "crossbow") > 0 or
				mcl_shields.wielding_shield(player, 1) or
				mcl_shields.wielding_shield(player, 2)
			if tbl.sneak ~= crouching then
				tbl.animation = nil
				tbl.sneak = crouching
			end
			if no_arm_moving and control.RMB and crouching or core.get_item_group(wielded_itemname, "crossbow") > 0 and crouching then
				mcl_player.player_set_animation(player, "bow_sneak", animation_speed_mod)
			elseif no_arm_moving and control.RMB or core.get_item_group(wielded_itemname, "crossbow") > 0 then
				mcl_player.player_set_animation(player, "bow_walk", animation_speed_mod)
			elseif is_sprinting and get_mouse_button(player) and not crouching and not head_in_water then
				mcl_player.player_set_animation(player, "run_walk_mine", animation_speed_mod)
			elseif get_mouse_button(player) and not crouching then
				mcl_player.player_set_animation(player, "walk_mine", animation_speed_mod)
			elseif get_mouse_button(player) and crouching then
				mcl_player.player_set_animation(player, "sneak_walk_mine", animation_speed_mod)
			elseif is_sprinting and not crouching and not head_in_water then
				mcl_player.player_set_animation(player, "run_walk", animation_speed_mod)
			elseif crouching then
				mcl_player.player_set_animation(player, "sneak_walk", animation_speed_mod)
			else
				mcl_player.player_set_animation(player, "walk", animation_speed_mod)
			end
		elseif get_mouse_button(player) and not crouching then
			set_bone_pos(player, "Head_Control", nil, vector.new(pitch, player_vel_yaw - yaw, 0))
			set_bone_pos(player, "Body_Control", nil, vector.new(0, -player_vel_yaw + yaw, 0))
			mcl_util.set_properties(player, player_props_normal)
			mcl_player.player_set_animation(player, "mine")
		elseif get_mouse_button(player) and crouching then
			set_bone_pos(player, "Head_Control", nil, vector.new(pitch, player_vel_yaw - yaw, player_vel_yaw - yaw))
			set_bone_pos(player, "Body_Control", nil, vector.new(0, -player_vel_yaw + yaw, 0))
			mcl_util.set_properties(player, player_props_sneaking)
			mcl_player.player_set_animation(player, "sneak_mine")
		elseif crouching then
			set_bone_pos(player, "Head_Control", nil, vector.new(pitch, player_vel_yaw - yaw, player_vel_yaw - yaw))
			set_bone_pos(player, "Body_Control", nil, vector.new(0, -player_vel_yaw + yaw, 0))
			mcl_util.set_properties(player, player_props_sneaking)
			mcl_player.player_set_animation(player, "sneak_stand", animation_speed_mod)
		elseif not tbl.attached then
			mcl_util.set_properties(player, player_props_normal)
			set_bone_pos(player,"Head_Control", nil, vector.new(pitch, player_vel_yaw - yaw, 0))
			set_bone_pos(player,"Body_Control", nil, vector.new(0, -player_vel_yaw + yaw, 0))
			mcl_player.player_set_animation(player, "stand", animation_speed_mod)
		end
	end

	mcl_player.position_wielditem (wielded_itemname, wielded_def, player)

	-- controls right and left arms pitch when shooting a bow or blocking
	if mcl_shields.is_blocking(player) == 2 then
		set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.new(20, -20, 0))
	elseif mcl_shields.is_blocking(player) == 1 then
		set_bone_pos(player, "Arm_Left_Pitch_Control", nil, vector.new(20, 20, 0))
	-- controls right and left arms pitch when holing a loaded crossbow
	elseif core.get_item_group(wielded_itemname, "crossbow") == 5 then
		set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.new(pitch + 90, -30, pitch * -1 * .35))
		set_bone_pos(player, "Arm_Left_Pitch_Control", nil, vector.new(pitch + 90, 43, pitch * .35))
	-- controls right and left arms pitch when loading a crossbow
	elseif core.get_item_group(wielded_itemname, "crossbow") > 0 then
		set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.new(45, -20, 25))
		set_bone_pos(player, "Arm_Left_Pitch_Control", nil, vector.new(55, 20, -45))
	elseif core.get_item_group(wielded_itemname, "bow") > 0 and control.RMB then
		local right_arm_rot = vector.new(pitch + 90, -30, pitch * -1 * .35)
		local left_arm_rot = vector.new(pitch + 90, 43, pitch * .35)
		set_bone_pos(player, "Arm_Right_Pitch_Control", nil, right_arm_rot)
		set_bone_pos(player, "Arm_Left_Pitch_Control", nil, left_arm_rot)
	-- when punching
	elseif control.LMB and not parent then
		set_bone_pos(player,"Arm_Right_Pitch_Control", nil, vector.new(pitch, 0, 0))
		set_bone_pos(player,"Arm_Left_Pitch_Control", nil, vector.zero())
	-- when holding an item.
	elseif wielded:get_name() ~= "" then
		set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.new(20, 0, 0))
		set_bone_pos(player, "Arm_Left_Pitch_Control", nil, vector.zero())
	-- resets arms pitch
	else
		set_bone_pos(player, "Arm_Left_Pitch_Control", nil, vector.zero())
		set_bone_pos(player, "Arm_Right_Pitch_Control", nil, vector.zero())
	end
end)

mcl_player.register_globalstep_slow(function(player)
	-- Underwater: Spawn bubble particles
	if not mcl_player.players[player].pspawner_underwater and core.get_item_group(mcl_player.players[player].nodes.head, "water") > 0 then
		mcl_player.players[player].pspawner_underwater = core.add_particlespawner({
			amount = 4,
			time = 0,
			minpos = { x = -0.25, y = 0.3, z = -0.25 },
			maxpos = { x = 0.25, y = 0.7, z = 0.75 },
			attached = player,
			minvel = {x = -0.2, y = 0, z = -0.2},
			maxvel = {x = 0.5, y = 0, z = 0.5},
			minacc = {x = -0.4, y = 4, z = -0.4},
			maxacc = {x = 0.5, y = 1, z = 0.5},
			minexptime = 0.3,
			maxexptime = 0.8,
			minsize = 0.7,
			maxsize = 2.4,
			texture = "mcl_particles_bubble.png"
		})
	elseif mcl_player.players[player].pspawner_underwater and core.get_item_group(mcl_player.players[player].nodes.head, "water") == 0 then
		core.delete_particlespawner(mcl_player.players[player].pspawner_underwater)
		mcl_player.players[player].pspawner_underwater = nil
	end
end)

core.register_on_respawnplayer(function(player)
	local pos = player:get_pos()
	core.add_particlespawner({
		amount = 20,
		time = 0.001,
		minpos = vector.add(pos, 0),
		maxpos = vector.add(pos, 0),
		minvel = vector.new(-5,-5,-5),
		maxvel = vector.new(5,5,5),
		minexptime = 1.1,
		maxexptime = 1.5,
		minsize = 1,
		maxsize = 2,
		collisiondetection = false,
		vertical = false,
		texture = "mcl_particles_mob_death.png^[colorize:#000000:255",
	})

	core.sound_play("mcl_mobs_mob_poof", {
		pos = pos,
		gain = 1.0,
		max_hear_distance = 8,
	}, true)
end)

-- Minecraft's player model, with wide (Steve) and slim (Alex) arms
for _, name in ipairs({"mcl_player_wide.glb", "mcl_player_slim.glb"}) do
	mcl_player.player_register_model(name, {
		procedural_animation = "minecraft_player",
		textures = {"character.png", "blank.png", "blank.png", "blank.png", "blank.png"},
		animations = {},
	})
end
