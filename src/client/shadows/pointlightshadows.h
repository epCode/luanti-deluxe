// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "irrlichttypes.h"
#include "mapnode.h"
#include "irr_v3d.h"
#include "irr_aabb3d.h"
#include "constants.h"
#include <string>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace video {
	class IVideoDriver;
	class ITexture;
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

	See client/shaders/shadow/pixel_shadows.glsl for the shader side.
*/
class PointLightShadows
{
public:
	// Material texture layer the volume is bound to
	static constexpr u32 TEXTURE_LAYER = 2;

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
};
