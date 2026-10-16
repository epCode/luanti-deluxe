local S = core.get_translator(core.get_current_modname())

-- Implemented in mcl_player (crouching speed). Only found in ancient city
-- loot: like Soul Speed, it is a treasure enchantment that is neither
-- tradable nor obtained from random enchantments.
mcl_enchanting.register_enchantment("swift_sneak", {
	name = S("Swift Sneak"),
	max_level = 3,
	secondary = {armor_legs = true},
	disallow = {non_combat_armor = true},
	weight = 1,
	description = S("Increases movement speed while sneaking."),
	treasure = true,
	tradable = false,
	power_range_table = {{25, 75}, {50, 100}, {75, 125}},
	inv_combat_tab = true,
	anvil_item_factor = 8,
	anvil_book_factor = 4,
})

function mcl_enchanting.enchant_swift_sneak(stack, pr)
	return mcl_enchanting.enchant(stack, "swift_sneak", mcl_enchanting.random(pr, 1, 3))
end
