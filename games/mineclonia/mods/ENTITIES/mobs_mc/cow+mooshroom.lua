--License for code WTFPL and otherwise stated in readmes

local S = core.get_translator("mobs_mc")
local mob_class = mcl_mobs.mob_class

local cow_def = {
	description = S("Cow"),
	type = "animal",
	_spawn_category = "creature",
	runaway = true,
	hp_min = 10,
	hp_max = 10,
	xp_min = 1,
	xp_max = 3,
	collisionbox = {-0.45, 0.0, -0.45, 0.45, 1.4, 0.45},
	-- Cow.java, MushroomCow.java: BABY_DIMENSIONS 0.45x0.7, eye
	-- height 0.69.
	child_collisionbox = {-0.225, 0.0, -0.225, 0.225, 0.7, 0.225},
	child_head_eye_height = 0.69,
	_group_baby_chance = 0.05,
	visual = "mesh",
	mesh = "mobs_mc_cow.b3d",
	textures = {
		{
			"mobs_mc_cow.png",
			"blank.png",
		},
	},
	head_swivel = "head.control",
	bone_eye_height = 10,
	head_eye_height = 1.3,
	horizontal_head_height=-1.8,
	curiosity = 2,
	head_yaw = "z",
	makes_footstep_sound = true,
	movement_speed = 4.0,
	drops = {
		{
			name = "mcl_mobitems:beef",
			chance = 1,
			min = 1,
			max = 3,
			looting = "common",
		},
		{
			name = "mcl_mobitems:leather",
			chance = 1,
			min = 0,
			max = 2,
			looting = "common",
		},
	},
	sounds = {
		random = {name = "mobs_mc_cow", gain = 0.5},
		damage = "mobs_mc_cow_hurt",
		death = "mobs_mc_cow_hurt",
		eat = "mobs_mc_animal_eat_generic",
		distance = 16,
	},
	animation = {
		stand_start = 0, stand_end = 0,
		walk_start = 0, walk_end = 40, walk_speed = 40,
		run_start = 0, run_end = 40, run_speed = 40,
	},
	_child_animations = {
		stand_start = 41, stand_end = 41,
		walk_start = 41, walk_end = 81, walk_speed = 80,
		run_start = 41, run_end = 81, run_speed = 80,
	},
	follow = {
		"mcl_farming:wheat_item",
	},
	-- AbstractCow.java: PanicGoal 2.0, TemptGoal 1.25,
	-- FollowParentGoal 1.25.
	run_bonus = 2.0,
	follow_bonus = 1.25,
	follow_herd_bonus = 1.25,
}

------------------------------------------------------------------------
-- Cow interaction.
------------------------------------------------------------------------

function cow_def:on_rightclick (clicker)
	if self:follow_holding(clicker) and self:feed_tame(clicker, nil, true, false) then return end
	if self.child then return end

	local item = clicker:get_wielded_item()
	if item:get_name() == "mcl_buckets:bucket_empty" and clicker:get_inventory() then
		local inv = clicker:get_inventory()
		inv:remove_item("main", "mcl_buckets:bucket_empty")
		core.sound_play("mobs_mc_cow_milk", {pos=self.object:get_pos(), gain=0.6})
		-- if room add bucket of milk to inventory, otherwise drop as item
		if inv:room_for_item("main", {name = "mcl_mobitems:milk_bucket"}) then
			clicker:get_inventory():add_item("main", "mcl_mobitems:milk_bucket")
		else
			local pos = self.object:get_pos()
			pos.y = pos.y + 0.5
			core.add_item(pos, {name = "mcl_mobitems:milk_bucket"})
		end
	end
end

------------------------------------------------------------------------
-- Cow AI.
------------------------------------------------------------------------

cow_def.ai_functions = {
	mob_class.check_frightened,
	mob_class.check_breeding,
	mob_class.check_following,
	mob_class.follow_herd,
	mob_class.check_pace,
}

mcl_mobs.register_mob ("mobs_mc:cow", cow_def)

------------------------------------------------------------------------
-- Mooshroom.
------------------------------------------------------------------------

local mooshroom = table.merge(cow_def, {
	description = S("Mooshroom"),
	textures = {
		{"mobs_mc_mooshroom.png", "mobs_mc_mushroom_red.png"},
		{"mobs_mc_mooshroom_brown.png", "mobs_mc_mushroom_brown.png" },
	},
	-- can have the item name of a small flower when used on a mooshroom. It determines
	-- the type of suspicious stew that is given after a bowl is used on the mooshroom.
	_sus_ingredient_held = nil,
})

function mooshroom:on_rightclick (clicker)
	if self:follow_holding(clicker) and self:feed_tame(clicker, nil, true, false) then return end
	if self.child then return end

	local object = self.object
	local obj_pos = object:get_pos()
	local item = clicker:get_wielded_item()
	local item_name = item:get_name()
	local inv = clicker:get_inventory()
	local is_brown_mooshroom = self.base_texture[1] == "mobs_mc_mooshroom_brown.png"

	if inv then
		-- Use shears to convert mooshroom into cow while harvesting mushrooms
		if core.get_item_group(item_name, "shears") > 0 then
			local stack
			local item_pos = vector.offset(obj_pos, 0, 1.4, 0)
			-- MushroomCow.shear
			if mcl_gameevent then
				mcl_gameevent.emit_entity (object, "shear", clicker)
			end

			if is_brown_mooshroom then
				stack = ItemStack("mcl_mushrooms:mushroom_brown 5")
			else
				stack = ItemStack("mcl_mushrooms:mushroom_red 5")
			end

			core.add_item(item_pos, stack)
			mcl_util.replace_mob(object, "mobs_mc:cow")

			if not core.is_creative_enabled(clicker:get_player_name()) then
				local wear = mcl_autogroup.get_wear(item_name, "shearsy")

				item:add_wear(wear)
				inv:set_stack("main", clicker:get_wield_index(), item)
			end
		-- Use an empty bucket to milk a cow
		elseif item_name == "mcl_buckets:bucket_empty" then
			local stack = ItemStack("mcl_mobitems:milk_bucket")

			inv:remove_item("main", item_name)
			core.sound_play("mobs_mc_cow_milk", {pos = obj_pos, gain = 0.6})

			if inv:room_for_item("main", stack) then
				inv:add_item("main", stack)
			else
				core.add_item(vector.offset(obj_pos, 0, 0.5, 0), stack)
			end
		-- Use a bowl to get a mushroom stew, or a suspicious stew if the mooshroom holds an effect
		elseif item_name == "mcl_core:bowl" then
			inv:remove_item("main", item_name)
			core.sound_play("mobs_mc_cow_mushroom_stew", {pos = obj_pos, gain = 0.6})

			local stack
			if is_brown_mooshroom and self._sus_ingredient_held then
				stack = mcl_sus_stew.get_sus_stew(self._sus_ingredient_held)
				self._sus_ingredient_held = nil
			else
				stack = ItemStack("mcl_mushrooms:mushroom_stew")
			end

			if inv:room_for_item("main", stack) then
				inv:add_item("main", stack)
			else
				core.add_item(vector.offset(obj_pos, 0, 0.5, 0), stack)
			end
		-- Use a small flower to give an effect to a brown mooshroom
		elseif core.get_item_group(item_name, "sus_stew_ingredient") > 0 and is_brown_mooshroom then
			if self._sus_ingredient_held then
				return
			end
			self._sus_ingredient_held = item_name
			inv:remove_item("main", item_name)
		end
	end
end

local RED_MOOSHROOM = { "mobs_mc_mooshroom.png", "mobs_mc_mushroom_red.png" }
local BROWN_MOOSHROOM = { "mobs_mc_mooshroom_brown.png", "mobs_mc_mushroom_brown.png" }

local function mooshroom_set_variant (self, brown)
	self.texture_selected = brown and 2 or 1
	self.base_texture = table.copy (brown and BROWN_MOOSHROOM or RED_MOOSHROOM)
	self:set_textures (self.base_texture)
end

-- MushroomCow.java does not select a variant in finalizeSpawn, so
-- every mooshroom spawns with the default (red) variant.
function mooshroom:on_spawn ()
	mooshroom_set_variant (self, false)
end

-- MushroomCow.getOffspringVariant: parents of the same variant have a
-- 1 in 1024 chance of producing the other variant; otherwise the
-- variant of either parent is inherited at random.
function mooshroom:on_breed (mate)
	local self_pos = self.object:get_pos ()
	local child = mcl_mobs.spawn_child (self_pos, self.name)
	if child then
		local ent_c = child:get_luaentity ()
		local brown = self.base_texture[1] == BROWN_MOOSHROOM[1]
		local mate_brown = mate.base_texture
			and mate.base_texture[1] == BROWN_MOOSHROOM[1] or false
		local child_brown
		if brown == mate_brown and math.random (1024) == 1 then
			child_brown = not brown
		elseif math.random (2) == 1 then
			child_brown = brown
		else
			child_brown = mate_brown
		end
		mooshroom_set_variant (ent_c, child_brown)
		ent_c.tamed = true
		ent_c.owner = self.owner
	end
end

function mooshroom:_on_lightning_strike ()
	mooshroom_set_variant (self, self.base_texture[1] ~= BROWN_MOOSHROOM[1])
	return true
end

function mooshroom:_on_dispense (dropitem, pos, droppos, dropnode, dropdir)
	if core.get_item_group(dropitem:get_name(), "shears") > 0 then
		-- ShearsDispenseItemBehavior.tryShearEntity
		if mcl_gameevent then
			mcl_gameevent.emit ("shear", droppos, {})
		end
		local droppos = vector.offset(pos, 0, 1.4, 0)
		if self.base_texture[1] == "mobs_mc_mooshroom_brown.png" then
			core.add_item(droppos, "mcl_mushrooms:mushroom_brown 5")
		else
			core.add_item(droppos, "mcl_mushrooms:mushroom_red 5")
		end
		mcl_util.replace_mob(self.object, "mobs_mc:cow")
		return dropitem
	end
	return mcl_mobs.mob_class._on_dispense(self, dropitem, pos, droppos, dropnode, dropdir)
end

mcl_mobs.register_mob ("mobs_mc:mooshroom", mooshroom)

------------------------------------------------------------------------
-- Cow & Mooshroom spawning.
------------------------------------------------------------------------

-- spawn egg
mcl_mobs.register_egg("mobs_mc:cow", S("Cow"), "#443626", "#a1a1a1", 0)
mcl_mobs.register_egg("mobs_mc:mooshroom", S("Mooshroom"), "#a00f10", "#b7b7b7", 0)

------------------------------------------------------------------------
-- Modern Cow & Mooshroom spawning.
------------------------------------------------------------------------

-- OverworldBiomes.meadowOrCherryGrove: cherry groves do not receive
-- BiomeDefaultFeatures.farmAnimals.
local farm_biomes = {}
for _, biome in ipairs (mobs_mc.farm_animal_biomes) do
	if biome ~= "CherryGrove" then
		table.insert (farm_biomes, biome)
	end
end

-- BiomeDefaultFeatures.farmAnimals: cow 8 (4-4).
local cow_spawner = table.merge (mobs_mc.animal_spawner, {
	name = "mobs_mc:cow",
	biomes = farm_biomes,
	weight = 8,
})

mcl_mobs.register_spawner (cow_spawner)

local mooshroom_spawner = table.merge (mobs_mc.animal_spawner, {
	name = "mobs_mc:mooshroom",
	biomes = {
		"MushroomIslands",
	},
	weight = 8,
	pack_min = 4,
	pack_max = 8,
})

function mooshroom_spawner:test_supporting_node (node)
	return core.get_item_group (node.name, "mycelium") > 0
end

function mooshroom_spawner:describe_supporting_nodes ()
	return "on mycelium"
end

mcl_mobs.register_spawner (mooshroom_spawner)
