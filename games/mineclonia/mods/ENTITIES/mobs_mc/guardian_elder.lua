-- v1.4

--###################
--################### GUARDIAN
--###################

local S = core.get_translator("mobs_mc")
local mob_class = mcl_mobs.mob_class

local guardian_elder = table.merge (mobs_mc.guardian, {
	description = S("Elder Guardian"),
	type = "monster",
	_spawn_category = "monster",
	hp_min = 80,
	hp_max = 80,
	xp_min = 10,
	xp_max = 10,
	can_ride_boat = false,
	damage = 8,
	movement_speed = 6.0,
	-- ElderGuardian.java: getAttackDuration () = 60 ticks after
	-- the initial 10 tick delay; +2 magic damage; attacks
	-- continue within 3 blocks.
	_default_laser_delay = 3.5,
	_laser_magic_bonus = 2,
	_laser_ignores_proximity = true,
	-- RandomStrollGoal interval 400; setPersistenceRequired.
	pace_chance = 400,
	can_despawn = false,
	head_eye_height = 0.99875,
	collisionbox = {-0.99875, 0, -0.99875, 0.99875, 1.9975, 0.99875},
	doll_size_override = { x = 0.72, y = 0.72 },
	visual = "mesh",
	mesh = "mobs_mc_guardian.b3d",
	textures = {
		{"mobs_mc_guardian_elder.png"},
	},
	visual_size = {x=7, y=7},
	-- entities/elder_guardian.json.  The second pool (cod 3,
	-- prismarine crystals 2, nothing 1) is rolled by
	-- `drop_custom'.
	drops = mobs_mc.guardian_drops ({
		{name = "mcl_sponges:sponge_wet",
		chance = 1,
		min = 1,
		max = 1,
		player_kill_only = true,},

		--armor trim
		{name = "mcl_armor:tide",
		chance = 5, -- 20%
		min = 1,
		max = 1},
	}),
	_guardian_loot_weights = {
		cod = 3,
		crystals = 2,
		empty = 1,
	},
})

------------------------------------------------------------------------
-- Elder Guardian AI.
------------------------------------------------------------------------

function guardian_elder:on_spawn ()
	-- Restrict to a 16 node radius around spawn point.
	self:restrict_to (self.object:get_pos (), 16)
end

function guardian_elder:ai_step (dtime)
	mob_class.ai_step (self, dtime)
	local self_pos
	-- See:
	-- https://minecraft.wiki/w/Elder_Guardian#Inflicting_Mining_Fatigue
	-- The phase of the 1200 tick interval is (tickCount + id).
	self._fatigue_counter = (self._fatigue_counter or math.random () * 60) + dtime
	self_pos = self.object:get_pos ()
	if self._fatigue_counter > 60 then
		self._fatigue_counter = self._fatigue_counter - 60

		for player in mcl_util.connected_players() do
			local pos = player:get_pos ()
			-- MobEffectUtil.addEffectToPlayersAround: only
			-- survival players who lack Mining Fatigue III
			-- lasting longer than 1199 ticks.
			local name = player:get_player_name ()
			local effect = mcl_potions.get_effect (player, "fatigue")
			local refresh = not effect
				or mcl_potions.get_effect_level (player, "fatigue") < 3
				or (effect.dur - (effect.timer or 0)) < 60
			if vector.distance (pos, self_pos) <= 50
				and refresh
				and not core.is_creative_enabled (name)
				and not (mcl_gamemode and mcl_gamemode.is_spectator (player)) then
				-- Inflict Mining Fatigue III for 5 minutes.
				mcl_potions.give_effect_by_level ("fatigue", player, 3, 300)
				-- TODO: display an apparition and play eerie noises.
			end
		end
	end
end

guardian_elder.ai_functions = {
	mob_class.return_to_restriction,
	mob_class.check_attack,
	mob_class.check_pace,
}

mcl_mobs.register_mob ("mobs_mc:guardian_elder", guardian_elder)

-- spawn eggs
mcl_mobs.register_egg("mobs_mc:guardian_elder", S("Elder Guardian"), "#ceccba", "#747693", 0)


