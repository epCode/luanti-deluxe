// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2013 celeron55, Perttu Ahola <celeron55@gmail.com>

#include "test.h"

#include "gamedef.h"
#include "voxelalgorithms.h"
#include "util/numeric.h"
#include "dummymap.h"
#include "nodedef.h"

class TestVoxelAlgorithms : public TestBase {
public:
	TestVoxelAlgorithms() { TestManager::registerTestModule(this); }
	const char *getName() { return "TestVoxelAlgorithms"; }

	void runTests(IGameDef *gamedef);

	void testVoxelLineIterator();
	void testLighting(IGameDef *gamedef);
	void testExtendedLighting(IGameDef *gamedef);
};

static TestVoxelAlgorithms g_test_instance;

void TestVoxelAlgorithms::runTests(IGameDef *gamedef)
{
	TEST(testVoxelLineIterator);
	TEST(testLighting, gamedef);
	TEST(testExtendedLighting, gamedef);
}

////////////////////////////////////////////////////////////////////////////////

void TestVoxelAlgorithms::testVoxelLineIterator()
{
	// Test some lines
	std::vector<core::line3d<f32>> lines;
	for (f32 x = -9.1f; x < 9.0f; x += 3.124f)
	for (f32 y = -9.2f; y < 9.0f; y += 3.123f)
	for (f32 z = -9.3f; z < 9.0f; z += 3.122f) {
		lines.emplace_back(-x, -y, -z, x, y, z);
	}
	for (f32 x = -3.0f; x < 3.1f; x += 0.5f)
	for (f32 y = -3.0f; y < 3.1f; y += 0.5f)
	for (f32 z = -3.0f; z < 3.1f; z += 0.5f) {
		lines.emplace_back(-x, -y, -z, x, y, z);
	}
	lines.emplace_back(0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f);
	// Test every line
	for (auto l : lines) {
		// Initialize test
		voxalgo::VoxelLineIterator iterator(l.start, l.getVector());

		//Test the first voxel
		v3s16 start_voxel = floatToInt(l.start, 1.0f);
		UASSERT(iterator.m_current_node_pos == start_voxel);

		// Values for testing
		v3s16 end_voxel = floatToInt(l.end, 1.0f);
		v3s16 voxel_vector = end_voxel - start_voxel;
		int nodecount = abs(voxel_vector.X) + abs(voxel_vector.Y)
			+ abs(voxel_vector.Z);
		int actual_nodecount = 0;
		v3s16 old_voxel = iterator.m_current_node_pos;

		while (iterator.hasNext()) {
			iterator.next();
			actual_nodecount++;
			v3s16 new_voxel = iterator.m_current_node_pos;
			// This must be a neighbor of the old voxel
			UASSERTEQ(f32, (new_voxel - old_voxel).getLengthSQ(), 1);
			// The line must intersect with the voxel
			v3f voxel_center = intToFloat(iterator.m_current_node_pos, 1);
			constexpr f32 eps = 1.0e-5f;
			aabb3f box(voxel_center - v3f(0.5f + eps),
				voxel_center + v3f(0.5f + eps));
			UASSERT(box.intersectsWithLine(l));
			// Update old voxel
			old_voxel = new_voxel;
		}

		// Test last node
		UASSERT(iterator.m_current_node_pos == end_voxel);
		// Test node count
		UASSERTEQ(int, actual_nodecount, nodecount);
	}
}

void TestVoxelAlgorithms::testLighting(IGameDef *gamedef)
{
	v3s16 pmin(-32, -32, -32);
	v3s16 pmax(31, 31, 31);
	v3s16 bpmin = getNodeBlockPos(pmin), bpmax = getNodeBlockPos(pmax);
	DummyMap map(gamedef, bpmin, bpmax);

	// Make a 21x21x21 hollow box centered at the origin.
	{
		std::map<v3s16, MapBlock*> modified_blocks;
		MMVManip vm(&map);
		vm.initialEmerge(bpmin, bpmax, false);
		u32 volume = vm.m_area.getVolume();
		for (u32 i = 0; i < volume; i++)
			vm.m_data[i] = MapNode(CONTENT_AIR);
		for (s16 z = -10; z <= 10; z++)
		for (s16 y = -10; y <= 10; y++)
		for (s16 x = -10; x <= 10; x++)
			vm.setNodeNoEmerge(v3s16(x, y, z), MapNode(t_CONTENT_STONE));
		for (s16 z = -9; z <= 9; z++)
		for (s16 y = -9; y <= 9; y++)
		for (s16 x = -9; x <= 9; x++)
			vm.setNodeNoEmerge(v3s16(x, y, z), MapNode(CONTENT_AIR));
		voxalgo::blit_back_with_light(&map, &vm, &modified_blocks);
	}

	// Place two holes on the edges a torch in the center.
	{
		std::map<v3s16, MapBlock*> modified_blocks;
		map.addNodeAndUpdate(v3s16(-10, 0, 0), MapNode(CONTENT_AIR), modified_blocks);
		map.addNodeAndUpdate(v3s16(9, 10, -9), MapNode(t_CONTENT_WATER), modified_blocks);
		map.addNodeAndUpdate(v3s16(0, 0, 0), MapNode(t_CONTENT_TORCH), modified_blocks);
		map.addNodeAndUpdate(v3s16(-10, 1, 0), MapNode(t_CONTENT_STONE, 153), modified_blocks);
	}

	const NodeDefManager *ndef = gamedef->ndef();
	{
		MapNode n = map.getNode(v3s16(9, 9, -9));
		UASSERTEQ(int, n.getLight(LIGHTBANK_NIGHT, ndef->getLightingFlags(n)), 0);
		UASSERTEQ(int, n.getLight(LIGHTBANK_DAY, ndef->getLightingFlags(n)), 13);
	}
	{
		MapNode n = map.getNode(v3s16(0, 1, 0));
		UASSERTEQ(int, n.getLight(LIGHTBANK_NIGHT, ndef->getLightingFlags(n)), 12);
		UASSERTEQ(int, n.getLight(LIGHTBANK_DAY, ndef->getLightingFlags(n)), 12);
	}
	{
		MapNode n = map.getNode(v3s16(-9, -1, 0));
		UASSERTEQ(int, n.getLight(LIGHTBANK_NIGHT, ndef->getLightingFlags(n)), 3);
		UASSERTEQ(int, n.getLight(LIGHTBANK_DAY, ndef->getLightingFlags(n)), 12);
	}
	{
		MapNode n = map.getNode(v3s16(-10, 0, 0));
		UASSERTEQ(int, n.getLight(LIGHTBANK_NIGHT, ndef->getLightingFlags(n)), 3);
		UASSERTEQ(int, n.getLight(LIGHTBANK_DAY, ndef->getLightingFlags(n)), 14);
	}
	{
		MapNode n = map.getNode(v3s16(-11, 0, 0));
		UASSERTEQ(int, n.getLight(LIGHTBANK_NIGHT, ndef->getLightingFlags(n)), 2);
		UASSERTEQ(int, n.getLight(LIGHTBANK_DAY, ndef->getLightingFlags(n)), 15);
	}
	{
		// Test that irrelevant param1 values are not clobbered.
		MapNode n = map.getNode(v3s16(-10, 1, 0));
		UASSERTEQ(int, n.getParam1(), 153);
	}
}

void TestVoxelAlgorithms::testExtendedLighting(IGameDef *gamedef)
{
	v3s16 pmin(-64, -16, -16);
	v3s16 pmax(63, 31, 15);
	v3s16 bpmin = getNodeBlockPos(pmin), bpmax = getNodeBlockPos(pmax);
	DummyMap map(gamedef, bpmin, bpmax);
	const NodeDefManager *ndef = gamedef->ndef();

	// Stone everywhere but a corridor along X, with a shaft to the sky
	// at x = 50
	{
		std::map<v3s16, MapBlock*> modified_blocks;
		MMVManip vm(&map);
		vm.initialEmerge(bpmin, bpmax, false);
		u32 volume = vm.m_area.getVolume();
		for (u32 i = 0; i < volume; i++)
			vm.m_data[i] = MapNode(t_CONTENT_STONE);
		for (s16 x = -60; x <= 60; x++)
			vm.setNodeNoEmerge(v3s16(x, 0, 0), MapNode(CONTENT_AIR));
		for (s16 y = 1; y <= pmax.Y; y++)
			vm.setNodeNoEmerge(v3s16(50, y, 0), MapNode(CONTENT_AIR));
		voxalgo::blit_back_with_light(&map, &vm, &modified_blocks);
	}

	auto light_at = [&] (s16 x, LightBank bank) -> int {
		MapNode n = map.getNode(v3s16(x, 0, 0));
		return n.getLight(bank, ndef->getLightingFlags(n));
	};

	// Sunlight comes down the shaft and spreads sideways as before
	{
		MapNode n = map.getNode(v3s16(50, 0, 0));
		UASSERT(n.isSunlit(ndef->getLightingFlags(n)));
		UASSERTEQ(int, light_at(50, LIGHTBANK_DAY), LIGHT_SUN_LEVEL);
		UASSERTEQ(int, light_at(49, LIGHTBANK_DAY), LIGHT_MAX);
		UASSERTEQ(int, light_at(45, LIGHTBANK_DAY), LIGHT_MAX - 4);
		UASSERTEQ(int, light_at(36, LIGHTBANK_DAY), 1);
		UASSERTEQ(int, light_at(35, LIGHTBANK_DAY), 0);
		UASSERTEQ(int, light_at(45, LIGHTBANK_NIGHT), 0);
	}

	// A lamp lights up to 39 nodes away
	{
		std::map<v3s16, MapBlock*> modified_blocks;
		map.addNodeAndUpdate(v3s16(0, 0, 0), MapNode(t_CONTENT_LAMP), modified_blocks);
	}
	UASSERTEQ(int, light_at(0, LIGHTBANK_NIGHT), 40);
	UASSERTEQ(int, light_at(0, LIGHTBANK_DAY), 40);
	UASSERTEQ(int, light_at(-1, LIGHTBANK_NIGHT), 39);
	UASSERTEQ(int, light_at(-25, LIGHTBANK_NIGHT), 15);
	UASSERTEQ(int, light_at(-39, LIGHTBANK_NIGHT), 1);
	UASSERTEQ(int, light_at(-40, LIGHTBANK_NIGHT), 0);
	UASSERTEQ(int, light_at(-30, LIGHTBANK_DAY), 10);
	// Next to the sunlit node, the lamp is brighter than sunlight
	UASSERTEQ(int, light_at(39, LIGHTBANK_NIGHT), 1);
	UASSERTEQ(int, light_at(45, LIGHTBANK_DAY), LIGHT_MAX - 4);
	UASSERTEQ(int, light_at(20, LIGHTBANK_DAY), 20);
	{
		// The day bank reports max(sunlight, artificial light)
		std::map<v3s16, MapBlock*> modified_blocks;
		map.addNodeAndUpdate(v3s16(48, 0, 0), MapNode(t_CONTENT_LAMP), modified_blocks);
		UASSERTEQ(int, light_at(50, LIGHTBANK_DAY), 38);
		UASSERTEQ(int, light_at(50, LIGHTBANK_NIGHT), 38);
		MapNode n = map.getNode(v3s16(50, 0, 0));
		UASSERT(n.isSunlit(ndef->getLightingFlags(n)));
		UASSERTEQ(int, light_at(55, LIGHTBANK_NIGHT), 33);
		map.addNodeAndUpdate(v3s16(48, 0, 0), MapNode(CONTENT_AIR), modified_blocks);
		UASSERTEQ(int, light_at(50, LIGHTBANK_DAY), LIGHT_SUN_LEVEL);
		UASSERTEQ(int, light_at(55, LIGHTBANK_NIGHT), 0);
		UASSERTEQ(int, light_at(55, LIGHTBANK_DAY), LIGHT_MAX - 4);
	}

	// Removing the lamp removes all of its light
	{
		std::map<v3s16, MapBlock*> modified_blocks;
		map.addNodeAndUpdate(v3s16(0, 0, 0), MapNode(CONTENT_AIR), modified_blocks);
	}
	for (s16 x = -60; x <= 35; x++) {
		UASSERTEQ(int, light_at(x, LIGHTBANK_NIGHT), 0);
		UASSERTEQ(int, light_at(x, LIGHTBANK_DAY), 0);
	}
	UASSERTEQ(int, light_at(45, LIGHTBANK_DAY), LIGHT_MAX - 4);

	// Blending reports levels as games see them
	{
		MapNode n = map.getNode(v3s16(50, 0, 0));
		UASSERTEQ(int, n.getLightBlend(1000, ndef->getLightingFlags(n)), LIGHT_SUN_LEVEL);
	}
}
