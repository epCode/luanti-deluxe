------------------------------------------------------------------------
-- Minecraft jigsaw structure placement.
--
-- A port of Minecraft 26.3's JigsawPlacement, StructureTemplatePool
-- and pool elements (single, list, feature and empty elements),
-- reproducing their pseudo-random number generation exactly, so that
-- jigsaw structures built from Minecraft's own templates (converted by
-- tools/mc_structure_to_template.py) assemble as they do in Minecraft
-- from the same structure seed.
--
-- This is independent of the jigsaw implementation in templates.lua,
-- whose semantics (LIFO placement, must_complete, jigsaw names) the
-- existing Mineclonia structures depend on.
--
-- Templates must carry the field `mc_jigsaws', a list of
--   { x, y, z, front, top, name, pool, target, joint,
--     placement_priority, selection_priority, turns_into, }
-- in Minecraft's palette order (sorted by Y, X, then Z), where FRONT and
-- TOP are Minecraft direction names in the unrotated template.
------------------------------------------------------------------------

if mcl_levelgen.mc_jigsaw_loaded then
	return
end
mcl_levelgen.mc_jigsaw_loaded = true

local ipairs = ipairs
local insert = table.insert
local mathmin = math.min
local mathmax = math.max
local floor = math.floor

local fisher_yates = mcl_levelgen.fisher_yates
local stable_sort = table.stable_sort

-- Rotation.values (): NONE, CLOCKWISE_90, CLOCKWISE_180,
-- COUNTERCLOCKWISE_90, in the template system's notation.
local ROTATIONS = { "0", "90", "180", "270", }

local ROTATE_DIR = {
	["0"] = {
		north = "north", east = "east", south = "south", west = "west",
		up = "up", down = "down",
	},
	["90"] = {
		north = "east", east = "south", south = "west", west = "north",
		up = "up", down = "down",
	},
	["180"] = {
		north = "south", east = "west", south = "north", west = "east",
		up = "up", down = "down",
	},
	["270"] = {
		north = "west", east = "north", south = "east", west = "south",
		up = "up", down = "down",
	},
}
mcl_levelgen.mc_rotate_direction = ROTATE_DIR

local OPPOSITE = {
	north = "south", south = "north", east = "west", west = "east",
	up = "down", down = "up",
}

-- Minecraft coordinates (north = -Z).
local DIR_VECTORS = {
	north = { 0, 0, -1, },
	south = { 0, 0, 1, },
	east = { 1, 0, 0, },
	west = { -1, 0, 0, },
	up = { 0, 1, 0, },
	down = { 0, -1, 0, },
}

local function rtz (x)
	if x < 0 then
		return -floor (-x)
	end
	return floor (x)
end

-- StructureTemplate.transform with a pivot of 0, 0 and no mirroring.
local function rotate_pos (x, y, z, rotation)
	if rotation == "90" then
		return -z, y, x
	elseif rotation == "180" then
		return -x, y, -z
	elseif rotation == "270" then
		return z, y, -x
	else
		return x, y, z
	end
end

------------------------------------------------------------------------
-- Template pools.
------------------------------------------------------------------------

local EMPTY_ELEMENT = { kind = "empty", }
local EMPTY_POOL_ID = "mcl_levelgen:empty"
local registered_pools = {}
mcl_levelgen.registered_mc_template_pools = registered_pools

local function pools_enabled ()
	return mcl_levelgen.levelgen_enabled or mcl_levelgen.enable_ersatz
end

local function load_template (elem)
	local template, err
		= mcl_levelgen.read_structure_template (elem.template_file)
	if not template then
		-- StructureTemplateManager.getOrCreate yields an empty
		-- template for nonexistent files.
		core.log ("info", "[mcl_levelgen] Structure template "
			  .. elem.template_file .. " unavailable ("
			  .. tostring (err) .. "); substituting an empty template")
		elem.template = false
		elem.jigsaws = {}
		return
	end
	elem.template = template
	local jigsaws = {}
	for i, info in ipairs (template.mc_jigsaws or {}) do
		jigsaws[i] = {
			x = info.x,
			y = info.y,
			z = info.z,
			front = info.front,
			top = info.top,
			name = info.name,
			pool = info.pool,
			target = info.target,
			rollable = info.joint == "rollable",
			placement_priority = info.placement_priority or 0,
			selection_priority = info.selection_priority or 0,
		}
	end
	elem.jigsaws = jigsaws
end

local pending_loads = {}

local function prepare_element (def)
	local kind = def.type or "single"
	if kind == "empty" then
		return EMPTY_ELEMENT
	elseif kind == "single" then
		local elem = {
			kind = "single",
			template_file = def.template,
			processors = def.processors or {},
			projection = def.projection or "rigid",
			ground_level_delta = 1,
		}
		if mcl_levelgen.is_levelgen_environment then
			load_template (elem)
		else
			insert (pending_loads, elem)
		end
		return elem
	elseif kind == "feature" then
		return {
			kind = "feature",
			feature = def.feature,
			projection = def.projection or "rigid",
			ground_level_delta = 1,
		}
	elseif kind == "list" then
		local elements = {}
		for i, sub in ipairs (def.elements) do
			elements[i] = prepare_element (sub)
		end
		return {
			kind = "list",
			elements = elements,
			projection = def.projection or "rigid",
			ground_level_delta = 1,
		}
	else
		error ("Unknown pool element type: " .. tostring (kind))
	end
end

if not mcl_levelgen.is_levelgen_environment and core.register_on_mods_loaded then
	core.register_on_mods_loaded (function ()
		for _, elem in ipairs (pending_loads) do
			load_template (elem)
		end
		pending_loads = {}
	end)
end

-- Register a Minecraft template pool.  DEF is:
--   {
--     fallback = POOL_ID or nil ("minecraft:empty"),
--     elements = {
--       { weight = N, type = "single", template = FILE,
--         processors = {...}, projection = "rigid", },
--       { weight = N, type = "empty", },
--       { weight = N, type = "feature", feature = CONFIGURED_FEATURE, },
--       { weight = N, type = "list", elements = { ELEMENT, ... }, },
--     },
--   }

function mcl_levelgen.register_mc_template_pool (id, def)
	if not pools_enabled () then
		return
	end
	if registered_pools[id] then
		error ("Minecraft template pool " .. id .. " is already registered")
	end
	local pool = {
		id = id,
		fallback = def.fallback or EMPTY_POOL_ID,
		templates = {},
	}
	for _, entry in ipairs (def.elements) do
		local elem = prepare_element (entry)
		for _ = 1, entry.weight do
			insert (pool.templates, elem)
		end
	end
	registered_pools[id] = pool
end

registered_pools[EMPTY_POOL_ID] = {
	id = EMPTY_POOL_ID,
	fallback = EMPTY_POOL_ID,
	templates = {},
}

local function shuffled_templates (pool, rng)
	local list = {}
	local templates = pool.templates
	for i = 1, #templates do
		list[i] = templates[i]
	end
	fisher_yates (list, rng)
	return list
end

------------------------------------------------------------------------
-- Pool elements.
------------------------------------------------------------------------

local function compare_selection_priority (a, b)
	return a.selection_priority > b.selection_priority
end

local FEATURE_JIGSAW = {
	x = 0, y = 0, z = 0,
	front = "down",
	top = "south",
	name = nil,
	pool = EMPTY_POOL_ID,
	target = "minecraft:empty",
	rollable = true,
	placement_priority = 0,
	selection_priority = 0,
}

-- StructurePoolElement.getShuffledJigsawBlocks.

local function element_jigsaws (elem, px, py, pz, rotation, rng)
	local kind = elem.kind
	if kind == "single" then
		local list = {}
		for i, info in ipairs (elem.jigsaws) do
			local x, y, z = rotate_pos (info.x, info.y, info.z, rotation)
			local rot = ROTATE_DIR[rotation]
			list[i] = {
				x = x + px,
				y = y + py,
				z = z + pz,
				front = rot[info.front],
				top = rot[info.top],
				name = info.name,
				pool = info.pool,
				target = info.target,
				rollable = info.rollable,
				placement_priority = info.placement_priority,
				selection_priority = info.selection_priority,
			}
		end
		fisher_yates (list, rng)
		stable_sort (list, compare_selection_priority)
		return list
	elseif kind == "feature" then
		local j = FEATURE_JIGSAW
		return {
			{
				x = px, y = py, z = pz,
				front = j.front,
				top = j.top,
				name = nil,
				pool = j.pool,
				target = j.target,
				rollable = true,
				placement_priority = 0,
				selection_priority = 0,
			},
		}
	elseif kind == "list" then
		return element_jigsaws (elem.elements[1], px, py, pz, rotation, rng)
	else
		return {}
	end
end

local function element_bbox (elem, x, y, z, rotation)
	local kind = elem.kind
	if kind == "single" then
		local template = elem.template
		local sx, sy, sz
		if template then
			sx, sy, sz = template.width - 1, template.height - 1,
				template.length - 1
		else
			sx, sy, sz = -1, -1, -1
		end
		local x2, y2, z2 = rotate_pos (sx, sy, sz, rotation)
		return {
			mathmin (0, x2) + x,
			mathmin (0, y2) + y,
			mathmin (0, z2) + z,
			mathmax (0, x2) + x,
			mathmax (0, y2) + y,
			mathmax (0, z2) + z,
		}
	elseif kind == "feature" then
		return { x, y, z, x, y, z, }
	elseif kind == "list" then
		local box
		for _, sub in ipairs (elem.elements) do
			if sub ~= EMPTY_ELEMENT then
				local b = element_bbox (sub, x, y, z, rotation)
				if not box then
					box = b
				else
					box[1] = mathmin (box[1], b[1])
					box[2] = mathmin (box[2], b[2])
					box[3] = mathmin (box[3], b[3])
					box[4] = mathmax (box[4], b[4])
					box[5] = mathmax (box[5], b[5])
					box[6] = mathmax (box[6], b[6])
				end
			end
		end
		return box
	else
		return { x, y, z, x, y, z, }
	end
end
mcl_levelgen.mc_element_bbox = element_bbox

-- JigsawBlock.canAttach.

local function can_attach (source, target)
	return source.front == OPPOSITE[target.front]
		and (source.rollable or source.top == target.top)
		and (target.name == nil or source.target == target.name)
end

------------------------------------------------------------------------
-- Free space bookkeeping.
--
-- Minecraft records the space available to children of a piece as a
-- VoxelShape from which the boxes of placed pieces are subtracted;
-- since every such shape is a box minus a union of boxes, it is
-- represented here as precisely that.
------------------------------------------------------------------------

local function box_inside_p (outer, b)
	return b[1] >= outer[1] and b[2] >= outer[2] and b[3] >= outer[3]
		and b[4] <= outer[4] and b[5] <= outer[5] and b[6] <= outer[6]
end

local function boxes_intersect_p (a, b)
	return a[1] <= b[4] and b[1] <= a[4]
		and a[2] <= b[5] and b[2] <= a[5]
		and a[3] <= b[6] and b[3] <= a[6]
end

local function free_fits_p (free, box)
	if not box_inside_p (free.box, box) then
		return false
	end
	local removed = free.removed
	for i = 1, #removed do
		if boxes_intersect_p (removed[i], box) then
			return false
		end
	end
	return true
end

local function free_subtract (free, box)
	insert (free.removed, box)
end

------------------------------------------------------------------------
-- SequencedPriorityIterator.
------------------------------------------------------------------------

local function queue_add (queue, data, priority)
	local q = queue.by_priority[priority]
	if not q then
		q = { first = 1, last = 0, }
		queue.by_priority[priority] = q
		insert (queue.priorities, priority)
	end
	q.last = q.last + 1
	q[q.last] = data
end

local function queue_next (queue)
	local best, best_q = nil, nil
	for _, priority in ipairs (queue.priorities) do
		local q = queue.by_priority[priority]
		if q.first <= q.last and (not best or priority > best) then
			best, best_q = priority, q
		end
	end
	if not best_q then
		return nil
	end
	local item = best_q[best_q.first]
	best_q[best_q.first] = nil
	best_q.first = best_q.first + 1
	return item
end

------------------------------------------------------------------------
-- JigsawPlacement.
------------------------------------------------------------------------

local function make_piece (elem, x, y, z, ground_level_delta, rotation, bbox)
	return {
		element = elem,
		x = x, y = y, z = z,
		ground_level_delta = ground_level_delta,
		rotation = rotation,
		bbox = bbox,
		junctions = {},
	}
end

local function try_placing_children (placer, source, context_free, depth)
	local rng = placer.rng
	local source_elem = source.element
	local source_rigid = source_elem.projection == "rigid"
	local source_free = { shape = nil, }
	local source_bb = source.bbox
	local source_box_y = source_bb[2]
	local pools = registered_pools

	local source_jigsaws
		= element_jigsaws (source_elem, source.x, source.y, source.z,
				   source.rotation, rng)
	for _, source_jigsaw in ipairs (source_jigsaws) do
		local dir = DIR_VECTORS[source_jigsaw.front]
		local tx = source_jigsaw.x + dir[1]
		local ty = source_jigsaw.y + dir[2]
		local tz = source_jigsaw.z + dir[3]
		local source_jigsaw_local_y = source_jigsaw.y - source_box_y
		local target_pool = pools[source_jigsaw.pool]

		if not target_pool
			or (#target_pool.templates == 0
			    and source_jigsaw.pool ~= EMPTY_POOL_ID) then
			if not placer.warned[source_jigsaw.pool] then
				placer.warned[source_jigsaw.pool] = true
				core.log ("warning", "[mcl_levelgen] Empty or non-existent pool: "
					  .. tostring (source_jigsaw.pool))
			end
		else
			local fallback = pools[target_pool.fallback]
			if not fallback
				or (#fallback.templates == 0
				    and target_pool.fallback ~= EMPTY_POOL_ID) then
				if not placer.warned[target_pool.fallback] then
					placer.warned[target_pool.fallback] = true
					core.log ("warning", "[mcl_levelgen] Empty or non-existent fallback pool: "
						  .. tostring (target_pool.fallback))
				end
			else
				local inside = tx >= source_bb[1] and tx <= source_bb[4]
					and ty >= source_bb[2] and ty <= source_bb[5]
					and tz >= source_bb[3] and tz <= source_bb[6]
				local children_free
				if inside then
					children_free = source_free
					if not source_free.shape then
						source_free.shape = {
							box = {
								source_bb[1], source_bb[2], source_bb[3],
								source_bb[4], source_bb[5], source_bb[6],
							},
							removed = {},
						}
					end
				else
					children_free = context_free
				end

				local target_pieces = {}
				if depth ~= placer.max_depth then
					target_pieces = shuffled_templates (target_pool, rng)
				end
				local fallback_list = shuffled_templates (fallback, rng)
				for _, elem in ipairs (fallback_list) do
					insert (target_pieces, elem)
				end
				local placement_priority = source_jigsaw.placement_priority
				local placed = false

				for _, target_elem in ipairs (target_pieces) do
					if target_elem == EMPTY_ELEMENT then
						break
					end

					local rotations = {
						ROTATIONS[1], ROTATIONS[2],
						ROTATIONS[3], ROTATIONS[4],
					}
					fisher_yates (rotations, rng)
					for _, target_rotation in ipairs (rotations) do
						local target_jigsaws
							= element_jigsaws (target_elem, 0, 0, 0,
									   target_rotation, rng)
						for _, target_jigsaw in ipairs (target_jigsaws) do
							if can_attach (source_jigsaw, target_jigsaw) then
								local rx = tx - target_jigsaw.x
								local ry = ty - target_jigsaw.y
								local rz = tz - target_jigsaw.z
								local raw_bb = element_bbox (target_elem, rx, ry, rz,
											     target_rotation)
								local raw_target_y = raw_bb[2]
								local target_rigid
									= target_elem.projection == "rigid"
								local target_jigsaw_local_y = target_jigsaw.y
								local delta_y = source_jigsaw_local_y
									- target_jigsaw_local_y
									+ dir[2]
								local target_box_y
								if source_rigid and target_rigid then
									target_box_y = source_box_y + delta_y
								else
									error ("terrain_matching jigsaw projection is not implemented")
								end
								local y_offset = target_box_y - raw_target_y
								local target_bb = {
									raw_bb[1], raw_bb[2] + y_offset, raw_bb[3],
									raw_bb[4], raw_bb[5] + y_offset, raw_bb[6],
								}
								if free_fits_p (children_free.shape, target_bb) then
									free_subtract (children_free.shape, target_bb)
									local source_gld = source.ground_level_delta
									local target_gld
									if target_rigid then
										target_gld = source_gld - delta_y
									else
										target_gld = target_elem.ground_level_delta
									end
									local piece = make_piece (target_elem, rx,
												  ry + y_offset, rz,
												  target_gld,
												  target_rotation,
												  target_bb)
									local junction_y
									if source_rigid then
										junction_y = source_box_y
											+ source_jigsaw_local_y
									else
										junction_y = target_box_y
											+ target_jigsaw_local_y
									end
									insert (source.junctions, {
										tx,
										junction_y - source_jigsaw_local_y
											+ source_gld,
										tz,
										delta_y,
									})
									insert (piece.junctions, {
										source_jigsaw.x,
										junction_y - target_jigsaw_local_y
											+ target_gld,
										source_jigsaw.z,
										-delta_y,
									})
									insert (placer.pieces, piece)
									if depth + 1 <= placer.max_depth then
										queue_add (placer.queue, {
											piece = piece,
											free = children_free,
											depth = depth + 1,
										}, placement_priority)
									end
									placed = true
									break
								end
							end
						end
						if placed then
							break
						end
					end
					if placed then
						break
					end
				end
			end
		end
	end
end

-- JigsawPlacement.addPieces.  Return a list of pieces (see make_piece)
-- and the position used for the biome test, or nil.  BIOME_TEST is
-- invoked with the latter position before any children are generated.

function mcl_levelgen.mc_jigsaw_add_pieces (rng, start_pool, start_jigsaw_name,
					    max_depth, x, y, z, max_distance,
					    level_min, level_height,
					    biome_test, biome_test_data)
	local rotation = ROTATIONS[1 + rng:next_within (4)]
	local pool = registered_pools[start_pool]
	if not pool then
		core.log ("error", "[mcl_levelgen] Start pool " .. start_pool
			  .. " does not exist")
		return nil
	end
	local templates = pool.templates
	local center_elem
	if #templates == 0 then
		center_elem = EMPTY_ELEMENT
	else
		center_elem = templates[1 + rng:next_within (#templates)]
	end
	if center_elem == EMPTY_ELEMENT then
		return nil
	end

	local ax, ay, az = x, y, z
	if start_jigsaw_name then
		local found = false
		for _, jigsaw in ipairs (element_jigsaws (center_elem, x, y, z,
							  rotation, rng)) do
			if jigsaw.name == start_jigsaw_name then
				ax, ay, az = jigsaw.x, jigsaw.y, jigsaw.z
				found = true
				break
			end
		end
		if not found then
			core.log ("error", "[mcl_levelgen] No starting jigsaw "
				  .. start_jigsaw_name .. " found in start pool "
				  .. start_pool)
			return nil
		end
	end

	local lx, ly, lz = ax - x, ay - y, az - z
	local px, py, pz = x - lx, y - ly, z - lz
	local gld = center_elem.ground_level_delta
	local box = element_bbox (center_elem, px, py, pz, rotation)
	local center = make_piece (center_elem, px, py, pz, gld, rotation, box)
	local center_x = rtz ((box[4] + box[1]) / 2)
	local center_z = rtz ((box[6] + box[3]) / 2)
	local bottom_y = py
	local old_ground_y = box[2] + gld
	local dy = bottom_y - old_ground_y
	center.y = center.y + dy
	box[2] = box[2] + dy
	box[5] = box[5] + dy
	local center_y = bottom_y + ly

	if biome_test and not biome_test (center_x, center_y, center_z,
					  biome_test_data) then
		return nil
	end

	local pieces = { center, }
	if max_depth > 0 then
		local level_max = level_min + level_height - 1
		local free = {
			box = {
				center_x - max_distance,
				mathmax (center_y - max_distance, level_min),
				center_z - max_distance,
				center_x + max_distance,
				mathmin (center_y + max_distance, level_max),
				center_z + max_distance,
			},
			removed = {
				{ box[1], box[2], box[3], box[4], box[5], box[6], },
			},
		}
		local placer = {
			rng = rng,
			max_depth = max_depth,
			pieces = pieces,
			queue = { by_priority = {}, priorities = {}, },
			warned = {},
		}
		try_placing_children (placer, center, { shape = free, }, 0)
		local item = queue_next (placer.queue)
		while item do
			try_placing_children (placer, item.piece, item.free, item.depth)
			item = queue_next (placer.queue)
		end
	end
	return pieces, center_x, center_y, center_z
end

------------------------------------------------------------------------
-- Structure pieces.
------------------------------------------------------------------------

local function place_nothing ()
end

local function place_list_piece (self, level, terrain, rng, x1, z1, x2, z2)
	for _, sub in ipairs (self.subpieces) do
		sub:place (level, terrain, rng, x1, z1, x2, z2)
	end
end

-- Convert pieces produced by `mc_jigsaw_add_pieces' into structure
-- pieces.  FEATURE_PIECE is a function (FEATURE, X, Y, Z) returning a
-- structure piece that places FEATURE at X, Y, Z.

local function single_piece (elem, piece, rng)
	if not elem.template then
		return nil
	end
	return mcl_levelgen.make_template_piece (elem.template, piece.x, piece.y,
						 piece.z, nil, piece.rotation,
						 rng, nil, elem.processors,
						 piece.ground_level_delta,
						 piece.bbox)
end

function mcl_levelgen.mc_jigsaw_structure_pieces (pieces, rng, feature_piece,
						  junction_amplitude)
	local result = {}
	for _, piece in ipairs (pieces) do
		local elem = piece.element
		local sp
		if elem.kind == "single" then
			sp = single_piece (elem, piece, rng)
			if not sp then
				sp = {
					place = place_nothing,
					bbox = piece.bbox,
				}
			end
		elseif elem.kind == "list" then
			local subs = {}
			for _, sub in ipairs (elem.elements) do
				if sub.kind == "single" then
					local p = single_piece (sub, piece, rng)
					if p then
						insert (subs, p)
					end
				elseif sub.kind == "feature" then
					insert (subs, feature_piece (sub.feature, piece.x,
								     piece.y, piece.z))
				end
			end
			sp = {
				place = place_list_piece,
				subpieces = subs,
				bbox = piece.bbox,
			}
		elseif elem.kind == "feature" then
			sp = feature_piece (elem.feature, piece.x, piece.y, piece.z)
			sp.bbox = piece.bbox
		end
		sp.ground_offset = piece.ground_level_delta
		sp.no_terrain_adaptation = elem.projection ~= "rigid"
		sp.mc_rotation = piece.rotation
		sp.mc_element = elem
		insert (result, sp)
	end

	-- Jigsaw junctions (Beardifier).
	if junction_amplitude then
		for _, piece in ipairs (pieces) do
			for _, junction in ipairs (piece.junctions) do
				local x, y, z = junction[1], junction[2], junction[3]
				insert (result, {
					place = place_nothing,
					bbox = { x, y, z, x, y, z, },
					reduced_terrain_adaptation = {
						x, y, z, junction_amplitude,
					},
					no_record = true,
				})
			end
		end
	end
	return result
end

------------------------------------------------------------------------
-- Jigsaw structure starts.
------------------------------------------------------------------------

local function biome_test (x, y, z, data)
	return mcl_levelgen.structure_biome_test (data[1], data[2], x, y, z)
end

-- A `create_start' function for structures defined with:
--   {
--     start_pool = POOL,
--     start_jigsaw_name = NAME or nil,
--     size = MAX_DEPTH,
--     max_distance_from_center = N,
--     start_height = function (rng) ... end,
--     feature_piece = function (feature, x, y, z) ... end,
--     record_full_bounds = STRUCTURE_ID or nil,
--   }
-- Heightmap projection is not supported.

function mcl_levelgen.mc_jigsaw_create_start (self, level, terrain, rng, cx, cz)
	local x, z = cx * 16, cz * 16
	local y = self.start_height (rng)
	local preset = level.preset
	local data = { level, self, }
	local pieces = mcl_levelgen.mc_jigsaw_add_pieces (rng, self.start_pool,
							  self.start_jigsaw_name,
							  self.size, x, y, z,
							  self.max_distance_from_center,
							  preset.min_y, preset.height,
							  biome_test, data)
	if not pieces then
		return nil
	end
	local result = mcl_levelgen.mc_jigsaw_structure_pieces (pieces, rng,
								self.feature_piece,
								self.terrain_adaptation ~= "none"
								and 0.4 or nil)
	if self.record_full_bounds then
		local bbox = mcl_levelgen.bbox_from_pieces (result)
		insert (result, {
			place = place_nothing,
			bbox = bbox,
			no_terrain_adaptation = true,
			record_as = self.record_full_bounds,
		})
	end
	return mcl_levelgen.create_structure_start (self, result)
end
