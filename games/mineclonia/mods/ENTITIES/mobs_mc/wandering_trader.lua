local mob_class = mcl_mobs.mob_class
local modname = core.get_current_modname ()
local S = core.get_translator (modname)
local villager_base = mobs_mc.villager_base

------------------------------------------------------------------------
-- Wandering Trader.
------------------------------------------------------------------------

-- WanderingTrader.java registerGoals: AvoidEntityGoal distances.
-- Zombie.class also covers zombie villagers and zombified piglins.
local avoid_distances = {
	["mobs_mc:zombie"] = 8.0,
	["mobs_mc:baby_zombie"] = 8.0,
	["mobs_mc:husk"] = 8.0,
	["mobs_mc:baby_husk"] = 8.0,
	["mobs_mc:drowned"] = 8.0,
	["mobs_mc:baby_drowned"] = 8.0,
	["mobs_mc:villager_zombie"] = 8.0,
	["mobs_mc:zombified_piglin"] = 8.0,
	["mobs_mc:evoker"] = 12.0,
	["mobs_mc:vindicator"] = 8.0,
	["mobs_mc:vex"] = 8.0,
	["mobs_mc:pillager"] = 15.0,
	["mobs_mc:illusioner"] = 12.0,
	["mobs_mc:zoglin"] = 10.0,
	["mobs_mc:baby_zoglin"] = 10.0,
}

local wandering_trader = table.merge (villager_base, {
       description = S ("Wandering Trader"),
       textures = {
	       "mobs_mc_villager_wandering_trader.png",
       },
       runaway_from = table.keyset (avoid_distances),
       runaway_view_range = 15.0,
       runaway = true,
       runaway_bonus_near = 0.5,
       runaway_bonus_far = 0.5,
       run_bonus = 0.5,
       restriction_bonus = 0.35,
       pace_bonus = 0.35,
       movement_speed = 14.0,
       wielditem_drop_probability = 0.085,
       _life_timer = nil,
})

function wandering_trader:should_runaway_from_mob (entity)
	local distance = avoid_distances[entity.name]
	local pos = entity.object:get_pos ()
	return distance and pos
		and vector.distance (self.object:get_pos (), pos) <= distance
end

------------------------------------------------------------------------
-- Wandering Trader trading.
------------------------------------------------------------------------

local function get_wood_sapling (wood, p)
	return p.saplingdrop or ("mcl_trees:sapling_" .. wood)
end

local function is_trading_wood (wood, p)
	local sap = get_wood_sapling (wood, p)
	local def = core.registered_nodes[sap]
	return def and not def._unobtainable
end

local function get_long_invisibility ()
	local stack = ItemStack ("mcl_potions:invisibility")
	local def = stack:get_definition ()
	stack:get_meta ():set_int ("mcl_potions:potion_plus",
				   def._default_extend_level or 1)
	if tt and tt.reload_itemstack_description then
		tt.reload_itemstack_description (stack)
	end
	return stack:to_string ()
end

local function E (f, t)
	return { "mcl_core:emerald", f or 1, t or f or 1 }
end

-- Trade sets are as defined in Minecraft's
-- data/minecraft/villager_trade/wandering_trader/ (default max_uses
-- 4).  Each item is a separate entry, so that e.g. dyes and logs are
-- weighted as in Minecraft.

-- #minecraft:wandering_trader/buying.
local trades_purchasing_table = {
	{ { "mcl_potions:water", 1, 1, }, E(), 2, 0 },
	{ { "mcl_buckets:bucket_water", 1, 1, }, E(2), 2, 0 },
	{ { "mcl_mobitems:milk_bucket", 1, 1, }, E(2), 2, 0 },
	{ { "mcl_potions:fermented_spider_eye", 1, 1, }, E(3), 2, 0 },
	{ { "mcl_farming:potato_item_baked", 4, 4, }, E(1), 2, 0 },
	{ { "mcl_farming:hay_block", 1, 1, }, E(1), 2, 0 },
}

-- #minecraft:wandering_trader/uncommon.
local trades_special_table = {
	{ E(), { "mcl_core:packed_ice", 1, 1, }, 6, 0 },
	{ E(6), { "mcl_core:blue_ice", 1, 1, }, 6, 0 },
	{ E(), { "mcl_mobitems:gunpowder", 4, 4, }, 2, 0 },
	{ E(3), { "mcl_core:podzol", 3, 3, }, 6, 0 },
	{ E(5), { get_long_invisibility, 1, 1, }, 1, 0 },
	{ E(6, 20), { "mcl_tools:pick_iron_enchanted", 1, 1 }, 1, 0 },
	-- One log trade per wood type is appended below.
}

-- #minecraft:wandering_trader/common.
local trades_ordinary_table = {
	-- One dye trade per color and one sapling trade per wood type
	-- are appended below.
	{ E(3), { "mcl_buckets:bucket_tropical_fish", 1, 1, }, 4, 0 },
	{ E(3), { "mcl_buckets:bucket_pufferfish", 1, 1, }, 4, 0 },
	{ E(2), { "mcl_ocean:sea_pickle_1_dead_brain_coral_block", 1, 1, }, 5, 0 },
	{ E(4), { "mcl_mobitems:slimeball", 1, 1, }, 5, 0 },
	{ E(2), { "mcl_nether:glowstone", 1, 1, }, 5, 0 },
	{ E(5), { "mcl_mobitems:nautilus_shell", 1, 1, }, 5, 0 },
	{ E(), { "mcl_flowers:fern", 1, 1, }, 12, 0 },
	{ E(), { "mcl_core:reeds", 1, 1, }, 8, 0 },
	{ E(), { "mcl_farming:pumpkin", 1, 1, }, 4, 0 },
	{ E(3), { "mcl_ocean:kelp", 1, 1, }, 12, 0 },
	{ E(3), { "mcl_core:cactus", 1, 1, }, 8, 0 },
	{ E(), { "mcl_flowers:dandelion", 1, 1, }, 12, 0 },
	{ E(), { "mcl_flowers:poppy", 1, 1, }, 12, 0 },
	{ E(), { "mcl_flowers:blue_orchid", 1, 1, }, 8, 0 },
	{ E(), { "mcl_flowers:allium", 1, 1, }, 12, 0 },
	{ E(), { "mcl_flowers:azure_bluet", 1, 1, }, 12, 0 },
	{ E(), { "mcl_flowers:tulip_red", 1, 1, }, 12, 0 },
	{ E(), { "mcl_flowers:tulip_orange", 1, 1, }, 12, 0 },
	{ E(), { "mcl_flowers:tulip_white", 1, 1, }, 12, 0 },
	{ E(), { "mcl_flowers:tulip_pink", 1, 1, }, 12, 0 },
	{ E(), { "mcl_flowers:oxeye_daisy", 1, 1, }, 12, 0 },
	{ E(), { "mcl_flowers:cornflower", 1, 1, }, 12, 0 },
	{ E(), { "mcl_flowers:lily_of_the_valley", 1, 1, }, 7, 0 },
	{ E(), { "mcl_farming:wheat_seeds", 1, 1, }, 12, 0 },
	{ E(), { "mcl_farming:beetroot_seeds", 1, 1, }, 12, 0 },
	{ E(), { "mcl_farming:pumpkin_seeds", 1, 1, }, 12, 0 },
	{ E(), { "mcl_farming:melon_seeds", 1, 1, }, 12, 0 },
	{ E(3), { "mcl_ocean:brain_coral_block", 1, 1, }, 8, 0 },
	{ E(3), { "mcl_ocean:bubble_coral_block", 1, 1, }, 8, 0 },
	{ E(3), { "mcl_ocean:fire_coral_block", 1, 1, }, 8, 0 },
	{ E(3), { "mcl_ocean:horn_coral_block", 1, 1, }, 8, 0 },
	{ E(3), { "mcl_ocean:tube_coral_block", 1, 1, }, 8, 0 },
	{ E(), { "mcl_core:vine", 3, 3, }, 4, 0 },
	{ E(), { "mcl_pale_oak:hanging_moss", 3, 3, }, 4, 0 },
	{ E(), { "mcl_mushrooms:mushroom_brown", 3, 3, }, 4, 0 },
	{ E(), { "mcl_mushrooms:mushroom_red", 3, 3, }, 4, 0 },
	{ E(), { "mcl_flowers:waterlily", 5, 5, }, 2, 0 },
	{ E(), { "mcl_lush_caves:dripleaf_small", 2, 2, }, 5, 0 },
	{ E(), { "mcl_core:sand", 8, 8, }, 8, 0 },
	{ E(), { "mcl_core:redsand", 4, 4, }, 6, 0 },
	{ E(), { "mcl_dripstone:pointed_dripstone", 2, 2, }, 5, 0 },
	{ E(), { "mcl_lush_caves:rooted_dirt", 2, 2, }, 5, 0 },
	{ E(), { "mcl_lush_caves:moss", 2, 2, }, 5, 0 },
	{ E(), { "mcl_pale_oak:pale_moss", 2, 2, }, 5, 0 },
	{ E(), { "mcl_flowers:wildflowers", 1, 1, }, 12, 0 },
	{ E(), { "mcl_flowers:tall_dry_grass", 1, 1, }, 12, 0 },
	{ E(3), { "mcl_flowers:firefly_bush", 1, 1, }, 12, 0 },
	{ E(1), { "mcl_mobitems:nametag", 1, 1, }, 5, 0 },
}

local tables_completed = false

local function complete_trade_tables ()
	if tables_completed then
		return
	end
	tables_completed = true
	local woods = table.keyset (mcl_trees.woods, is_trading_wood)
	table.sort (woods)
	for _, wood in ipairs (woods) do
		local p = mcl_trees.woods[wood]
		table.insert (trades_special_table, {
			E(), { "mcl_trees:tree_" .. wood, 8, 8, }, 4, 0,
		})
		table.insert (trades_ordinary_table, {
			E(5), { get_wood_sapling (wood, p), 1, 1, }, 8, 0,
		})
	end
	local colors = table.keyset (mcl_dyes.colors)
	table.sort (colors)
	for _, color in ipairs (colors) do
		table.insert (trades_ordinary_table, {
			E(), { "mcl_dyes:" .. color, 3, 3, }, 12, 0,
		})
	end
	-- Omit trades whose items are not registered.
	local function filter (list)
		for i = #list, 1, -1 do
			local item = list[i][2][1]
			if type (item) == "string"
				and not core.registered_items[item] then
				table.remove (list, i)
			end
		end
	end
	filter (trades_special_table)
	filter (trades_ordinary_table)
end

local pr = PcgRandom (os.time () + 593)

-- WanderingTrader.java updateTrades: 2 buying, 2 uncommon and 5
-- common offers, in that order, drawn without replacement.
local function get_wandering_trades ()
	complete_trade_tables ()
	local t = {}
	local function draw (list, amount)
		local list = table.copy (list)
		for _ = 1, math.min (amount, #list) do
			local trade = table.remove (list, math.random (#list))
			table.insert (t, mobs_mc.trade_from_table (pr, trade, true))
		end
	end
	draw (trades_purchasing_table, 2)
	draw (trades_special_table, 2)
	draw (trades_ordinary_table, 5)
	return t
end

function wandering_trader:on_spawn ()
	self:update_trades (get_wandering_trades ())
end

function wandering_trader:on_rightclick (clicker)
	local clicker_pos = clicker:get_pos ()
	local self_pos = self.object:get_pos ()

	if vector.distance (clicker_pos, self_pos) < 16 then
		self:show_trade_formspec (clicker, 0)
	end
end

function wandering_trader:show_trade_progress_bar ()
	return false
end

function wandering_trader:actionable_on_rightclick (player)
	return true
end

------------------------------------------------------------------------
-- Wandering Trader AI.
------------------------------------------------------------------------

function wandering_trader:mob_activate (staticdata, dtime)
	if not villager_base.mob_activate (self, staticdata, dtime) then
		return false
	end
	self._llamas = {}
	self._provide_owner = function ()
		return self.object:is_valid () and self.object
	end
	return true
end

function wandering_trader:get_staticdata_table ()
	local supertable = villager_base.get_staticdata_table (self)
	if supertable then
		supertable._llamas = nil
	end
	return supertable
end

function wandering_trader:ai_step (dtime)
	mob_class.ai_step (self, dtime)
	-- WanderingTrader.java maybeDespawn: the despawn delay does
	-- not elapse while trading.
	if self._life_timer and not self:is_trading () then
		self._life_timer = self._life_timer - dtime
		if self._life_timer <= 0 then
			self:safe_remove ()
		end
	end
	local is_day = mcl_util.is_daytime ()
	-- Potions and milk take 32 ticks to drink.
	if not self._mob_invisible and not is_day then
		local wielditem = self:get_wielditem ()
		if not self._using_wielditem
			or wielditem:get_name () ~= "mcl_potions:invisibility" then
			self:set_wielditem (ItemStack ("mcl_potions:invisibility"))
			self:use_wielditem ()
		elseif self._using_wielditem >= 1.6 then
			mcl_hunger.play_drinking_sound(self.object)
			-- Potions.INVISIBILITY: 3600 ticks.
			mcl_potions.give_effect ("invisibility", self.object,
						 0, mcl_potions.DURATION)
			-- LivingEntity.completeUsingItem: Consumable.onConsume
			-- and stopUsingItem
			if mcl_gameevent then
				mcl_gameevent.emit_entity (self.object, "drink")
				mcl_gameevent.emit_entity (self.object, "item_interact_finish")
			end
			self:set_wielditem (ItemStack ())
		end
	elseif self._mob_invisible and is_day then
		local wielditem = self:get_wielditem ()
		if not self._using_wielditem
			or wielditem:get_name () ~= "mcl_mobitems:milk_bucket" then
			self:set_wielditem (ItemStack ("mcl_mobitems:milk_bucket"))
			self:use_wielditem ()
		elseif self._using_wielditem >= 1.6 then
			mcl_potions._reset_effects (self.object)
			mcl_hunger.play_drinking_sound(self.object)
			-- LivingEntity.completeUsingItem: Consumable.onConsume
			-- and stopUsingItem
			if mcl_gameevent then
				mcl_gameevent.emit_entity (self.object, "drink")
				mcl_gameevent.emit_entity (self.object, "item_interact_finish")
			end
			self:set_wielditem (ItemStack ())
		end
	end

	local valid_llamas = {}
	-- Delete invalid llamas.
	for _, llama in pairs (self._llamas) do
		if llama:is_valid () then
			table.insert (valid_llamas, llama)
		end
	end
	-- Search within a 16 node radius for llamas belonging to this
	-- trader.  TODO: revisit this once leashes are available.
	if #valid_llamas < 2
		and self:check_timer ("locate_llamas", 0.5) then
		local self_pos = self.object:get_pos ()
		for object in core.objects_inside_radius (self_pos, 16) do
			local entity = object:get_luaentity ()
			if entity and entity.name == "mobs_mc:trader_llama"
				and entity._trader_id == self._trader_id then
				entity._get_owner = self._provide_owner
				table.insert (valid_llamas, object)
			end
		end
	end
	self._llamas = valid_llamas
end

local function is_mob (source)
	local entity = source:get_luaentity ()
	return entity and entity.is_mob
end

function wandering_trader:receive_damage (mcl_reason, damage)
	if mob_class.receive_damage (self, mcl_reason, damage) then
		if mcl_reason.source
			and (mcl_reason.source:is_player ()
			     or is_mob (mcl_reason.source)) then
			-- Call llamas to retaliate.
			for _, llama in pairs (self._llamas) do
				local entity = llama:get_luaentity ()
				if entity then
					entity:receive_attack (mcl_reason.source)
				end
			end
		end
		return true
	end
	return false
end

local function wandering_trader_check_trading (self, self_pos, dtime, moveresult)
	if self._halted_for_trading then
		if self._immersion_depth >= 1
			or (not moveresult.touching_ground
				and not moveresult.standing_on_object
				and not self.object:get_attach ())
			or self.runaway_timer >= 4.5 then
			self:stop_trading ()
			self._halted_for_trading = false
			return false
		elseif not self:is_trading () then
			self._halted_for_trading = false
			return false
		else
			local dist_min = math.huge
			for player, _ in pairs (self._trading_with) do
				if player:is_valid () then
					local pos = player:get_pos ()
					local d = vector.distance (pos, self_pos)
					if d > 16 then
						local name = player:get_player_name ()
						local formname = "mobs_mc:trading_formspec"
						mobs_mc.return_trading_fields (player)
						core.close_formspec (name, formname)
						self._trading_with[player] = nil
					end
					dist_min = math.min (d, dist_min)
				end
			end
			if dist_min > 16 then
				self._halted_for_trading = false
				return false
			end
			return true
		end
	elseif self:is_trading () then
		self:cancel_navigation ()
		self:halt_in_tracks ()
		self._halted_for_trading = true
		return "_halted_for_trading"
	end
	return false
end

local function wandering_trader_check_wander (self, self_pos, dtime)
	if self._wandering_to_target then
		if self:navigation_finished () then
			local distance
				= vector.distance (self_pos, self._wander_last_pos)
			local target_dist
				= vector.distance (self_pos, self._wander_to)
			if target_dist <= 2.0 then
				self:cancel_navigation ()
				self:halt_in_tracks ()
				self._wander_to = nil
				self._wander_last_pos = nil
				self._wandering_to_target = false
				return false
			end
			if distance < 1.0 then
				self._wander_retries
					= (self._wander_retries or 0) + 1

				-- Give up.
				if self._wander_retries > 3 then
					self._wander_to = nil
					self._wander_last_pos = nil
					self._wandering_to_target = false
					return false
				end
			end
			self._wander_last_pos = self_pos
			self:gopath (self._wander_to, 0.35)
		end
		return true
	elseif self._wander_to then
		self:gopath (self._wander_to, 0.35)
		self._wandering_to_target = true
		self._wander_last_pos = self_pos
		self._wander_retries = 0
		return true
	end
	return false
end

wandering_trader.ai_functions = {
	mob_class.check_frightened,
	wandering_trader_check_trading,
	mob_class.check_avoid,
	wandering_trader_check_wander,
	mob_class.return_to_restriction,
	mob_class.check_pace,
}

------------------------------------------------------------------------
-- Upgrading old traders.
------------------------------------------------------------------------

local function convert_old_trades (tradestring)
	if type (tradestring) ~= "string" then
		return {}
	end
	local trades = core.deserialize (tradestring)
	local new_trades = {}
	for _, trade in ipairs (trades) do
		local trade_object = mobs_mc.make_villager_trade ({
			wanted1 = trade.wanted[1],
			wanted2 = trade.wanted[2] or "",
			offered = ItemStack (trade.offered):to_string (),
			uses = trade.trade_counter or 0,
			max_uses = trade.max_uses or 12,
			reward_xp = false,
		})
		table.insert (new_trades, trade_object)
	end
	return new_trades
end

function wandering_trader:post_load_staticdata ()
	mob_class.post_load_staticdata (self)
	if self._trades and type (self._trades) ~= "table" then
		self._trades = convert_old_trades (self._trades, self._tier)
	end
end

mcl_mobs.register_mob ("mobs_mc:wandering_trader", wandering_trader)

------------------------------------------------------------------------
-- Wandering Trader spawning.
------------------------------------------------------------------------

local storage = core.get_mod_storage ()

local function spawn_one_llama (around, entity)
	for i = 1, 10 do
		local dx = pr:next (-4, 4)
		local dz = pr:next (-4, 4)
		local pos = vector.offset (around, dx, 0, dz)
		local surface = mobs_mc.find_surface_position (pos)
		local llama = mcl_mobs.spawn_abnormally (surface, "mobs_mc:trader_llama",
							 nil, "trader_spawning")
		if llama then
			local llama = llama:get_luaentity ()
			llama._trader_id = entity._trader_id
			llama._get_owner = entity._provide_owner
			llama._life_timer = entity._life_timer
			table.insert (entity._llamas, llama.object)
			return
		end
	end
end

local function spawn_llamas (surface, entity)
	entity._llamas = {}
	spawn_one_llama (surface, entity)
	spawn_one_llama (surface, entity)
end

local function spawn_wandering_trader ()
	-- Select a random player in the overworld.
	local players_in_overworld = {}
	for player in mcl_util.connected_players () do
		local pos = player:get_pos ()
		local dim = mcl_worlds.pos_to_dimension (pos)

		if dim == "overworld" then
			table.insert (players_in_overworld, player)
		end
	end
	local nplayers = #players_in_overworld
	if nplayers == 0 then
		return true
	elseif pr:next (1, 10) ~= 1 then
		return false
	end
	local player = players_in_overworld[pr:next (1, nplayers)]

	-- Find nearby bells.
	local player_pos = mcl_util.get_nodepos (player:get_pos ())
	local aa = vector.offset (player_pos, -48, -48, -48)
	local bb = vector.offset (player_pos, 48, 48, 48)

	-- Try to spawn beside a meeting point POI, if any.
	local poi = nil
	local pois = mcl_villages.get_pois_in_by_nodepos (aa, bb)
	table.shuffle (pois)
	for _, poi1 in pairs (pois) do
		if poi1.data == "mcl_villages:bell"
			or poi1.data == "mcl_villages:demo_poi" then
			poi = poi1.min
			break
		end
	end

	-- Locate a valid surface spawn position.
	local base_position = poi or player_pos
	for i = 1, 10 do
		local dx = pr:next (-48, 48)
		local dz = pr:next (-48, 48)
		local pos = vector.offset (base_position, dx, 0, dz)
		local surface = mobs_mc.find_surface_position (pos)

		-- Spawn a trader and attempt to link llamas to the
		-- same.
		local trader = mcl_mobs.spawn_abnormally (surface,
							  "mobs_mc:wandering_trader",
							  nil, "trader_spawning")
		if trader then
			local trader_id = storage:get_int ("last_trader_id") + 1
			storage:set_int ("last_trader_id", trader_id)
			local entity = trader:get_luaentity ()
			-- WanderingTraderSpawner.java: 48000 ticks.
			entity._life_timer = 2400
			entity._trader_id = trader_id
			entity._wander_to = base_position
			entity:restrict_to (base_position, 16)
			spawn_llamas (surface, entity)
			return true
		end
	end
	return false
end

mobs_mc.spawn_wandering_trader = spawn_wandering_trader

if core.settings:get_bool ("mobs_spawn", true) then

local local_spawn_counter = 60

core.register_globalstep (function (dtime)
	local_spawn_counter = local_spawn_counter - dtime
	if local_spawn_counter < 0 then
		local_spawn_counter = 60
		local level_spawn_counter
			= storage:get_int ("trader_spawn_delay") - 60

		-- WanderingTraderSpawner.java tick: the spawn chance
		-- (25-75%) rises by 25 after every daily attempt, and
		-- is reset to 25 by a successful spawn.  The roll is
		-- against the chance before it is raised.
		if level_spawn_counter <= -1200 then
			level_spawn_counter = 0

			local chance = math.max (25, math.min (75,
				storage:get_int ("trader_spawn_chance")))
			local new_chance = math.min (75, chance + 25)
			if pr:next (0, 99) <= chance then
				if spawn_wandering_trader () then
					new_chance = 25
				end
			end
			storage:set_int ("trader_spawn_chance", new_chance)
		end

		storage:set_int ("trader_spawn_delay", level_spawn_counter)
	end
end)

end

mcl_mobs.register_egg ("mobs_mc:wandering_trader", S("Wandering Trader"), "#1E90FF", "#bc8b72", 0)

local wandering_trader_spawner = table.merge (mcl_mobs.default_spawner, {
	name = "mobs_mc:wandering_trader",
	biomes = {},
	is_canonical = true,
})

mcl_mobs.register_spawner (wandering_trader_spawner)

------------------------------------------------------------------------------
-- Trader Llama.
------------------------------------------------------------------------------

local llama = mobs_mc.llama

local trader_llama = table.merge (llama, {
	description = S ("Trader Llama"),
	textures = {
		{
			"blank.png",
			"mobs_mc_llama_decor_wandering_trader.png",
			"mobs_mc_llama_brown.png",
		},
		{
			"blank.png",
			"mobs_mc_llama_decor_wandering_trader.png",
			"mobs_mc_llama_creamy.png",
		},
		{
			"blank.png",
			"mobs_mc_llama_decor_wandering_trader.png",
			"mobs_mc_llama_gray.png",
		},
		{
			"blank.png",
			"mobs_mc_llama_decor_wandering_trader.png",
			"mobs_mc_llama_white.png",
		},
	},
	persistent = true,
	-- TraderLlama.java: PanicGoal (2.0).
	run_bonus = 2.0,
	_default_decor_texture = "mobs_mc_llama_decor_wandering_trader.png",
})

-- TraderLlama.java: DEFAULT_DESPAWN_DELAY = 47999 ticks.
local TRADER_LLAMA_DESPAWN_DELAY = 47999 / 20

function trader_llama:on_spawn ()
	llama.on_spawn (self)
	-- Overwritten by the wandering trader spawner with its
	-- trader's own despawn delay.
	if not self._life_timer then
		self._life_timer = TRADER_LLAMA_DESPAWN_DELAY
	end
end

-- TraderLlama.java registerGoals: attack zombies other than
-- zombified piglins, and illagers.
local trader_llama_enemies = {
	"mobs_mc:zombie",
	"mobs_mc:baby_zombie",
	"mobs_mc:husk",
	"mobs_mc:baby_husk",
	"mobs_mc:drowned",
	"mobs_mc:baby_drowned",
	"mobs_mc:villager_zombie",
}

local illagers = {
	"mobs_mc:evoker",
	"mobs_mc:illusioner",
	"mobs_mc:pillager",
	"mobs_mc:vindicator",
}

trader_llama._targeting_rules = table.copy (llama._targeting_rules)
table.insert (trader_llama._targeting_rules,
	      mcl_mobs.build_nearest_target_rule ("mob", trader_llama_enemies,
						  nil, nil, false))
table.insert (trader_llama._targeting_rules,
	      mcl_mobs.build_nearest_target_rule ("mob", illagers,
						  nil, nil, false))

function trader_llama:allow_mount ()
	return self:_get_owner () == nil
end

function trader_llama:_get_owner ()
	return nil
end

function trader_llama:is_leashed ()
	-- TODO: revise this once leashes are introduced.
	return self:_get_owner () ~= nil
end

-- XXX: revisit this function once leashes are implemented.
local function trader_llama_follow_owner (self, self_pos, dtime)
	if self._following_owner then
		local owner = self:_get_owner ()
		if not owner then
			self._following_owner = false
			return false
		end
		local owner_pos = owner:get_pos ()
		if vector.distance (self_pos, owner_pos) < 6.0 then
			self._following_owner = false
			self:look_at (owner_pos)
			return false
		end

		if self:check_timer ("follow_owner", 0.5) then
			self:gopath (owner_pos, 1.4, nil, 3.0)
		end
		return true
	else
		local owner = self:_get_owner ()
		if not owner then
			return
		end
		local owner_pos = owner:get_pos ()
		if vector.distance (self_pos, owner_pos) <= 20 then
			if vector.distance (self_pos, owner_pos) >= 6.0 then
				self._following_owner = true
				self:gopath (owner_pos, 1.4, nil, 3.0)
				return "_following_owner"
			end
		elseif owner then
			self._trader_id = nil
			self._get_owner = trader_llama._get_owner
		end
	end
	return false
end

function trader_llama:ai_step (dtime)
	llama.ai_step (self, dtime)

	-- TraderLlama.java canDespawn: not tamed, ridden or
	-- persistent (named).
	if not self.tamed and not self.driver
		and (self.nametag or "") == "" then
		local owner = self:_get_owner ()
		if owner then
			self._life_timer = owner:get_luaentity ()._life_timer
		elseif self._life_timer then
			self._life_timer = self._life_timer - dtime
		end
	end

	if self._life_timer and self._life_timer <= 0 then
		self:safe_remove ()
	end
end

trader_llama.ai_functions = {
	llama.check_tame,
	llama.follow_caravan,
	mob_class.check_attack,
	trader_llama_follow_owner,
	mob_class.check_frightened,
	mob_class.check_breeding,
	mob_class.check_following,
	mob_class.follow_herd,
	mob_class.check_pace,
}

------------------------------------------------------------------------
-- Trader Llama spawning & registration.
------------------------------------------------------------------------

mcl_mobs.register_mob ("mobs_mc:trader_llama", trader_llama)
mcl_mobs.register_egg ("mobs_mc:trader_llama", S("Trader Llama"), "#eaa430", "#456296", 0)
mcl_entity_invs.register_inv ("mobs_mc:trader_llama", S ("Trader Llama"), nil, true)

local trader_llama_spawner = table.merge (mcl_mobs.default_spawner, {
	name = "mobs_mc:trader_llama",
	biomes = {},
	is_canonical = true,
})

mcl_mobs.register_spawner (trader_llama_spawner)
