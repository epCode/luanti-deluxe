mcl_target = {}

local S = core.get_translator("mcl_target")
local ACHIEVEMENT_DISTANCE = 30

-- Port of Minecraft's TargetBlock.
local BLOCK = "mcl_target:target"

-- TargetBlock.getRedstoneStrength: the hit point's distance from the
-- centre of the face that was hit (in its two axes, largest wins).
local function get_redstone_strength(rel)
	local ax, ay, az = math.abs(rel.x), math.abs(rel.y), math.abs(rel.z)
	local distance
	if ay >= ax and ay >= az then
		distance = math.max(ax, az)
	elseif az >= ax then
		distance = math.max(ax, ay)
	else
		distance = math.max(ay, az)
	end
	return math.max(1, math.ceil(15 * math.max(0, math.min(1, (0.5 - distance) / 0.5))))
end

local function calculate_dist(dx, dy)
	return math.sqrt(dx * dx + dy * dy)
end

local function check_achievement(pos, arrow, signal)
	if not arrow then return end
	local shooter = arrow._shooter
	if signal ~= 15 or not (shooter and shooter.is_player and shooter:is_player()) then
		return
	end
	local shooter_pos = shooter:get_pos()
	local rel = vector.subtract(shooter_pos, pos)
	local dist = calculate_dist(rel.x, rel.z)
	if math.floor(dist) >= ACHIEVEMENT_DISTANCE then
		awards.unlock(shooter:get_player_name(), "mcl:bullseye")
	end
end

-- TargetBlock.onProjectileHit
function mcl_target.hit(pos, arrow)
	local arrow_pos = arrow and arrow.object and arrow.object:get_pos() or pos
	local signal = get_redstone_strength(vector.subtract(arrow_pos, pos))
	local duration = arrow and arrow._is_arrow and 20 or 8
	mcl_redstone._begin()
	if not mcl_redstone.has_scheduled_tick(pos, BLOCK) then
		mcl_redstone.set_block(pos, {name = signal > 0 and "mcl_target:target_on" or "mcl_target:target_off", param2 = signal}, 3)
		mcl_redstone.schedule_tick(pos, BLOCK, duration)
	end
	mcl_redstone._end()
	check_achievement(pos, arrow, signal)
end

local function own_signal(pos, node)
	return node.name == "mcl_target:target_on" and node.param2 or 0
end

local commdef = {
	_mcl_hardness = 0.5,
	_mcl_redstone = {
		block = BLOCK,
		signal_source = true,
		own_signal = own_signal,
		get_signal = own_signal,
		tick = function(pos, node)
			if own_signal(pos, node) ~= 0 then
				mcl_redstone.set_block(pos, {name = "mcl_target:target_off", param2 = 0}, 3)
			end
		end,
		on_place = function(pos, node, oldnode)
			if mcl_redstone.block_id(oldnode.name) ~= BLOCK and own_signal(pos, node) > 0
					and not mcl_redstone.has_scheduled_tick(pos, BLOCK) then
				mcl_redstone.set_block(pos, {name = "mcl_target:target_off", param2 = 0}, 18)
			end
		end,
	},
	description = S("Target"),
	groups = {hoey = 1},
	sounds = mcl_sounds.node_sound_dirt_defaults({
		footstep = {gain = 0.1, name = "default_grass_footstep"}
	}),
	tiles = {
		"mcl_target_target_top.png", "mcl_target_target_top.png", "mcl_target_target_side.png"
	}
}

core.register_node("mcl_target:target_off", table.merge(commdef, {
	_doc_items_longdesc = S("A target is a block that provides a temporary redstone charge when hit by a projectile."),
	_doc_items_usagehelp = S("Throw a projectile on the target to activate it."),
	_on_arrow_hit = function(pos, arrow) mcl_target.hit(pos, arrow) end
}))

core.register_node("mcl_target:target_on", table.merge(commdef, {
	_doc_items_create_entry = false,
	drop = "mcl_target:target_off",
	groups = table.merge(commdef.groups, {not_in_creative_inventory = 1}),
	-- Targets lit by the previous implementation
	on_timer = function(pos)
		if core.get_node(pos).name == "mcl_target:target_on" and not mcl_redstone.has_scheduled_tick(pos, BLOCK) then
			mcl_redstone.set_block(pos, {name = "mcl_target:target_off", param2 = 0}, 3)
		end
	end,
}))

core.register_craft({
	output = "mcl_target:target_off",
	recipe = {
		{"", "mcl_redstone:redstone", ""},
		{"mcl_redstone:redstone", "mcl_farming:hay_block", "mcl_redstone:redstone"},
		{"", "mcl_redstone:redstone", ""}
	}
})
