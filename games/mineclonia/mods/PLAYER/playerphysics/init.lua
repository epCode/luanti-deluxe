playerphysics = {}

-- Deserialized copies of each player's "playerphysics:physics" meta,
-- so the per-step FOV controller need not deserialize it every step.
local physics_cache = {}

local function get_data(player)
	local a = physics_cache[player]
	if a == nil then
		a = core.deserialize(player:get_meta():get_string("playerphysics:physics")) or false
		physics_cache[player] = a
	end
	return a or nil
end

local function set_data(player, a)
	physics_cache[player] = a or false
	player:get_meta():set_string("playerphysics:physics", core.serialize(a))
end

-- Returns the (read-only) table of physics factors of PLAYER, or nil.
playerphysics.get_physics_data = get_data

local function calculate_attribute_product(player, attribute)
	local a = get_data(player)
	local product = 1
	if a == nil or a[attribute] == nil then
		return product
	end
	local factors = a[attribute]
	if type(factors) == "table" then
		for _, factor in pairs(factors) do
			product = product * factor
		end
	end
	return product
end

-- Override the player's FOV with an absolute value in degrees, or
-- pass 0 to return control to the FOV controller (see fov.lua).
function playerphysics.set_absolute_fov(player, fov)
	local a = table.copy(get_data(player) or {})
	if fov == 0 then
		fov = nil
	end
	if a.fov_absolute == fov then return end
	a.fov_absolute = fov
	set_data(player, a)
end

-- "fov" factors are not applied here; the FOV controller multiplies
-- them into its own FOV modifier every step.
function playerphysics.add_physics_factor(player, attribute, id, value)
	local a = table.copy(get_data(player) or {})
	if a[attribute] == nil then
		a[attribute] = { [id] = value }
	else
		a[attribute][id] = value
	end
	set_data(player, a)
	if attribute ~= "fov" and not mcl_serverplayer.is_csm_capable (player) then
		player:set_physics_override({[attribute] = calculate_attribute_product(player, attribute)})
	end
end

function playerphysics.remove_physics_factor(player, attribute, id)
	local a = get_data(player)
	if a == nil or a[attribute] == nil or a[attribute][id] == nil then
		-- Nothing to remove
		return
	end
	a = table.copy(a)
	a[attribute][id] = nil
	set_data(player, a)
	if attribute ~= "fov" and not mcl_serverplayer.is_csm_capable (player) then
		player:set_physics_override({[attribute] = calculate_attribute_product(player, attribute)})
	end
end

function playerphysics.get_physics_factor(player, attribute, id)
	local a = get_data(player)
	if a == nil then
		return nil
	elseif a[attribute] == nil then
		return nil
	else
		return a[attribute][id]
	end
end

core.register_on_leaveplayer(function(player)
	physics_cache[player] = nil
end)

dofile(core.get_modpath(core.get_current_modname()).."/elytra.lua")
dofile(core.get_modpath(core.get_current_modname()).."/fov.lua")
