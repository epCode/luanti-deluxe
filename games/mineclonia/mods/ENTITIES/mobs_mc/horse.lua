local S = core.get_translator("mobs_mc")
local mob_class = mcl_mobs.mob_class

local function attach_driver(self, clicker)
	if self:attach (clicker) then
		mcl_title.set(clicker, "actionbar", {
			text=S("Sneak to dismount"),
			color="white", stay = 60,
		})
	end
end

local function detach_driver(self)
	if self.driver then
		self:detach (self.driver, {x=0, y=0, z=0})
	end

	if self._selectionbox_overloaded then
		self._selectionbox_overloaded = false
		self.object:set_properties ({
			selectionbox = self.collisionbox,
		})
	end
end

-- Entity type tag `can_wear_horse_armor': horse and zombie_horse.
local function can_equip_horse_armor (entity_id)
	return entity_id == "mobs_mc:horse"
		or entity_id == "mobs_mc:zombie_horse"
end

local horse_base = {
	"mobs_mc_horse_brown.png",
	"mobs_mc_horse_darkbrown.png",
	"mobs_mc_horse_white.png",
	"mobs_mc_horse_gray.png",
	"mobs_mc_horse_black.png",
	"mobs_mc_horse_chestnut.png",
	"mobs_mc_horse_creamy.png",
}

local horse_markings = {
	"", -- no markings
	"mobs_mc_horse_markings_whitedots.png", -- snowflake appaloosa
	"mobs_mc_horse_markings_blackdots.png", -- sooty
	"mobs_mc_horse_markings_whitefield.png", -- paint
	"mobs_mc_horse_markings_white.png", -- stockings and blaze
}

local horse_textures = {}
for b=1, #horse_base do
	for m=1, #horse_markings do
		local fur = horse_base[b]
		if horse_markings[m] ~= "" then
			fur = fur .. "^" .. horse_markings[m]
		end
		table.insert(horse_textures, {
			"blank.png", -- chest
			fur, -- base texture + markings and optional armor
			"blank.png", -- saddle
		})
	end
end

-- Horse
local horse = {
	description = S("Horse"),
	type = "animal",
	_spawn_category = "creature",
	visual = "mesh",
	mesh = "mobs_mc_horse.b3d",
	visual_size = {x=3.0, y=3.0},
	collisionbox = {-0.69825, 0, -0.69825, 0.69825, 1.6, 0.69825},
	runaway = true,
	movement_speed = 6.75,
	animation = {
		stand_start = 0, stand_end = 0, stand_speed = 25,
		walk_start = 0, walk_end = 40, walk_speed = 25,
		run_start = 0, run_end = 40, run_speed = 50,
	},
	follow = {
		"mcl_farming:carrot_item_gold",
		"mcl_core:apple_gold",
		"mcl_core:apple_gold_enchanted",
	},
	textures = horse_textures,
	sounds = {
		random = "mobs_mc_horse_random",
		damage = "mobs_mc_horse_hurt",
		death = "mobs_mc_horse_death",
		eat = "mobs_mc_animal_eat_generic",
		distance = 16,
	},
	steer_class = "controls",
	-- AbstractHorse.handleEating.
	_food_items = {
		["mcl_farming:wheat_item"] = {
			2.0, -- Health.
			20, -- Age delta in seconds (AgeableMob.ageUp).
			3, -- Temper.
		},
		["mcl_core:sugar"] = {
			1.0, -- Health.
			30, -- Age delta in seconds.
			3, -- Temper.
		},
		["mcl_farming:hay_block"] = {
			20.0, -- Health.
			180, -- Age delta in seconds.
			0, -- Temper.
		},
		["mcl_core:apple"] = {
			3.0,
			60,
			3,
		},
		["mcl_farming:carrot_item"] = {
			3.0,
			60,
			3,
		},
		["mcl_farming:carrot_item_gold"] = {
			4.0,
			60,
			5,
			true -- Breed.
		},
		["mcl_core:apple_gold"] = {
			10.0,
			240,
			10,
			true -- Breed.
		},
		["mcl_core:apple_gold_enchanted"] = {
			10.0,
			240,
			10,
			true -- Breed.
		},
	},
	hp_min = 30,
	hp_max = 30,
	xp_min = 1,
	xp_max = 3,
	floats = 1,
	makes_footstep_sound = true,
	can_ride_boat = false,
	jump = true,
	drops = {
		{
			name = "mcl_mobitems:leather",
			chance = 1,
			min = 0,
			max = 2,
			looting = "common",
		},
	},
	_dispenser_actions = {
		{
			groups = {
				"horse_armor",
			},
			fn = function (self, item)
				if self._horse_armor_stack == ""
					and can_equip_horse_armor (self.name)
					and not self.child and self.tamed then
					self:set_armor_1 (item:get_name (), item)
					self:update_armor_inv ()
					item:take_item ()
					return item
				end
				return nil
			end,
		},
		{
			names = {
				"mcl_mobitems:saddle",
			},
			fn = function (self, item)
				if self._saddle == ""
					and not self.child and self.tamed then
					self:set_saddle (item, nil)
					self:update_armor_inv ()
					item:take_item ()
					return item
				end
				return nil
			end,
		},
	},
	jump_height = 14,
	fall_damage_multiplier = 0.5,
	_safe_fall_distance = 6.0,
	-- Values of 1.0 precisely trigger engine bugs.
	stepheight = 1.02,
	head_eye_height = 1.52,
	-- Horse.BABY_DIMENSIONS: scale (0.7).
	child_scale = 0.7,
	-- Horse.HorseGroupData: AgeableMobGroupData (true), 5% babies.
	_group_baby_chance = 0.05,
	_temper = 0,
	-- AbstractHorse.getMaxTemper.
	_max_temper = 100,
	-- AbstractHorse.MountPanicGoal (1.2).
	run_bonus = 1.2,
	pace_bonus = 0.7,
	follow_bonus = 1.25,
	follow_herd_bonus = 1.0,
	_saddle = "",
	_horse_armor_stack = "",
	_eats = true,
	-- AbstractHorse.canPerformRearing.
	_can_rear = true,
	-- RandomStandGoal.nextStand; -getAmbientStandInterval ().
	_next_stand = -400,
	_csm_driving_enabled = true,
}

local pr = PcgRandom (os.time () + 343)

local function horse_texture (base, markings)
	local fur = horse_base[base]
	if horse_markings[markings] ~= "" then
		fur = fur .. "^" .. horse_markings[markings]
	end
	return fur
end

local function split_horse_texture (texture)
	local splt = string.split (texture, "^")
	local base, markings = 1, 1
	for i, name in ipairs (horse_base) do
		if name == splt[1] then
			base = i
		end
	end
	for i, name in ipairs (horse_markings) do
		if splt[2] and name == splt[2] then
			markings = i
		end
	end
	return base, markings
end

function horse:on_spawn ()
	self:initial_movement_properties ()
	-- Horse.finalizeSpawn: every member of a group shares one
	-- variant (HorseGroupData), but markings are random.
	if self._spawn_variant and self.name == "mobs_mc:horse" then
		local fur = horse_texture (self._spawn_variant,
					   pr:next (1, #horse_markings))
		self.base_texture = { "blank.png", fur, "blank.png", }
	end
	self._spawn_variant = nil
	local tex = self:extra_textures ()
	self:set_textures (tex)
end

function horse:actionable_on_rightclick (clicker)
	local wielditem = clicker:get_wielded_item ()
	local wield_food = self._food_items[wielditem:get_name ()] ~= nil
	return self.tamed or wield_food
end

------------------------------------------------------------------------
-- Horse AI.
------------------------------------------------------------------------

function horse:breeding_possible ()
	local entity_id = self.name
	return (entity_id == "mobs_mc:horse"
		or entity_id == "mobs_mc:donkey")
		and self.tamed
		and mob_class.breeding_possible (self)
end

-- AbstractHorse.canParent.
function horse:can_parent ()
	local hp_max = self.object:get_properties ().hp_max
	return not self.driver
		and not self.object:get_attach ()
		and self.tamed
		and not self.child
		and self.health >= hp_max
		and self:is_breeding ()
end

-- Horse.canMate, Donkey.canMate, Llama.canMate: both partners must
-- satisfy canParent.
function horse:can_mate_with (with)
	if not mob_class.can_mate_with (self, with) then
		return false
	end
	local entity = with:get_luaentity ()
	return self:can_parent ()
		and entity.can_parent ~= nil
		and entity:can_parent ()
end

-- AbstractHorse.standIfPossible and setStanding (20).
function horse:stand_if_possible ()
	if self._can_rear then
		self._eating = nil
		self._standing = 1.0
	end
end

-- AbstractHorse.makeMad.
function horse:enrage ()
	if not self._standing then
		self:stand_if_possible ()
		self:mob_sound ("angry")
	end
end

function horse:receive_damage (mcl_reason, damage)
	if mob_class.receive_damage (self, mcl_reason, damage) then
		-- AbstractHorse.hurtServer: rear 1 in 3 times.
		if pr:next (0, 2) == 0 then
			self:stand_if_possible ()
		end
		return true
	end
	return false
end

local SOLID_PACING_GROUPS = mcl_mobs.SOLID_PACING_GROUPS

local function smoke_particles (self_pos)
	-- AbstractHorse.spawnTamingParticles (false).
	mcl_mobs.effect (vector.offset (self_pos, 0, 0.7, 0), 7,
			 "mcl_particles_mob_death.png^[colorize:#000000:255",
			 2, 4, 2.0, 0.1)
end

-- RunAroundLikeCrazyGoal.
local function horse_maybe_tame (self, self_pos, dtime)
	local driver = self.driver

	if self._evaluating_handler then
		if not driver or not driver:is_valid () or self.tamed then
			self:cancel_navigation ()
			self:halt_in_tracks ()
			self._evaluating_handler = false
			return false
		end

		if self:navigation_finished () then
			self._evaluating_handler = false
			return false
		end

		-- Evaluate this handler every (on average) 50 ticks.
		if pr:next (1, mcl_mobs.scale_chance (50, dtime)) == 1 then
			if driver:is_player () then
				-- random.nextInt (maxTemper) < temper.
				if self._max_temper > 0
					and pr:next (0, self._max_temper - 1)
						< self._temper then
					self:just_tame (self_pos, driver)
					self._evaluating_handler = false
					self:post_attach (driver)
					return false
				end
				self._temper = math.min (self._temper + 5,
							 self._max_temper)
			end
			detach_driver (self)
			self:enrage ()
			smoke_particles (self_pos)
			self._evaluating_handler = false
			return false
		end
		return true
	elseif driver and not self.tamed then
		local target = self:pacing_target (self_pos, 5, 4, SOLID_PACING_GROUPS)
		if target then
			self:gopath (target, 1.2)
			self._evaluating_handler = true
			return "_evaluating_handler"
		end
		return false
	end
end

function horse:begin_eating (dtime)
	-- TODO: eating animation.
	self._eating = dtime
end

function horse:stop_eating ()
	self._eating = nil
end

-- AbstractHorse.isImmobile: grazing or rearing.
function horse:is_immobile ()
	return self._eating ~= nil or self._standing ~= nil
end

function horse:ai_step (dtime)
	mob_class.ai_step (self, dtime)
	-- AbstractHorse.aiStep: regenerate health.
	if pr:next (1, mcl_mobs.scale_chance (900, dtime)) == 1 then
		self:heal_mob (1)
	end

	-- AbstractHorse.canEatGrass.
	if self._eats then
		if not self._eating
			and not self.driver
			and pr:next (1, mcl_mobs.scale_chance (300, dtime)) == 1
			and self.standing_on == "mcl_core:dirt_with_grass" then
			self:begin_eating (2.55)
		end
		if self._eating then
			self._eating = self._eating - dtime
			if self._eating <= 0 then
				self:stop_eating ()
			end
		end
	end

	-- AbstractHorse.tick: standCounter.
	if self._standing then
		self._standing = self._standing - dtime
		if self._standing <= 0 then
			self._standing = nil
		end
	end
	if not self._standing then
		self._allow_stand_sliding = nil
	end
end

-- RandomStandGoal.canUse, evaluated every other tick.
local function horse_random_stand (self, dtime)
	if not self._can_rear then
		return
	end
	local t = (self._stand_eval_time or 0) + dtime
	while t >= 0.1 do
		t = t - 0.1
		self._next_stand = self._next_stand + 1
		if self._next_stand > 0
			and pr:next (0, 999) < self._next_stand then
			self._next_stand = -400
			if not self:is_immobile () and pr:next (0, 9) == 0 then
				self:stand_if_possible ()
				self:mob_sound ("random")
			end
		end
	end
	self._stand_eval_time = t
end

function horse:run_ai (dtime, moveresult)
	-- LivingEntity.aiStep: no AI runs while immobile.
	if self:is_immobile () then
		self:halt_in_tracks ()
		return
	end
	horse_random_stand (self, dtime)
	mob_class.run_ai (self, dtime, moveresult)
end

function horse:navigation_step (dtime, moveresult)
	if self:is_immobile () then
		return
	end
	mob_class.navigation_step (self, dtime, moveresult)
end

function horse:set_animation_speed (custom_speed)
	local anim = self._current_animation
	if not anim then
		return
	end
	local name = anim .. "_speed"
	local normal_speed = self.animation[name]
		or self.animation.speed_normal
		or 25
	local speed = custom_speed or normal_speed
	local v = self:get_velocity ()
	local scaled_speed = speed * self.frame_speed_multiplier
	self.object:set_animation_frame_speed (scaled_speed * math.max (1, v / 2))
end

horse.check_tame = horse_maybe_tame

horse.ai_functions = {
	mob_class.check_frightened,
	horse_maybe_tame,
	mob_class.check_breeding,
	mob_class.check_following,
	mob_class.follow_herd,
	mob_class.check_pace,
}

------------------------------------------------------------------------
-- Horse armor.
------------------------------------------------------------------------

function horse:extra_textures (cstring)
	local horse = self
	local base = horse._naked_texture or horse.base_texture[2]
	local saddle = ItemStack (horse._saddle)
	local chest = horse._chest
	local armor = ItemStack (horse._horse_armor_stack)
	local armor_name = armor:get_name ()
	local textures = {}
	if not armor:is_empty ()
		and core.get_item_group (armor_name, "horse_armor") > 0 then
		if cstring then
			textures[2] = base
				.. "^("
				.. core.registered_items[armor_name]._horse_overlay_image:gsub(".png$", "_desat.png")
				.. "^[multiply:" .. cstring .. ")"
		else
			textures[2] = base .. "^"
				.. core.registered_items[armor_name]._horse_overlay_image
		end
	else
		textures[2] = base
	end
	if not saddle:is_empty () then
		textures[3] = base
	else
		textures[3] = "blank.png"
	end
	if chest then
		textures[1] = base
	else
		textures[1] = "blank.png"
	end
	return textures
end

function horse:set_armor_1 (iname, w)
	local cstring
	if core.get_item_group(iname, "armor_leather") > 0 then
		local m = w:get_meta()
		local cs = m:get_string("mcl_armor:color")
		cstring = cs ~= "" and cs or nil
	end
	self._horse_armor_stack = w:to_string ()
	self:apply_horse_armor_points ()
	if not self._naked_texture then
		self._naked_texture = self.base_texture[2]
	end
	local tex = self:extra_textures (cstring)
	self.base_texture = tex
	self:set_textures (tex)
	local def = w:get_definition()
	if def.sounds and def.sounds._mcl_armor_equip then
		core.sound_play({name = def.sounds._mcl_armor_equip},
			{gain=0.5, max_hear_distance=12, pos=self.object:get_pos()}, true)
	end
	self:equipment_game_event (w)
end

function horse:set_armor (clicker)
	local w = clicker:get_wielded_item ()
	local iname = w:get_name ()
	if self._horse_armor_stack == "" then
		self:set_armor_1 (iname, w)
		self:update_armor_inv ()
		if not core.is_creative_enabled(clicker:get_player_name()) then
			w:take_item()
			clicker:set_wielded_item(w)
		end
		return true
	end
end

function horse:remove_armor (stack)
	self._horse_armor_stack = ""
	local def = stack:get_definition ()
	if def.sounds and def.sounds._mcl_armor_unequip then
		core.sound_play ({name = def.sounds._mcl_armor_unequip},
			{gain=0.5, max_hear_distance=12, pos=self.object:get_pos()}, true)
	end
	local tex = self:extra_textures ()
	self.base_texture = tex
	self:set_textures (tex)

	-- Restore initial armor values.
	self:apply_horse_armor_points ()
	self:equipment_game_event (ItemStack ())
end

-- Horse armor contributes to Minecraft's ARMOR attribute (the
-- `_horse_armor_points' of each item, i.e. the BODY slot defense of
-- its ArmorMaterial), which mcl_armor applies to damage.
function horse:apply_horse_armor_points ()
	local stack = ItemStack (self._horse_armor_stack)
	local def = not stack:is_empty () and stack:get_definition ()
	if def and core.get_item_group (stack:get_name (), "horse_armor") > 0 then
		self._natural_armor = def._horse_armor_points
			or (100 - core.get_item_group (stack:get_name (),
							"horse_armor")) / 4
		self._natural_armor_toughness = def._horse_armor_toughness
	else
		self._natural_armor = nil
		self._natural_armor_toughness = nil
	end
	-- Erase armor groups that approximated horse armor in
	-- earlier versions.
	if rawget (self, "armor") ~= nil then
		self.armor = nil
		local armor = self.armor
		local agroups
		if type (armor) == "table" then
			agroups = table.copy (armor)
			agroups.immortal = 1
		else
			agroups = { immortal = 1, fleshy = armor, }
		end
		self.object:set_armor_groups (agroups)
	end
end

------------------------------------------------------------------------
-- Horse inventories.
------------------------------------------------------------------------

local SADDLE_SLOT = 1
local ARMOR_SLOT = 2

function horse:is_saddle_item (stack)
	return stack:get_name () == "mcl_mobitems:saddle"
end

local function armor_allow_move (inv, from_list, from_index, to_list, to_index, count, player)
	return 0
end

local function armor_allow_put (horse, inv, listname, index, stack, player)
	if index == ARMOR_SLOT then
		local armor = core.get_item_group (stack:get_name (),
						       "horse_armor")
		return armor > 1 and 1 or 0
	elseif index == SADDLE_SLOT then
		local saddle = horse:is_saddle_item (stack)
		return saddle and 1 or 0
	end
	return 1
end

local function armor_on_put (horse, inv, listname, index, stack, player)
	if index == SADDLE_SLOT then
		horse:set_saddle (stack, nil)
	elseif index == ARMOR_SLOT then
		horse:set_armor_1 (stack:get_name (), stack)
	end
end

local function armor_on_take (horse, inv, listname, index, stack, player)
	if index == SADDLE_SLOT then
		horse:remove_saddle ()
	elseif index == ARMOR_SLOT then
		horse:remove_armor (stack)
	end
end

local horse_inventory_counter = 0

function horse:get_staticdata_table ()
	local supertable = mob_class.get_staticdata_table (self)
	if supertable then
		supertable._armor_inv = nil
		supertable._armor_inv_name = nil
	end
	return supertable
end

function horse:post_load_staticdata ()
	mob_class.post_load_staticdata (self)
	-- Update old horses.
	if self._horse_armor and self._wearing_armor then
		self._horse_armor_stack
			= ItemStack (self._horse_armor):to_string ()
	end
	if self._saddle and type (self._saddle) ~= "string" then
		self._saddle
			= ItemStack ("mcl_mobitems:saddle"):to_string ()
	end
	if not self._saddle then
		self._saddle = ""
	end
	if not self._horse_armor_stack then
		self._horse_armor_stack = ""
	end
	self._horse_armor = nil
end

function horse:mob_activate (staticdata, dtime)
	if not mob_class.mob_activate (self, staticdata, dtime) then
		return false
	end
	-- Erase obsolete drop lists.
	self.drops = nil
	-- Reconfigure maximum HP.
	if self.hp_max then
		self.object:set_properties ({
				hp_max = self.hp_max,
		})
		self.health = math.min (self.health, self.hp_max)
	end
	self._selectionbox_overloaded = false
	self:init_attachment_position ()
	self:apply_horse_armor_points ()
	return true
end

function horse:driver_detached (player, is_deactivation)
	if player:is_valid () then
		mcl_player.set_inventory_formspec (player, nil, 100)
	end
	mob_class.driver_detached (self, player, is_deactivation)
end

function horse:on_deactivate (removal)
	mob_class.on_deactivate (self, removal)

	if self._armor_inv_name then
		core.remove_detached_inventory (self._armor_inv_name)
		self._armor_inv_name = nil
		self._armor_inv = nil
	end
end

function horse:update_armor_inv ()
	if not self._armor_inv then
		return
	end
	local stack = ItemStack (self._saddle)
	self._armor_inv:set_stack ("main", SADDLE_SLOT, stack)
	stack = ItemStack (self._horse_armor_stack)
	self._armor_inv:set_stack ("main", ARMOR_SLOT, stack)
end

function horse:generate_inventory_formspec ()
	if not self._armor_inv_name then
		return "formspec_version[6]"
	end
	local objectname = mcl_util.get_object_name (self.object)
	objectname = core.formspec_escape (objectname)
	local armorname = self._armor_inv_name
	armorname = core.formspec_escape ("detached:" .. armorname)
	local chest_itemslots
	if self._chest then
		chest_itemslots = string.format ("list[detached:%s;main;5.375,0.875;5,3;]",
					 self._inv_id)
	else
		chest_itemslots = "image[5.375,0.825;6.10,3.625;mcl_formspec_itemslot.png;2]"
	end
	local nslots
	if can_equip_horse_armor (self.name) then
		nslots = 2
	else
		nslots = 1
	end
	return table.concat ({
		"formspec_version[6]",
		"size[11.75,10.45]",
		"position[0.5,0.5]",
		string.format ("label[0.375,0.5;%s]", objectname),
		mcl_formspec.get_itemslot_bg_v4 (0.375, 0.875, 1, nslots),
		string.format ("list[%s;main;0.375,0.875;1,%d;]", armorname, nslots),
		"image[1.55,0.825;3.625,3.625;mcl_inventory_background9.png;2]",
		string.format ("model[1.55,0.875;3.625,3.5;horse;mobs_mc_horse.b3d;%s;%s]",
			       table.concat (self.base_texture, ","), "0,45,0"),
		self._chest and mcl_formspec.get_itemslot_bg_v4 (5.375, 0.875, 5, 3) or "",
		chest_itemslots,
		-- Main inventory.
		mcl_formspec.get_itemslot_bg_v4 (0.375, 5, 9, 3),
		"list[current_player;main;0.375,5;9,3;9]",
		-- Hotbar.
		mcl_formspec.get_itemslot_bg_v4 (0.375, 8.95, 9, 1),
		"list[current_player;main;0.375,8.95;9,1;]",
		string.format ("listring[%s;main]", armorname),
		self._chest and string.format ("listring[detached:%s;main]",
					self._inv_id) or "",
		"listring[current_player;main]",
	})
end

function horse:post_attach (player)
	if not self._armor_inv then
		-- Create a temporary inventory that holds armor and
		-- saddles and populate it with any such items already
		-- present.
		local name = self.name .. ":" .. horse_inventory_counter
		horse_inventory_counter = horse_inventory_counter + 1
		local inventory = core.create_detached_inventory (name, {
			allow_move = armor_allow_move,
			allow_put = function (inv, listname, index, stack, player)
				return armor_allow_put (self, inv, listname, index, stack, player)
			end,
			on_put = function (inv, listname, index, stack, player)
				return armor_on_put (self, inv, listname, index, stack, player)
			end,
			on_take = function (inv, listname, index, stack, player)
				return armor_on_take (self, inv, listname, index, stack, player)
			end,
		})
		self._armor_inv_name = name
		self._armor_inv = inventory
		if can_equip_horse_armor (self.name) then
			inventory:set_size ("main", 2)
		else
			inventory:set_size ("main", 1)
		end
		self:update_armor_inv ()
	end
	local formspec = self:generate_inventory_formspec ()
	mcl_player.set_inventory_formspec (player, formspec, 100)
	mcl_entity_invs.load_inv (self, self._inv_size or 15)
	self.object:set_properties ({
		selectionbox = {0,0,0,0,0,0},
	})
	self._selectionbox_overloaded = true
end

function horse:attach (player, server_side)
	if mob_class.attach (self, player, server_side) then
		if self.tamed then
			self:post_attach (player)
		end
		return true
	end
	return false
end

function horse:complete_attachment (player, state)
	mob_class.complete_attachment (self, player, state)
	if self.tamed then
		self:post_attach (player)
	end
end

function horse:detach (player, offset)
	mob_class.detach (self, player, offset)
	if not self.tamed then
		return
	end
	mcl_entity_invs.save_inv (self)
	if self._armor_inv_name then
		core.remove_detached_inventory (self._armor_inv_name)
		self._armor_inv_name = nil
		self._armor_inv = nil
	end
end

function horse:set_textures (texturelist)
	mob_class.set_textures (self, texturelist)
	if not self.tamed then
		return
	end
	if self.driver then
		local formspec = self:generate_inventory_formspec ()
		mcl_player.set_inventory_formspec (self.driver, formspec, 100)
	end
end

function horse:drop_armor (bonus)
	local self_pos = self.object:get_pos ()
	if self._saddle ~= "" then
		local stack = ItemStack (self._saddle)
		mcl_util.drop_item_stack (self_pos, stack)
	end
	if self._horse_armor_stack ~= "" then
		local stack = ItemStack (self._horse_armor_stack)
		mcl_util.drop_item_stack (self_pos, stack)
	end
	if self._chest then
		local stack = ItemStack ("mcl_chests:chest")
		mcl_util.drop_item_stack (self_pos, stack)
	end
	self._horse_armor_stack = ""
	self._saddle = ""
	self._chest = false
end

------------------------------------------------------------------------
-- Horse mounting.
------------------------------------------------------------------------

function horse:should_drive ()
	return self._saddle ~= "" and mob_class.should_drive (self)
end

function horse:apply_driver_input (velocity, self_pos, moveresult, dtime)
	mob_class.apply_driver_input (self, velocity, self_pos, moveresult, dtime)

	self._jump = false
	local controls = self.driver:get_player_control ()
	if controls.jump then
		if not self._jump_charge or self._jump_charge == 0 then
			self._jump_charge = 0.0
			-- AbstractHorse.handleStartJump.
			self._allow_stand_sliding = true
			self:stand_if_possible ()
		end
		local charge = self._jump_charge
		self._jump_charge = charge + dtime
	end

	-- AbstractHorse.getRiddenInput: no movement while rearing
	-- on the ground, save when rearing to jump.
	if self._standing and not self._allow_stand_sliding
		and moveresult.touching_ground then
		self.acc_dir.x = 0
		self.acc_dir.z = 0
	end
end

function horse:post_apply_driver_input (velocity, self_pos, moveresult, dtime)
	local controls = self.driver:get_player_control ()
	if not controls.jump
		and self._jump_charge and self._jump_charge > 0.0 then
		if not moveresult.touching_ground
			or moveresult.standing_on_object then
			return
		end

		local mc_ticks = math.floor (self._jump_charge * 20)
		local scale

		if mc_ticks >= 10 then
			scale = 0.8 + 2.0 / (mc_ticks - 9) * 0.1
		else
			scale = mc_ticks * 0.1
		end
		if scale >= 0.9 then
			scale = 1.0
		else
			scale = 0.4 + 0.4 * scale / 0.9
		end
		-- AbstractHorse.onPlayerJump.
		self._allow_stand_sliding = true
		self:stand_if_possible ()

		-- AbstractHorse.executeRidersJump.
		local v = self.object:get_velocity ()
		v.y = scale * self.jump_height
		if self.acc_dir.z > 0 then
			-- 0.4 * amount blocks/tick in the facing direction.
			local yaw = self.object:get_yaw ()
			v.x = v.x - 8.0 * scale * math.sin (yaw)
			v.z = v.z + 8.0 * scale * math.cos (yaw)
		end
		self.object:set_velocity (v)
		self._jump_charge = 0
	end
end

function horse:init_attachment_position ()
	local vsize = self.object:get_properties ().visual_size
	self.driver_attach_at = {x = 0, y = 4.17, z = -1.75}
	self.driver_scale = {x = 1/vsize.x, y = 1/vsize.y}
end

function horse:do_custom (dtime)
	if self.driver then
		local ctrl = self.driver:get_player_control ()
		if ctrl and ctrl.sneak then
			detach_driver (self)
		end
	else
		detach_driver (self)
		self._jump_charge = nil

		if self._armor_inv_name then
			core.remove_detached_inventory (self._armor_inv_name)
			self._armor_inv_name = nil
			self._armor_inv = nil
		end
	end

	return true
end

function horse:on_die ()
	if self.driver then
		detach_driver(self)
	end
end

function horse:allow_mount (clicker)
	return true
end

-- AbstractHorse.handleEating.  Return whether the item was used.
function horse:handle_eating (iname)
	local heal, age, temper, breed = unpack (self._food_items[iname])
	local item_used = false

	-- Golden carrots and apples: tamed horses that are not
	-- babies, not on breeding cooldown (getAge () == 0) and not
	-- already in love, fall in love.
	if breed and self.tamed and not self.child
		and self._mob_age == 0 and not self:is_breeding () then
		item_used = true
		-- Animal.setInLove: 600 ticks.
		self._mob_breeding = 600
	end

	-- Heal mob if necessary.
	local maxhp = self.object:get_properties ().hp_max
	if heal and heal > 0 and self.health < maxhp then
		self:heal_mob (heal, maxhp)
		item_used = true
	end
	-- AgeableMob.ageUp: AGE seconds.
	if self.child and age and age > 0 then
		self._mob_age = self._mob_age + age * 20
		item_used = true
	end
	if temper and temper > 0 and (item_used or not self.tamed)
		and self._temper < self._max_temper then
		self._temper = math.min (self._temper + temper,
					 self._max_temper)
		item_used = true
	end
	if item_used then
		self:mob_sound ("eat", nil, true)
		-- AbstractHorse.handleEating
		if mcl_gameevent then
			mcl_gameevent.emit_entity (self.object, "eat")
		end
	end
	return item_used
end

function horse:on_rightclick (clicker)
	if not clicker or not clicker:is_player() then
		return
	end

	local item = clicker:get_wielded_item()
	local iname = item:get_name()
	local creative = core.is_creative_enabled (clicker:get_player_name())
	local sneak = clicker:get_player_control ().sneak
	local open_inventory = not self.child and self.tamed and sneak

	-- Horse.mobInteract and AbstractChestedHorse.mobInteract.
	if not self.driver and not open_inventory
		and not item:is_empty () then
		if self._food_items[iname] then
			-- AbstractHorse.fedFood.
			if self:handle_eating (iname) and not creative then
				item:take_item ()
				clicker:set_wielded_item (item)
			end
			return
		end

		-- It shouldn't be possible to mount an untamed horse
		-- without an empty hand.
		if not self.tamed then
			self:enrage ()
			return
		end

		if self._inv_id and not self._chest
			and iname == "mcl_chests:chest" and not self.child then
			if not creative then
				item:take_item()
				clicker:set_wielded_item(item)
			end
			self._chest = true
			-- Update texture
			if not self._naked_texture then
				-- Base horse texture without chest or saddle
				self._naked_texture = self.base_texture[2]
			end
			local tex = self:extra_textures ()
			self.base_texture = tex
			self:set_textures (tex)
			return
		end
	end

	if self.driver or self.child then
		return
	end

	-- AbstractHorse.openCustomInventoryScreen.
	if open_inventory then
		if self._inv_id and self._chest then
			mcl_entity_invs.show_inv_form(self,clicker)
		end
		return
	end

	local saddle = self._saddle ~= "" and ItemStack(self._saddle)
	local armor = self._horse_armor_stack ~= "" and ItemStack(self._horse_armor_stack)

	if self.tamed and self.owner == clicker:get_player_name() then
		if self:is_saddle_item (item)
			and self:set_saddle (item, clicker) then
			return
		elseif core.get_item_group(iname, "horse_armor") > 0
			and can_equip_horse_armor(self.name)
			and self:set_armor(clicker) then
			return
		elseif core.get_item_group(iname, "shears") > 0
			and (armor or saddle) then
			local pos = self.object:get_pos()
			if armor then
				self:remove_armor(armor)
				if not creative then core.add_item(pos, armor) end
			elseif saddle then
				self:remove_saddle()
				if not creative then core.add_item(pos, saddle) end
			end
			core.sound_play("mcl_tools_shears_cut", {pos = pos}, true)
			-- Mob.shearItem
			if mcl_gameevent then
				mcl_gameevent.emit_entity (self.object, "shear", clicker)
			end
			if not creative then
				local wear = mcl_autogroup.get_wear(iname, "shearsy")
				item:add_wear(wear)
				clicker:get_inventory():set_stack("main", clicker:get_wield_index(), item)
			end
			return
		end
	end

	if self:allow_mount (clicker) then
		-- AbstractHorse.doPlayerRide.
		self._jump_charge = nil
		self._eating = nil
		self._standing = nil
		attach_driver (self, clicker)
	end
end

function horse:set_saddle (stack, clicker)
	if self._saddle == "" then
		self._saddle = stack:peek_item ():to_string ()
		if clicker then
			local name = clicker:get_player_name ()
			if not core.is_creative_enabled (name) then
				stack:take_item ()
				clicker:set_wielded_item (stack)
			end
			self:update_armor_inv ()
		end
		if not self._naked_texture then
			self._naked_texture = self.base_texture[2]
		end
		local tex = self:extra_textures ()
		self.base_texture = tex
		self:set_textures (tex)
		core.sound_play({name = "mcl_armor_equip_leather"},
			{gain=0.5, max_hear_distance=12, pos=self.object:get_pos()}, true)
		self:equipment_game_event (self._saddle)
		return true
	end
end

function horse:remove_saddle ()
	self._saddle = ""
	if not self._naked_texture then
		self._naked_texture = self.base_texture[2]
	end
	local tex = self:extra_textures ()
	self.base_texture = tex
	self:set_textures (tex)
	core.sound_play ({name = "mcl_armor_unequip_leather"},
		{gain=0.5, max_hear_distance=12, pos=self.object:get_pos()}, true)
	self:equipment_game_event (ItemStack ())
end

------------------------------------------------------------------------
-- Horse breeding and attributes.
------------------------------------------------------------------------

-- AbstractHorse.generateMaxHealth: 15 + nextInt (8) + nextInt (9).
function horse:generate_hp_max (rand, rand1)
	return 15.0 + (rand or pr:next (0, 7)) + (rand1 or pr:next (0, 8))
end

local r = 1 / 2147483647

function horse:generate_jump_height (rand)
	local t1, t2, t3
	t1 = (rand or pr:next (0, 2147483647) * r) * 0.2
	t2 = (rand or pr:next (0, 2147483647) * r) * 0.2
	t3 = (rand or pr:next (0, 2147483647) * r) * 0.2

	return (0.4 + t1 + t2 + t3) * 20
end

function horse:generate_movement_speed (rand)
	local t1, t2, t3
	t1 = (rand or pr:next (0, 2147483647) * r) * 0.3
	t2 = (rand or pr:next (0, 2147483647) * r) * 0.3
	t3 = (rand or pr:next (0, 2147483647) * r) * 0.3

	return (0.45 + t1 + t2 + t3) * 20 * 0.25
end

function horse:initial_movement_properties ()
	local hp_max = self:generate_hp_max ()
	local jump_height = self:generate_jump_height ()
	local speed = self:generate_movement_speed ()

	self.object:set_properties ({
			hp_max = hp_max,
	})
	self.jump_height = jump_height
	self.movement_speed = speed
	self.health = hp_max
	self.hp_max = hp_max
end

function horse:derive_child_properties (p1, p2)
	local hp_max = self:generate_hp_max (7, 8)
	local jump_max = self:generate_jump_height (1.0)
	local speed_max = self:generate_movement_speed (1.0)
	local hp_min = self:generate_hp_max (0, 0)
	local jump_min = self:generate_jump_height (0.0)
	local speed_min = self:generate_movement_speed (0.0)
	local props_p1 = p1.object:get_properties ()
	local props_p2 = p2.object:get_properties ()
	local value = self:child_properties (props_p1.hp_max,
					     props_p2.hp_max,
					     hp_min, hp_max)
	self.object:set_properties ({
		hp_max = value,
	})
	self.hp_max = value
	self.health = value
	value = self:child_properties (p1:stock_value ("jump_height"),
				       p2:stock_value ("jump_height"),
				       jump_min, jump_max)
	self.jump_height = value
	value = self:child_properties (p1:stock_value ("movement_speed"),
				       p2:stock_value ("movement_speed"),
				       speed_min, speed_max)
	self.movement_speed = value
end

-- AbstractHorse.createOffspringAttribute.
function horse:child_properties (p1, p2, min, max)
	p1 = math.min (math.max (p1, min), max)
	p2 = math.min (math.max (p2, min), max)
	local t1 = 0.15 * (max - min)
	local t2 = math.abs (p1 - p2) + t1 * 2
	local t3 = (p1 + p2) / 2
	local t4 = pr:next (0, 2147483647) * r
	local t5 = pr:next (0, 2147483647) * r
	local t6 = pr:next (0, 2147483647) * r
	local t7 = (t4 + t5 + t6) / 3 - 0.5
	local t8 = t3 + t2 * t7
	if t8 > max then
		return max - (t8 - max)
	elseif t8 < min then
		return min + (min - t8)
	end
	return t8
end

function horse:on_grown ()
	self:init_attachment_position ()
	self.can_ride_boat = false
	self.object:set_detach ()
end

function horse:on_breed (parent2)
	local pos = self.object:get_pos()
	local child = mcl_mobs.spawn_child(pos, self.name)
	if child then
		local ent_c = child:get_luaentity()
		-- Horse.getBreedOffspring: the variant is this
		-- parent's 4 times in 9, the partner's 4 times in 9,
		-- and random otherwise; markings likewise 2, 2 and 1
		-- times in 5.
		local b1, m1 = split_horse_texture (self._naked_texture
						    or self.base_texture[2])
		local b2, m2 = split_horse_texture (parent2._naked_texture
						    or parent2.base_texture[2])
		local base, markings
		local select_skin = pr:next (0, 8)
		if select_skin < 4 then
			base = b1
		elseif select_skin < 8 then
			base = b2
		else
			base = pr:next (1, #horse_base)
		end
		local select_marking = pr:next (0, 4)
		if select_marking < 2 then
			markings = m1
		elseif select_marking < 4 then
			markings = m2
		else
			markings = pr:next (1, #horse_markings)
		end
		local child_texture = horse_texture (base, markings)
		ent_c.base_texture = { "blank.png", child_texture, "blank.png" }
		ent_c._naked_texture = child_texture
		ent_c:set_textures (ent_c.base_texture)
		ent_c:derive_child_properties (self, parent2)
		ent_c.can_ride_boat = true
	end
end

mcl_mobs.register_mob ("mobs_mc:horse", horse)
mobs_mc.horse = horse

------------------------------------------------------------------------
-- Skeleton & Zombie Horse
------------------------------------------------------------------------

local skeleton_horse = table.merge(horse, {
	description = S("Skeleton Horse"),
	armor = {undead = 100, fleshy = 100},
	textures = {{"blank.png", "mobs_mc_horse_skeleton.png", "blank.png"}},
	drops = {
		{
			name = "mcl_mobitems:bone",
			chance = 1,
			min = 0,
			max = 2,
			looting = "common",
		},
	},
	sounds = {
		random = "mobs_mc_skeleton_random",
		death = "mobs_mc_skeleton_death",
		damage = "mobs_mc_skeleton_hurt",
		eat = "mobs_mc_animal_eat_generic",
		base_pitch = 0.95,
		distance = 16,
	},
	-- SkeletonHorse.createAttributes.
	hp_min = 15,
	hp_max = 15,
	movement_speed = 4.0,
	harmed_by_heal = true,
	-- AbstractHorse.finalizeSpawn: AgeableMobGroupData (0.2F).
	_group_baby_chance = 0.2,
	_trap_age = 0,
	_is_trap = false,
	floats = 0,
})

function skeleton_horse:step_drowning (_)
	return
end

function skeleton_horse:_on_lightning_strike ()
	-- Only the bolt of this horse's own skeleton trap is
	-- harmless to it.
	return self._trap_bolt == true
end

-- SkeletonHorse.canAgeUp, ZombieHorse.canAgeUp: babies never grow up.
function skeleton_horse:tick_breeding (dtime)
	if self.child then
		return
	end
	mob_class.tick_breeding (self, dtime)
end

function skeleton_horse:do_custom (dtime, moveresult)
	horse.do_custom (self, dtime, moveresult)
	if not self._is_trap then
		return
	end
	self._trap_age = self._trap_age + dtime
	if self._trap_age > 900 then
		self:safe_remove ()
		return false
	end
end

local function get_helmet (skeleton)
	if skeleton.armor_list.head ~= "" then
		local stack = ItemStack (skeleton.armor_list.head)
		stack:get_meta ():set_string ("mcl_enchanting:enchantments", "")
		return stack
	end
	return ItemStack ("mcl_armor:helmet_iron")
end

local function check_skeleton_trap (self, self_pos, dtime)
	if not self._is_trap then
		return false
	end
	if not self:check_timer ("skeleton_trap", 0.15) then
		return false
	end
	for player in mcl_util.connected_players (self_pos, 10) do
		self._is_trap = false
		-- SkeletonTrapGoal: the bolt is visual only.  TODO:
		-- mcl_lightning cannot yet strike without damaging
		-- other objects or starting fires.
		self._trap_bolt = true
		mcl_lightning.strike (self_pos, true)
		self._trap_bolt = nil
		self.tamed = true

		-- Spawn three horses.
		local horses = { self.object, }
		for _ = 1, 3 do
			local horse = core.add_entity (self_pos, self.name)
			if horse then
				table.insert (horses, horse)
				local entity = horse:get_luaentity ()
				entity.tamed = true
				entity.persistent = true
			end
		end

		local mob_factor = mcl_worlds.get_special_difficulty (self_pos)
		-- Spawn skeletons for each horse.
		for _, horse in pairs (horses) do
			local skelly = core.add_entity (self_pos, "mobs_mc:skeleton")
			if skelly then
				local entity = skelly:get_luaentity ()
				entity:jock_to_existing (horse, "", {
					x = 0,
					y = 1.6,
					z = 0,
				}, vector.zero ())
				-- Equip it with an enchanted iron
				-- helmet and bow (or whatever it
				-- generated with) between levels 5.0
				-- and 23.
				local helmet = get_helmet (entity)
				local level = 5.0 + math.random (18) * mob_factor
				mcl_enchanting.enchant_randomly (helmet, level, false, false, true)
				entity.persistent = true
				entity.armor_list.head = helmet:to_string ()
				entity:set_armor_texture ()

				local bow = ItemStack ("mcl_bows:bow")
				local level = 5.0 + math.random (18) * mob_factor
				mcl_enchanting.enchant_randomly (bow, level, false, false, true)
				entity:set_wielditem (bow)
			end
		end
		return false
	end
end

function skeleton_horse:initial_movement_properties ()
	local jump_height = self:generate_jump_height ()
	self.jump_height = jump_height
end

skeleton_horse.follow = {}
skeleton_horse._food_items = {}

function skeleton_horse:on_rightclick (clicker)
	if self.tamed then
		return horse.on_rightclick (self, clicker)
	end
end

-- SkeletonHorse.addBehaviourGoals is empty: no panicking, tempting
-- or floating.
skeleton_horse.ai_functions = {
	check_skeleton_trap,
	horse_maybe_tame,
	mob_class.follow_herd,
	mob_class.check_pace,
}

mcl_mobs.register_mob("mobs_mc:skeleton_horse", skeleton_horse)

local zombie_horse = table.merge(skeleton_horse, {
	description = S("Zombie Horse"),
	textures = {{"blank.png", "mobs_mc_horse_zombie.png", "blank.png"}},
	-- ZombieHorse.createAttributes.
	hp_min = 25,
	hp_max = 25,
	drops = {
		{
			name = "mcl_mobitems:rotten_flesh",
			chance = 1,
			min = 2,
			max = 3,
			looting = "common",
		},
	},
	sounds = {
		random = "mobs_mc_horse_random",
		damage = "mobs_mc_horse_hurt",
		death = "mobs_mc_horse_death",
		eat = "mobs_mc_animal_eat_generic",
		base_pitch = 0.5,
		distance = 16,
	},
	-- EntityTypes.ZOMBIE_HORSE is MobCategory.MONSTER and
	-- ZombieHorse.removeWhenFarAway.
	_spawn_category = "monster",
	-- ZombieHorse.addBehaviourGoals: FloatGoal.
	floats = 1,
	-- ItemTags.ZOMBIE_HORSE_FOOD.
	follow = {
		"mcl_mushrooms:mushroom_red",
	},
	_food_items = {
		["mcl_mushrooms:mushroom_red"] = {
			3.0, -- Health.
			0, -- Age delta in seconds.
			3, -- Temper.
		},
	},
})

local function rand_double ()
	return pr:next (0, 2147483647) * r
end

-- ZombieHorse.randomizeAttributes.
function zombie_horse:initial_movement_properties ()
	self.jump_height = (0.5 + rand_double () * 0.06666666666666667
			    + rand_double () * 0.06666666666666667
			    + rand_double () * 0.06666666666666667) * 20
	self.movement_speed = (9.0 + rand_double () + rand_double ()
			       + rand_double ()) / 42.16 * 20
end

function zombie_horse:on_rightclick (clicker)
	-- ZombieHorse.interact: setPersistenceRequired.
	self.persistent = true
	return horse.on_rightclick (self, clicker)
end

-- Mob.burnUndead (entity type tag `burn_in_daylight').  The sun
-- protection slot of zombie horses is the body, where horse armor is
-- worn.
local function zombie_horse_sun_burn (self, dtime)
	if math.random (mcl_mobs.scale_chance (25, dtime)) ~= 1 then
		return
	end
	local pos = self.object:get_pos ()
	local _, dim = mcl_worlds.y_to_layer (pos.y)
	if dim ~= "overworld" then
		return
	end
	local node_pos = vector.round (vector.offset (pos, 0, self:get_eye_height (), 0))
	local tod = mcl_util.get_current_time_of_day ()
	local sunlight, direct_sunlight, has_rain
		= self:get_weather_with_light (node_pos, tod)
	-- LevelReader.getLightLevelDependentMagicValue.
	local v = sunlight / 15
	local br = v / (4.0 - 3.0 * v)
	if direct_sunlight >= 15 and br > 0.5
		and math.random () < (br - 0.4) * 2.0 * 25 / 30
		and not has_rain and self._liquidtype ~= "water"
		and self._horse_armor_stack == "" then
		self:fast_ignite (8.0)
	end
end

function zombie_horse:ai_step (dtime)
	horse.ai_step (self, dtime)
	if not self.dead then
		zombie_horse_sun_burn (self, dtime)
	end
end

-- ZombieHorse.addBehaviourGoals: TemptGoal (1.25) but no panicking.
zombie_horse.ai_functions = {
	horse_maybe_tame,
	mob_class.check_following,
	mob_class.follow_herd,
	mob_class.check_pace,
}

mcl_mobs.register_mob("mobs_mc:zombie_horse", zombie_horse)

------------------------------------------------------------------------
-- Donkeys.
------------------------------------------------------------------------

local d = 0.86
local donkey = table.merge (horse, {
	description = S("Donkey"),
	textures = {{"blank.png", "mobs_mc_donkey.png", "blank.png"}},
	movement_speed = 3.5,
	head_eye_height = 1.425,
	animation = {
		stand_start = 0, stand_end = 0,
		walk_start = 0, walk_end = 40,
		run_speed = 50
	},
	sounds = {
		random = "mobs_mc_donkey_random",
		damage = "mobs_mc_donkey_hurt",
		death = "mobs_mc_donkey_death",
		eat = "mobs_mc_animal_eat_generic",
		distance = 16,
	},
	visual_size = { x=horse.visual_size.x*d, y=horse.visual_size.y*d },
	-- EntityTypes.DONKEY: sized (1.3964844F, 1.5F).
	collisionbox = {-0.69825, 0, -0.69825, 0.69825, 1.5, 0.69825},
	-- AbstractChestedHorse.babyDimensions: scale (0.5F).
	child_scale = 0.5,
	-- AbstractHorse.finalizeSpawn: AgeableMobGroupData (0.2F).
	_group_baby_chance = 0.2,
	-- MC Wiki is completely wrong: the Minecraft value is 0.5
	-- (not 0.4), not 0.175, and which multiplied by 20 yields
	-- 10.0.
	jump_height = 10.0,
})

function donkey:initial_movement_properties ()
	local hp_max = self:generate_hp_max ()

	self.object:set_properties ({
		hp_max = hp_max,
	})
	self.hp_max = hp_max
	self.health = hp_max
end

function donkey:same_species_p (ent)
	return ent.name == self.name
		or ent.name == "mobs_mc:horse"
end

function donkey:on_breed (parent2)
	-- `donkey:on_breed' is guaranteed to be invoked during
	-- matings between horses and donkeys, as only
	-- `donkey:same_species_p' is defined to accept both species.
	-- See `mcl_mobs.check_breeding'.
	local name = parent2.name == "mobs_mc:horse"
		and "mobs_mc:mule" or self.name
	local pos = self.object:get_pos ()
	local child = mcl_mobs.spawn_child (pos, name)
	if child then
		local ent_c = child:get_luaentity ()
		ent_c:derive_child_properties (self, parent2)
	end
end

mcl_mobs.register_mob ("mobs_mc:donkey", donkey)
mcl_entity_invs.register_inv ("mobs_mc:donkey", S ("Donkey"), 15, true)

------------------------------------------------------------------------
-- Mules.
------------------------------------------------------------------------

local m = 0.94
local mule = table.merge(donkey, {
	description = S("Mule"),
	textures = {{"blank.png", "mobs_mc_mule.png", "blank.png"}},
	visual_size = { x=horse.visual_size.x*m, y=horse.visual_size.y*m },
	sounds = table.merge(donkey.sounds, {
		base_pitch = 1.15,
	}),
	head_eye_height = 1.52,
	-- EntityTypes.MULE: sized (1.3964844F, 1.6F).
	collisionbox = table.copy (horse.collisionbox),
})
mule.ai_functions = {
	mob_class.check_frightened,
	horse_maybe_tame,
	mob_class.check_following,
	mob_class.follow_herd,
	mob_class.check_pace,
}

mcl_mobs.register_mob ("mobs_mc:mule", mule)
mcl_entity_invs.register_inv ("mobs_mc:mule", S ("Mule"), 15, true)

------------------------------------------------------------------------
-- Horse Spawning.
------------------------------------------------------------------------

mcl_mobs.register_egg("mobs_mc:horse", S("Horse"), "#c09e7d", "#eee500", 0)
mcl_mobs.register_egg("mobs_mc:skeleton_horse", S("Skeleton Horse"), "#68684f", "#e5e5d8", 0)
mcl_mobs.register_egg("mobs_mc:zombie_horse", S("Zombie Horse"), "#2a5a37", "#84d080", 0)
mcl_mobs.register_egg("mobs_mc:donkey", S("Donkey"), "#534539", "#867566", 0)
mcl_mobs.register_egg("mobs_mc:mule", S("Mule"), "#1b0200", "#51331d", 0)

------------------------------------------------------------------------
-- Modern Horse & Donkey Spawning.
------------------------------------------------------------------------

local horse_spawner = table.merge (mobs_mc.animal_spawner, {
	name = "mobs_mc:horse",
	weight = 5,
	pack_min = 2,
	pack_max = 6,
	-- AbstractHorse.getMaxSpawnClusterSize.
	max_cluster = 6,
	biomes = {
		"Plains",
		"SunflowerPlains",
	},
})

-- Horse.finalizeSpawn: HorseGroupData shares one variant among the
-- whole group.
function horse_spawner:prepare_to_spawn (pack_size, center)
	return {
		_spawn_variant = pr:next (1, #horse_base),
	}
end

local horse_spawner_savannah = table.merge (horse_spawner, {
	weight = 1,
	biomes = {
		"#is_savannah",
	},
})

local donkey_spawner = table.merge (mobs_mc.animal_spawner, {
	name = "mobs_mc:donkey",
	weight = 1,
	pack_min = 1,
	pack_max = 3,
	-- AbstractHorse.getMaxSpawnClusterSize.
	max_cluster = 6,
	biomes = {
		"#is_savannah",
	},
})

local donkey_spawner_meadow = table.merge (donkey_spawner, {
	pack_max = 1,
	biomes = {
		"Meadow",
	},
})

-- BiomeDefaultFeatures.plainsSpawns: commonSpawnWithZombieHorse
-- adds zombie horses (weight 5, 1-1) to the monsters of plains.
local zombie_horse_spawner = table.merge (mobs_mc.monster_spawner, {
	name = "mobs_mc:zombie_horse",
	weight = 5,
	pack_min = 1,
	pack_max = 1,
	-- AbstractHorse.getMaxSpawnClusterSize.
	max_cluster = 6,
	biomes = {
		"Plains",
		"SunflowerPlains",
	},
})

function zombie_horse_spawner:spawn (spawn_pos, idx, sdata, pack_size)
	local object = core.add_entity (spawn_pos, self.name)
	if object then
		-- ZombieHorse.finalizeSpawn: naturally spawned zombie
		-- horses are ridden by a zombie.  Minecraft arms it
		-- with an iron spear, which Mineclonia lacks.
		local zombie = core.add_entity (spawn_pos, "mobs_mc:zombie")
		if zombie then
			local entity = zombie:get_luaentity ()
			entity:jock_to_existing (object, "", vector.new (0, 1.6, 0),
						 vector.zero ())
		end
	end
	return object
end

function zombie_horse_spawner:describe_criteria (tbl, omit_group_details)
	mobs_mc.monster_spawner.describe_criteria (self, tbl, omit_group_details)
	table.insert (tbl, S ("Zombie Horses spawn ridden by Zombies."))
end

mcl_mobs.register_spawner (horse_spawner)
mcl_mobs.register_spawner (horse_spawner_savannah)
mcl_mobs.register_spawner (donkey_spawner)
mcl_mobs.register_spawner (donkey_spawner_meadow)
mcl_mobs.register_spawner (zombie_horse_spawner)
