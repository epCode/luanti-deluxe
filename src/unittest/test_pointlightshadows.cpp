// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "test.h"

#include "client/shadows/pointlightshadows.h"
#include "constants.h"

class TestPointLightShadows : public TestBase {
public:
	TestPointLightShadows() { TestManager::registerTestModule(this); }
	const char *getName() override { return "TestPointLightShadows"; }

	void runTests(IGameDef *gamedef) override;

	void testBoxMask();
};

static TestPointLightShadows g_test_instance;

void TestPointLightShadows::runTests(IGameDef *gamedef)
{
	TEST(testBoxMask);
}

static u64 mask_of(std::vector<aabb3f> boxes)
{
	return PointLightShadows::computeBoxMask(boxes);
}

// Mask of the sub-voxels within [x0, x1) x [y0, y1) x [z0, z1)
static u64 cells(int x0, int x1, int y0, int y1, int z0, int z1)
{
	u64 mask = 0;
	for (int z = z0; z < z1; z++)
	for (int y = y0; y < y1; y++)
	for (int x = x0; x < x1; x++)
		mask |= (u64)1 << (x + 4 * y + 16 * z);
	return mask;
}

void TestPointLightShadows::testBoxMask()
{
	const float h = BS / 2;
	UASSERTEQ(u64, mask_of({}), 0);
	// Full node
	UASSERTEQ(u64, mask_of({{-h, -h, -h, h, h, h}}), ~(u64)0);
	// Bottom slab
	UASSERTEQ(u64, mask_of({{-h, -h, -h, h, 0, h}}), cells(0, 4, 0, 2, 0, 4));
	// Stair: bottom slab and the upper back half (+Z)
	UASSERTEQ(u64, mask_of({{-h, -h, -h, h, 0, h}, {-h, 0, 0, h, h, h}}),
			cells(0, 4, 0, 2, 0, 4) | cells(0, 4, 2, 4, 2, 4));
	// Fence post, 4/16 wide: covers half of the middle sub-voxels along X and Z
	const float post = BS * 2 / 16;
	UASSERTEQ(u64, mask_of({{-post, -h, -post, post, h, post}}), cells(1, 3, 0, 4, 1, 3));
	// Carpet, 1/16 high: too thin
	UASSERTEQ(u64, mask_of({{-h, -h, -h, h, -h + BS / 16, h}}), 0);
	// Boxes reaching out of the node are clipped, inverted ones repaired
	UASSERTEQ(u64, mask_of({{h * 3, h * 3, h * 3, -h * 3, -h * 3, -h * 3}}), ~(u64)0);
}
