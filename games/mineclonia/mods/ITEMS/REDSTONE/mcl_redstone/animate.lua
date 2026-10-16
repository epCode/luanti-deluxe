-- Minecraft's ClientLevel.animateTick for redstone blocks: every tick each
-- player samples 667 random positions around them (offsets x + rand(16) -
-- rand(16), and the same with 32) and calls Block.animateTick on what is
-- there.  Here the candidate nodes near each player are known, and each one
-- is animated with the probability of being sampled.
--
-- Behaviours define animate = function(pos, node, player_name).

local animate_names
local candidates = {}

local RADIUS = 15

-- Chance per tick that the client's random sampling hits a block at this
-- offset from the player.
local function hit_chance(dx, dy, dz)
	dx, dy, dz = math.abs(dx), math.abs(dy), math.abs(dz)
	local p = 0
	if dx < 16 and dy < 16 and dz < 16 then
		p = p + 667 * (16 - dx) * (16 - dy) * (16 - dz) / 16777216
	end
	if dx < 32 and dy < 32 and dz < 32 then
		p = p + 667 * (32 - dx) * (32 - dy) * (32 - dz) / 1073741824
	end
	return p
end

mcl_redstone.register_on_game_tick(function(time)
	if not animate_names then
		animate_names = {}
		for name, b in pairs(mcl_redstone._blocks) do
			if b.animate then
				table.insert(animate_names, name)
			end
		end
	end
	if #animate_names == 0 then
		return
	end
	for _, player in ipairs(core.get_connected_players()) do
		local name = player:get_player_name()
		local ppos = vector.round(player:get_pos())
		local c = candidates[name]
		if not c or time % 10 == 0 or not vector.equals(c.center, ppos) and time % 2 == 0 then
			c = {
				center = ppos,
				list = core.find_nodes_in_area(vector.subtract(ppos, RADIUS), vector.add(ppos, RADIUS), animate_names),
			}
			candidates[name] = c
		end
		for _, pos in ipairs(c.list) do
			if math.random() < hit_chance(pos.x - ppos.x, pos.y - ppos.y, pos.z - ppos.z) then
				local node = core.get_node(pos)
				local b = mcl_redstone._blocks[node.name]
				if b and b.animate then
					b.animate(pos, node, name)
				end
			end
		end
	end
end)

core.register_on_leaveplayer(function(player)
	candidates[player:get_player_name()] = nil
end)

-- RedstoneWireBlock.COLORS
local colors = {}
for i = 0, 15 do
	local p = i / 15
	local r = p * 0.6 + (p > 0 and 0.4 or 0.3)
	local g = math.max(0, math.min(1, p * p * 0.7 - 0.5))
	local b = math.max(0, math.min(1, p * p * 0.6 - 0.7))
	colors[i] = {r = r, g = g, b = b}
end
mcl_redstone.wire_colors = colors

-- Frames of the particle texture: Minecraft's generic_7 .. generic_1 (the
-- dust sprite set; generic_0 is never reached before the particle dies).
local FRAMES = 7
-- Particle.friction 0.96 per tick as Luanti drag (per second)
local DRAG = -math.log(0.96) * 20

-- DustParticle (DustParticleBase) with the given colour (0..1 components)
-- and scale, spawned at pos for one player.
function mcl_redstone.dust_particle(player_name, pos, color, scale)
	scale = scale or 1
	-- Particle(level, x, y, z, xa, ya, za) with xa = ya = za = 0
	local xd, yd, zd = (math.random() * 2 - 1) * 0.4, (math.random() * 2 - 1) * 0.4, (math.random() * 2 - 1) * 0.4
	local speed = (math.random() + math.random() + 1) * 0.15
	local d = math.sqrt(xd * xd + yd * yd + zd * zd)
	if d > 0 then
		xd, yd, zd = xd / d * speed * 0.4, yd / d * speed * 0.4 + 0.1, zd / d * speed * 0.4
	end
	-- DustParticleBase: slower, smaller, 8 / (0.2 .. 1) ticks
	xd, yd, zd = xd * 0.1, yd * 0.1, zd * 0.1
	local quad_size = 0.1 * (math.random() * 0.5 + 0.5) * 2 * 0.75 * scale
	local lifetime = math.floor(8 / (math.random() * 0.8 + 0.2))
	lifetime = math.max(1, math.floor(lifetime * scale))
	-- DustParticle: randomizeColor
	local f = math.random() * 0.4 + 0.6
	local function c(v)
		return math.floor(math.max(0, math.min(1, (math.random() * 0.2 + 0.8) * v * f)) * 255 + 0.5)
	end
	core.add_particle({
		playername = player_name,
		pos = pos,
		-- blocks per tick to nodes per second
		velocity = vector.new(xd * 20, yd * 20, zd * 20),
		drag = vector.new(DRAG, DRAG, DRAG),
		expirationtime = lifetime / 20,
		-- quadSize is half the width; Luanti sizes are in tenths of a node
		size = quad_size * 20,
		collisiondetection = true,
		texture = ("mcl_redstone_dust_particle.png^[multiply:#%02x%02x%02x"):format(c(color.r), c(color.g), c(color.b)),
		animation = {type = "vertical_frames", aspect_w = 8, aspect_h = 8, length = lifetime / 20},
		glow = 0,
	})
end

-- The colour of DustParticleOptions.REDSTONE (0xFF0000)
mcl_redstone.REDSTONE_DUST = {r = 1, g = 0, b = 0}
