--MCmobs v0.4
--maikerumine
--made for MC like Survival game
--License for code WTFPL and otherwise stated in readmes

local S = core.get_translator("mobs_mc")
local mob_class = mcl_mobs.mob_class

--###################
--################### PARROT
--###################

local parrot = {
	description = S("Parrot"),
	-- Parrot.isFlapping / onFlap (game event flap)
	_is_flapping = mcl_mobs.flap_by_distance,
	type = "animal",
	_spawn_category = "creature",
	hp_min = 6,
	hp_max = 6,
	xp_min = 1,
	xp_max = 3,
	head_swivel = "head.control",
	bone_eye_height = 1.1,
	horizontal_head_height=0,
	head_eye_height = 0.54,
	curiosity = 10,
	collisionbox = {-0.25, 0, -0.25, 0.25, 0.9, 0.25},
	visual = "mesh",
	mesh = "mobs_mc_parrot.b3d",
	textures = {
		{"mobs_mc_parrot_blue.png"},
		{"mobs_mc_parrot_green.png"},
		{"mobs_mc_parrot_grey.png"},
		{"mobs_mc_parrot_red_blue.png"},
		{"mobs_mc_parrot_yellow_blue.png"},
	},
	visual_size = {x=3, y=3},
	sounds = {
		random = "mobs_mc_parrot_random",
		damage = {name="mobs_mc_parrot_hurt", gain=0.3},
		death = {name="mobs_mc_parrot_death", gain=0.6},
		eat = "mobs_mc_animal_eat_generic",
		distance = 16,
	},
	drops = {
		{
			name = "mcl_mobitems:feather",
			chance = 1,
			min = 1,
			max = 2,
			looting = "common",
		},
	},
	animation = {
		stand_start = 0, stand_end = 0, stand_speed = 50,
		fly_start = 130, fly_end = 150, fly_speed = 50,
		walk_start = 20, walk_end = 40, walk_speed = 50,
		sit_start = 160, sit_end = 160,
		dance_start = 161, dance_end = 201, dance_speed = 80,
	},
	_no_fall_damage = true,
	gravity_drag = 0.6,
	floats = 1,
	physical = true,
	movement_speed = 4.0,
	airborne = true,
	makes_footstep_sound = false,
	chase_owner_distance = 5.0,
	stop_chasing_distance = 1.0,
	pace_height = 7,
	pace_width = 8,
	_is_party_parrot = false,
}

------------------------------------------------------------------------
-- Parrot interaction.
------------------------------------------------------------------------

local parrot_foods = {
	"mcl_farming:wheat_seeds",
	"mcl_farming:melon_seeds",
	"mcl_farming:pumpkin_seeds",
	"mcl_farming:beetroot_seeds",
}

function parrot:actionable_on_rightclick (clicker)
	local item = clicker:get_wielded_item ()
	local wield_food = table.indexof(parrot_foods, item:get_name ()) ~= -1
	return item:get_name () == "mcl_farming:cookie" or self.tamed or wield_food
end

function parrot:on_rightclick (clicker)
	local item = clicker:get_wielded_item ()
	if not item then
		return
	end
	local name = item:get_name()
	-- Kill parrot if fed with cookie
	if item and name == "mcl_farming:cookie" then
		core.sound_play ("mobs_mc_animal_eat_generic", {
			object = self.object,
			max_hear_distance = 16,
		}, true)

		local mcl_reason = {
			type = "player",
			source = clicker,
		}
		mcl_damage.finish_reason (mcl_reason)
		self:receive_damage (mcl_reason, 65535.0)
		-- Parrot.java: POISON for 900 ticks, amplifier 0.
		mcl_potions.give_effect_by_level ("poison", self.object, 1, 45)
		if not core.is_creative_enabled (clicker:get_player_name()) then
			item:take_item ()
			clicker:set_wielded_item (item)
		end
		return
	end

	-- Feed to tame, but not breed
	if not self.tamed and table.indexof (parrot_foods, name) ~= -1 then
		self:feed_tame (clicker, nil, false, true, false, 0.1)
		return
	end

	if self.tamed then
		-- Otherwise, toggle sitting.
		if self.order == "sit" then
			self.order = ""
		else
			self:stay ()
		end
	end
end

------------------------------------------------------------------------
-- Parrot AI.
------------------------------------------------------------------------

local shoulders = {
	left = vector.new(-3.75,10.5,0),
	right = vector.new(3.75,10.5,0),
}

-- Parrot.MOB_SOUND_MAP: the mobs whose sounds parrots imitate.
-- Minecraft has dedicated (pitched up) imitation sounds; their
-- ambient sounds are played at an elevated pitch in their place.
local imitated_mobs = {
	"mobs_mc:blaze",
	"mobs_mc:cave_spider",
	"mobs_mc:creeper",
	"mobs_mc:creeper_charged",
	"mobs_mc:drowned",
	"mobs_mc:baby_drowned",
	"mobs_mc:guardian_elder",
	"mobs_mc:enderdragon",
	"mobs_mc:endermite",
	"mobs_mc:evoker",
	"mobs_mc:ghast",
	"mobs_mc:guardian",
	"mobs_mc:hoglin",
	"mobs_mc:baby_hoglin",
	"mobs_mc:husk",
	"mobs_mc:baby_husk",
	"mobs_mc:illusioner",
	"mobs_mc:magma_cube_big",
	"mobs_mc:magma_cube_small",
	"mobs_mc:magma_cube_tiny",
	"mobs_mc:piglin",
	"mobs_mc:piglin_brute",
	"mobs_mc:pillager",
	"mobs_mc:ravager",
	"mobs_mc:shulker",
	"mobs_mc:silverfish",
	"mobs_mc:skeleton",
	"mobs_mc:slime_big",
	"mobs_mc:slime_small",
	"mobs_mc:slime_tiny",
	"mobs_mc:spider",
	"mobs_mc:stray",
	"mobs_mc:vex",
	"mobs_mc:vindicator",
	"mobs_mc:witch",
	"mobs_mc:wither",
	"mobs_mc:witherskeleton",
	"mobs_mc:zoglin",
	"mobs_mc:baby_zoglin",
	"mobs_mc:zombie",
	"mobs_mc:baby_zombie",
	"mobs_mc:zombie_horse",
	"mobs_mc:villager_zombie",
}
local is_imitated_mob = {}
for _, name in ipairs (imitated_mobs) do
	is_imitated_mob[name] = true
end

local IMITATION_PITCH = 2.5

local function get_imitated_sound (name)
	local def = core.registered_entities[name]
	local snd = def and def.sounds and def.sounds.random
	if type (snd) == "table" then
		snd = snd.name
	end
	return snd
end

-- Parrot.getPitch.
local function random_pitch ()
	return (math.random () - math.random ()) * 0.2 + 1.0
end

local function play_imitation (self, snd, gain)
	return core.sound_play (snd, {
		pos = self.object:get_pos (),
		gain = gain,
		pitch = IMITATION_PITCH * random_pitch (),
		max_hear_distance = self.sounds and self.sounds.distance or 32
	}, true)
end

-- Parrot.aiStep: a 1 in 400 chance every tick of calling
-- imitateNearbyMobs, which in turn succeeds half of the time and
-- imitates a random imitable mob within 20 blocks.
local function check_mobimitate (self, dtime)
	if math.random () >= dtime * 20 / 400
		or math.random (2) ~= 1 then
		return
	end
	local candidates = {}
	for o in core.objects_inside_radius (self.object:get_pos (), 20) do
		local l = o:get_luaentity ()
		if l and is_imitated_mob[l.name] then
			table.insert (candidates, l.name)
		end
	end
	if #candidates > 0 then
		local snd = get_imitated_sound (candidates[math.random (#candidates)])
		if snd then
			play_imitation (self, snd, 0.7)
		end
	end
end

-- Parrot.getAmbient: outside peaceful, one ambient sound in 1000 is
-- the imitation of a random imitable mob.
function parrot:mob_sound (soundname, is_opinion, fixed_pitch)
	if soundname == "random" and mcl_vars.difficulty ~= 0
		and math.random (1000) == 1 then
		if is_opinion and not self:check_timer ("opinion_sound_cooloff",
							 self.opinion_sound_cooloff) then
			return
		end
		local snd = get_imitated_sound (imitated_mobs[math.random (#imitated_mobs)])
		if snd then
			play_imitation (self, snd, 1.0)
		end
		return
	end
	return mob_class.mob_sound (self, soundname, is_opinion, fixed_pitch)
end

--find a free shoulder or return nil
local function get_shoulder(player)
	local sh = "left"
	for _,o in pairs(player:get_children()) do
		local l = o:get_luaentity()
		if l and l.name == "mobs_mc:parrot" then
			local _,_,a = l.object:get_attach()
			for _,s in pairs(shoulders) do
				if a and vector.equals(a,s) then
					if sh == "left" then
						sh = "right"
					else
						return
					end

				end
			end
		end
	end
	return shoulders[sh]
end

local function perch(self,player)
	if self.tamed and player:get_player_name() == self.owner and not self.object:get_attach() then
		local shoulder = get_shoulder(player)
		if not shoulder then return true end
		self.object:set_attach(player,"",shoulder,vector.new(0,0,0),true)
		self:set_animation ("stand")
		mcl_attachments.spawn_attachment_entity (self.object)
	end
end

function parrot:check_perch (self_pos, dtime)
	local attach = self.object:get_attach ()
	-- ShoulderRidingEntity.java: RIDE_COOLDOWN = 100 ticks.
	if self.perch_cooldown then
		self.perch_cooldown
			= math.max (0, self.perch_cooldown - dtime)
	else
		self.perch_cooldown = 5.0
	end
	if attach then
		if not self.perching then
			-- Perching was interrupted, and therefore
			-- this object must be detached.
			self.object:set_detach ()
			mcl_attachments.remove_attachment_entity (self.object)
			return false
		end
		local n1 = core.get_node (vector.offset (self_pos, 0, -0.6, 0)).name
		local n2 = core.get_node (vector.offset (self_pos, 0, 0, 0)).name
		if n1 == "air" or core.get_item_group (n2,"water") > 0
			or core.get_item_group (n2,"lava") > 0 then
			self.object:set_detach()
			mcl_attachments.remove_attachment_entity (self.object)
			self.perching = false
			self.perch_cooldown = 5.0
			return false
		end
		return true
	elseif self.owner and self.perch_cooldown == 0
		and self.order ~= "sit" then
		local owner = core.get_player_by_name (self.owner)
		if not owner then
			return false
		end
		-- LandOnOwnersShoulderGoal: not while the owner is in
		-- water or powder snow.
		local owner_node = core.get_node (owner:get_pos ()).name
		if core.get_item_group (owner_node, "water") > 0
			or owner_node == "mcl_powder_snow:powder_snow" then
			return false
		end
		if vector.distance (self_pos, owner:get_pos ()) < 0.5 then
			perch (self, owner)
			self.perching = true
			return "perching"
		end
	end
	return false
end

-- Parrot.ParrotWanderGoal.getTreePos: the first position (in
-- BlockPos.betweenClosed order) within 3 blocks horizontally and 6
-- vertically above leaves or logs with room for a parrot.
local function get_tree_pos (pos)
	local self_node = mcl_util.get_nodepos (pos)
	local x0, y0, z0 = math.floor (pos.x - 3.0 + 0.5),
		math.floor (pos.y - 6.0 + 0.5),
		math.floor (pos.z - 3.0 + 0.5)
	local x1, y1, z1 = math.floor (pos.x + 3.0 + 0.5),
		math.floor (pos.y + 6.0 + 0.5),
		math.floor (pos.z + 3.0 + 0.5)
	local vm = core.get_voxel_manip (vector.new (x0, y0 - 1, z0),
					 vector.new (x1, y1 + 1, z1))
	local p = vector.zero ()
	for z = z0, z1 do
		for y = y0, y1 do
			for x = x0, x1 do
				p.x, p.y, p.z = x, y, z
				if not vector.equals (p, self_node) then
					local below = vm:get_node_at (vector.new (x, y - 1, z)).name
					if (core.get_item_group (below, "leaves") > 0
					    or core.get_item_group (below, "tree") > 0)
						and vm:get_node_at (p).name == "air"
						and vm:get_node_at (vector.new (x, y + 1, z)).name == "air" then
						return vector.new (x, y, z)
					end
				end
			end
		end
	end
	return nil
end

function parrot:airborne_pacing_target (pos, width, height, groups)
	-- WaterAvoidingRandomStrollGoal.PROBABILITY = 0.001.
	if math.random () >= 0.001 then
		local target = get_tree_pos (pos)
		if target then
			return target
		end
	end
	return mob_class.airborne_pacing_target (self, pos, width, height, groups)
end

function parrot:ai_step (dtime)
	mob_class.ai_step (self, dtime)
	check_mobimitate (self, dtime)
	-- Lest sit_if_ordered should interrupt perching.
	if self.object:get_attach () and not self.perching then
		self.object:set_detach ()
		mcl_attachments.remove_attachment_entity (self.object)
	end
end

function parrot:set_animation (anim, custom_frame)
	if self._is_party_parrot then
		mob_class.set_animation (self, "dance")
	else
		mob_class.set_animation (self, anim, custom_frame)
	end
end

function parrot:set_party_parrot (is_party_parrot, moveresult)
	local touching_ground = moveresult.touching_ground
		or moveresult.standing_on_object

	self._is_party_parrot = is_party_parrot

	if is_party_parrot then
		self:set_animation ("dance")
	elseif self._active_activity == "sit_if_ordered" then
		self:set_animation ("sit")
	elseif self.movement_goal and touching_ground then
		self:set_animation ("walk")
	elseif self.movement_goal then
		self:set_animation ("fly")
	else
		self:set_animation ("stand")
	end
end

local function parrot_check_dance (self, self_pos, dtime, moveresult)
	local is_party_parrot = false
	-- Search for playing jukeboxes nearby.
	for hash, track in pairs (mcl_jukebox.active_tracks) do
		if track then
			local node = core.get_position_from_hash (hash)
			-- Parrot.aiStep: closerToCenterThan (..., 3.46).
			if vector.distance (self_pos, node) < 3.46 then
				is_party_parrot = true
			end
		end
	end

	if is_party_parrot and not self._is_party_parrot then
		self:set_party_parrot (true, moveresult)
	elseif not is_party_parrot and self._is_party_parrot then
		self:set_party_parrot (false, moveresult)
	end
end

function parrot:get_staticdata_table ()
	local supertable = mob_class.get_staticdata_table (self)
	if supertable then
		supertable._is_party_parrot = nil
		supertable._following_mob_started = nil
	end
	return supertable
end

-- FollowMobGoal (this, 1.0, 3.0F, 7.0F): follow the first mob
-- other than a parrot within 7 blocks till within 3 blocks of it,
-- retreating if closer than sqrt (3).
local function parrot_follow_mob (self, self_pos, dtime)
	local target = self._following_mob
	if target then
		local target_pos = target:is_valid () and target:get_pos ()
		if not target_pos
			or (self:navigation_finished ()
			    and not self._following_mob_started)
			or vector.distance (self_pos, target_pos) <= 3.0 then
			self._following_mob = nil
			self._following_mob_started = nil
			self:cancel_navigation ()
			return false
		end
		if self:check_timer ("parrot_follow_mob_repath", 0.5) then
			self._following_mob_started = nil
			self:gopath (target_pos, 1.0)
		end
		return true
	elseif self:check_timer ("parrot_follow_mob", 0.1) then
		local cbox = self.collisionbox
		local aa = vector.offset (self_pos, cbox[1] - 7.0, cbox[2] - 7.0, cbox[3] - 7.0)
		local bb = vector.offset (self_pos, cbox[4] + 7.0, cbox[5] + 7.0, cbox[6] + 7.0)
		for object in core.objects_in_area (aa, bb) do
			local entity = object:get_luaentity ()
			if entity and entity.is_mob and not entity.dead
				and entity.name ~= self.name then
				local target_pos = object:get_pos ()
				local d = vector.distance (self_pos, target_pos)
				if d * d <= 3.0 then
					-- Retreat directly away from the mob.
					local away = vector.subtract (self_pos, target_pos)
					self:gopath (vector.add (self_pos, away), 1.0)
					return false
				end
				self._following_mob = object
				self._following_mob_started = true
				self:gopath (target_pos, 1.0)
				return "_following_mob"
			end
		end
	end
	return false
end

-- Parrot.registerGoals: TamableAnimalPanicGoal has priority 0.
parrot.ai_functions = {
	parrot_check_dance,
	mob_class.check_frightened,
	mob_class.sit_if_ordered,
	mob_class.check_travel_to_owner,
	parrot.check_perch,
	mob_class.check_pace,
	parrot_follow_mob,
}

parrot._is_idle_activity = table.merge (mob_class._is_idle_activity, {
	_following_mob = true,
})

-- Parrot.java: hurtServer cancels any order to sit.
function parrot:receive_damage (mcl_reason, damage)
	if self.dead or self.removed then
		return false
	end
	if damage > 0 then
		self.order = ""
	end
	return mob_class.receive_damage (self, mcl_reason, damage)
end

parrot.gwp_penalties = table.copy (mob_class.gwp_penalties)
parrot.gwp_penalties.DANGER_FIRE = -1.0
parrot.gwp_penalties.DAMAGE_FIRE = -1.0

mcl_mobs.register_mob ("mobs_mc:parrot", parrot)

------------------------------------------------------------------------
-- Parrot spawning.
------------------------------------------------------------------------

-- spawn eggs
mcl_mobs.register_egg("mobs_mc:parrot", S("Parrot"), "#0da70a", "#ff0000", 0)

------------------------------------------------------------------------
-- Modern Parrot spawning.
-----------------------------------------------------------------------

local parrot_spawner = table.merge (mobs_mc.animal_spawner, {
	name = "mobs_mc:parrot",
	weight = 40,
	pack_min = 1,
	pack_max = 2,
	biomes = {
		"#is_jungle",
	},
})

function parrot_spawner:describe_supporting_nodes ()
	return S ("on grass, leaves, or logs")
end

function parrot_spawner:test_supporting_node (node)
	return  core.get_item_group (node.name, "grass_block") > 0
		or core.get_item_group (node.name, "leaves") > 0
		or core.get_item_group (node.name, "tree") > 0
end

mcl_mobs.register_spawner (parrot_spawner)
