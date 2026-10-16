local S = core.get_translator(core.get_current_modname())
local F = core.formspec_escape
local H = core.hypertext_escape

local function get_formspec(text, title, author)
	local fs = "size[8,9]" ..
	"no_prepend[]" .. mcl_vars.gui_nonbg .. mcl_vars.gui_bg_color ..
	"style_type[button;border=false;bgimg=mcl_books_button9.png;bgimg_pressed=mcl_books_button9_pressed.png;bgimg_middle=2,2]" ..
	"background[-0.5,-0.5;9,10;mcl_books_book_bg.png]"

	if title ~= "" then
		fs = fs .. "scroll_container[0,0.5;8,0.7;;vertical]hypertext[0,-0.2;8,10;title;<style color=black font=normal size=24><center>"..H(F(title or "")).."</center></style>]scroll_container_end[]"
	end
	if author ~= "" then
		fs = fs .. "scroll_container[0.75,1.0;7.25,0.5;;vertical]hypertext[0,-0.2;7.25,10;author;<style color=black font=normal size=12>by </style><style color=#1E1E1E font=mono size=14>"..H(F(author or "")).."</style>]scroll_container_end[]"
	end
	fs = fs .."textarea[0.75,1.24;7.20,7.5;;" .. F(text or "") .. ";]" ..
	"button_exit[1.25,7.95;3,1;ok;" .. F(S("Done")) .. "]"..
	"button_exit[4.25,7.95;3,1;take;" .. F(S("Take Book")) .. "]"
	return fs
end

local lectern_tpl = {
	description = S("Lectern"),
	_tt_help = S("Lecterns not only look good, but are job site blocks for Librarians."),
	_doc_items_longdesc = S("Lecterns not only look good, but are job site blocks for Librarians."),
	_doc_items_usagehelp = S("Place the Lectern on a solid node for best results. May attract villagers, so it's best to place outside of where you call 'home'."),
	sounds = mcl_sounds.node_sound_wood_defaults(),
	paramtype = "light",
	paramtype2 = "facedir",
	drawtype = "mesh",
	mesh = "mcl_lectern_lectern.obj",
	tiles = {"mcl_lectern_lectern.png", },
	drop = "mcl_lectern:lectern",
	groups = {handy = 1, axey = 1, flammable = 2, fire_encouragement = 5, fire_flammability = 5, solid = 1, deco_block=1, lectern = 1, pathfinder_partial = 2},
	sunlight_propagates = true,
	is_ground_content = false,
	node_placement_prediction = "",
	_mcl_blast_resistance = 3,
	_mcl_hardness = 2,
	_mcl_burntime = 15,
	selection_box = {
		type = "fixed",
		fixed = {
			--   L,    T,    Ba,    R,    Bo,    F.
			{-0.5, -0.5, -0.5, 0.5, -0.5 + 2/16, 0.5},
			{-0.25, -0.5 + 2/16, -0.25, 0.25, 0.5 - 2/16, 0.25},
			{-0.5 + 1/16, 0.5 - 2/16, -0.5 + 1/16, 0.5 - 1/16, 0.5 + 2/16, 0.5 - 1/16},
		}
	},
	collision_box = {
		type = "fixed",
		fixed = {
			--   L,    T,    Ba,    R,    Bo,    F.
			{-0.32, 0.46, -0.32, 0.32, 0.175, 0.32},
			{-0.18, 0.175, -0.055, 0.18, -0.37, 0.21},
			{-0.5 + 1/16, 0.5 - 2/16, -0.5 + 1/16, 0.5 - 1/16, 0.5 + 0/16, 0.5 - 1/16},
		}
	},

	on_place = function(itemstack, placer, pointed_thing)

		if not placer or not placer:is_player() then
			return itemstack
		end

		local rc = mcl_util.call_on_rightclick(itemstack, placer, pointed_thing)
		if rc then return rc end

		if core.is_protected(pointed_thing.above, placer:get_player_name()) then
			core.record_protection_violation(pointed_thing.above, placer:get_player_name())
			return
		end

		if core.dir_to_wallmounted(vector.subtract(pointed_thing.under,  pointed_thing.above)) == 1 then
			local _, success = core.item_place_node(itemstack, placer, pointed_thing, core.dir_to_facedir(vector.direction(placer:get_pos(),pointed_thing.above)))
			if not success then
				return
			end
			core.sound_play(mcl_sounds.node_sound_wood_defaults().place, {pos=pointed_thing.above, gain=1}, true)
		end
		return itemstack
	end,
}

-- Port of Minecraft's LecternBlock.  Both nodes are states of one block
-- (HAS_BOOK); POWERED is kept in param2 >= 128.  The page (LecternBlockEntity)
-- is kept in the node metadata, 1-based.
local BLOCK = "mcl_lectern:lectern"

local function is_powered(node)
	return node.param2 >= 128
end

local function has_book(node)
	return node.name == "mcl_lectern:lectern_with_book"
end

-- Java float arithmetic (round to the nearest float)
local function fround(x)
	if x == 0 or x ~= x or x == math.huge or x == -math.huge then
		return x
	end
	local m, e = math.frexp(x)
	local s = m * 2^24
	local r = math.floor(s + 0.5)
	if r - s == 0.5 and r % 2 == 1 then
		r = r - 1
	end
	return math.ldexp(r, e - 24)
end

-- LecternBlockEntity.getRedstoneSignal
local function get_redstone_signal(pos)
	local meta = core.get_meta(pos)
	local page_count = tonumber(meta:get_string("pages")) or 1
	local page = (tonumber(meta:get_string("page")) or 1) - 1
	local progress = page_count > 1 and fround(page / (page_count - 1)) or 1
	return math.floor(fround(progress * 14)) + 1
end

-- LecternBlock.updateBelow
local function update_below(pos)
	mcl_redstone.update_neighbors_at(vector.offset(pos, 0, -1, 0), BLOCK)
end

-- LecternBlock.changePowered
local function change_powered(pos, node, powered)
	mcl_redstone.set_block(pos, {name = node.name, param2 = node.param2 % 128 + (powered and 128 or 0)}, 3)
	update_below(pos)
end

-- LecternBlock.resetBookState
local function reset_book_state(pos, node, with_book, source)
	local new = {
		name = with_book and "mcl_lectern:lectern_with_book" or "mcl_lectern:lectern",
		param2 = node.param2 % 128,
	}
	mcl_redstone.set_block(pos, new, 3)
	if mcl_gameevent then
		mcl_gameevent.emit("block_change", pos, {source = core.is_player(source) and source or nil, node = new})
	end
	update_below(pos)
end

-- LecternBlock.signalPageChange
local function signal_page_change(pos, node)
	change_powered(pos, node, true)
	mcl_redstone.schedule_tick(pos, BLOCK, 2)
end

local function own_signal(_, node)
	return is_powered(node) and 15 or 0
end

local redstone = {
	block = BLOCK,
	signal_source = true,
	own_signal = own_signal,
	get_signal = own_signal,
	get_direct_signal = function(_, node, d)
		return d == mcl_redstone.UP and is_powered(node) and 15 or 0
	end,
	analog_output = function(pos, node)
		return has_book(node) and get_redstone_signal(pos) or 0
	end,
	tick = function(pos, node)
		change_powered(pos, node, false)
	end,
	affect_neighbors_after_removal = function(pos, oldnode)
		if is_powered(oldnode) then
			update_below(pos)
		end
	end,
}

core.register_node("mcl_lectern:lectern", table.merge(lectern_tpl,{
	on_rightclick = function(pos, node, clicker, itemstack)
		if itemstack:get_name() == "mcl_books:written_book"
			or itemstack:get_name() == "mcl_books:writable_book" then
			local player_name = clicker:get_player_name()
			if core.is_protected(pos, player_name) then
				core.record_protection_violation(pos, player_name)
				return
			end
			-- LecternBlock.placeBook: LecternBlockEntity.setBook, then resetBookState
			local im = itemstack:get_meta()
			local nm = core.get_meta(pos)
			nm:set_string("formspec",get_formspec(im:get_string("text"),im:get_string("title"),im:get_string("author")))
			if itemstack:get_name() == "mcl_books:written_book" then
				nm:set_string("infotext", im:get_string("author") .. " - " .. im:get_string("title"))
			end
			nm:set_string("pages","15")
			nm:set_string("page","1")
			local book_item = ItemStack(itemstack)
			if not core.is_creative_enabled(player_name) then
				book_item = itemstack:take_item()
			end
			book_item:set_count(1)
			nm:set_string("book_item", book_item:to_string())
			reset_book_state(pos, node, true, clicker)
			return itemstack
		end
	end,
	_mcl_redstone = redstone,
}))

core.register_node("mcl_lectern:lectern_with_book", table.merge( lectern_tpl,{
	groups = table.merge(lectern_tpl.groups, {not_in_creative_inventory = 1}),
	mesh = "mcl_lectern_lectern_with_book.obj",
	on_receive_fields = function(pos, _, fields, sender)
		local sender_name = sender:get_player_name()
		if core.is_protected(pos, sender_name) then
			core.record_protection_violation(pos, sender_name)
			return
		end
		local node = core.get_node(pos)
		if node.name ~= "mcl_lectern:lectern_with_book" then
			return
		end
		if fields and fields.take then
			-- LecternBlockEntity.onBookItemRemove
			local inv = sender:get_inventory()
			local nm = core.get_meta(pos)
			local is = nm:get_string("book_item")
			if is and is ~= "" then
				inv:add_item("main", is)
			end
			for _, key in pairs({"book_item", "formspec", "infotext", "pages", "page"}) do
				nm:set_string(key, "")
			end
			reset_book_state(pos, node, false)
		elseif fields and fields.ok then
			-- simulate a page turn (LecternBlockEntity.setPage)
			-- TODO: actually implement multi page books
			local nm = core.get_meta(pos)
			local pages = tonumber(nm:get_string("pages")) or 1
			local page = tonumber(nm:get_string("page")) or 1
			local new_page = (page % pages) + 1
			if new_page ~= page then
				nm:set_string("page",tostring(new_page))
				mcl_redstone.update_comparators(pos) -- setChanged
				signal_page_change(pos, node)
			end
		end
	end,
	after_dig_node = function(pos, _, oldmetadata, _)
		if oldmetadata and oldmetadata.fields and oldmetadata.fields.book_item then
			core.add_item(pos, ItemStack(oldmetadata.fields.book_item))
		end
	end,
	_mcl_redstone = redstone,
}))

-- Lecterns left powered by the previous implementation
core.register_lbm({
	label = "Turn off powered lecterns",
	name = "mcl_lectern:unpower",
	nodenames = {"mcl_lectern:lectern", "mcl_lectern:lectern_with_book"},
	run_at_every_load = true,
	action = function(pos, node)
		if is_powered(node) and not mcl_redstone.has_scheduled_tick(pos, BLOCK) then
			mcl_redstone.schedule_tick(pos, BLOCK, 2)
		end
	end,
})

mcl_wip.register_wip_item("mcl_lectern:lectern")

-- April Fools setup
local date = os.date("*t")
if (date.month == 4 and date.day == 1) then
	core.override_item("mcl_lectern:lectern", {waving = 2})
end

core.register_craft({
	output = "mcl_lectern:lectern",
	recipe = {
		{"group:wood_slab", "group:wood_slab", "group:wood_slab"},
		{"", "mcl_books:bookshelf", ""},
		{"", "group:wood_slab", ""},
	}
})
