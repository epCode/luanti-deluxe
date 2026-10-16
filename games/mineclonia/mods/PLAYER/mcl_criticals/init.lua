mcl_criticals = {}

-- Approximations of the state consulted by Player.canCriticalAttack
-- and Player.isSweepAttack.

local function node_def (player, which)
	local info = mcl_player and mcl_player.players[player]
	local name = info and info.nodes and info.nodes[which]
	return name and core.registered_nodes[name]
end

function mcl_criticals.player_on_ground (player)
	local v = player:get_velocity ()
	local stand = node_def (player, "stand")
	return v and math.abs (v.y) < 0.1 and stand and stand.walkable or false
end

-- Player.canCriticalAttack: fallDistance > 0 && !onGround &&
-- !onClimbable && !isInWater && !isMobilityRestricted (blindness) &&
-- !isPassenger && !isSprinting.
function mcl_criticals.can_critical_attack (player)
	local v = player:get_velocity ()
	if not v or v.y >= 0 then
		return false
	end
	if player:get_attach () then
		return false
	end
	if mcl_sprint and mcl_sprint.is_sprinting (player:get_player_name ()) then
		return false
	end
	if mcl_potions and mcl_potions.get_effect (player, "blindness") then
		return false
	end
	local feet = node_def (player, "feet")
	if feet and (feet.climbable
		     or core.get_item_group (feet.name, "water") > 0) then
		return false
	end
	return true
end

function mcl_criticals.crit_effect (obj)
	local pos = mcl_util.get_object_center(obj)
	core.add_particlespawner({
		amount = 15,
		time = 0.1,
		minpos = {x=pos.x-0.5, y=pos.y-0.5, z=pos.z-0.5},
		maxpos = {x=pos.x+0.5, y=pos.y+0.5, z=pos.z+0.5},
		minvel = {x=-0.1, y=-0.1, z=-0.1},
		maxvel = {x=0.1, y=0.1, z=0.1},
		minacc = {x=0, y=0, z=0},
		maxacc = {x=0, y=0, z=0},
		minexptime = 1,
		maxexptime = 2,
		minsize = 1.5,
		maxsize = 1.5,
		collisiondetection = false,
		vertical = false,
		texture = "mcl_particles_crit.png^[colorize:#bc7a57:127",
	})
	core.sound_play("mcl_criticals_hit", {object = obj})
end

-- Critical hits between players.  (Mob targets compute critical hits
-- in mcl_mobs's on_punch and set `crit_handled'.)
mcl_damage.register_modifier(function(obj, damage, reason)
	if reason.type == "player" and reason.melee
		and not reason.crit_handled and damage > 0 then
		local hitter = reason.direct
		if hitter and hitter:is_player ()
			and (reason.attack_strength or 1) > 0.9
			and mcl_criticals.can_critical_attack (hitter) then
			mcl_criticals.crit_effect (obj)
			-- Player.attack: baseDamage *= 1.5F.
			return damage * 1.5
		end
	end
end, -100)
