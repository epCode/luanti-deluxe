local S = core.get_translator(core.get_current_modname())

-- Flows like mcl_core lava (fast in the Nether), see mcl_core/nodes_liquid.lua

core.register_node("mcl_nether:nether_lava_source", table.merge(core.registered_nodes["mcl_core:lava_source"], {
	description = S("Nether Lava Source"),
	_doc_items_create_entry = false,
	_doc_items_entry_name = nil,
	_doc_items_longdesc = nil,
	_doc_items_usagehelp = nil,
	liquid_range = 7,
	liquid_alternative_source = "mcl_nether:nether_lava_source",
	liquid_alternative_flowing = "mcl_nether:nether_lava_flowing",
}))

core.register_node("mcl_nether:nether_lava_flowing", table.merge(core.registered_nodes["mcl_core:lava_flowing"], {
	description = S("Flowing Nether Lava"),
	_doc_items_create_entry = false,
	liquid_range = 7,
	liquid_alternative_flowing = "mcl_nether:nether_lava_flowing",
	liquid_alternative_source = "mcl_nether:nether_lava_source",
}))
doc.add_entry_alias("nodes", "mcl_core:lava_source", "nodes", "mcl_nether:nether_lava_source")
doc.add_entry_alias("nodes", "mcl_core:lava_source", "nodes", "mcl_nether:nether_lava_flowing")

