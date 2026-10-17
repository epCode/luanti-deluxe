// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>

#pragma once

#include "nodedef.h"
#include "tile.h"
#include <S3DVertex.h>

struct MeshMakeData;
struct MeshCollector;

// Day and night brightness, 0..LIGHT_HDR_MAX (see decode_light_hdr())
struct LightPair {
	u16 lightDay;
	u16 lightNight;

	LightPair() = default;
	explicit LightPair(u32 value) : lightDay(value & 0xffff), lightNight(value >> 16) {}
	LightPair(u16 valueA, u16 valueB) : lightDay(valueA), lightNight(valueB) {}
	LightPair(float valueA, float valueB) :
		lightDay(core::clamp(core::round32(valueA), 0, LIGHT_HDR_MAX)),
		lightNight(core::clamp(core::round32(valueB), 0, LIGHT_HDR_MAX)) {}
	operator u32() const { return lightDay | (u32)lightNight << 16; }
};

struct LightInfo {
	float light_day;
	float light_night;
	float light_boosted;

	LightPair getPair(float sunlight_boost = 0.0f) const
	{
		return LightPair(
			(1 - sunlight_boost) * light_day
			+ sunlight_boost * light_boosted,
			light_night);
	}
};

struct LightFrame {
	f32 lightsDay[8];
	f32 lightsNight[8];
	bool sunlight[8];
};

/*
	Lightmap lighting (Minecraft-style sky/block light, see lighting.h).
	Light values are in 1/16 light level units (0..240), like Minecraft's
	packed light coordinates.
*/
struct LMLight {
	s32 block = 0;
	s32 sky = 0;

	bool isZero() const { return block == 0 && sky == 0; }
};

struct LMVertexLight {
	f32 ao = -1.0f; // ambient occlusion, or < 0 for flat lighting
	f32 shade;      // directional shade
	LMLight light;

	// Vertex color: AO quantized to 8 bits, then scaled by the shade
	// (BlockModelLighter / QuadInstance.scaleColor)
	u8 gray() const;
};

// Per-content properties of the Minecraft block state that affect lighting
struct LMNodeProps {
	f32 shade_brightness; // 0.2 for full collision cubes, 1 otherwise
	bool full_collision;
	bool solid_render;    // opaque full cube
	bool clear;           // !view blocking || light block == 0
};

// Ambient occlusion values of one face (Minecraft AmbientOcclusionFace)
struct LMFaceCorners {
	// [i][j]: i = 0/1 along corners[0]/corners[1], j = 0/1 along corners[2]/corners[3]
	f32 brightness[2][2];
	LMLight light[2][2];
};

class MapblockMeshGenerator
{
public:
	MapblockMeshGenerator(MeshMakeData *input, MeshCollector *output);
	void generate();

private:
	MeshMakeData *const data;
	MeshCollector *const collector;

	const NodeDefManager *const nodedef;

	const v3s16 blockpos_nodes;

// current node
	struct {
		v3s16 p; // relative to blockpos_nodes
		v3f origin; // p in BS space
		MapNode n;
		const ContentFeatures *f;
		LightFrame lframe; // smooth lighting
		video::SColor lcolor; // unsmooth lighting
		// lightmap lighting
		bool lm_ao;     // ambient occlusion (smooth lighting) applies
		bool lm_shade;  // directional face shading applies
		u16 lm_corners_valid; // bit (dir * 2 + cubic) set if cached below
		LMFaceCorners lm_corners[12];
	} cur_node;

// lightmap lighting
	bool lightmap() const;
	const LMNodeProps &lmProps(content_t c);
	LMLight lmLightColor(const ContentFeatures &state, v3s16 p);
	LMLight lmLightColorAt(v3s16 p);
	const LMFaceCorners &lmFaceCorners(int dir, bool cubic);
	f32 lmShade(int dir, bool shade) const;
	LMVertexLight lmVertexLight(v3f pos, v3f normal);
	void lmLightVertices(video::S3DVertex *vertices, int count, v3f origin = v3f());
	LMVertexLight lmLiquidLight(int dir);
	void lmLightLiquidVertices(video::S3DVertex *vertices, int count, int dir);
	void lmSetupNode(bool solid_part = false);
	f32 lmFluidHeight(v3s16 p);
	void lmFluidCornerLevels(bool &top_visible);
	std::vector<LMNodeProps> lm_props;
	std::vector<bool> lm_props_valid;

// lighting
	void getSmoothLightFrame();
	LightInfo blendLight(const v3f &vertex_pos);
	video::SColor blendLightColor(const v3f &vertex_pos);
	video::SColor blendLightColor(const v3f &vertex_pos, const v3f &vertex_normal);

	void useTile(TileSpec *tile_ret, int index = 0, u8 set_flags = 0,
		u8 reset_flags = 0, bool special = false);
	void getTile(int index, TileSpec *tile_ret);
	void getTile(v3s16 direction, TileSpec *tile_ret);
	void getSpecialTile(int index, TileSpec *tile_ret, bool apply_crack = false);

// face drawing
	void drawQuad(const TileSpec &tile, v3f *vertices, const v3s16 &normal = v3s16(0, 0, 0),
		float vertical_tiling = 1.0);

// cuboid drawing!
	template <typename Fn>
	void drawCuboid(const aabb3f &box, const TileSpec *tiles, int tilecount,
			const f32 *txc, u8 mask, Fn &&face_lighter);
	static void generateCuboidTextureCoords(aabb3f const &box, f32 *coords);
	void drawAutoLightedCuboid(aabb3f box, const TileSpec &tile, f32 const *txc	= nullptr, u8 mask = 0);
	void drawAutoLightedCuboid(aabb3f box, const TileSpec *tiles, int tile_count, f32 const *txc = nullptr, u8 mask = 0);
	u8 getNodeBoxMask(aabb3f box, u8 solid_neighbors, u8 sametype_neighbors) const;

// liquid-specific
	struct LiquidData {
		struct NeighborData {
			f32 level;
			content_t content;
			bool is_same_liquid;
			bool top_is_same_liquid;
		};

		bool top_is_same_liquid;
		bool draw_bottom;
		TileSpec tile;
		TileSpec tile_top;
		content_t c_flowing;
		content_t c_source;
		video::SColor color_top;
		NeighborData neighbors[3][3];
		f32 corner_levels[2][2];
	};
	LiquidData cur_liquid;

	void prepareLiquidNodeDrawing();
	void getLiquidNeighborhood();
	void calculateCornerLevels();
	f32 getCornerLevel(int i, int k) const;
	void drawLiquidSides();
	void drawLiquidTop();
	void drawLiquidBottom();

// raillike-specific
	// name of the group that enables connecting to raillike nodes of different kind
	static const std::string raillike_groupname;
	struct RaillikeData {
		int raillike_group;
	};
	RaillikeData cur_rail;
	bool isSameRail(v3s16 dir);

// plantlike-specific
	struct PlantlikeData {
		PlantlikeStyle draw_style;
		v3f offset;
		float scale;
		float rotate_degree;
		bool random_offset_Y;
		int face_num;
		float plant_height;
	};
	PlantlikeData cur_plant;

	void drawPlantlikeQuad(const TileSpec &tile, float rotation, float quad_offset = 0,
		bool offset_top_only = false);
	void drawPlantlike(const TileSpec &tile, bool is_rooted = false);

// firelike-specific
	void drawFirelikeQuad(const TileSpec &tile, float rotation, float opening_angle,
		float offset_h, float offset_v = 0.0);

// drawtypes
	void drawSolidNode();
	void drawLiquidNode();
	void drawGlasslikeNode();
	void drawGlasslikeFramedNode();
	void drawAllfacesNode();
	void drawTorchlikeNode();
	void drawSignlikeNode();
	void drawPlantlikeNode();
	void drawPlantlikeRootedNode();
	void drawFirelikeNode();
	void drawFencelikeNode();
	void drawRaillikeNode();
	void drawNodeboxNode();
	void drawMeshNode();

// common
	void errorUnknownDrawtype();
	void drawNode();
	void drawNodeBody();

	// Waterlogging: the liquid held by a waterlogged node is drawn like a
	// liquid source node in the same place
	struct {
		bool active = false;
		u8 full_faces = 0; // bit k: the holder covers solid_tile_dirs[k]
	} cur_holder;
	// The node's liquid for neighbour checks: the held liquid of a
	// waterlogged node, the node itself otherwise
	content_t liquidContentOf(MapNode n) const;
	void drawWaterloggedLiquid();
};
