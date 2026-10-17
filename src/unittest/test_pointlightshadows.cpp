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
	void testBoxRows();
	void testRasterizeTriangle();
};

static TestPointLightShadows g_test_instance;

void TestPointLightShadows::runTests(IGameDef *gamedef)
{
	TEST(testBoxMask);
	TEST(testBoxRows);
	TEST(testRasterizeTriangle);
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

// Position of volume coordinates v in a box, from the rows
static v3f box_pos(const f32 rows[12], v3f v)
{
	auto row = [&] (int r) {
		return rows[4 * r] * v.X + rows[4 * r + 1] * v.Y + rows[4 * r + 2] * v.Z + rows[4 * r + 3];
	};
	return v3f(row(0), row(1), row(2));
}

void TestPointLightShadows::testBoxRows()
{
	// A box 2 x 4 x 6 (local), turned 90 degrees around Y, scaled by 2 and
	// moved; the volume corner is at scene position (5, 0, -5)
	const aabb3f box(v3f(-1, -2, -3), v3f(1, 2, 3));
	core::matrix4 transform;
	transform.setTranslation(v3f(30, 40, 50));
	core::matrix4 rot;
	rot.setRotationDegrees(v3f(0, 90, 0));
	core::matrix4 scale;
	scale.setScale(v3f(2, 2, 2));
	transform *= rot;
	transform *= scale;
	const v3f origin(5, 0, -5);
	f32 rows[12];
	PointLightShadows::computeBoxRows(box, transform, origin, rows);

	auto check = [&] (v3f local, v3f expected) {
		v3f scene = local;
		transform.transformVect(scene);
		const v3f v = (scene - origin) / BS;
		const v3f u = box_pos(rows, v);
		UASSERT(u.getDistanceFrom(expected) < 1e-4f);
	};
	check(v3f(0, 0, 0), v3f(0, 0, 0));
	check(v3f(1, 2, 3), v3f(1, 1, 1));
	check(v3f(-1, 2, -3), v3f(-1, 1, -1));
	check(v3f(0.5f, -1, 1.5f), v3f(0.5f, -0.5f, 0.5f));
	check(v3f(2, 0, 0), v3f(2, 0, 0));

	// Degenerate transformations never contain anything
	core::matrix4 flat;
	flat.setScale(v3f(1, 0, 1));
	PointLightShadows::computeBoxRows(box, flat, origin, rows);
	const v3f u = box_pos(rows, v3f(0.5f, 0.5f, 0.5f));
	UASSERT(std::fabs(u.X) > 1 || std::fabs(u.Y) > 1 || std::fabs(u.Z) > 1);
}

void TestPointLightShadows::testRasterizeTriangle()
{
	// Closed cube from 0.4 to 2.4 sub-voxels, faces with outward normals
	const f32 lo = 0.4f, hi = 2.4f;
	auto cube = [&] (std::unordered_map<v3s16, u64> &voxels,
			const PointLightShadows::AlphaMask *mask) {
		for (int axis = 0; axis < 3; axis++)
		for (int side = 0; side < 2; side++) {
			const int a1 = (axis + 1) % 3, a2 = (axis + 2) % 3;
			v3f corners[4];
			for (int k = 0; k < 4; k++) {
				corners[k][axis] = side ? hi : lo;
				corners[k][a1] = (k == 1 || k == 2) ? hi : lo;
				corners[k][a2] = (k >= 2) ? hi : lo;
			}
			v3f normal;
			normal[axis] = side ? 1.0f : -1.0f;
			PointLightShadows::rasterizeTriangle(corners[0], corners[1], corners[2],
					normal, voxels, mask, {0, 0}, {1, 0}, {1, 1});
			PointLightShadows::rasterizeTriangle(corners[0], corners[2], corners[3],
					normal, voxels, mask, {0, 0}, {1, 1}, {0, 1});
		}
	};

	// The sub-voxels whose centers are inside: (0..1)^3 of node (0, 0, 0)
	std::unordered_map<v3s16, u64> voxels;
	cube(voxels, nullptr);
	UASSERTEQ(size_t, voxels.size(), 1);
	UASSERTEQ(u64, voxels[v3s16(0, 0, 0)], cells(0, 2, 0, 2, 0, 2));

	// Transparent textures don't make voxels
	PointLightShadows::AlphaMask clear;
	clear.width = clear.height = 1;
	clear.opaque = {false};
	clear.any_opaque = false;
	voxels.clear();
	cube(voxels, &clear);
	for (const auto &it : voxels)
		UASSERTEQ(u64, it.second, 0);

	// Negative coordinates go to the right nodes: an upwards facing triangle
	// fills the layer just below it, the top layer of the node below
	voxels.clear();
	PointLightShadows::rasterizeTriangle(v3f(0.4f, -0.4f, 0.4f), v3f(2.4f, -0.4f, 0.4f),
			v3f(2.4f, -0.4f, 2.4f), v3f(0, 1, 0), voxels);
	UASSERTEQ(size_t, voxels.size(), 1);
	const u64 below = voxels[v3s16(0, -1, 0)];
	UASSERT(below != 0);
	UASSERTEQ(u64, below & ~cells(0, 2, 3, 4, 0, 2), 0);
}
