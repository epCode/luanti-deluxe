// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "irrlichttypes.h"
#include "mapnode.h"
#include "irr_v3d.h"
#include "irr_aabb3d.h"
#include "constants.h"
#include <matrix4.h>
#include <array>
#include <string>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace video {
	class IVideoDriver;
	class ITexture;
}
namespace scene {
	class ISceneNode;
	class IMesh;
	class IMeshBuffer;
}
class Client;
class IWritableShaderSource;
class NodeDefManager;

/*
	Shadows cast by light emitting nodes (torches, lamps, lava, ...).

	A voxel copy of the map around the camera lives on the GPU, and the node
	and object shaders ray-march from each surface texel towards the light
	sources that can reach it. Everything sits in one RGBA8 2D array texture:

	- layers [0, SIZE): occupancy, two texels (64 bits) per node, one bit per
	  1/4 node sub-voxel (bit = x + 4 * y + 16 * z). Texel x = 2 * node x (+1
	  for the high bits), y = node z, layer = node y, all taken modulo SIZE
	  so that moving the volume only rewrites the blocks that entered it.
	- the last CLUSTER_LAYERS layers: for each CELL^3 cell of the volume, up
	  to CELL_LIGHTS light sources that can reach it, strongest first. Each
	  texel is (x, y, z, light level) relative to the volume origin; level 0
	  ends the list.

	Entities cast shadows in one of these ways (point_light_entity_shadows),
	from the cheapest to the most expensive:

	- boxes: the boxes of the entities' bones (or of their meshes) go to the
	  shaders, which test each ray against them.
	- voxels: the entities' triangles are rasterized into the sub-voxels of
	  the volume every frame, on top of a CPU copy of the map's occupancy.
	- shadowmaps: the light sources nearest to the camera that reach an
	  entity render the entities' distance from them into the six cube faces
	  of a slot of an atlas (texture layer ENTITY_MAP_LAYER).

	See client/shaders/shadow/pixel_shadows.glsl for the shader side.
*/
class PointLightShadows
{
public:
	// Material texture layer the volume is bound to
	static constexpr u32 TEXTURE_LAYER = 2;
	// Material texture layer of the entity shadow map atlas
	static constexpr u32 ENTITY_MAP_LAYER = 4;

	// Entity boxes sent to the shaders at most
	static constexpr u32 MAX_BOXES = 32;
	// Light sources with entity shadow maps, and their face size in pixels
	static constexpr u32 MAP_LIGHTS = 6;
	static constexpr u32 MAP_FACE_SIZE = 256;
	// Distance covered by the shadow maps (scene units): the farthest a
	// light source reaches
	static constexpr f32 MAP_FAR = LIGHT_LIMIT * BS;

	enum class EntityMode : u8 { None, Boxes, Voxels, ShadowMaps };

	// Volume size in map blocks and nodes along each axis (power of two)
	static constexpr s16 VOLUME_BLOCKS = 8;
	static constexpr s16 SIZE = VOLUME_BLOCKS * MAP_BLOCKSIZE;
	// Light list cells
	static constexpr s16 CELL = 8;
	static constexpr s16 CELLS = SIZE / CELL;
	static constexpr u32 CELL_LIGHTS = 16;

	static constexpr u32 TEX_WIDTH = 2 * SIZE;
	static constexpr u32 TEX_HEIGHT = SIZE;
	static constexpr u32 CLUSTER_LAYERS =
			(CELLS * CELLS * CELLS * CELL_LIGHTS) / (TEX_WIDTH * TEX_HEIGHT);

	/// Creates the point light shadows if enabled and supported, and
	/// registers their shader constants and uniforms. Must be called
	/// before any shaders are generated.
	static std::unique_ptr<PointLightShadows> create(Client *client,
			video::IVideoDriver *driver, IWritableShaderSource *shsrc);

	/// The active instance, if any
	static PointLightShadows *get() { return s_instance; }

	~PointLightShadows();

	/// A block's nodes changed (or it was received)
	void markBlockChanged(v3s16 blockpos);

	/// Moves the volume with the camera and uploads changed blocks.
	/// @param camera_pos camera position (world, BS units)
	/// @param camera_offset camera offset (nodes)
	void update(v3f camera_pos, v3s16 camera_offset);

	video::ITexture *getTexture() const { return m_texture; }
	/// Entity shadow map atlas, if any
	video::ITexture *getEntityMapTexture() const { return m_entity_map; }

	EntityMode getEntityMode() const { return m_entity_mode; }
	/// Box matrix rows for the shaders, 3 vec4 per box, MAX_BOXES boxes
	const std::vector<f32> &getEntityBoxes() const { return m_box_rows; }
	u32 getEntityBoxCount() const { return m_box_count; }
	/// Shadow mapped light sources (volume coordinates, w = 1 if used)
	const std::array<f32, 4 * MAP_LIGHTS> &getEntityMapLights() const { return m_map_lights; }
	/// Projections of the cube faces, from the light source (scene units)
	const std::array<f32, 16 * 6> &getEntityMapFaces() const { return m_map_faces; }

	/// Corner of the volume in scene coordinates (BS units)
	v3f getOriginScene() const { return m_origin_scene; }
	/// Volume origin node modulo SIZE
	v3f getWrap() const;
	/// 0 disables the effect
	float getStrength() const { return m_enabled ? m_strength : 0.0f; }

	/// Sub-voxel occupancy of node boxes (node local, BS units): bit
	/// x + 4 * y + 16 * z is set if a box covers at least half of that 1/4
	/// node cube along each axis
	static u64 computeBoxMask(const std::vector<aabb3f> &boxes);

	/// Rows of the matrix that takes volume coordinates (nodes, from the
	/// volume corner at volume_origin_scene) into [-1, 1]^3 for the box,
	/// which is transformed by box_transform (to scene coordinates)
	static void computeBoxRows(const aabb3f &box, const core::matrix4 &box_transform,
			v3f volume_origin_scene, f32 rows[12]);

	/// Which texels of a texture are opaque (alpha >= 0.5)
	struct AlphaMask {
		u32 width = 0, height = 0;
		std::vector<bool> opaque; // empty: all opaque
		bool any_opaque = true;
		bool isOpaque(v2f uv) const;
		// Whether any of a few samples of a triangle is opaque
		bool isTriangleOpaque(v2f a, v2f b, v2f c) const;
	};

	/// Sets the sub-voxels (bit x + 4 * y + 16 * z of the node mask) whose
	/// centers lie just behind (against the outward normal) a triangle
	/// given in sub-voxel coordinates, where the texture (if any) is opaque.
	/// Closed meshes become their solid shape's shell.
	static void rasterizeTriangle(v3f a, v3f b, v3f c, v3f normal,
			std::unordered_map<v3s16, u64> &voxels,
			const AlphaMask *mask = nullptr, v2f ta = {}, v2f tb = {}, v2f tc = {});

private:
	struct Light {
		v3s16 pos; // absolute node position
		u8 level;
		bool operator==(const Light &other) const
		{
			return pos == other.pos && level == other.level;
		}
	};

	struct Slot {
		v3s16 blockpos;
		bool valid = false;
		std::vector<Light> lights;
		// Voxel entity shadows: the map's own masks, MAP_BLOCKSIZE^3,
		// x fastest then z then y
		std::vector<u64> map_masks;
	};

	PointLightShadows(Client *client, video::IVideoDriver *driver);
	bool init();

	struct ContentInfo {
		// 0 = not computed yet, 1 = fixed mask, 2 = boxes depend on param2
		// (and maybe neighbors), see m_box_masks
		u8 kind = 0;
		bool connected = false;
		u8 light = 0;
		u64 mask = 0;
	};

	const ContentInfo &getContentInfo(content_t c);
	u64 getBoxMask(const MapNode &n, v3s16 p, const ContentInfo &info);

	void fillSlot(Slot &slot, v3s16 blockpos, v3s16 slot_index);
	void rebuildLightLists();

	// Entity shadows (pointshadowentities.cpp)
	void setEntityMode(EntityMode mode);
	void updateEntities(v3f camera_pos);
	void collectEntityNodes(v3f camera_pos, std::vector<scene::ISceneNode *> &nodes);
	bool reachesLight(const aabb3f &scene_box) const;
	void updateEntityBoxes(const std::vector<scene::ISceneNode *> &nodes);
	void updateEntityVoxels(const std::vector<scene::ISceneNode *> &nodes);
	void clearEntityVoxels();
	void uploadVoxelNodes(const std::vector<v3s16> &nodes);
	void updateEntityShadowMaps(const std::vector<scene::ISceneNode *> &nodes);
	void createEntityMapTexture();
	bool initEntityMaps();
	void readSettings();
	static void settingChangedCallback(const std::string &name, void *data);

	static PointLightShadows *s_instance;

	Client *m_client;
	video::IVideoDriver *m_driver;
	const NodeDefManager *m_ndef;
	video::ITexture *m_texture = nullptr;

	bool m_enabled = true;
	float m_strength = 0.75f;

	bool m_has_origin = false;
	v3s16 m_origin_block; // minimum block of the volume
	v3f m_origin_scene;
	std::vector<Slot> m_slots; // VOLUME_BLOCKS^3, indexed by blockpos mod VOLUME_BLOCKS
	std::unordered_set<v3s16> m_changed_blocks;
	bool m_lights_dirty = true;

	std::vector<ContentInfo> m_content;
	// content << 16 | param2 << 8 | neighbors -> mask
	std::unordered_map<u32, u64> m_box_masks;

	std::vector<u32> m_upload_buffer;

	// Entity shadows
	IWritableShaderSource *m_shsrc = nullptr;
	EntityMode m_entity_mode = EntityMode::None;
	// Per light list cell: whether any light reaches it
	std::vector<bool> m_cell_lit;
	// Boxes
	std::vector<f32> m_box_rows;
	u32 m_box_count = 0;
	// Voxels: entity sub-voxels per node (absolute node position)
	std::unordered_map<v3s16, u64> m_entity_voxels;
	// Alpha of entity textures, read back once
	std::unordered_map<video::ITexture *, AlphaMask> m_alpha_masks;
	const AlphaMask *getAlphaMask(video::ITexture *texture);
	// Boxes of the opaque parts of meshes, per mesh and textures: (joint,
	// box in joint space), joint -1 - i for unskinned buffer i
	std::unordered_map<std::string, std::vector<std::pair<s32, aabb3f>>> m_part_boxes;
	const std::vector<std::pair<s32, aabb3f>> &getPartBoxes(scene::ISceneNode *node,
			scene::IMesh *mesh);
	// Shadow maps
	video::ITexture *m_entity_map = nullptr;
	s32 m_entity_map_material = -1;
	bool m_entity_maps_failed = false;
	bool m_entity_map_clear = true;
	std::array<f32, 4 * MAP_LIGHTS> m_map_lights {};
	std::array<f32, 16 * 6> m_map_faces {};
	std::array<core::matrix4, 6> m_face_views;
	core::matrix4 m_face_projection;
};
