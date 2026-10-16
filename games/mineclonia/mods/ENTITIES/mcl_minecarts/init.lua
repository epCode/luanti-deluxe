local modname = core.get_current_modname()
local S = core.get_translator(modname)

mcl_minecarts = {}
mcl_minecarts.modpath = core.get_modpath(modname)
mcl_minecarts.speed_max = 10
mcl_minecarts.check_float_time = 15

dofile(mcl_minecarts.modpath.."/functions.lua")
dofile(mcl_minecarts.modpath.."/rails.lua")

-- Entity.startRiding / Entity.removeVehicle: at the vehicle, with the
-- rider as source
local function ge_ride(self, event, rider)
	if mcl_gameevent and rider and rider:get_pos() and self.object:get_pos() then
		mcl_gameevent.emit(event, self.object:get_pos(), {source = rider})
	end
end

local function detach_driver(self)
	if not self._driver then
		return
	end
	local player = core.get_player_by_name(self._driver)
	self._driver = nil
	self._start_pos = nil
	if player then
		if player:get_attach() then
			ge_ride(self, "entity_dismount", player)
		end
		mcl_player.players[player].attached = nil
		player:set_detach()
		player:set_eye_offset({x=0, y=0, z=0},{x=0, y=0, z=0})
		mcl_player.player_set_animation(player, "stand" , 30)
	end
end

local function activate_tnt_minecart(self, timer)
	if self._boomtimer then
		return
	end
	self.object:set_armor_groups({immortal=1})
	if timer then
		self._boomtimer = timer
	else
		self._boomtimer = mcl_tnt.BOOMTIMER
	end
	self.object:set_properties({textures = {
		"mcl_tnt_blink.png",
		"mcl_tnt_blink.png",
		"mcl_tnt_blink.png",
		"mcl_tnt_blink.png",
		"mcl_tnt_blink.png",
		"mcl_tnt_blink.png",
		"mcl_minecarts_minecart.png",
	}})
	self._blinktimer = mcl_tnt.BLINKTIMER
	core.sound_play("tnt_ignite", {pos = self.object:get_pos(), gain = 1.0, max_hear_distance = 15}, true)
end

local activate_normal_minecart = detach_driver

local function hopper_take_item(self)
	local pos = self.object:get_pos()
	if not pos then return end

	if not self or self.name ~= "mcl_minecarts:hopper_minecart" then return end
	-- MinecartHopper.isEnabled: switched off by a powered activator rail
	if self._hopper_enabled == false then return end

	local above_pos = vector.offset(pos, 0, 0.9, 0)

	for v in core.objects_inside_radius(above_pos, 1.25) do
		local ent = v:get_luaentity()
		local taken_items = false

		if ent and not ent._removed and ent.itemstring and ent.itemstring ~= "" then
			local inv = mcl_entity_invs.load_inv(self, 5)
			if not inv then	return false end

			local current_itemstack = ItemStack(ent.itemstring)

			if inv:room_for_item("main", current_itemstack) then
				inv:add_item("main", current_itemstack)
				v:get_luaentity().itemstring = ""
				v:remove()
				taken_items = true
			end

			if not taken_items then
				local items_remaining = current_itemstack:get_count()
				for i = 1, self._inv_size, 1 do
					local stack = inv:get_stack("main", i)

					if current_itemstack:get_name() == stack:get_name() then
						local room_for = stack:get_stack_max() - stack:get_count()
						if room_for < items_remaining then
							items_remaining = items_remaining - room_for
							stack:set_count(stack:get_stack_max())
							inv:set_stack("main", i, stack)
							taken_items = true
						elseif room_for ~= 0 then --do nothing if 0
							local new_stack_size = stack:get_count() + items_remaining
							stack:set_count(new_stack_size)
							inv:set_stack("main", i, stack)
							v:get_luaentity().itemstring = ""
							v:remove()
							taken_items = true
							break
						end
					end

					if i == self._inv_size and taken_items then
						current_itemstack:set_count(items_remaining)
						ent.itemstring = current_itemstack:to_string()
					end
				end
			end
		end

		if taken_items then
			mcl_entity_invs.save_inv(ent)
			return taken_items
		end
	end

	return false
end

-- Table for item-to-entity mapping. Keys: itemstring, Values: Corresponding entity ID
local entity_mapping = {}

-- Active minecarts in the order they were activated (the entity list)
local active_carts = {}

local function register_entity(entity_id, mesh, textures, drop, on_rightclick, on_activate_by_rail)
	local cart = {
		initial_properties = {
			physical = false,
			collisionbox = {-10/16., -0.5, -10/16, 10/16, 0.25, 10/16},
			visual = "mesh",
			mesh = mesh,
			visual_size = {x=1, y=1},
			textures = textures,
		},

		on_rightclick = on_rightclick,

		_driver = nil, -- player who sits in and controls the minecart (only for minecart!)
		_passenger = nil, -- for mobs
		_punched = false, -- used to re-send _velocity and position
		_velocity = {x=0, y=0, z=0}, -- only used on punch
		_start_pos = nil, -- Used to calculate distance for “On A Rail” achievement
		_last_float_check = nil, -- timestamp of last time the cart was checked to be still on a rail
		_fueltime = nil, -- how many seconds worth of fuel is left. Only used by minecart with furnace
		_boomtimer = nil, -- how many seconds are left before exploding
		_blinktimer = nil, -- how many seconds are left before TNT blinking
		_blink = false, -- is TNT blink texture active?
		_old_dir = {x=0, y=0, z=0},
		_old_pos = nil,
		_old_vel = {x=0, y=0, z=0},
		_old_switch = 0,
		_railtype = nil,
		_mcl_fishing_hookable = true,
		_mcl_fishing_reelable = true,
	}

	function cart:on_activate(staticdata, _)
		-- Initialize
		local data = core.deserialize(staticdata)
		if type(data) == "table" then
			self._railtype = data._railtype
			self._passenger = data._passenger
			self._hopper_enabled = data._hopper_enabled
		end
		self.object:set_armor_groups({immortal=1})
		active_carts[#active_carts + 1] = self
	end

	function cart:on_deactivate()
		self._deactivated = true
	end

	function cart:on_punch(puncher, time_from_last_punch, tool_capabilities, _)
		local pos = self.object:get_pos()
		if not self._railtype then
			local node = core.get_node(vector.floor(pos)).name
			self._railtype = core.get_item_group(node, "connect_to_raillike")
		end

		if not puncher or not puncher:is_player() then
			local cart_dir = mcl_minecarts:get_rail_direction(pos, {x=1, y=0, z=0}, nil, nil, self._railtype)
			if vector.equals(cart_dir, {x=0, y=0, z=0}) then
				return
			end
			mcl_minecarts:set_velocity(self, cart_dir)
			return
		end

		-- Punch+sneak: Pick up minecart (unless TNT was ignited)
		if puncher:get_player_control().sneak and not self._boomtimer then
			if self._driver then
				if self._old_pos then
					self.object:set_pos(self._old_pos)
				end
				detach_driver(self)
			end

			-- Drop items and remove cart entity
			if not core.is_creative_enabled(puncher:get_player_name()) then
				for d=1, #drop do
					core.add_item(self.object:get_pos(), drop[d])
				end
				if self._on_destroy_minecart then
					self:_on_destroy_minecart (puncher)
				end
			elseif puncher and puncher:is_player() then
				local inv = puncher:get_inventory()
				for d=1, #drop do
					if not inv:contains_item("main", drop[d]) then
						inv:add_item("main", drop[d])
					end
				end
			end

			self.object:remove()
			return
		end

		local vel = self.object:get_velocity()
		if puncher:get_player_name() == self._driver then
			if math.abs(vel.x + vel.z) > 7 then
				return
			end
		end

		local punch_dir = mcl_minecarts:velocity_to_dir(puncher:get_look_dir())
		punch_dir.y = 0
		local cart_dir = mcl_minecarts:get_rail_direction(pos, punch_dir, nil, nil, self._railtype)
		if vector.equals(cart_dir, {x=0, y=0, z=0}) then
			return
		end

		time_from_last_punch = math.min(time_from_last_punch, tool_capabilities.full_punch_interval)
		local f = 3 * (time_from_last_punch / tool_capabilities.full_punch_interval)

		mcl_minecarts:set_velocity(self, cart_dir, f)
	end

	cart.on_activate_by_rail = on_activate_by_rail

	local passenger_attach_position = vector.new(0, -1.75, 0)

	function cart:on_step(dtime)
		hopper_take_item(self)

		-- Entity.move: minecarts emit movement events
		-- (MovementEmission.EVENTS); being on rails counts as on ground
		if mcl_gameevent then
			local gpos = self.object:get_pos()
			self._ge_tracker = self._ge_tracker or mcl_gameevent.new_movement_tracker()
			local rpos = vector.round(gpos)
			local on_rails = mcl_minecarts:is_rail(rpos)
			mcl_gameevent.track_movement(self.object, self._ge_tracker, {
				pos = gpos,
				on_ground = on_rails or (core.registered_nodes[core.get_node(
					vector.offset(rpos, 0, -1, 0)).name] or {}).walkable == true,
				in_water = core.get_item_group(core.get_node(rpos).name, "water") > 0,
				swimming = false, climbing = false, crouching = false,
				passenger = self.object:get_attach() ~= nil,
				supporting = on_rails and core.get_node(rpos).name or nil,
			})
		end

		local ctrl, player = nil, nil
		if self._driver then
			player = core.get_player_by_name(self._driver)
			if player then
				ctrl = player:get_player_control()
				-- player detach
				if ctrl.sneak then
					detach_driver(self)
					return
				end
			end
		end

		local vel = self.object:get_velocity()
		local update = {}
		if self._last_float_check == nil then
			self._last_float_check = 0
		else
			self._last_float_check = self._last_float_check + dtime
		end

		local pos, rou_pos, node = self.object:get_pos()
		local r = 0.6
		for _, node_pos in pairs({{r, 0}, {0, r}, {-r, 0}, {0, -r}}) do
			if core.get_node(vector.offset(pos, node_pos[1], 0, node_pos[2])).name == "mcl_core:cactus" then
				detach_driver(self)
				for d = 1, #drop do
					core.add_item(pos, drop[d])
				end
				self.object:remove()
				return
			end
		end

		-- Grab mob
		if math.random(1,20) > 15 and not self._passenger then
			if self.name == "mcl_minecarts:minecart" then
				for mob in core.objects_inside_radius(self.object:get_pos(), 1.3) do
					local entity = mob:get_luaentity()
					if entity and entity.is_mob and entity.can_ride_cart then
						self._passenger = entity
						mob:set_attach(self.object, "", passenger_attach_position, vector.zero())
						mcl_attachments.spawn_attachment_entity (mob)
						ge_ride(self, "entity_mount", mob)
						break
					end
				end
			end
		elseif self._passenger then
			local passenger_pos = self._passenger.object:get_pos()
			if not passenger_pos then
				self._passenger = nil
			end
		end

		-- Drop minecart if it isn't on a rail anymore
		if self._last_float_check >= mcl_minecarts.check_float_time then
			pos = self.object:get_pos()
			rou_pos = vector.round(pos)
			node = mcl_waterlogging.as_dry(core.get_node(rou_pos))
			local g = core.get_item_group(node.name, "connect_to_raillike")
			if g ~= self._railtype and self._railtype then
				-- Detach driver
				if player then
					if self._old_pos then
						self.object:set_pos(self._old_pos)
					end
					if player:get_attach() then
						ge_ride(self, "entity_dismount", player)
					end
					mcl_player.players[player].attached = nil
					player:set_detach()
				end

				-- Explode if already ignited
				if self._boomtimer then
					mcl_explosions.explode(pos, 4, {}, self.object)
					self.object:remove()
					return
				end

				-- Do not drop minecart. It goes off the rails too frequently, and anyone using them for farms won't
				-- notice and lose their iron and not bother. Not cool until fixed.
			end
			self._last_float_check = 0
		end

		-- Update furnace stuff
		if self._fueltime and self._fueltime > 0 then
			self._fueltime = self._fueltime - dtime
			if self._fueltime <= 0 then
				self.object:set_properties({textures =
					{
					"default_furnace_top.png",
					"default_furnace_top.png",
					"default_furnace_front.png",
					"default_furnace_side.png",
					"default_furnace_side.png",
					"default_furnace_side.png",
					"mcl_minecarts_minecart.png",
				}})
				self._fueltime = 0
			end
		end
		local has_fuel = self._fueltime and self._fueltime > 0

		-- Update TNT stuff
		if self._boomtimer then
			-- Explode
			self._boomtimer = self._boomtimer - dtime
			local pos = self.object:get_pos()
			if self._boomtimer <= 0 then
				mcl_explosions.explode(pos, 4, {}, self.object)
				self.object:remove()
				return
			else
				mcl_tnt.smoke_step(pos)
			end
		end
		if self._blinktimer then
			self._blinktimer = self._blinktimer - dtime
			if self._blinktimer <= 0 then
				self._blink = not self._blink
				if self._blink then
					self.object:set_properties({textures =
					{
					"default_tnt_top.png",
					"default_tnt_bottom.png",
					"default_tnt_side.png",
					"default_tnt_side.png",
					"default_tnt_side.png",
					"default_tnt_side.png",
					"mcl_minecarts_minecart.png",
					}})
				else
					self.object:set_properties({textures =
					{
					"mcl_tnt_blink.png",
					"mcl_tnt_blink.png",
					"mcl_tnt_blink.png",
					"mcl_tnt_blink.png",
					"mcl_tnt_blink.png",
					"mcl_tnt_blink.png",
					"mcl_minecarts_minecart.png",
					}})
				end
				self._blinktimer = mcl_tnt.BLINKTIMER
			end
		end

		if self._punched then
			vel = vector.add(vel, self._velocity)
			self.object:set_velocity(vel)
			self._old_dir.y = 0
		elseif vector.equals(vel, {x=0, y=0, z=0}) and (not has_fuel) then
			return
		end

		local dir, last_switch, restart_pos = nil, nil, nil
		if not pos then
			pos = self.object:get_pos()
		end
		if self._old_pos and not self._punched then
			local flo_pos = vector.floor(pos)
			local flo_old = vector.floor(self._old_pos)
			if vector.equals(flo_pos, flo_old) and (not has_fuel) then
				return
				-- Prevent querying the same node over and over again
			end

			if not rou_pos then
				rou_pos = vector.round(pos)
			end
			if not node then
				node = mcl_waterlogging.as_dry(core.get_node(rou_pos))
			end
			if node.name == "mcl_minecarts:golden_rail_on" then
				restart_pos = rou_pos
			end
		end

		-- Stop cart if velocity vector flips
		if self._old_vel and self._old_vel.y == 0 and
				(self._old_vel.x * vel.x < 0 or self._old_vel.z * vel.z < 0) then
			self._old_vel = {x = 0, y = 0, z = 0}
			self._old_pos = pos
			self.object:set_velocity(vector.new())
			self.object:set_acceleration(vector.new())
			return
		end
		self._old_vel = vector.new(vel)

		if self._old_pos then
			local diff = vector.subtract(self._old_pos, pos)
			for _,v in ipairs({"x","y","z"}) do
				if math.abs(diff[v]) > 1.1 then
					local expected_pos = vector.add(self._old_pos, self._old_dir)
					dir, last_switch = mcl_minecarts:get_rail_direction(pos, self._old_dir, ctrl, self._old_switch, self._railtype)
					if vector.equals(dir, {x=0, y=0, z=0}) then
						dir = false
						pos = vector.new(expected_pos)
						update.pos = true
					end
					break
				end
			end
		end

		if vel.y == 0 then
			for _,v in ipairs({"x", "z"}) do
				if vel[v] ~= 0 and math.abs(vel[v]) < 0.9 then
					vel[v] = 0
					update.vel = true
				end
			end
		end

		local cart_dir = mcl_minecarts:velocity_to_dir(vel)
		local max_vel = mcl_minecarts.speed_max
		if not dir then
			dir, last_switch = mcl_minecarts:get_rail_direction(pos, cart_dir, ctrl, self._old_switch, self._railtype)
		end

		local new_acc = {x=0, y=0, z=0}
		if vector.equals(dir, {x=0, y=0, z=0}) and not has_fuel then
			vel = {x=0, y=0, z=0}
			update.vel = true
		else
			-- If the direction changed
			if dir.x ~= 0 and self._old_dir.z ~= 0 then
				vel.x = dir.x * math.abs(vel.z)
				vel.z = 0
				pos.z = math.floor(pos.z + 0.5)
				update.pos = true
			end
			if dir.z ~= 0 and self._old_dir.x ~= 0 then
				vel.z = dir.z * math.abs(vel.x)
				vel.x = 0
				pos.x = math.floor(pos.x + 0.5)
				update.pos = true
			end
			-- Up, down?
			if dir.y ~= self._old_dir.y then
				vel.y = dir.y * math.abs(vel.x + vel.z)
				pos = vector.round(pos)
				update.pos = true
			end

			-- Slow down or speed up
			local acc = dir.y * -1.8
			local friction = 0.4
			local ndef = core.registered_nodes[core.get_node(pos).name]
			local speed_mod = ndef and ndef._rail_acceleration

			acc = acc - friction

			if has_fuel then
				acc = acc + 0.6
			end

			if speed_mod and speed_mod ~= 0 then
				acc = acc + speed_mod + friction
			end

			new_acc = vector.multiply(dir, acc)
		end

		self.object:set_acceleration(new_acc)
		self._old_pos = vector.new(pos)
		self._old_dir = vector.new(dir)
		self._old_switch = last_switch

		-- Limits
		for _,v in ipairs({"x","y","z"}) do
			if math.abs(vel[v]) > max_vel then
				vel[v] = mcl_minecarts:get_sign(vel[v]) * max_vel
				new_acc[v] = 0
				update.vel = true
			end
		end

		-- Give achievement when player reached a distance of 1000 nodes from the start position
		if self._driver and (vector.distance(self._start_pos, pos) >= 1000) then
			awards.unlock(self._driver, "mcl:onARail")
		end


		if update.pos or self._punched then
			local yaw = 0
			if dir.x < 0 then
				yaw = 0.5
			elseif dir.x > 0 then
				yaw = 1.5
			elseif dir.z < 0 then
				yaw = 1
			end
			self.object:set_yaw(yaw * math.pi)

			-- Handle tilting on slopes
			local yaw_rad = yaw * math.pi
			local target_pitch = 0
			if dir.y ~= 0 then
				target_pitch = dir.y * (math.pi / 4)
			end

			self.object:set_rotation(vector.new(target_pitch, yaw_rad, 0))
		end

		if self._punched then
			self._punched = false
		end

		if not (update.vel or update.pos) then
			return
		end


		local anim = {x=0, y=0}
		if dir.y == -1 then
			anim = {x=1, y=1}
		elseif dir.y == 1 then
			anim = {x=2, y=2}
		end
		self.object:set_animation(anim, 1, 0)

		self.object:set_velocity(vel)
		if update.pos then
			self.object:set_pos(pos)
		end

		-- stopped on "mcl_minecarts:golden_rail_on"
		if vector.equals(vel, {x=0, y=0, z=0}) and restart_pos then
			local dir = mcl_minecarts:get_start_direction(restart_pos)
			if dir then
				mcl_minecarts:set_velocity(self, dir)
			end
		end
	end

	function cart:get_staticdata()
		return core.serialize({_railtype = self._railtype, _hopper_enabled = self._hopper_enabled})
	end

	core.register_entity(entity_id, cart)
	return core.registered_entities[entity_id]
end

-- What the rails do to minecarts, every game tick (the parts of
-- AbstractMinecart.tick and Entity.checkInsideBlocks that involve rails).

-- AbstractMinecart.getCurrentBlockPosOrRailBelow
local function get_rail_pos(pos)
	local p = vector.round(pos)
	if core.get_item_group(core.get_node(p).name, "rail") == 0 then
		local below = vector.offset(p, 0, -1, 0)
		if core.get_item_group(core.get_node(below).name, "rail") ~= 0 then
			return below
		end
	end
	return p
end

local detector_rails = {
	["mcl_minecarts:detector_rail"] = true,
	["mcl_minecarts:detector_rail_on"] = true,
}

local function minecart_rail_tick(self)
	local pos = self.object:get_pos()
	local railpos = get_rail_pos(pos)
	local node = mcl_waterlogging.as_dry(core.get_node(railpos))
	if node.name == "mcl_minecarts:activator_rail" or node.name == "mcl_minecarts:activator_rail_on" then
		-- activateMinecart(x, y, z, state.getValue(POWERED))
		local powered = node.name == "mcl_minecarts:activator_rail_on"
		if self.name == "mcl_minecarts:hopper_minecart" then
			self._hopper_enabled = not powered
		end
		if powered and self.on_activate_by_rail then
			self:on_activate_by_rail()
		end
	elseif node.name == "mcl_minecarts:golden_rail_on" then
		-- A powered rail starts a standing minecart away from a block next to it
		-- (OldMinecartBehavior.moveAlongTrack)
		if not self._punched and vector.equals(self.object:get_velocity(), vector.zero()) then
			local dir = mcl_minecarts:get_start_direction(railpos)
			if dir then
				mcl_minecarts:set_velocity(self, dir)
			end
		end
	end
	-- Entity.checkInsideBlocks: entityInside of the detector rails it touches
	local x1, y1, z1, x2, y2, z2 = mcl_minecarts.get_minecart_box(pos)
	local floor, eps = math.floor, 1e-5
	for x = floor(x1 + 0.5 + eps), floor(x2 + 0.5 - eps) do
		for y = floor(y1 + 0.5 + eps), floor(y2 + 0.5 - eps) do
			for z = floor(z1 + 0.5 + eps), floor(z2 + 0.5 - eps) do
				local p = vector.new(x, y, z)
				local n = mcl_redstone.get_node(p)
				if detector_rails[n.name] then
					mcl_minecarts.detector_rail_entity_inside(p, n)
				end
			end
		end
	end
end

mcl_redstone.register_on_game_tick(function()
	local n = #active_carts
	local kept = {}
	for i = 1, n do
		local cart = active_carts[i]
		if not cart._deactivated and cart.object:get_pos() then
			kept[#kept + 1] = cart
			mcl_redstone._begin()
			local ok, err = pcall(minecart_rail_tick, cart)
			mcl_redstone._end()
			if not ok then
				core.log("error", "[mcl_minecarts] " .. tostring(err))
			end
		end
	end
	for i = n + 1, #active_carts do
		kept[#kept + 1] = active_carts[i]
	end
	active_carts = kept
end)

-- Place a minecart at pointed_thing
function mcl_minecarts.place_minecart(itemstack, pointed_thing, placer)
	if pointed_thing.type ~= "node" then
		return
	end

	local railpos, node
	if mcl_minecarts:is_rail(pointed_thing.under) then
		railpos = pointed_thing.under
		node = core.get_node(pointed_thing.under)
	elseif mcl_minecarts:is_rail(pointed_thing.above) then
		railpos = pointed_thing.above
		node = core.get_node(pointed_thing.above)
	else
		return
	end

	local entity_id = entity_mapping[itemstack:get_name()]
	local cart = core.add_entity(railpos, entity_id)
	if not cart or not cart:get_pos() then return end
	local railtype = core.get_item_group(node.name, "connect_to_raillike")
	local le = cart:get_luaentity()
	if le then
		le._railtype = railtype
	end
	local cart_dir
	if node.name == "mcl_minecarts:golden_rail_on" then
		cart_dir = mcl_minecarts:get_start_direction(railpos)
	end
	if cart_dir then
		mcl_minecarts:set_velocity(le, cart_dir)
	else
		cart_dir = mcl_minecarts:get_rail_direction(railpos, {x=1, y=0, z=0}, nil, nil, railtype)
	end
	cart:set_yaw(core.dir_to_yaw(cart_dir))

	-- MinecartItem.useOn (dispensers place minecarts without a game event)
	if placer and mcl_gameevent then
		mcl_gameevent.emit("entity_place", railpos, {
			source = type(placer) == "userdata" and placer or nil,
			node = core.get_node(vector.offset(railpos, 0, -1, 0)),
		})
	end

	local pname = ""
	if placer then
		pname = placer:get_player_name()
	end
	if not core.is_creative_enabled(pname) then
		itemstack:take_item()
	end
	return itemstack
end


local function register_craftitem(itemstring, entity_id, description, tt_help, longdesc, usagehelp, icon, creative)
	entity_mapping[itemstring] = entity_id

	local groups = { minecart = 1, transport = 1 }
	if creative == false then
		groups.not_in_creative_inventory = 1
	end
	local def = {
		stack_max = 1,
		on_place = function(itemstack, placer, pointed_thing)
			if pointed_thing.type ~= "node" then
				return
			end

			-- Call on_rightclick if the pointed node defines it
			local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
			if rc then return rc end

			return mcl_minecarts.place_minecart(itemstack, pointed_thing, placer)
		end,
		_on_dispense = function(stack, _, droppos, dropnode, _)
			-- Place minecart as entity on rail. If there's no rail, just drop it.
			local placed
			if core.get_item_group(dropnode.name, "rail") ~= 0 then
				-- FIXME: This places minecarts even if the spot is already occupied
				local pointed_thing = { under = droppos, above = { x=droppos.x, y=droppos.y+1, z=droppos.z } }
				placed = mcl_minecarts.place_minecart(stack, pointed_thing)
			end
			if placed == nil then
				-- Drop item
				core.add_item(droppos, stack)
			end
		end,
		groups = groups,
	}
	def.description = description
	def._tt_help = tt_help
	def._doc_items_longdesc = longdesc
	def._doc_items_usagehelp = usagehelp
	def.inventory_image = icon
	def.wield_image = icon
	core.register_craftitem(itemstring, def)
end

--[[
Register a minecart
* itemstring: Itemstring of minecart item
* entity_id: ID of minecart entity
* description: Item name / description
* longdesc: Long help text
* usagehelp: Usage help text
* mesh: Minecart mesh
* textures: Minecart textures table
* icon: Item icon
* drop: Dropped items after destroying minecart
* on_rightclick: Called after rightclick
* on_activate_by_rail: Called when above activator rail
* creative: If false, don't show in Creative Inventory
]]
local function register_minecart(itemstring, entity_id, description, tt_help, longdesc, usagehelp, mesh, textures, icon, drop, on_rightclick, on_activate_by_rail, creative)
	local entity = register_entity(entity_id, mesh, textures, drop, on_rightclick, on_activate_by_rail)
	tt_help = (tt_help and tt_help .. "\n" or "") .. S("Sneak-click to remove")
	register_craftitem(itemstring, entity_id, description, tt_help, longdesc, usagehelp, icon, creative)
	doc.sub.identifier.register_object(entity_id, "craftitems", itemstring)
	return entity
end

-- Minecart
register_minecart(
	"mcl_minecarts:minecart",
	"mcl_minecarts:minecart",
	S("Minecart"),
	S("Vehicle for fast travel on rails"),
	S("Minecarts can be used for a quick transportion on rails.") .. "\n" ..
	S("Minecarts only ride on rails and always follow the tracks. At a T-junction with no straight way ahead, they turn left. The speed is affected by the rail type."),
	S("You can place the minecart on rails. Right-click it to enter it. Punch it to get it moving.") .. "\n" ..
	S("To obtain the minecart, punch it while holding down the sneak key.") .. "\n" ..
	S("If it moves over a powered activator rail, you'll get ejected."),
	"mcl_minecarts_minecart.b3d",
	{"mcl_minecarts_minecart.png"},
	"mcl_minecarts_minecart_normal.png",
	{"mcl_minecarts:minecart"},
	function(self, clicker)
		if not clicker or not clicker:is_player() then
			return
		end
		local name = clicker:get_player_name()
		if self._driver and name == self._driver then
			detach_driver(self)
		elseif not self._driver then
			self._driver = name
			self._start_pos = self.object:get_pos()
			mcl_player.players[clicker].attached = true
			clicker:set_attach(self.object, "", {x=0, y=-1.75, z=-2}, {x=0, y=0, z=0})
			mcl_attachments.spawn_attachment_entity (clicker)
			ge_ride(self, "entity_mount", clicker)
			core.after(0.2, function(name)
				local player = core.get_player_by_name(name)
				if player then
					mcl_player.player_set_animation(player, "sit" , 30)
					mcl_title.set(clicker, "actionbar", {text=S("Sneak to dismount"), color="white", stay=60})
				end
			end, name)
		end
	end, activate_normal_minecart
)

-- Minecart with Chest
local minecart_with_chest = register_minecart(
	"mcl_minecarts:chest_minecart",
	"mcl_minecarts:chest_minecart",
	S("Minecart with Chest"),
	nil, nil, nil,
	"mcl_minecarts_minecart_chest.b3d",
	{ "mcl_chests_normal.png", "mcl_minecarts_minecart.png" },
	"mcl_minecarts_minecart_chest.png",
	{"mcl_minecarts:minecart", "mcl_chests:chest"},
	nil, nil, true)
mcl_entity_invs.register_inv("mcl_minecarts:chest_minecart","Minecart",27,false,true)

function minecart_with_chest:_on_show_entity_inv (player)
	-- MinecartChest.interact
	if mcl_gameevent then
		mcl_gameevent.emit_entity (self.object, "container_open",
			type (player) == "userdata" and player or false)
	end
	mobs_mc.enrage_piglins (player, true)
end

-- MinecartChest.stopOpen
core.register_on_player_receive_fields (function (player, formname, fields)
	if mcl_gameevent and fields.quit and formname:sub (1, 11) == "entity_inv_" then
		local ent = mcl_entity_invs.get_entity_by_invname (formname)
		if ent and ent.name == "mcl_minecarts:chest_minecart" and ent.object:get_pos () then
			mcl_gameevent.emit ("container_close", ent.object:get_pos (), {source = player})
		end
	end
end)

function minecart_with_chest:_on_destroy_minecart (player)
	mobs_mc.enrage_piglins (player, true)
end

-- Minecart with Furnace
register_minecart(
	"mcl_minecarts:furnace_minecart",
	"mcl_minecarts:furnace_minecart",
	S("Minecart with Furnace"),
	nil,
	S("A minecart with furnace is a vehicle that travels on rails. It can propel itself with fuel."),
	S("Place it on rails. If you give it some coal, the furnace will start burning for a long time and the minecart will be able to move itself. Punch it to get it moving.") .. "\n" ..
	S("To obtain the minecart and furnace, punch them while holding down the sneak key."),

	"mcl_minecarts_minecart_block.b3d",
	{
		"default_furnace_top.png",
		"default_furnace_top.png",
		"default_furnace_front.png",
		"default_furnace_side.png",
		"default_furnace_side.png",
		"default_furnace_side.png",
		"mcl_minecarts_minecart.png",
	},
	"mcl_minecarts_minecart_furnace.png",
	{"mcl_minecarts:minecart", "mcl_furnaces:furnace"},
	-- Feed furnace with coal
	function(self, clicker)
		if not clicker or not clicker:is_player() then
			return
		end
		if not self._fueltime then
			self._fueltime = 0
		end
		local held = clicker:get_wielded_item()
		if core.get_item_group(held:get_name(), "coal") == 1 then
			self._fueltime = self._fueltime + 180

			if not core.is_creative_enabled(clicker:get_player_name()) then
				held:take_item()
				local index = clicker:get_wield_index()
				local inv = clicker:get_inventory()
				inv:set_stack("main", index, held)
			end
			self.object:set_properties({textures =
			{
				"default_furnace_top.png",
				"default_furnace_top.png",
				"default_furnace_front_active.png",
				"default_furnace_side.png",
				"default_furnace_side.png",
				"default_furnace_side.png",
				"mcl_minecarts_minecart.png",
			}})
		end
	end, nil, true
)

-- Minecart with Command Block
register_minecart(
	"mcl_minecarts:command_block_minecart",
	"mcl_minecarts:command_block_minecart",
	S("Minecart with Command Block"),
	nil, nil, nil,
	"mcl_minecarts_minecart_block.b3d",
	{
		"jeija_commandblock_off.png^[verticalframe:2:0",
		"jeija_commandblock_off.png^[verticalframe:2:0",
		"jeija_commandblock_off.png^[verticalframe:2:0",
		"jeija_commandblock_off.png^[verticalframe:2:0",
		"jeija_commandblock_off.png^[verticalframe:2:0",
		"jeija_commandblock_off.png^[verticalframe:2:0",
		"mcl_minecarts_minecart.png",
	},
	"mcl_minecarts_minecart_command_block.png",
	{"mcl_minecarts:minecart"},
	nil, nil, false
)

-- Minecart with Hopper
register_minecart(
	"mcl_minecarts:hopper_minecart",
	"mcl_minecarts:hopper_minecart",
	S("Minecart with Hopper"),
	nil, nil, nil,
	"mcl_minecarts_minecart_hopper.b3d",
	{
		"mcl_hoppers_hopper_inside.png",
		"mcl_minecarts_minecart.png",
		"mcl_hoppers_hopper_outside.png",
		"mcl_hoppers_hopper_top.png",
	},
	"mcl_minecarts_minecart_hopper.png",
	{"mcl_minecarts:minecart", "mcl_hoppers:hopper"},
	nil, nil, true
)
mcl_entity_invs.register_inv("mcl_minecarts:hopper_minecart", "Hopper Minecart", 5, false, true)

-- Minecart with TNT
register_minecart(
	"mcl_minecarts:tnt_minecart",
	"mcl_minecarts:tnt_minecart",
	S("Minecart with TNT"),
	S("Vehicle for fast travel on rails").."\n"..S("Can be ignited by tools or powered activator rail"),
	S("A minecart with TNT is an explosive vehicle that travels on rail."),
	S("Place it on rails. Punch it to move it. The TNT is ignited with a flint and steel or when the minecart is on an powered activator rail.") .. "\n" ..
	S("To obtain the minecart and TNT, punch them while holding down the sneak key. You can't do this if the TNT was ignited."),
	"mcl_minecarts_minecart_block.b3d",
	{
		"default_tnt_top.png",
		"default_tnt_bottom.png",
		"default_tnt_side.png",
		"default_tnt_side.png",
		"default_tnt_side.png",
		"default_tnt_side.png",
		"mcl_minecarts_minecart.png",
	},
	"mcl_minecarts_minecart_tnt.png",
	{"mcl_minecarts:minecart", "mcl_tnt:tnt"},
	-- Ingite
	function(self, clicker)
		if not clicker or not clicker:is_player() then
			return
		end
		if self._boomtimer then
			return
		end
		local held = clicker:get_wielded_item()
		if core.get_item_group(held:get_name(),"flint_and_steel") > 0 then
			if not core.is_creative_enabled(clicker:get_player_name()) then
				held:add_wear(65535/65) -- 65 uses
				local index = clicker:get_wield_index()
				local inv = clicker:get_inventory()
				inv:set_stack("main", index, held)
			end
			activate_tnt_minecart(self)
		end
	end, activate_tnt_minecart)


core.register_craft({
	output = "mcl_minecarts:minecart",
	recipe = {
		{"mcl_core:iron_ingot", "", "mcl_core:iron_ingot"},
		{"mcl_core:iron_ingot", "mcl_core:iron_ingot", "mcl_core:iron_ingot"},
	},
})

core.register_craft({
	output = "mcl_minecarts:tnt_minecart",
	recipe = {
		{"mcl_tnt:tnt"},
		{"mcl_minecarts:minecart"},
	},
})

core.register_craft({
	output = "mcl_minecarts:furnace_minecart",
	recipe = {
		{"mcl_furnaces:furnace"},
		{"mcl_minecarts:minecart"},
	},
})

core.register_craft({
	output = "mcl_minecarts:hopper_minecart",
	recipe = {
		{"mcl_hoppers:hopper"},
		{"mcl_minecarts:minecart"},
	},
})


core.register_craft({
	output = "mcl_minecarts:chest_minecart",
	recipe = {
		{"mcl_chests:chest"},
		{"mcl_minecarts:minecart"},
	},
})


mcl_wip.register_wip_item("mcl_minecarts:chest_minecart")
mcl_wip.register_wip_item("mcl_minecarts:furnace_minecart")
mcl_wip.register_wip_item("mcl_minecarts:command_block_minecart")
