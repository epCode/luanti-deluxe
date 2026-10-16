------------------------------------------------------------------------
-- Sculk sensor and calibrated sculk sensor (SculkSensorBlock,
-- CalibratedSculkSensorBlock and their block entities)
--
-- State: the phase is in the node name (inactive / _active / _cooldown),
-- the power in param2 (sensor: param2 = power; calibrated: 4dir facing +
-- 4 * power). Block entity data in the node metadata: "listener"
-- (VibrationSystem.Data) and "last_vibration_frequency".
------------------------------------------------------------------------

local S = mcl_sculk.S
local R = mcl_redstone
local G = mcl_gameevent
local floor = math.floor
local random = math.random

local ACTIVE_TICKS = 30
local COOLDOWN_TICKS = 10

-- SculkSensorBlock.RESONANCE_PITCH_BEND (NoteBlock.getPitchFromNote)
local RESONANCE_PITCH_BEND = {}
do
	local tones = {0, 0, 2, 4, 6, 7, 9, 10, 12, 14, 15, 18, 19, 21, 22, 24}
	for i = 0, 15 do
		RESONANCE_PITCH_BEND[i] = 2 ^ ((tones[i + 1] - 12) / 12)
	end
end

local KINDS = {
	sensor = {
		prefix = "mcl_sculk:sensor",
		block = "mcl_sculk:sensor",
		radius = 8,
		active_ticks = ACTIVE_TICKS,
	},
	calibrated = {
		prefix = "mcl_sculk:calibrated_sensor",
		block = "mcl_sculk:calibrated_sensor",
		radius = 16,
		active_ticks = 10,
		calibrated = true,
	},
}

local kind_by_name = {}
local phase_by_name = {}

local function node_name(kind, phase)
	return kind.prefix .. (phase == "inactive" and "" or "_" .. phase)
end

local function phase_of(node)
	return phase_by_name[node.name]
end

local function power_of(node, kind)
	kind = kind or kind_by_name[node.name]
	if kind.calibrated then
		return floor(node.param2 / 4) % 16
	end
	return node.param2 % 16
end

local function facing_of(node)
	return R.fourdir_to_dir[node.param2 % 4]
end

local function with_state(node, phase, power)
	local kind = kind_by_name[node.name]
	local param2 = power
	if kind.calibrated then
		param2 = node.param2 % 4 + power * 4
	end
	return {name = node_name(kind, phase), param2 = param2}
end

-- SculkSensorBlock.canActivate
local function can_activate(node)
	return phase_of(node) == "inactive"
end
mcl_sculk.sensor_can_activate = can_activate

-- SculkSensorBlock.updateNeighbours
local function update_neighbours(pos, node)
	local block = R.block_id(node.name)
	R.update_neighbors_at(pos, block)
	R.update_neighbors_at(vector.offset(pos, 0, -1, 0), block)
end

-- SculkSensorBlock.deactivate
local function deactivate(pos, node)
	local kind = kind_by_name[node.name]
	R.set_block(pos, with_state(node, "cooldown", 0), 3)
	R.schedule_tick(pos, kind.block, COOLDOWN_TICKS)
	update_neighbours(pos, node)
end

-- SculkSensorBlock.tryResonateVibration
local function try_resonate(source, pos, frequency)
	for _, d in ipairs(mcl_sculk.DIRECTIONS) do
		local rpos = R.rel(pos, d)
		local rnode = core.get_node(rpos)
		if mcl_sculk.vibration_resonators[rnode.name] then
			G.emit(G.resonance_event(frequency), rpos, {source = source, node = rnode})
			mcl_sculk.play("block.amethyst_block.resonate", rpos, 1.0, RESONANCE_PITCH_BEND[frequency])
		end
	end
end

-- SculkSensorBlock.activate
local function activate(source, pos, node, power, frequency)
	local kind = kind_by_name[node.name]
	R.set_block(pos, with_state(node, "active", power), 3)
	R.schedule_tick(pos, kind.block, kind.active_ticks)
	update_neighbours(pos, node)
	try_resonate(source, pos, frequency)
	G.emit("sculk_sensor_tendrils_clicking", pos, {source = source})
	mcl_sculk.play("block.sculk_sensor.clicking", pos, 1.0, random() * 0.2 + 0.8)
end

------------------------------------------------------------------------
-- Block entity (SculkSensorBlockEntity / CalibratedSculkSensorBlockEntity)
------------------------------------------------------------------------

local function save(be)
	local meta = core.get_meta(be.pos)
	meta:set_string("listener", G.serialize_vibration_data(be.data))
end

local function make_user(be, kind)
	local user = {
		radius = kind.radius,
		can_trigger_avoid_vibration = true,
		requires_adjacent_chunks = true,
	}
	function user:get_position()
		return be.pos
	end
	-- CalibratedSculkSensorBlockEntity.VibrationUser.getBackSignal
	local function back_signal(node)
		local d = R.opposite[facing_of(node)]
		return R.get_signal(R.rel(be.pos, d), d)
	end
	function user:can_receive(node_pos, event, _)
		local node = core.get_node(be.pos)
		if not kind_by_name[node.name] then
			return false
		end
		if kind.calibrated then
			local comparison = back_signal(node)
			if comparison ~= 0 and G.get_frequency(event) ~= comparison then
				return false
			end
		end
		if vector.equals(node_pos, be.pos) and (event == "block_destroy" or event == "block_place") then
			return false
		end
		if G.get_frequency(event) == 0 then
			return false
		end
		return can_activate(node)
	end
	function user:on_receive(_, event, source, _, distance)
		local node = core.get_node(be.pos)
		if kind_by_name[node.name] and can_activate(node) then
			local frequency = G.get_frequency(event)
			core.get_meta(be.pos):set_int("last_vibration_frequency", frequency)
			local power = G.redstone_strength_for_distance(distance, self.radius)
			activate(source, be.pos, node, power, frequency)
		end
	end
	function user:on_data_changed()
		save(be)
	end
	return user
end

local function register_block_entity(kind)
	local names = {node_name(kind, "inactive"), node_name(kind, "active"), node_name(kind, "cooldown")}
	return mcl_sculk.register_block_entity(names, {
		keep_on_destruct = true,
		create = function(pos)
			local be = {}
			be.pos = pos
			be.data = G.deserialize_vibration_data(core.get_meta(pos):get_string("listener"))
			be.user = make_user(be, kind)
			be.listener = G.new_vibration_listener(be.data, be.user)
			be.listener.node_check = function(node)
				return kind_by_name[node.name] == kind
			end
			G.add_block_listener(pos, be.listener)
			return be
		end,
		-- VibrationSystem.Ticker.tick
		tick = function(be)
			G.vibration_tick(be.data, be.user)
		end,
	})
end

------------------------------------------------------------------------
-- Nodes
------------------------------------------------------------------------

local function tendril_tile(active)
	if active then
		return {name = "mcl_sculk_sensor_tendril_active.png", backface_culling = false,
			animation = {type = "vertical_frames", aspect_w = 16, aspect_h = 16, length = 0.8}}
	end
	return {name = "mcl_sculk_sensor_tendril_inactive.png", backface_culling = false,
		animation = {type = "vertical_frames", aspect_w = 16, aspect_h = 16, length = 1.6}}
end

local function plain(name)
	return {name = name, backface_culling = false}
end

-- SculkSensorBlock.SHAPE: Block.column(16, 0, 8)
local SHAPE = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0, 0.5}}

local function register_kind(kind, desc, longdesc)
	local get_be
	for _, phase in ipairs({"inactive", "active", "cooldown"}) do
		local name = node_name(kind, phase)
		kind_by_name[name] = kind
		phase_by_name[name] = phase
		-- blockstates: cooldown shows the active model
		local active = phase ~= "inactive"
		local tiles
		if kind.calibrated then
			tiles = {plain("mcl_sculk_sensor_side.png"), plain("mcl_sculk_calibrated_sensor_input_side.png"),
				plain("mcl_sculk_calibrated_sensor_top.png"), plain("mcl_sculk_sensor_bottom.png"),
				tendril_tile(active), plain("mcl_sculk_calibrated_sensor_amethyst.png")}
		else
			tiles = {plain("mcl_sculk_sensor_side.png"), plain("mcl_sculk_sensor_top.png"),
				plain("mcl_sculk_sensor_bottom.png"), tendril_tile(active)}
		end
		core.register_node(name, {
			description = desc,
			_doc_items_longdesc = longdesc,
			_doc_items_create_entry = phase == "inactive",
			drawtype = "mesh",
			mesh = kind.calibrated and "mcl_sculk_calibrated_sensor.obj" or "mcl_sculk_sensor.obj",
			tiles = tiles,
			use_texture_alpha = "clip",
			paramtype = "light",
			paramtype2 = kind.calibrated and "4dir" or "none",
			sunlight_propagates = true,
			light_source = 1,
			selection_box = SHAPE,
			collision_box = SHAPE,
			groups = {handy = 1, hoey = 1, sculk = 1, sculk_sensor = kind.calibrated and 2 or 1,
				redstone = 1,
				not_in_creative_inventory = phase == "inactive" and 0 or 1},
			sounds = mcl_sculk.sounds.sensor,
			is_ground_content = false,
			drop = "",
			_mcl_silk_touch_drop = {node_name(kind, "inactive")},
			after_dig_node = function(pos, _, _, digger)
				mcl_sculk.drop_experience(pos, digger, 5)
			end,
			_mcl_hardness = 1.5,
			_mcl_blast_resistance = 1.5,
			_mcl_sculk_step_on = function(pos, node, obj)
				-- SculkSensorBlock.stepOn
				if not can_activate(node) then
					return
				end
				local le = obj:get_luaentity()
				if le and le.name == "mobs_mc:warden" then
					return
				end
				local be = get_be(pos)
				if be.user:can_receive(pos, "step", {node = node}) then
					be.listener:force_schedule("step", {source = obj}, obj:get_pos())
				end
			end,
			_mcl_redstone = {
				block = kind.block,
				signal_source = true,
				own_signal = function(_, n)
					return power_of(n)
				end,
				get_signal = function(_, n, d)
					-- CalibratedSculkSensorBlock.getSignal: not towards its facing
					if kind.calibrated and d == facing_of(n) then
						return 0
					end
					return power_of(n)
				end,
				get_direct_signal = function(_, n, d)
					if d ~= R.UP then
						return 0
					end
					if kind.calibrated and d == facing_of(n) then
						return 0
					end
					return power_of(n)
				end,
				analog_output = function(pos, n)
					if phase_of(n) == "active" then
						return core.get_meta(pos):get_int("last_vibration_frequency")
					end
					return 0
				end,
				-- SculkSensorBlock.tick
				tick = function(pos, n)
					local p = phase_of(n)
					if p ~= "active" then
						if p == "cooldown" then
							R.set_block(pos, with_state(n, "inactive", power_of(n)), 3)
							mcl_sculk.play("block.sculk_sensor.clicking_stop", pos, 1.0, random() * 0.2 + 0.8)
						end
					else
						deactivate(pos, n)
					end
				end,
				-- SculkSensorBlock.onPlace
				on_place = function(pos, n, oldnode)
					if R.block_id(oldnode.name) ~= kind.block and power_of(n) > 0
							and not R.has_scheduled_tick(pos, kind.block) then
						R.set_block(pos, with_state(n, phase_of(n), 0), 18)
					end
				end,
				-- SculkSensorBlock.affectNeighborsAfterRemoval
				affect_neighbors_after_removal = function(pos, oldnode)
					if phase_of(oldnode) == "active" then
						update_neighbours(pos, oldnode)
					end
				end,
				-- SculkSensorBlock.animateTick
				animate = function(pos, n, player_name)
					if phase_of(n) ~= "active" then
						return
					end
					local d = mcl_sculk.DIRECTIONS[random(1, 6)]
					if d == R.UP or d == R.DOWN then
						return
					end
					local v = R.dirvec[d]
					local x = pos.x + (v.x == 0 and 0.5 - random() or v.x * 0.6)
					local y = pos.y - 0.25
					local z = pos.z + (v.z == 0 and 0.5 - random() or v.z * 0.6)
					mcl_sculk.sculk_to_redstone_dust(player_name, vector.new(x, y, z), 0, random() * 0.04, 0)
				end,
			},
		})
	end
	get_be = register_block_entity(kind)
end

register_kind(KINDS.sensor, S("Sculk Sensor"),
	S("A sculk sensor detects vibrations within 8 blocks and gives off a redstone signal that is stronger the closer the vibration was. A comparator reads the frequency of the last vibration."))
register_kind(KINDS.calibrated, S("Calibrated Sculk Sensor"),
	S("A calibrated sculk sensor detects vibrations within 16 blocks. A redstone signal into its amethyst side makes it listen only to vibrations of that frequency."))

core.register_craft({
	output = "mcl_sculk:calibrated_sensor",
	recipe = {
		{"", "mcl_amethyst:amethyst_shard", ""},
		{"mcl_amethyst:amethyst_shard", "mcl_sculk:sensor", "mcl_amethyst:amethyst_shard"},
	},
})

mcl_sculk.sensor_kind_by_name = kind_by_name
mcl_sculk.sensor_power = power_of
