------------------------------------------------------------------------
-- Particles and level events of the sculk blocks. Minecraft spawns these
-- on the client; here they go to the players within the distance that
-- ServerLevel.levelEvent (64 blocks) / sendParticles (32) reaches.
-- Particle sizes: Luanti size = Minecraft quadSize * 20 (quadSize is half
-- the width, Luanti sizes are tenths of a node).
------------------------------------------------------------------------

local R = mcl_redstone
local random = math.random

local function players_near(pos, dist)
	local list = {}
	for _, player in ipairs(core.get_connected_players()) do
		if vector.distance(player:get_pos(), pos) <= dist then
			table.insert(list, player:get_player_name())
		end
	end
	return list
end
mcl_sculk.players_near = players_near

-- Mth.nextDouble
local function next_double(a, b)
	return a + random() * (b - a)
end

-- Particle friction per tick as drag per second
local function drag(friction)
	local d = -math.log(friction) * 20
	return vector.new(d, d, d)
end

-- The base Particle quadSize: 0.1 * (rand * 0.5 + 0.5) * 2
local function base_quad_size()
	return 0.1 * (random() * 0.5 + 0.5) * 2
end

-- SculkChargeParticle: 7 frames over its life (setSpriteFromAge),
-- friction 0.96, scale 1.5, lifetime 8..19 ticks, full bright
local function sculk_charge(players, pos, vel)
	local life = (random(0, 11) + 8) / 20
	local size = base_quad_size() * 1.5 * 20
	for _, name in ipairs(players) do
		core.add_particle({
			playername = name,
			pos = pos,
			velocity = vector.multiply(vel, 20),
			drag = drag(0.96),
			expirationtime = life,
			size = size,
			texture = "mcl_sculk_charge.png",
			animation = {type = "vertical_frames", aspect_w = 16, aspect_h = 16, length = life},
			glow = 15,
		})
	end
end

-- SculkChargePopParticle: 4 frames, friction 0.96, lifetime 6..9 ticks
local function sculk_charge_pop(players, pos, vel)
	local life = (random(0, 3) + 6) / 20
	local size = base_quad_size() * 20
	for _, name in ipairs(players) do
		core.add_particle({
			playername = name,
			pos = pos,
			velocity = vector.multiply(vel, 20),
			drag = drag(0.96),
			expirationtime = life,
			size = size,
			texture = "mcl_sculk_charge_pop.png",
			animation = {type = "vertical_frames", aspect_w = 16, aspect_h = 16, length = life},
			glow = 15,
		})
	end
end

local FACE_DIRS = mcl_sculk.DIRECTIONS

-- ParticleUtils.spawnParticleOnFace
local function on_face(players, pos, d, speed, step)
	local v = R.dirvec[d]
	local p = vector.new(
		pos.x + (v.x == 0 and next_double(-0.5, 0.5) or v.x * step),
		pos.y + (v.y == 0 and next_double(-0.5, 0.5) or v.y * step),
		pos.z + (v.z == 0 and next_double(-0.5, 0.5) or v.z * step))
	local vel = vector.new(v.x == 0 and speed.x or 0, v.y == 0 and speed.y or 0, v.z == 0 and speed.z or 0)
	sculk_charge(players, p, vel)
end

-- LevelEventHandler case 3006 (SculkSpreader charge): data = count << 6 |
-- MultifaceBlock.pack(faces), or 0 when the charge ran out
function mcl_sculk.charge_event(pos, data)
	local players = players_near(pos, 64)
	if #players == 0 then
		return
	end
	local count = bit.rshift(data, 6)
	if count > 0 then
		if random() < 0.3 + count * 0.1 then
			local volume = 0.15 + 0.02 * count * count * random()
			local pitch = 0.4 + 0.3 * count * random()
			mcl_sculk.play("block.sculk.charge", pos, volume, pitch)
		end
		local faces = bit.band(data, 63)
		local function speed()
			return vector.new(next_double(-0.005, 0.005), next_double(-0.005, 0.005), next_double(-0.005, 0.005))
		end
		if faces == 0 then
			for _, d in ipairs(FACE_DIRS) do
				local factor = R.axis[d] == 0 and 0.65 or 0.57
				for _ = 1, random(0, count) do
					on_face(players, pos, d, speed(), factor)
				end
			end
		else
			for _, d in ipairs(FACE_DIRS) do
				if mcl_sculk.has_face(faces, d) then
					for _ = 1, random(0, count) do
						on_face(players, pos, d, speed(), 0.35)
					end
				end
			end
		end
	else
		mcl_sculk.play("block.sculk.charge", pos, 1, 1)
		local node = core.get_node(pos)
		local solid = R.is_collision_full_block(pos, node)
		local n = solid and 40 or 20
		local spread = solid and 0.45 or 0.25
		for _ = 1, n do
			local vx, vy, vz = 2 * random() - 1, 2 * random() - 1, 2 * random() - 1
			sculk_charge_pop(players, vector.new(pos.x + vx * spread, pos.y + vy * spread, pos.z + vz * spread),
				vector.new(vx * 0.07, vy * 0.07, vz * 0.07))
		end
	end
end

-- ParticleTypes.SCULK_SOUL (SoulParticle): rises slowly, 11 frames
function mcl_sculk.soul_particles(pos, count, spread)
	local players = players_near(pos, 32)
	for _ = 1, count do
		-- ServerLevel.sendParticles: gaussian offsets times the spread
		local p = vector.new(pos.x + (random() + random() - 1) * spread.x,
			pos.y + (random() + random() - 1) * spread.y,
			pos.z + (random() + random() - 1) * spread.z)
		local life = math.floor(8 / (random() * 0.8 + 0.2)) / 20 + 0.2
		for _, name in ipairs(players) do
			core.add_particle({
				playername = name,
				pos = p,
				velocity = vector.new((random() - 0.5) * 0.1, 0.1 + random() * 0.4, (random() - 0.5) * 0.1),
				drag = drag(0.96),
				expirationtime = life,
				size = base_quad_size() * 1.5 * 20,
				texture = "mcl_sculk_soul.png",
				animation = {type = "vertical_frames", aspect_w = 16, aspect_h = 16, length = life},
				glow = 15,
			})
		end
	end
end

-- LevelEventHandler case 3007 (shriek): ten ShriekParticles, one every 5
-- ticks, rising 0.1 blocks per tick for 30 ticks, growing to 0.85 x 0.75
-- quad size and fading out; and the shriek sound
function mcl_sculk.shriek_event(pos)
	-- pos + (0.5, SculkShriekerBlock.TOP_Y = 0.5, 0.5): the node center
	local top = vector.copy(pos)
	local players = players_near(pos, 64)
	for i = 0, 9 do
		core.after(i * 5 / 20, function()
			for _, name in ipairs(players) do
				core.add_particlespawner({
					playername = name,
					amount = 1,
					time = 0.05,
					pos = top,
					-- yd = 0.1 blocks per tick, friction 0.98
					vel = vector.new(0, 2, 0),
					drag = drag(0.98),
					exptime = 1.5,
					size = 0.85 * 20,
					-- rotationX(-1.0472); the second quad is its back
					rotation = mcl_gameevent.mc_quad_rotation({{"x", -1.0472}}),
					texture = {
						name = "mcl_sculk_shriek.png",
						-- alpha = 1 - age / lifetime, quad size
						-- 0.85 * clamp(age / lifetime * 0.75)
						alpha_tween = {1, 0},
						scale_tween = {0, 0.75},
					},
					glow = 15,
				})
			end
		end)
	end
	mcl_sculk.play("block.sculk_shrieker.shriek", top, 2.0, 0.6 + random() * 0.4)
end

-- DustColorTransitionOptions.SCULK_TO_REDSTONE: a dust particle that turns
-- from sculk blue (#39D6E0) to redstone red over its life
local FRAMES = 7
local function lerp_color(t)
	local r = math.floor(0x39 + (0xFF - 0x39) * t + 0.5)
	local g = math.floor(0xD6 + (0x00 - 0xD6) * t + 0.5)
	local b = math.floor(0xE0 + (0x00 - 0xE0) * t + 0.5)
	return string.format("#%02X%02X%02X", r, g, b)
end
local transition_texture
do
	local parts = {}
	for i = 0, FRAMES - 1 do
		parts[#parts + 1] = ("0,%d=mcl_redstone_dust_particle.png\\^[verticalframe\\:%d\\:%d\\^[multiply\\:%s"):format(
			i * 8, FRAMES, i, lerp_color(i / (FRAMES - 1)))
	end
	transition_texture = "[combine:8x" .. (8 * FRAMES) .. ":" .. table.concat(parts, ":")
end

-- Particle(level, x, y, z, xa, ya, za): random speed around (xa, ya, za)
local function particle_speed(xa, ya, za)
	local xd = xa + (random() * 2 - 1) * 0.4
	local yd = ya + (random() * 2 - 1) * 0.4
	local zd = za + (random() * 2 - 1) * 0.4
	local speed = (random() + random() + 1) * 0.15
	local d = math.sqrt(xd * xd + yd * yd + zd * zd)
	if d > 0 then
		xd, yd, zd = xd / d * speed * 0.4, yd / d * speed * 0.4 + 0.1, zd / d * speed * 0.4
	end
	return xd, yd, zd
end

function mcl_sculk.sculk_to_redstone_dust(player_name, pos, xa, ya, za)
	-- DustParticleBase with scale 1: lifetime 8 / (0.2..1) ticks, speed
	-- 0.1 times the base speed, friction 0.96
	local xd, yd, zd = particle_speed(xa, ya, za)
	local vel = vector.new(xd * 0.1, yd * 0.1, zd * 0.1)
	local life = math.max(1, math.floor(8 / (random() * 0.8 + 0.2))) / 20
	local quad = 0.1 * (random() * 0.5 + 0.5) * 2 * 0.75
	core.add_particle({
		playername = player_name,
		pos = pos,
		velocity = vector.multiply(vel, 20),
		drag = drag(0.96),
		expirationtime = life,
		size = quad * 20,
		texture = transition_texture,
		animation = {type = "vertical_frames", aspect_w = 8, aspect_h = 8, length = life},
	})
end
