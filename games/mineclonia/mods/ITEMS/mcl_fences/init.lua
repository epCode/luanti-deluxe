local S = core.get_translator("mcl_fences")

mcl_fences = {}

-- Node box
local p = { -0.125, -0.5, -0.125, 0.125, 0.5, 0.125 }
local x1 = { -0.5, 0.25, -0.0625, -0.125, 0.4375, 0.0625 }
local x12 = { -0.5, -0.125, -0.0625, -0.125, 0.0625, 0.0625 }
local x2 = { 0.125, 0.25, -0.0625, 0.5, 0.4375, 0.0625 }
local x22 = { 0.125, -0.125, -0.0625, 0.5, 0.0625, 0.0625 }
local z1 = { -0.0625, 0.25, -0.5, 0.0625, 0.4375, -0.125 }
local z12 = { -0.0625, -0.125, -0.5, 0.0625, 0.0625, -0.125 }
local z2 = { -0.0625, 0.25, 0.125, 0.0625, 0.4375, 0.5 }
local z22 = { -0.0625, -0.125, 0.125, 0.0625, 0.0625, 0.5 }

-- Collision box
local cp = { -0.125, -0.5, -0.125, 0.125, 1.01, 0.125 }
local cx1 = { -0.5, -0.5, -0.125, -0.125, 1.01, 0.125 }
local cx2 = { 0.125, -0.5, -0.125, 0.5, 1.01, 0.125 }
local cz1 = { -0.125, -0.5, -0.5, 0.125, 1.01, -0.125 }
local cz2 = { -0.125, -0.5, 0.125, 0.125, 1.01, 0.5 }

local on_rotate = screwdriver.rotate_simple

-- Port of Minecraft's FenceGateBlock.  OPEN is the node (gate or gate_open,
-- one redstone block), POWERED is kept in the metadata.  IN_WALL is not
-- supported.

local function is_open(node)
	return node.name:sub(-5) == "_open"
end

local function with_open(node, open)
	local base = is_open(node) and node.name:sub(1, -6) or node.name
	return {name = open and base.."_open" or base, param2 = node.param2}
end

local function is_powered(pos)
	return core.get_meta(pos):get_string("powered") == "1"
end

local function set_powered(pos, powered)
	core.get_meta(pos):set_string("powered", powered and "1" or "0")
end

local function play_sound(pos, node, state)
	local sounddefs = {}
	local defs = core.registered_nodes[node.name]
	if defs and defs._mcl_fences_sounds then
		sounddefs = defs._mcl_fences_sounds[state]
	end
	local spec = sounddefs.spec or ("doors_fencegate_"..state)
	local gain = sounddefs.gain or 0.3
	core.sound_play(spec, { gain = gain, max_hear_distance = 16, pos = pos,
		pitch = math.random() * 0.1 + 0.9 }, true)
end

-- Level.gameEvent(BLOCK_OPEN / BLOCK_CLOSE); `source` is a player, a mob
-- (its luaentity) or nil
local function gate_event(pos, open, source, node)
	if not mcl_gameevent then
		return
	end
	if type(source) == "table" and not core.is_player(source) then
		source = source.object
	end
	if source and not core.is_player(source) and not (source.get_luaentity and source:get_luaentity()) then
		source = nil
	end
	mcl_gameevent.emit(open and "block_open" or "block_close", pos, {source = source, node = node})
end

-- FenceGateBlock.useWithoutItem
local function use_gate(pos, node, clicker)
	node = core.get_node(pos)
	local new
	if is_open(node) then
		new = with_open(node, false)
	else
		-- Opens away from the player
		new = with_open(node, true)
		local d = mcl_redstone.horizontal_looking_direction(clicker)
		local rot = node.param2 % 4
		if mcl_redstone.fourdir_to_dir[rot] == mcl_redstone.opposite[d] then
			new.param2 = node.param2 - rot + mcl_redstone.dir_to_fourdir[d]
		end
	end
	mcl_redstone.set_block(pos, new, 10)
	play_sound(pos, new, is_open(new) and "open" or "close")
	gate_event(pos, is_open(new), clicker)
end

-- FenceGateBlock.onExplosionHit (wind charges)
local function on_wind_charge_hit(pos)
	if not is_powered(pos) then
		local node = core.get_node(pos)
		local open = is_open(node)
		mcl_redstone.set_block(pos, with_open(node, not open), 3)
		play_sound(pos, node, open and "close" or "open")
		gate_event(pos, not open, nil, node)
	end
	return true
end

local function gate_behaviour(block)
	return {
		block = block,
		-- FenceGateBlock.neighborChanged
		neighbor_changed = function(pos, node)
			local has_power = mcl_redstone.has_neighbor_signal(pos)
			if is_powered(pos) ~= has_power then
				set_powered(pos, has_power)
				local new = with_open(node, has_power)
				if mcl_redstone.same_node(new, node) then
					-- Only POWERED changed, still a new state for Minecraft
					mcl_redstone.node_changed(pos, node, node, 2)
				else
					mcl_redstone.set_block(pos, new, 2)
				end
				if is_open(node) ~= has_power then
					play_sound(pos, node, has_power and "open" or "close")
					gate_event(pos, has_power, nil)
				end
			end
		end,
		-- FenceGateBlock.getStateForPlacement
		placement = function(pos, node, oldnode)
			if mcl_redstone.block_id(oldnode.name) == block then
				return
			end
			local open = mcl_redstone.has_neighbor_signal(pos)
			set_powered(pos, open)
			if open then
				return with_open(node, true)
			end
		end,
	}
end

local function handle_textures(block, definitions)
    local tiles = definitions.tiles[1]
    local texture = "mcl_fences_"..block.."_mask.png^"..tiles..
        "^mcl_fences_"..block.."_mask.png^[makealpha:255,126,126"

    if not definitions.inventory_image then
        definitions.inventory_image = texture
    end

    if not definitions.wield_image then
        definitions.wield_image = texture
    end
end

local tpl_fences = {
    _doc_items_longdesc = S("Fences are structures which block the way. Fences will connect to each other and solid blocks. They cannot be jumped over with a simple jump."),
	paramtype = "light",
	is_ground_content = false,
	connect_sides = { "front", "back", "left", "right" },
	sunlight_propagates = true,
	drawtype = "nodebox",
    node_box = {
        type = "connected",
        fixed = { p },
        connect_front = { z1, z12 },
        connect_back = { z2, z22 },
        connect_left = { x1, x12 },
        connect_right = { x2, x22 }
    },
    collision_box = {
        type = "connected",
        fixed = { cp },
        connect_front = { cz1 },
        connect_back = { cz2 },
        connect_left = { cx1 },
        connect_right = { cx2 }
    }
}

local tpl_fence_gates = {
    _tt_help = S("Openable by players and redstone power"),
	_doc_items_longdesc = S("Fence gates can be opened or closed and can't be jumped over. Fences will connect nicely to fence gates."),
	_doc_items_usagehelp = S("Right-click the fence gate to open or close it."),
	paramtype = "light",
	is_ground_content = false,
	paramtype2 = "facedir",
	sunlight_propagates = true,
	drawtype = "nodebox",
	node_box = {
		type = "fixed",
		fixed = {
			{ -0.5, -0.1875, -0.0625, -0.375, 0.5, 0.0625 },
			{ 0.375, -0.1875, -0.0625, 0.5, 0.5, 0.0625 },
			{ -0.125, -0.125, -0.0625, 0, 0.4375, 0.0625 },
			{ 0, -0.125, -0.0625, 0.125, 0.4375, 0.0625 },
			{ -0.5, 0.25, -0.0625, -0.125, 0.4375, 0.0625 },
			{ -0.5, -0.125, -0.0625, -0.125, 0.0625, 0.0625 },
			{ 0.125, 0.25, -0.0625, 0.5, 0.4375, 0.0625 },
			{ 0.125, -0.125, -0.0625, 0.5, 0.0625, 0.0625 }
		}
	},
	collision_box = {
		type = "fixed",
		fixed = {{ -0.5, -0.1875, -0.125, 0.5, 1, 0.125 }}
	},
	selection_box = {
		type = "fixed",
		fixed = {{ -0.5, -0.1875, -0.0625, 0.5, 0.5, 0.0625 }}
	},
	on_rotate = on_rotate,
	on_rightclick = use_gate,
	_on_wind_charge_hit = on_wind_charge_hit,
}

local tpl_fence_gates_open = {
	paramtype = "light",
	paramtype2 = "facedir",
	is_ground_content = false,
	sunlight_propagates = true,
	walkable = false,
	drawtype = "nodebox",
	node_box = {
		type = "fixed",
		fixed = {
			{ -0.5, -0.1875, -0.0625, -0.375, 0.5, 0.0625 },
			{ 0.375, -0.1875, -0.0625, 0.5, 0.5, 0.0625 },
			{ -0.5, 0.25, 0.0625, -0.375, 0.4375, 0.375 },
			{ -0.5, -0.125, 0.0625, -0.375, 0.0625, 0.375 },
			{ 0.375, 0.25, 0.0625, 0.5, 0.4375, 0.5 },
			{ 0.375, -0.125, 0.0625, 0.5, 0.0625, 0.5 },
			{ -0.5, -0.125, 0.375, -0.375, 0.4375, 0.5 },
			{ 0.375, 0.0625, 0.5, 0.5, 0.25, 0.375 }
		}
	},
	selection_box = {
		type = "fixed",
		fixed = {{ -0.5, -0.1875, -0.0625, 0.5, 0.5, 0.0625 }}
	},
	on_rightclick = use_gate,
	on_rotate = on_rotate,
	_on_wind_charge_hit = on_wind_charge_hit,
}

function mcl_fences.register_fence_def(name, definitions)
    local fence_name = "mcl_fences:"..name

    definitions.groups = definitions.groups and table.copy(definitions.groups) or {}
    definitions.groups.fence = 1
    definitions._pathfinding_class = "FENCE"
    definitions.groups.deco_block = 1

    if not definitions.connects_to then
        definitions.connects_to = { fence_name, "group:fence", "group:fence_gate", "group:solid" }
    end

    if definitions.tiles and definitions.tiles[1] then
        handle_textures("fence", definitions)
    end

    core.register_node(":"..fence_name, table.merge(tpl_fences, definitions))

    if definitions._mcl_fences_baseitem then
        local stick = "mcl_core:stick"
		local material = definitions._mcl_fences_baseitem
		local amount = definitions._mcl_fences_output_amount or 3

		if definitions._mcl_fences_stickreplacer then
			stick = definitions._mcl_fences_stickreplacer
		end

		core.register_craft({
			output = fence_name.." "..tostring(amount),
			recipe = {
				{ material, stick, material },
				{ material, stick, material }
			}
		})
    end

    return fence_name
end

function mcl_fences.register_fence_gate_def(name, definitions)
    local fence_gate_name = "mcl_fences:"..name.."_gate"
    local fence_gate_name_open = fence_gate_name.."_open"

	definitions.groups = definitions.groups and table.copy(definitions.groups) or {}
	definitions.groups.fence_gate = 1
	definitions._pathfinding_class = "FENCE"
	definitions.groups.deco_block = 1

	if definitions.tiles and definitions.tiles[1] then
		handle_textures("fence_gate", definitions)
	end

	local behaviour = gate_behaviour(fence_gate_name)

    core.register_node(":"..fence_gate_name, table.merge(tpl_fence_gates, definitions, {
		_mcl_redstone = behaviour,
	}))

	local opendefinitions = table.copy(definitions)
	opendefinitions.description = nil
	opendefinitions.inventory_image = nil
	opendefinitions.wield_image = nil
	opendefinitions._mcl_burntime = nil
	opendefinitions.groups = table.copy (definitions.groups)
	opendefinitions._pathfinding_class = "OPEN"

	opendefinitions.groups.not_in_creative_inventory = 1
	opendefinitions.groups.breaking_cactus = 1
	opendefinitions.mesecon_ignore_opaque_dig = 1
	opendefinitions.mesecon_effector_on = 1

    core.register_node(":"..fence_gate_name_open, table.merge(tpl_fence_gates_open, {
		drop = fence_gate_name
	}, opendefinitions, {
		_mcl_redstone = behaviour,
	}))

    if definitions._mcl_fences_baseitem then
		local stick = "mcl_core:stick"
		local material = definitions._mcl_fences_baseitem
		local amount = definitions._mcl_fences_output_amount or 1

		if definitions._mcl_fences_stickreplacer then
			stick = definitions._mcl_fences_stickreplacer
		end

		core.register_craft({
			output = fence_gate_name.." "..tostring(amount),
			recipe = {
				{ stick, material, stick },
				{ stick, material, stick }
			}
		})
	end

	doc.add_entry_alias("nodes", fence_gate_name, "nodes", fence_gate_name_open)

	return fence_gate_name, fence_gate_name_open
end

function mcl_fences.register_fence_and_fence_gate_def(name, commondefs, fencedefs, gatedefs)
	local fence, gate, gate_open

	fence = mcl_fences.register_fence_def(name, table.merge(commondefs, fencedefs))
	gate, gate_open = mcl_fences.register_fence_gate_def(name, table.merge(commondefs, gatedefs))

	return fence, gate, gate_open
end

-- Support for old definitions

function mcl_fences.register_fence(id, fence_name, texture, groups, hardness, blast_resistance, connects_to, sounds, burntime, baseitem, stickreplacer)
	return mcl_fences.register_fence_def(id, {
		description = fence_name,
		tiles = { texture },
		groups = groups,
		_mcl_blast_resistance = blast_resistance,
		_mcl_hardness = hardness,
		connects_to = connects_to,
		sounds = sounds,
		_mcl_burntime = burntime,
		_mcl_fences_baseitem = baseitem,
		_mcl_fences_stickreplacer = stickreplacer
	})
end

function mcl_fences.register_fence_gate(id, fence_gate_name, texture, groups, hardness, blast_resistance, sounds, sound_open, sound_close, sound_gain_open, sound_gain_close, burntime, baseitem, stickreplacer)
	return mcl_fences.register_fence_gate_def(id, {
		description = fence_gate_name,
		tiles = { texture },
		groups = groups,
		_mcl_blast_resistance = blast_resistance,
		_mcl_hardness = hardness,
		sounds = sounds,
		_mcl_burntime = burntime,
		_mcl_fences_sounds = {
			open = {
				spec = sound_open,
				gain = sound_gain_open
			},
			close = {
				spec = sound_close,
				gain = sound_gain_close
			}
		},
		_mcl_fences_baseitem = baseitem,
		_mcl_fences_stickreplacer = stickreplacer
	})
end

function mcl_fences.register_fence_and_fence_gate(id, fence_name, fence_gate_name, texture_fence, groups, hardness, blast_resistance, connects_to, sounds, sound_open, sound_close, sound_gain_open, sound_gain_close, texture_fence_gate)
	if texture_fence_gate == nil then
		texture_fence_gate = texture_fence
	end
	local fence_id = mcl_fences.register_fence(id, fence_name, texture_fence, groups, hardness, blast_resistance, connects_to, sounds)
	local gate_id, open_gate_id = mcl_fences.register_fence_gate(id, fence_gate_name, texture_fence_gate, groups, hardness, blast_resistance, sounds, sound_open, sound_close, sound_gain_open, sound_gain_close)
	return fence_id, gate_id, open_gate_id
end
