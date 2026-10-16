local S = core.get_translator(core.get_current_modname())

mcl_torches.register_torch({
	name = "redstone_torch_off",
	description = S("Redstone Torch (off)"),
	doc_items_longdesc = S("A redstone torch is a redstone component which can be used to invert a redstone signal. It supplies its surrounding blocks with redstone power, except for the block it is attached to. A redstone torch is normally lit, but it can also be turned off by powering the block it is attached to. While unlit, a redstone torch does not power anything."),
	doc_items_usagehelp = S("Redstone torches can be placed at the side and on the top of full solid opaque blocks."),
	icon = "jeija_torches_off.png",
	tiles = {"jeija_torches_off.png"},
	light = 0,
	groups = {dig_immediate=3, dig_by_water=1, redstone_torch=2, not_in_creative_inventory=1},
	sounds = mcl_sounds.node_sound_wood_defaults(),
	drop = "mcl_redstone_torch:redstone_torch_on",
})

mcl_torches.register_torch({
	name = "redstone_torch_on",
	description = S("Redstone Torch"),
	icon = "jeija_torches_on.png",
	tiles = {"jeija_torches_on.png"},
	light = 7,
	groups = {dig_immediate=3, dig_by_water=1, redstone_torch=1},
	sounds = mcl_sounds.node_sound_wood_defaults(),
})

-- Port of Minecraft's RedstoneTorchBlock and RedstoneWallTorchBlock.

local DOWN, UP = mcl_redstone.DOWN, mcl_redstone.UP
local rel = mcl_redstone.rel
local get_node = mcl_redstone.get_node

local RECENT_TOGGLE_TIMER = 60
local MAX_RECENT_TOGGLES = 8
local RESTART_DELAY = 160
local TOGGLE_DELAY = 2

-- RedstoneTorchBlock.RECENT_TOGGLES: {pos, when} in toggle order
local recent_toggles = {}

local function is_toggled_too_frequently(pos, add)
	if add then
		recent_toggles[#recent_toggles + 1] = {pos = vector.copy(pos), when = mcl_redstone.get_game_time()}
	end
	local count = 0
	for _, t in ipairs(recent_toggles) do
		if vector.equals(t.pos, pos) then
			count = count + 1
			if count >= MAX_RECENT_TOGGLES then
				return true
			end
		end
	end
	return false
end

-- The direction from the torch towards the block it is attached to.
local function attached_dir(node)
	return mcl_redstone.dir_index(core.wallmounted_to_dir(node.param2)) or DOWN
end

local function is_lit(node)
	return node.name:find("_on", 1, true) ~= nil
end

-- RedstoneTorchBlock.hasNeighborSignal / RedstoneWallTorchBlock.hasNeighborSignal
local function has_neighbor_signal(pos, node)
	local a = attached_dir(node)
	return mcl_redstone.has_signal(rel(pos, a), a)
end

local function notify_neighbors(pos, block)
	for d = 0, 5 do
		mcl_redstone.update_neighbors_at(rel(pos, d), block)
	end
end

local function toggled(node)
	local ndef = core.registered_nodes[node.name]
	return {name = is_lit(node) and ndef._mcl_redstone_torch_off or ndef._mcl_redstone_torch_on, param2 = node.param2}
end

local function can_survive(pos, node)
	local a = attached_dir(node)
	local spos = rel(pos, a)
	local snode = get_node(spos)
	if a == DOWN then
		-- BaseTorchBlock: Block.canSupportCenter(level, below, UP)
		return mcl_redstone.can_support_center(spos, snode, UP)
	end
	-- WallTorchBlock.canSurvive: the wall's face towards the torch is sturdy
	return mcl_redstone.is_face_sturdy(spos, snode, mcl_redstone.opposite[a], "full")
end

local function make_behaviour(block, lit)
	return {
		block = block,
		signal_source = true,
		push_reaction = "destroy",
		own_signal = function()
			return lit and 15 or 0
		end,
		get_signal = function(pos, node, d)
			if not lit then
				return 0
			end
			-- Floor torches do not power up into the block above sideways,
			-- wall torches do not power the block they hang on.
			local facing = mcl_redstone.opposite[attached_dir(node)]
			return d ~= facing and 15 or 0
		end,
		get_direct_signal = function(pos, node, d)
			if not lit or d ~= DOWN then
				return 0
			end
			return 15
		end,
		on_place = function(pos, node)
			notify_neighbors(pos, block)
		end,
		affect_neighbors_after_removal = function(pos, node, moved)
			if not moved then
				notify_neighbors(pos, block)
			end
		end,
		-- RedstoneTorchBlock/RedstoneWallTorchBlock.animateTick
		animate = lit and function(pos, node, name)
			local p = vector.new(pos.x + (math.random() - 0.5) * 0.2, pos.y + 0.2 + (math.random() - 0.5) * 0.2,
				pos.z + (math.random() - 0.5) * 0.2)
			local a = attached_dir(node)
			if a ~= DOWN then
				local v = mcl_redstone.dirvec[a]
				p = vector.offset(p, 0.27 * v.x, 0.22, 0.27 * v.z)
			end
			mcl_redstone.dust_particle(name, p, mcl_redstone.REDSTONE_DUST)
		end or nil,
		update_shape = function(pos, node, d)
			if d == attached_dir(node) and not can_survive(pos, node) then
				return {name = "air"}
			end
		end,
		neighbor_changed = function(pos, node)
			if lit == has_neighbor_signal(pos, node) and not mcl_redstone.will_tick_this_tick(pos, block) then
				mcl_redstone.schedule_tick(pos, block, TOGGLE_DELAY)
			end
		end,
		tick = function(pos, node)
			local signal = has_neighbor_signal(pos, node)
			local now = mcl_redstone.get_game_time()
			while recent_toggles[1] and now - recent_toggles[1].when > RECENT_TOGGLE_TIMER do
				table.remove(recent_toggles, 1)
			end
			if lit then
				if signal then
					mcl_redstone.set_block(pos, toggled(node), 3)
					if is_toggled_too_frequently(pos, true) then
						-- LevelEvent 1502: redstone torch burnout
						core.sound_play("fire_extinguish_flame", {pos = pos, gain = 0.5, max_hear_distance = 16}, true)
						core.add_particlespawner({
							amount = 5, time = 0.1,
							minpos = vector.offset(pos, -0.25, 0.1, -0.25), maxpos = vector.offset(pos, 0.25, 0.3, 0.25),
							minvel = vector.new(0, 0.2, 0), maxvel = vector.new(0, 0.4, 0),
							minexptime = 0.5, maxexptime = 1, minsize = 1, maxsize = 2,
							texture = "mcl_particles_smoke.png",
						})
						mcl_redstone.schedule_tick(pos, mcl_redstone.block_id(get_node(pos).name), RESTART_DELAY)
					end
				end
			elseif not signal and not is_toggled_too_frequently(pos, false) then
				mcl_redstone.set_block(pos, toggled(node), 3)
			end
		end,
	}
end

for _, wall in pairs({"", "_wall"}) do
	local block = "mcl_redstone_torch:redstone_torch" .. wall
	for _, state in pairs({"on", "off"}) do
		core.override_item("mcl_redstone_torch:redstone_torch_" .. state .. wall, {
			_mcl_redstone_torch_on = "mcl_redstone_torch:redstone_torch_on" .. wall,
			_mcl_redstone_torch_off = "mcl_redstone_torch:redstone_torch_off" .. wall,
			_mcl_redstone = make_behaviour(block, state == "on"),
		})
	end
end

core.register_node("mcl_redstone_torch:redstoneblock", {
	description = S("Block of Redstone"),
	_tt_help = S("Provides redstone power"),
	_doc_items_longdesc = S("A block of redstone permanently supplies redstone power to its surrounding blocks."),
	tiles = {"redstone_redstone_block.png"},
	stack_max = 64,
	groups = {pickaxey=1},
	sounds = mcl_sounds.node_sound_stone_defaults(),
	is_ground_content = false,
	-- PoweredBlock
	_mcl_redstone = {
		signal_source = true,
		conductor = false,
		get_signal = function()
			return 15
		end,
		own_signal = function()
			return 15
		end,
	},
	_mcl_blast_resistance = 6,
	_mcl_hardness = 5,
})

core.register_craft({
	output = "mcl_redstone_torch:redstone_torch_on",
	recipe = {
		{"mcl_redstone:redstone"},
		{"mcl_core:stick"},}
})

core.register_craft({
	output = "mcl_redstone_torch:redstoneblock",
	recipe = {
		{"mcl_redstone:redstone","mcl_redstone:redstone","mcl_redstone:redstone"},
		{"mcl_redstone:redstone","mcl_redstone:redstone","mcl_redstone:redstone"},
		{"mcl_redstone:redstone","mcl_redstone:redstone","mcl_redstone:redstone"},
	}
})

core.register_craft({
	output = "mcl_redstone:redstone 9",
	recipe = {
		{"mcl_redstone_torch:redstoneblock"},
	}
})
