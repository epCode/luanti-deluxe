-- Liquids: Water and lava

local S = core.get_translator(core.get_current_modname())

--local WATER_ALPHA = 179
local WATER_VISC = 1
local LAVA_VISC = 7
local LIGHT_LAVA = core.LIGHT_MAX

-- Liquid flow follows Minecraft's fluid ticks (engine liquid_model
-- "minecraft", 20 game ticks per second).  Water moves one node every
-- 5 game ticks and reaches 7 nodes from its source.  Lava moves every
-- 30 game ticks and reaches 3 nodes, but in the Nether ("ultrawarm") it
-- moves every 10 game ticks and reaches 7 nodes like water.
local WATER_FLOW = {
	liquid_model = "minecraft",
	liquid_tick_delay = 5,
	liquid_drop_off = 1,
	liquid_slope_find_distance = 4,
	liquid_renewable = true,
}

local LAVA_FLOW = {
	liquid_model = "minecraft",
	liquid_tick_delay = 30,
	liquid_drop_off = 2,
	liquid_slope_find_distance = 2,
	liquid_renewable = false,
	liquid_flow_zones = {
		{
			y_min = mcl_vars.mg_nether_min,
			y_max = mcl_vars.mg_nether_max + 128,
			tick_delay = 10,
			drop_off = 1,
			slope_find_distance = 4,
		},
	},
}

-- Minecraft's lava "fizz" (level event 1501)
local function lava_fizz(pos)
	core.sound_play("fire_extinguish_flame", {pos = pos, gain = 0.2, max_hear_distance = 16}, true)
	core.add_particlespawner({
		amount = 8,
		time = 0.1,
		pos = {min = vector.offset(pos, -0.5, 0.5, -0.5), max = vector.offset(pos, 0.5, 0.6, 0.5)},
		vel = {min = vector.new(-0.05, 0.2, -0.05), max = vector.new(0.05, 0.6, 0.05)},
		exptime = {min = 0.8, max = 1.6},
		size = {min = 3, max = 4},
		texture = "mcl_particles_smoke.png",
	})
end
mcl_core.lava_fizz = lava_fizz

-- LiquidBlock.shouldSpreadLiquid: lava touching water from above or from
-- the side hardens at once (source: obsidian, flowing: cobblestone), and
-- lava on soul soil touching blue ice turns into basalt.
local LAVA_REACT_SIDES = {
	vector.new(0, 1, 0), vector.new(0, 0, -1), vector.new(0, 0, 1),
	vector.new(-1, 0, 0), vector.new(1, 0, 0),
}

function mcl_core.lava_on_liquid_update(pos, node)
	local below = core.get_node(vector.offset(pos, 0, -1, 0)).name
	local on_soul_soil = below == "mcl_blackstone:soul_soil"
	for _, side in ipairs(LAVA_REACT_SIDES) do
		local name = core.get_node(pos + side).name
		local result
		if core.get_item_group(name, "water") > 0 then
			result = core.get_item_group(node.name, "lava_source") > 0
				and "mcl_core:obsidian" or "mcl_core:cobble"
		elseif on_soul_soil and name == "mcl_core:blue_ice"
				and core.registered_nodes["mcl_blackstone:basalt"] then
			result = "mcl_blackstone:basalt"
		end
		if result then
			core.set_node(pos, {name = result})
			lava_fizz(pos)
			return true
		end
	end
	return false
end

-- Lava flowing down onto water turns the water into stone
-- (LavaFluid.spreadTo)
function mcl_core.water_on_flood(pos, _, newnode)
	if core.get_item_group(newnode.name, "lava") > 0 then
		core.set_node(pos, {name = "mcl_core:stone"})
		lava_fizz(pos)
		return true
	end
	return false
end

core.register_node("mcl_core:water_flowing", table.merge(WATER_FLOW, {
	description = S("Flowing Water"),
	_doc_items_create_entry = false,
	wield_image = "default_water_flowing_animated.png^[verticalframe:64:0",
	drawtype = "flowingliquid",
	tiles = {"default_water_flowing_animated.png^[verticalframe:64:0"},
	special_tiles = {
		{
			name = "default_water_flowing_animated.png",
			backface_culling=false,
			animation={type="vertical_frames", aspect_w=16, aspect_h=16, length=4.0}
		},
		{
			name = "default_water_flowing_animated.png",
			backface_culling=false,
			animation={type="vertical_frames", aspect_w=16, aspect_h=16, length=4.0}
		},
	},
	sounds = mcl_sounds.node_sound_water_defaults(),
	is_ground_content = false,
	use_texture_alpha = "blend",
	paramtype = "light",
	paramtype2 = "flowingliquid",
	walkable = false,
	pointable = false,
	diggable = false,
	buildable_to = true,
	drop = "",
	drowning = 4,
	liquidtype = "flowing",
	liquid_alternative_flowing = "mcl_core:water_flowing",
	liquid_alternative_source = "mcl_core:water_source",
	liquid_viscosity = WATER_VISC,
	liquid_range = 7,
	on_flood = mcl_core.water_on_flood,
	waving = 3,
	post_effect_color = {a=60, r=0x03, g=0x3C, b=0x5C},
	groups = { liquid_flowing=1, water=3, liquid=3, puts_out_fire=1, not_in_creative_inventory=1, freezes=1, melt_around=1, dig_by_piston=1, unsticky = 1},
	_pathfinding_class = "WATER",
	_on_bottle_place = mcl_core.get_bottle_place_on_water("mcl_potions:water"),
	_mcl_blast_resistance = 100,
	-- Hardness intentionally set to infinite instead of 100 (Minecraft value) to avoid problems in creative mode
	_mcl_hardness = -1,
}))

core.register_node("mcl_core:water_source", table.merge(WATER_FLOW, {
	description = S("Water Source"),
	_doc_items_entry_name = S("Water"),
	_doc_items_longdesc =
S("Water is abundant in oceans and also appears in a few springs in the ground. You can swim easily in water, but you need to catch your breath from time to time.").."\n\n"..
S("Water interacts with lava in various ways:").."\n"..
S("• When water is directly above or horizontally next to a lava source, the lava turns into obsidian.").."\n"..
S("• When flowing water touches flowing lava either from above or horizontally, the lava turns into cobblestone.").."\n"..
S("• When water is directly below lava, the water turns into stone."),
	_doc_items_hidden = false,
	drawtype = "liquid",
	waving = 3,
	tiles = {
		{name="default_water_source_animated.png", animation={type="vertical_frames", aspect_w=16, aspect_h=16, length=5.0}}
	},
	special_tiles = {
		-- New-style water source material (mostly unused)
		{
			name = "default_water_source_animated.png",
			animation={type="vertical_frames", aspect_w=16, aspect_h=16, length=5.0},
			backface_culling = false,
		}
	},
	sounds = mcl_sounds.node_sound_water_defaults(),
	is_ground_content = false,
	use_texture_alpha = "blend",
	paramtype = "light",
	walkable = false,
	pointable = false,
	diggable = false,
	buildable_to = true,
	drop = "",
	drowning = 4,
	liquidtype = "source",
	liquid_alternative_flowing = "mcl_core:water_flowing",
	liquid_alternative_source = "mcl_core:water_source",
	liquid_viscosity = WATER_VISC,
	liquid_range = 7,
	on_flood = mcl_core.water_on_flood,
	post_effect_color = {a=60, r=0x03, g=0x3C, b=0x5C},
	groups = { liquid_source=1, water=3, liquid=3, puts_out_fire=1, freezes=1, not_in_creative_inventory=1, dig_by_piston=1, unsticky = 1},
	_pathfinding_class = "WATER",
	_on_bottle_place = mcl_core.get_bottle_place_on_water("mcl_potions:water"),
	_mcl_blast_resistance = 100,
	-- Hardness intentionally set to infinite instead of 100 (Minecraft value) to avoid problems in creative mode
	_mcl_hardness = -1,
	after_destruct = core.check_for_falling,
}))

core.register_node("mcl_core:lava_flowing", table.merge(LAVA_FLOW, {
	description = S("Flowing Lava"),
	_doc_items_create_entry = false,
	wield_image = "default_lava_flowing_animated.png^[verticalframe:64:0",
	drawtype = "flowingliquid",
	tiles = {"default_lava_flowing_animated.png^[verticalframe:64:0"},
	special_tiles = {
		{
			name = "default_lava_flowing_animated.png",
			backface_culling=false,
			animation={type="vertical_frames", aspect_w=16, aspect_h=16, length=6.6}
		},
		{
			name = "default_lava_flowing_animated.png",
			backface_culling=false,
			animation={type="vertical_frames", aspect_w=16, aspect_h=16, length=6.6}
		},
	},
	paramtype = "light",
	paramtype2 = "flowingliquid",
	light_source = LIGHT_LAVA,
	is_ground_content = false,
	sounds = mcl_sounds.node_sound_lava_defaults(),
	walkable = false,
	pointable = false,
	diggable = false,
	buildable_to = true,
	drop = "",
	--[[ Drowning in Minecraft deals 2 damage per second.
	In Minetest, drowning damage is dealt every 2 seconds so this
	translates to 4 drowning damage ]]
	drowning = 0,
	liquidtype = "flowing",
	liquid_alternative_flowing = "mcl_core:lava_flowing",
	liquid_alternative_source = "mcl_core:lava_source",
	liquid_viscosity = LAVA_VISC,
	liquid_renewable = false,
	liquid_range = 3,
	on_liquid_update = mcl_core.lava_on_liquid_update,
	damage_per_second = 4*2,
	post_effect_color = {a=245, r=208, g=73, b=10},
	groups = { liquid_flowing=1, lava=3, liquid=2, destroys_items=1, not_in_creative_inventory=1, dig_by_piston=1, set_on_fire=15, unsticky = 1},
	_pathfinding_class = "LAVA",
	_mcl_blast_resistance = 100,
	-- Hardness intentionally set to infinite instead of 100 (Minecraft value) to avoid problems in creative mode
	_mcl_hardness = -1,
}))

local fire_text
local fire_enabled = core.settings:get_bool("enable_fire", true)
if fire_enabled then
	fire_text = S("A lava source sets fire to a couple of air blocks above when they're next to a flammable block.")
else
	fire_text = ""
end

core.register_node("mcl_core:lava_source", table.merge(LAVA_FLOW, {
	description = S("Lava Source"),
	_doc_items_entry_name = "Lava",
	_doc_items_longdesc =
S("Lava is hot and rather dangerous. Don't touch it, it will hurt you a lot and it is hard to get out.").."\n"..
fire_text.."\n\n"..
S("Lava interacts with water various ways:").."\n"..
S("• When a lava source is directly below or horizontally next to water, the lava turns into obsidian.").."\n"..
S("• When flowing water touches flowing lava either from above or horizontally, the lava turns into cobblestone.").."\n"..
S("• When lava is directly above water, the water turns into stone."),
	drawtype = "liquid",
	tiles = {
		{name="default_lava_source_animated.png", animation={type="vertical_frames", aspect_w=16, aspect_h=16, length=3.0}}
	},
	special_tiles = {
		-- New-style lava source material (mostly unused)
		{
			name="default_lava_source_animated.png",
			animation={type="vertical_frames", aspect_w=16, aspect_h=16, length=3.0},
			backface_culling = false,
		}
	},
	paramtype = "light",
	light_source = LIGHT_LAVA,
	is_ground_content = false,
	sounds = mcl_sounds.node_sound_lava_defaults(),
	walkable = false,
	pointable = false,
	diggable = false,
	buildable_to = true,
	drop = "",
	drowning = 0,
	liquidtype = "source",
	liquid_alternative_flowing = "mcl_core:lava_flowing",
	liquid_alternative_source = "mcl_core:lava_source",
	liquid_viscosity = LAVA_VISC,
	liquid_renewable = false,
	liquid_range = 3,
	on_liquid_update = mcl_core.lava_on_liquid_update,
	damage_per_second = 4*2,
	post_effect_color = {a=245, r=208, g=73, b=10},
	groups = { liquid_source=1, lava=3, lava_source=1, liquid=2, destroys_items=1, not_in_creative_inventory=1, dig_by_piston=1, set_on_fire=15, fire_damage=1, unsticky = 1},
	_pathfinding_class = "LAVA",
	_mcl_blast_resistance = 100,
	-- Hardness intentionally set to infinite instead of 100 (Minecraft value) to avoid problems in creative mode
	_mcl_hardness = -1,
	after_destruct = core.check_for_falling,
}))

local function emit_lava_particle(pos)
	local node = core.get_node(pos)
	if core.get_item_group(node.name, "lava_source") == 0 then
		return
	end
	local ppos = vector.add(pos, { x = math.random(-7, 7)/16, y = 0.45, z = math.random(-7, 7)/16})
	--local spos = vector.add(ppos, { x = 0, y = -0.2, z = 0 })
	local vel = { x = math.random(-3, 3)/10, y = math.random(4, 7), z = math.random(-3, 3)/10 }
	local acc = { x = 0, y = -9.81, z = 0 }
	-- Lava droplet
	core.add_particle({
		pos = ppos,
		velocity = vel,
		acceleration = acc,
		expirationtime = 2.5,
		collisiondetection = true,
		collision_removal = true,
		size = math.random(20, 30)/10,
		texture = "mcl_particles_lava.png",
		glow = LIGHT_LAVA,
	})
end

if core.settings:get("mcl_node_particles") == "full" then
	core.register_abm({
		label = "Lava particles",
		nodenames = {"group:lava_source"},
		interval = 8.0,
		chance = 20,
		action = function(pos)
			local apos = {x=pos.x, y=pos.y+1, z=pos.z}
			local anode = core.get_node(apos)
			-- Only emit partiles when directly below lava
			if anode.name ~= "air" then
				return
			end

			core.after(math.random(0, 800)*0.01, emit_lava_particle, pos)
		end,
	})
end


