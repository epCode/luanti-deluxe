// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2023 Vitaliy Lobachevskiy

#include "test.h"

#include "gamedef.h"
#include "inventory.h" // ItemStack
#include "dummygamedef.h"
#include "client/content_mapblock.h"
#include "client/mapblock_mesh.h"
#include "client/meshgen/collector.h"
#include "client/node_visuals.h"
#include <memory>
#include "mesh_compare.h"
#include "noise.h"
#include "light.h"

namespace {

class MockGameDef : public DummyGameDef {
public:
	IWritableItemDefManager *item_mgr() noexcept {
		return static_cast<IWritableItemDefManager *>(m_itemdef);
	}

	NodeDefManager *node_mgr() noexcept {
		return const_cast<NodeDefManager *>(m_nodedef);
	}

	content_t registerNode(const ItemDefinition &itemdef, const ContentFeatures &nodedef,
			std::unique_ptr<NodeVisuals> visuals) {
		item_mgr()->registerItem(itemdef);

		NodeDefManager *mgr = node_mgr();
		content_t id = mgr->set(nodedef.name, nodedef);

		// mgr->set cannot add ContentFeatures that already contain visuals
		// We set them manually instead of calling NodeVisuals::fillNodeVisuals
		ContentFeatures &f = const_cast<ContentFeatures&>(mgr->get(id));
		setNodeVisuals(f, std::move(visuals));

		return id;
	}

	void finalize() {
		node_mgr()->resolveCrossrefs();

		// Need to fill node visuals for predefined nodes
		node_mgr()->applyFunction([] (ContentFeatures &f) {
			if (!f.visuals)
				setNodeVisuals(f);
		});
	}

	MeshMakeData makeSingleNodeMMD(bool smooth_lighting = true)
	{
		MeshMakeData data{ndef(), 1, MeshGrid{1}};
		data.m_generate_minimap = false;
		data.m_smooth_lighting = smooth_lighting;
		data.m_enable_water_reflections = false;
		data.m_blockpos = {0, 0, 0};
		for (s16 x = -1; x <= 1; x++)
		for (s16 y = -1; y <= 1; y++)
		for (s16 z = -1; z <= 1; z++)
			data.m_vmanip.setNode({x, y, z}, {CONTENT_AIR, 0, 0});
		return data;
	}

	content_t addSimpleNode(std::string name, u32 texture)
	{
		ItemDefinition itemdef;
		itemdef.type = ITEM_NODE;
		itemdef.name = "test:" + name;
		itemdef.description = name;

		ContentFeatures f;
		auto visuals = constructNodeVisuals(&f);
		f.name = itemdef.name;
		f.drawtype = NDT_NORMAL;
		visuals->solidness = 2;
		f.alpha = ALPHAMODE_OPAQUE;
		for (TileDef &tiledef : f.tiledef)
			tiledef.name = name + ".png";
		for (TileSpec &tile : visuals->tiles)
			tile.layers[0].texture_id = texture;

		return registerNode(itemdef, f, std::move(visuals));
	}

	content_t addLiquidSource(std::string name, u32 texture)
	{
		ItemDefinition itemdef;
		itemdef.type = ITEM_NODE;
		itemdef.name = "test:" + name + "_source";
		itemdef.description = name;

		ContentFeatures f;
		auto visuals = constructNodeVisuals(&f);
		f.name = itemdef.name;
		f.drawtype = NDT_LIQUID;
		visuals->solidness = 1;
		f.alpha = ALPHAMODE_BLEND;
		f.light_propagates = true;
		f.param_type = CPT_LIGHT;
		f.liquid_type = LIQUID_SOURCE;
		f.liquid_viscosity = 4;
		f.groups["liquids"] = 3;
		f.liquid_alternative_source = "test:" + name + "_source";
		f.liquid_alternative_flowing = "test:" + name + "_flowing";
		for (TileDef &tiledef : f.tiledef)
			tiledef.name = name + ".png";
		for (TileSpec &tile : visuals->tiles)
			tile.layers[0].texture_id = texture;

		return registerNode(itemdef, f, std::move(visuals));
	}

	content_t addLiquidFlowing(std::string name, u32 texture_top, u32 texture_side)
	{
		ItemDefinition itemdef;
		itemdef.type = ITEM_NODE;
		itemdef.name = "test:" + name + "_flowing";
		itemdef.description = name;

		ContentFeatures f;
		auto visuals = constructNodeVisuals(&f);
		f.name = itemdef.name;
		f.drawtype = NDT_FLOWINGLIQUID;
		visuals->solidness = 0;
		f.alpha = ALPHAMODE_BLEND;
		f.light_propagates = true;
		f.param_type = CPT_LIGHT;
		f.liquid_type = LIQUID_FLOWING;
		f.liquid_viscosity = 4;
		f.groups["liquids"] = 3;
		f.liquid_alternative_source = "test:" + name + "_source";
		f.liquid_alternative_flowing = "test:" + name + "_flowing";
		f.tiledef_special[0].name = name + "_top.png";
		f.tiledef_special[1].name = name + "_side.png";
		visuals->special_tiles[0].layers[0].texture_id = texture_top;
		visuals->special_tiles[1].layers[0].texture_id = texture_side;

		return registerNode(itemdef, f, std::move(visuals));
	}

	content_t addGlassNode(std::string name, u32 texture)
	{
		ItemDefinition itemdef;
		itemdef.type = ITEM_NODE;
		itemdef.name = "test:" + name;
		itemdef.description = name;

		ContentFeatures f;
		auto visuals = constructNodeVisuals(&f);
		f.name = itemdef.name;
		f.drawtype = NDT_GLASSLIKE;
		visuals->solidness = 0;
		visuals->visual_solidness = 1;
		f.alpha = ALPHAMODE_CLIP;
		f.param_type = CPT_LIGHT;
		f.light_propagates = true;
		f.sunlight_propagates = true;
		for (TileDef &tiledef : f.tiledef)
			tiledef.name = name + ".png";
		for (TileSpec &tile : visuals->tiles)
			tile.layers[0].texture_id = texture;

		return registerNode(itemdef, f, std::move(visuals));
	}
};

void set_light_decode_table()
{
	// Classic levels 0..15 in steps of 0x11, extended levels in steps of 5,
	// sunlight like level 15
	u16 table[LIGHT_SUN + 1];
	for (int i = 0; i <= LIGHT_SUN_LEVEL; i++)
		table[i] = i * 0x11;
	for (int i = LIGHT_SUN_LEVEL + 1; i <= LIGHT_LIMIT; i++)
		table[i] = 0xFF + (i - LIGHT_SUN_LEVEL) * 5;
	table[LIGHT_SUN] = 0xFF;
	memcpy(const_cast<u16 *>(light_decode_table), table, sizeof(table));
}

class TestMapblockMeshGenerator : public TestBase {
public:
	TestMapblockMeshGenerator() { TestManager::registerTestModule(this); }
	const char *getName() override { return "TestMapblockMeshGenerator"; }

	void runTests(IGameDef *gamedef) override;
	void testLightCurve();
	void testSimpleNode();
	void testSurroundedNode();
	void testInterliquidSame();
	void testInterliquidDifferent();
	void testLightmapAmbientOcclusion();
	void testLightmapFluid();
};

static TestMapblockMeshGenerator g_test_instance;

void TestMapblockMeshGenerator::runTests(IGameDef *gamedef)
{
	TEST(testLightCurve);
	set_light_decode_table();
	TEST(testSimpleNode);
	TEST(testSurroundedNode);
	TEST(testInterliquidSame);
	TEST(testInterliquidDifferent);
	TEST(testLightmapAmbientOcclusion);
	TEST(testLightmapFluid);
}

void TestMapblockMeshGenerator::testLightCurve()
{
	set_light_curve(1.0f);

	// Classic levels
	UASSERTEQ(int, decode_light_hdr(0), 0);
	UASSERTEQ(int, decode_light_hdr(LIGHT_SUN_LEVEL), 255);
	UASSERTEQ(int, decode_light_hdr(LIGHT_SUN), 255);
	UASSERT(decode_light_hdr(LIGHT_MAX) < 255);
	// Extended levels get brighter with diminishing steps, up to about
	// twice the brightness of LIGHT_MAX
	const int max14 = decode_light_hdr(LIGHT_MAX);
	UASSERT(std::abs(decode_light_hdr(LIGHT_LIMIT) - 2 * max14) <= 1);
	UASSERT(decode_light_hdr(LIGHT_LIMIT) <= LIGHT_HDR_MAX);
	for (int i = 1; i <= LIGHT_LIMIT; i++)
		UASSERT(decode_light_hdr(i) > decode_light_hdr(i - 1));
	for (int i = LIGHT_SUN_LEVEL + 2; i <= LIGHT_LIMIT; i++) {
		UASSERT(decode_light_hdr(i) - decode_light_hdr(i - 1) <=
				decode_light_hdr(i - 1) - decode_light_hdr(i - 2) + 1);
	}
	// decode_light() stays in the classic range
	UASSERTEQ(int, decode_light(LIGHT_LIMIT), 255);
	UASSERTEQ(int, decode_light(LIGHT_MAX), max14);

	// Vertex colors are halved, extended light fills the rest of the range
	UASSERTEQ(int, encode_light(255 | 255 << 16, 0).getRed(), 127);
	UASSERTEQ(int, encode_light(255 | 0 << 16, 0).getAlpha(), 255);
	const u32 hdr = decode_light_hdr(LIGHT_LIMIT);
	video::SColor c = encode_light(hdr | hdr << 16, 0);
	UASSERTEQ(int, c.getRed(), hdr / 2);
	UASSERTEQ(int, c.getAlpha(), 0);
	// Emissive light doesn't make extended brightness
	UASSERTEQ(int, encode_light(250 << 16, LIGHT_MAX).getRed(), 127);
}

namespace quad {
	constexpr float h = BS / 2.0f;
	const Quad zp{{{{-h, -h, h}, {0, 0, 1}, 0, {1, 1}}, {{h, -h, h}, {0, 0, 1}, 0, {0, 1}}, {{h, h, h}, {0, 0, 1}, 0, {0, 0}}, {{-h, h, h}, {0, 0, 1}, 0, {1, 0}}}};
	const Quad yp{{{{-h, h, -h}, {0, 1, 0}, 0, {0, 1}}, {{-h, h, h}, {0, 1, 0}, 0, {0, 0}}, {{h, h, h}, {0, 1, 0}, 0, {1, 0}}, {{h, h, -h}, {0, 1, 0}, 0, {1, 1}}}};
	const Quad xp{{{{h, -h, -h}, {1, 0, 0}, 0, {0, 1}}, {{h, h, -h}, {1, 0, 0}, 0, {0, 0}}, {{h, h, h}, {1, 0, 0}, 0, {1, 0}}, {{h, -h, h}, {1, 0, 0}, 0, {1, 1}}}};
	const Quad zn{{{{-h, -h, -h}, {0, 0, -1}, 0, {0, 1}}, {{-h, h, -h}, {0, 0, -1}, 0, {0, 0}}, {{h, h, -h}, {0, 0, -1}, 0, {1, 0}}, {{h, -h, -h}, {0, 0, -1}, 0, {1, 1}}}};
	const Quad yn{{{{-h, -h, -h}, {0, -1, 0}, 0, {0, 0}}, {{h, -h, -h}, {0, -1, 0}, 0, {1, 0}}, {{h, -h, h}, {0, -1, 0}, 0, {1, 1}}, {{-h, -h, h}, {0, -1, 0}, 0, {0, 1}}}};
	const Quad xn{{{{-h, -h, -h}, {-1, 0, 0}, 0, {1, 1}}, {{-h, -h, h}, {-1, 0, 0}, 0, {0, 1}}, {{-h, h, h}, {-1, 0, 0}, 0, {0, 0}}, {{-h, h, -h}, {-1, 0, 0}, 0, {1, 0}}}};
}

void TestMapblockMeshGenerator::testSimpleNode()
{
	MockGameDef gamedef;
	content_t stone = gamedef.addSimpleNode("stone", 42);
	gamedef.finalize();

	MeshMakeData data = gamedef.makeSingleNodeMMD();
	data.m_vmanip.setNode({0, 0, 0}, {stone, 0, 0});

	MeshCollector col{{}};
	MapblockMeshGenerator mg{&data, &col};
	mg.generate();
	UASSERTEQ(std::size_t, col.prebuffers[0].size(), 1);
	UASSERTEQ(std::size_t, col.prebuffers[1].size(), 0);

	auto &&buf = col.prebuffers[0][0];
	UASSERTEQ(u32, buf.layer.texture_id, 42);
	UASSERT(checkMeshEqual(buf.vertices, buf.indices, {quad::xn, quad::xp, quad::yn, quad::yp, quad::zn, quad::zp}));
}

void TestMapblockMeshGenerator::testSurroundedNode()
{
	MockGameDef gamedef;
	content_t stone = gamedef.addSimpleNode("stone", 42);
	content_t wood = gamedef.addSimpleNode("wood", 13);
	gamedef.finalize();

	MeshMakeData data = gamedef.makeSingleNodeMMD();
	data.m_vmanip.setNode({0, 0, 0}, {stone, 0, 0});
	data.m_vmanip.setNode({1, 0, 0}, {wood, 0, 0});

	MeshCollector col{{}};
	MapblockMeshGenerator mg{&data, &col};
	mg.generate();
	UASSERTEQ(std::size_t, col.prebuffers[0].size(), 1);
	UASSERTEQ(std::size_t, col.prebuffers[1].size(), 0);

	auto &&buf = col.prebuffers[0][0];
	UASSERTEQ(u32, buf.layer.texture_id, 42);
	UASSERT(checkMeshEqual(buf.vertices, buf.indices, {quad::xn, quad::yn, quad::yp, quad::zn, quad::zp}));
}

void TestMapblockMeshGenerator::testInterliquidSame()
{
	MockGameDef gamedef;
	auto water = gamedef.addLiquidSource("water", 42);
	gamedef.finalize();

	MeshMakeData data = gamedef.makeSingleNodeMMD();
	data.m_vmanip.setNode({0, 0, 0}, {water, 0, 0});
	data.m_vmanip.setNode({1, 0, 0}, {water, 0, 0});

	MeshCollector col{{}};
	MapblockMeshGenerator mg{&data, &col};
	mg.generate();
	UASSERTEQ(std::size_t, col.prebuffers[0].size(), 1);
	UASSERTEQ(std::size_t, col.prebuffers[1].size(), 0);

	auto &&buf = col.prebuffers[0][0];
	UASSERTEQ(u32, buf.layer.texture_id, 42);
	UASSERT(checkMeshEqual(buf.vertices, buf.indices, {quad::xn, quad::yn, quad::yp, quad::zn, quad::zp}));
}

void TestMapblockMeshGenerator::testInterliquidDifferent()
{
	MockGameDef gamedef;
	auto water = gamedef.addLiquidSource("water", 42);
	auto lava = gamedef.addLiquidSource("lava", 13);
	gamedef.finalize();

	MeshMakeData data = gamedef.makeSingleNodeMMD();
	data.m_vmanip.setNode({0, 0, 0}, {water, 0, 0});
	data.m_vmanip.setNode({0, 0, 1}, {lava, 0, 0});

	MeshCollector col{{}};
	MapblockMeshGenerator mg{&data, &col};
	mg.generate();
	UASSERTEQ(std::size_t, col.prebuffers[0].size(), 1);
	UASSERTEQ(std::size_t, col.prebuffers[1].size(), 0);

	auto &&buf = col.prebuffers[0][0];
	UASSERTEQ(u32, buf.layer.texture_id, 42);
	UASSERT(checkMeshEqual(buf.vertices, buf.indices, {quad::xn, quad::xp, quad::yn, quad::yp, quad::zn, quad::zp}));
}


/*
	Lightmap lighting: compares the smooth lighting of a full cube with a
	literal port of Minecraft's BlockModelLighter (Java Edition 26.3),
	written in Minecraft's own coordinates (north is -Z) to also check the
	mapping to Luanti's (north is +Z).
*/
namespace mc {

enum Dir { DOWN, UP, NORTH, SOUTH, WEST, EAST };
const v3s16 step[6] = {{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}};
// AdjacencyInfo.corners
const Dir corners[6][4] = {
	{WEST, EAST, NORTH, SOUTH}, {EAST, WEST, NORTH, SOUTH}, {UP, DOWN, EAST, WEST},
	{WEST, EAST, DOWN, UP}, {UP, DOWN, NORTH, SOUTH}, {DOWN, UP, NORTH, SOUTH},
};
// AmbientVertexRemap
const int remap[6][4] = {{0, 1, 2, 3}, {2, 3, 0, 1}, {3, 0, 1, 2}, {0, 1, 2, 3}, {3, 0, 1, 2}, {1, 2, 3, 0}};
// FaceInfo vertex positions (0 = min, 1 = max)
const int face_info[6][4][3] = {
	{{0, 0, 1}, {0, 0, 0}, {1, 0, 0}, {1, 0, 1}},
	{{0, 1, 0}, {0, 1, 1}, {1, 1, 1}, {1, 1, 0}},
	{{1, 1, 0}, {1, 0, 0}, {0, 0, 0}, {0, 1, 0}},
	{{0, 1, 1}, {0, 0, 1}, {1, 0, 1}, {1, 1, 1}},
	{{0, 1, 0}, {0, 0, 0}, {0, 0, 1}, {0, 1, 1}},
	{{1, 1, 1}, {1, 0, 1}, {1, 0, 0}, {1, 1, 0}},
};

struct State { bool solid; s32 sky, block; };

int sky(int c) { return c >> 20 & 15; }
int block(int c) { return c >> 4 & 15; }

int smoothBlend(int n1, int n2, int n3, int center)
{
	if (sky(center) > 2 || block(center) > 2) {
		for (int *n : {&n1, &n2, &n3}) {
			if (*n == 0)
				*n = center;
			else if (sky(*n) == 0)
				*n |= center & 0xFF0000;
		}
	}
	return (n1 + n2 + n3 + center) >> 2 & 0xFF00FF;
}

}

void TestMapblockMeshGenerator::testLightmapAmbientOcclusion()
{
	MockGameDef gamedef;
	content_t stone = gamedef.addSimpleNode("stone", 42);
	content_t glass = gamedef.addGlassNode("glass", 7);
	gamedef.finalize();

	const bool separate_before = g_separate_sky_light;
	g_separate_sky_light = true;
	PcgRandom rnd(1234);
	int total_checked = 0;

	for (int round = 0; round < 300; round++) {
		MeshMakeData data{gamedef.ndef(), 1, MeshGrid{1}};
		data.m_generate_minimap = false;
		data.m_smooth_lighting = true;
		data.m_lightmap = true;
		data.m_blockpos = {0, 0, 0};
		for (s16 x = -3; x <= 3; x++)
		for (s16 y = -3; y <= 3; y++)
		for (s16 z = -3; z <= 3; z++) {
			int kind = rnd.range(0, 9);
			content_t c = kind < 3 ? stone : kind < 4 ? glass : CONTENT_AIR;
			u8 sky = rnd.range(0, 15), block = rnd.range(0, 15);
			data.m_vmanip.setNode({x, y, z}, {c, pack_light(sky == 15 ? LIGHT_SUN : sky, block), 0});
		}
		data.m_vmanip.setNode({0, 0, 0}, {stone, 0, 0});

		// Minecraft's view of the world: Luanti node at (x, y, -z)
		auto state = [&] (v3s16 mc) {
			MapNode n = data.m_vmanip.getNodeNoExNoEmerge(v3s16(mc.X, mc.Y, -mc.Z));
			mc::State s;
			s.solid = n.getContent() == stone;
			s.sky = s.solid ? 0 : light_level(unpack_light_day(n.param1));
			s.block = s.solid ? 0 : unpack_light_night(n.param1);
			return s;
		};
		auto light_color = [&] (v3s16 p) {
			mc::State s = state(p);
			return s.sky << 20 | s.block << 4;
		};
		auto shade_brightness = [&] (v3s16 p) { return state(p).solid ? 0.2f : 1.0f; };
		auto light_permeable = [&] (v3s16 p) { return !state(p).solid; };

		MeshCollector col{{}};
		MapblockMeshGenerator mg{&data, &col};
		mg.generate();

		int checked = 0;
		for (int face = 0; face < 6; face++) {
			v3s16 d = mc::step[face];
			if (state(d).solid)
				continue; // face is culled
			// BlockModelLighter: a full cube face is cubic and not partial
			v3s16 base = d;
			v3s16 c[4];
			for (int k = 0; k < 4; k++)
				c[k] = mc::step[mc::corners[face][k]];
			int l[4];
			f32 b[4];
			bool perm[4];
			for (int k = 0; k < 4; k++) {
				l[k] = light_color(base + c[k]);
				b[k] = shade_brightness(base + c[k]);
				perm[k] = light_permeable(base + c[k] + d);
			}
			auto corner = [&] (int i, int j, f32 &cb, int &cl) {
				if (!perm[j] && !perm[i]) {
					cb = b[0];
					cl = l[0];
				} else {
					cb = shade_brightness(base + c[i] + c[j]);
					cl = light_color(base + c[i] + c[j]);
				}
			};
			f32 b02, b03, b12, b13;
			int l02, l03, l12, l13;
			corner(0, 2, b02, l02);
			corner(0, 3, b03, l03);
			corner(1, 2, b12, l12);
			corner(1, 3, b13, l13);
			int center_l = light_color(d); // faceCubic
			f32 center_b = shade_brightness(base);
			f32 vb[4] = {
				(b[3] + b[0] + b03 + center_b) * 0.25f,
				(b[2] + b[0] + b02 + center_b) * 0.25f,
				(b[2] + b[1] + b12 + center_b) * 0.25f,
				(b[3] + b[1] + b13 + center_b) * 0.25f,
			};
			int vl[4] = {
				mc::smoothBlend(l[3], l[0], l03, center_l),
				mc::smoothBlend(l[2], l[0], l02, center_l),
				mc::smoothBlend(l[2], l[1], l12, center_l),
				mc::smoothBlend(l[3], l[1], l13, center_l),
			};
			const f32 shade[6] = {0.5f, 1.0f, 0.8f, 0.8f, 0.6f, 0.6f};
			for (int vert = 0; vert < 4; vert++) {
				int quad_vertex = mc::remap[face][vert];
				const int *fi = mc::face_info[face][quad_vertex];
				// Minecraft block coordinates -> Luanti node-relative position
				v3f pos((fi[0] - 0.5f) * BS, (fi[1] - 0.5f) * BS, ((1 - fi[2]) - 0.5f) * BS);
				v3f normal = v3f::from(v3s16(d.X, d.Y, -d.Z));
				int gray = (int)((int)std::floor(vb[vert] * 255.0f) * shade[face]);
				int exp_block = vl[vert] & 0xFF, exp_sky = vl[vert] >> 16 & 0xFF;

				bool found = false;
				for (auto &buf : col.prebuffers[0]) {
					for (auto &v : buf.vertices) {
						if (v.Pos.getDistanceFrom(pos) > 0.001f || v.Normal != normal)
							continue;
						found = true;
						UASSERTEQ(int, v.Color.getRed(), gray);
						UASSERTEQ(int, v.Light[0], exp_block);
						UASSERTEQ(int, v.Light[1], exp_sky);
						checked++;
					}
				}
				UASSERT(found);
			}
		}
		total_checked += checked;
	}
	g_separate_sky_light = separate_before;
	// Most faces are visible: about 300 rounds * 4 faces * 4 vertices
	UASSERT(total_checked > 3000);
}


// Lightmap lighting: fluid surfaces are 8/9 high (LiquidBlockRenderer)
void TestMapblockMeshGenerator::testLightmapFluid()
{
	MockGameDef gamedef;
	auto water = gamedef.addLiquidSource("water", 42);
	gamedef.addLiquidFlowing("water", 43, 44);
	gamedef.finalize();

	MeshMakeData data = gamedef.makeSingleNodeMMD();
	data.m_lightmap = true;
	// A pool: the middle source has full 8/9 corners
	for (s16 x = -1; x <= 1; x++)
	for (s16 z = -1; z <= 1; z++)
		data.m_vmanip.setNode({x, 0, z}, {water, 0, 0});
	// Only draw the middle node
	data.m_side_length = 1;

	MeshCollector col{{}};
	MapblockMeshGenerator mg{&data, &col};
	mg.generate();
	UASSERTEQ(std::size_t, col.prebuffers[0].size(), 1);
	auto &&buf = col.prebuffers[0][0];
	// top and bottom only; sides face more water
	UASSERTEQ(std::size_t, buf.vertices.size(), 8);
	f32 top = -BS;
	for (auto &v : buf.vertices)
		top = std::max(top, v.Pos.Y);
	UASSERT(std::fabs(top - (8.0f / 9.0f - 0.001f - 0.5f) * BS) < 0.001f);
}

}
