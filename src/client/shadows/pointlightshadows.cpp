// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "client/shadows/pointlightshadows.h"
#include "client/client.h"
#include "client/clientenvironment.h"
#include "client/shader.h"
#include "log.h"
#include "map.h"
#include "mapblock.h"
#include "nodedef.h"
#include "profiler.h"
#include "settings.h"
#include "util/numeric.h"
#include "util/string.h"
#include <IVideoDriver.h>
#include <IImage.h>
#include <IMaterialRendererServices.h>
#include <algorithm>
#include <cstring>

PointLightShadows *PointLightShadows::s_instance = nullptr;

// Blocks rewritten per frame at most (a one block move of the volume
// rewrites VOLUME_BLOCKS^2 of them)
static constexpr size_t MAX_BLOCKS_PER_FRAME = 128;

static inline s16 wrap(s16 v, s16 n)
{
	return ((v % n) + n) % n;
}

namespace {

class PointShadowConstantSetter : public IShaderConstantSetter
{
public:
	void onGenerate(const std::string &name, ShaderConstants &constants) override
	{
		constants["ENABLE_POINT_SHADOWS"] = 1;
		constants["POINT_SHADOW_SIZE"] = (int)PointLightShadows::SIZE;
		constants["POINT_SHADOW_CELL"] = (int)PointLightShadows::CELL;
		constants["POINT_SHADOW_CELL_LIGHTS"] = (int)PointLightShadows::CELL_LIGHTS;
		constants["POINT_SHADOW_MAX_BOXES"] = (int)PointLightShadows::MAX_BOXES;
		constants["POINT_SHADOW_MAP_LIGHTS"] = (int)PointLightShadows::MAP_LIGHTS;
		constants["POINT_SHADOW_MAP_FAR"] = (float)PointLightShadows::MAP_FAR;
	}
};

class PointShadowUniformSetter : public IShaderUniformSetter
{
	CachedPixelShaderSetting<f32, 3> m_origin{"pointShadowOrigin"};
	CachedPixelShaderSetting<f32, 3> m_wrap{"pointShadowWrap"};
	CachedPixelShaderSetting<f32> m_strength{"pointShadowStrength"};
	CachedPixelShaderSetting<f32> m_entity_mode{"pointShadowEntityMode"};
	CachedPixelShaderSetting<f32, 12 * PointLightShadows::MAX_BOXES> m_boxes{"pointShadowBoxes"};
	CachedPixelShaderSetting<f32> m_box_count{"pointShadowBoxCount"};
	CachedPixelShaderSetting<f32, 4 * PointLightShadows::MAP_LIGHTS> m_map_lights{"pointShadowMapLights"};
	CachedPixelShaderSetting<f32, 16 * 6> m_map_faces{"pointShadowMapFaces"};

public:
	void onSetUniforms(video::IMaterialRendererServices *services) override
	{
		PointLightShadows *pls = PointLightShadows::get();
		f32 strength = pls ? pls->getStrength() : 0.0f;
		m_strength.set(&strength, services);
		if (!pls)
			return;
		m_origin.set(pls->getOriginScene(), services);
		m_wrap.set(pls->getWrap(), services);

		using Mode = PointLightShadows::EntityMode;
		const Mode mode = pls->getEntityMode();
		f32 mode_f = (f32)mode;
		m_entity_mode.set(&mode_f, services);
		if (mode == Mode::Boxes) {
			m_boxes.set(pls->getEntityBoxes().data(), services);
			f32 count = pls->getEntityBoxCount();
			m_box_count.set(&count, services);
		} else if (mode == Mode::ShadowMaps) {
			m_map_lights.set(pls->getEntityMapLights().data(), services);
			m_map_faces.set(pls->getEntityMapFaces().data(), services);
		}
	}
};

class PointShadowUniformSetterFactory : public IShaderUniformSetterFactory
{
public:
	IShaderUniformSetter *create(const std::string &name) override
	{
		if (str_starts_with(name, "shadow/"))
			return nullptr;
		return new PointShadowUniformSetter();
	}
};

}

std::unique_ptr<PointLightShadows> PointLightShadows::create(Client *client,
		video::IVideoDriver *driver, IWritableShaderSource *shsrc)
{
	if (!g_settings->getBool("enable_point_light_shadows"))
		return nullptr;

	// Needs integer and texelFetch support in shaders (GLSL 1.30+)
	const auto type = driver->getDriverType();
	if (type != video::EDT_OPENGL3 &&
			!(type == video::EDT_OGLES2 && driver->getLimits().GLVersion.X >= 3)) {
		warningstream << "Point light shadows need the OpenGL 3 or OpenGL ES 3 "
				"video driver, disabling them." << std::endl;
		return nullptr;
	}

	std::unique_ptr<PointLightShadows> pls(new PointLightShadows(client, driver));
	pls->m_shsrc = shsrc;
	// Entities take it into their materials when created
	pls->createEntityMapTexture();
	if (!pls->init()) {
		warningstream << "Point light shadows are not supported, disabling them."
				<< std::endl;
		return nullptr;
	}

	shsrc->addShaderConstantSetter(std::make_unique<PointShadowConstantSetter>());
	shsrc->addShaderUniformSetterFactory(std::make_unique<PointShadowUniformSetterFactory>());
	s_instance = pls.get();
	return pls;
}

PointLightShadows::PointLightShadows(Client *client, video::IVideoDriver *driver) :
	m_client(client), m_driver(driver), m_ndef(client->ndef())
{
	m_slots.resize(VOLUME_BLOCKS * VOLUME_BLOCKS * VOLUME_BLOCKS);
	readSettings();
	g_settings->registerChangedCallback("enable_point_light_shadows",
			settingChangedCallback, this);
	g_settings->registerChangedCallback("point_light_shadow_strength",
			settingChangedCallback, this);
	g_settings->registerChangedCallback("point_light_entity_shadows",
			settingChangedCallback, this);
	m_box_rows.assign(12 * MAX_BOXES, 0.0f);
	m_cell_lit.assign(CELLS * CELLS * CELLS, false);
}

PointLightShadows::~PointLightShadows()
{
	g_settings->deregisterAllChangedCallbacks(this);
	if (s_instance == this)
		s_instance = nullptr;
	if (m_texture)
		m_driver->removeTexture(m_texture);
	if (m_entity_map)
		m_driver->removeTexture(m_entity_map);
}

bool PointLightShadows::init()
{
	const u32 layers = SIZE + CLUSTER_LAYERS;
	std::vector<video::IImage *> images;
	images.reserve(layers);
	for (u32 i = 0; i < layers; i++) {
		video::IImage *img = m_driver->createImage(video::ECF_A8R8G8B8,
				core::dimension2du(TEX_WIDTH, TEX_HEIGHT));
		memset(img->getData(), 0, img->getImageDataSizeInBytes());
		images.push_back(img);
	}

	// texelFetch() reads level 0 only, mipmaps would waste memory and time
	const bool mipmaps = m_driver->getTextureCreationFlag(video::ETCF_CREATE_MIP_MAPS);
	m_driver->setTextureCreationFlag(video::ETCF_CREATE_MIP_MAPS, false);
	m_texture = m_driver->addArrayTexture("point_light_shadows",
			images.data(), (u32)images.size());
	m_driver->setTextureCreationFlag(video::ETCF_CREATE_MIP_MAPS, mipmaps);

	for (video::IImage *img : images)
		img->drop();

	if (!m_texture)
		return false;
	// The shader decodes the bits assuming this exact format
	u32 zero = 0;
	if (m_texture->getColorFormat() != video::ECF_A8R8G8B8 ||
			!m_texture->uploadRegion(0, 0, 0, 1, 1, 1, &zero)) {
		m_driver->removeTexture(m_texture);
		m_texture = nullptr;
		return false;
	}
	return true;
}

void PointLightShadows::readSettings()
{
	m_enabled = g_settings->getBool("enable_point_light_shadows");
	m_strength = rangelim(g_settings->getFloat("point_light_shadow_strength"), 0.0f, 1.0f);

	const std::string mode = g_settings->get("point_light_entity_shadows");
	EntityMode entity_mode = EntityMode::Boxes;
	if (mode == "none")
		entity_mode = EntityMode::None;
	else if (mode == "voxels")
		entity_mode = EntityMode::Voxels;
	else if (mode == "shadowmaps")
		entity_mode = EntityMode::ShadowMaps;
	setEntityMode(entity_mode);
}

void PointLightShadows::settingChangedCallback(const std::string &name, void *data)
{
	auto *self = static_cast<PointLightShadows *>(data);
	const bool was_enabled = self->m_enabled;
	self->readSettings();
	if (self->m_enabled && !was_enabled) {
		// Changes were not tracked while disabled
		for (Slot &slot : self->m_slots)
			slot.valid = false;
		self->m_lights_dirty = true;
	}
}

v3f PointLightShadows::getWrap() const
{
	const v3s16 origin = m_origin_block * MAP_BLOCKSIZE;
	return v3f(wrap(origin.X, SIZE), wrap(origin.Y, SIZE), wrap(origin.Z, SIZE));
}

void PointLightShadows::markBlockChanged(v3s16 blockpos)
{
	if (m_enabled)
		m_changed_blocks.insert(blockpos);
}

const PointLightShadows::ContentInfo &PointLightShadows::getContentInfo(content_t c)
{
	if (c >= m_content.size())
		m_content.resize(c + 1);
	ContentInfo &info = m_content[c];
	if (info.kind != 0)
		return info;

	const ContentFeatures &f = m_ndef->get(c);
	info.kind = 1;
	info.light = std::min<u8>(f.light_source, LIGHT_LIMIT);
	switch (f.drawtype) {
	case NDT_NORMAL:
	case NDT_ALLFACES:
	case NDT_ALLFACES_OPTIONAL:
	case NDT_PLANTLIKE_ROOTED:
		info.mask = ~(u64)0;
		break;
	case NDT_NODEBOX:
		info.kind = 2;
		info.connected = f.node_box.type == NODEBOX_CONNECTED;
		break;
	case NDT_MESH:
		// Approximated by the selection box, but only for solid things:
		// plants are often meshes too.
		if (f.walkable)
			info.kind = 2;
		break;
	default:
		// Glass, liquids, plants, torches etc. let the light through
		break;
	}
	return info;
}

u64 PointLightShadows::getBoxMask(const MapNode &n, v3s16 p, const ContentInfo &info)
{
	const content_t c = n.getContent();
	u8 neighbors = 0;
	if (info.connected)
		neighbors = n.getNeighbors(p, &m_client->getEnv().getMap());

	const u32 key = (u32)c << 16 | (u32)n.getParam2() << 8 | neighbors;
	auto it = m_box_masks.find(key);
	if (it != m_box_masks.end())
		return it->second;

	std::vector<aabb3f> boxes;
	if (m_ndef->get(c).drawtype == NDT_NODEBOX)
		n.getNodeBoxes(m_ndef, &boxes, neighbors);
	else
		n.getSelectionBoxes(m_ndef, &boxes, neighbors);
	const u64 mask = computeBoxMask(boxes);
	m_box_masks.emplace(key, mask);
	return mask;
}

u64 PointLightShadows::computeBoxMask(const std::vector<aabb3f> &boxes)
{
	// A sub-voxel is filled if a box covers at least half of it along each
	// axis: thin posts still cast shadows, carpets and panes do not.
	constexpr float min_overlap = 0.5f - 1e-4f;
	u64 mask = 0;
	for (aabb3f box : boxes) {
		box.repair();
		// Node local coordinates in sub-voxels, [0, 4]
		const v3f lo = (box.MinEdge / BS + 0.5f) * 4.0f;
		const v3f hi = (box.MaxEdge / BS + 0.5f) * 4.0f;
		for (int z = 0; z < 4; z++)
		for (int y = 0; y < 4; y++)
		for (int x = 0; x < 4; x++) {
			const float ox = std::min(hi.X, x + 1.0f) - std::max(lo.X, (float)x);
			const float oy = std::min(hi.Y, y + 1.0f) - std::max(lo.Y, (float)y);
			const float oz = std::min(hi.Z, z + 1.0f) - std::max(lo.Z, (float)z);
			if (ox >= min_overlap && oy >= min_overlap && oz >= min_overlap)
				mask |= (u64)1 << (x + 4 * y + 16 * z);
		}
	}
	return mask;
}

void PointLightShadows::fillSlot(Slot &slot, v3s16 blockpos, v3s16 slot_index)
{
	constexpr u32 ROW = 2 * MAP_BLOCKSIZE;
	m_upload_buffer.assign(ROW * MAP_BLOCKSIZE * MAP_BLOCKSIZE, 0);
	std::vector<Light> lights;
	const bool keep_masks = m_entity_mode == EntityMode::Voxels;
	if (keep_masks)
		slot.map_masks.assign(MAP_BLOCKSIZE * MAP_BLOCKSIZE * MAP_BLOCKSIZE, 0);
	else
		std::vector<u64>().swap(slot.map_masks);

	MapBlock *block = m_client->getEnv().getMap().getBlockNoCreateNoEx(blockpos);
	if (block) {
		const v3s16 base = blockpos * MAP_BLOCKSIZE;
		for (s16 y = 0; y < MAP_BLOCKSIZE; y++)
		for (s16 z = 0; z < MAP_BLOCKSIZE; z++)
		for (s16 x = 0; x < MAP_BLOCKSIZE; x++) {
			const MapNode n = block->getNodeNoCheck(x, y, z);
			const content_t c = n.getContent();
			if (c == CONTENT_AIR || c == CONTENT_IGNORE)
				continue;
			const ContentInfo &info = getContentInfo(c);
			const v3s16 p = base + v3s16(x, y, z);
			if (info.light > 0)
				lights.push_back({p, info.light});

			const u64 mask = info.kind == 2 ? getBoxMask(n, p, info) : info.mask;
			if (mask == 0)
				continue;
			if (keep_masks)
				slot.map_masks[(y * MAP_BLOCKSIZE + z) * MAP_BLOCKSIZE + x] = mask;
			const u32 i = (y * MAP_BLOCKSIZE + z) * ROW + 2 * x;
			m_upload_buffer[i] = (u32)mask;
			m_upload_buffer[i + 1] = (u32)(mask >> 32);
		}
	}

	// Entity voxels in the block
	if (keep_masks && !m_entity_voxels.empty()) {
		const v3s16 base = blockpos * MAP_BLOCKSIZE;
		for (const auto &it : m_entity_voxels) {
			const v3s16 rel = it.first - base;
			if (rel.X < 0 || rel.Y < 0 || rel.Z < 0 || rel.X >= MAP_BLOCKSIZE ||
					rel.Y >= MAP_BLOCKSIZE || rel.Z >= MAP_BLOCKSIZE)
				continue;
			const u32 i = (rel.Y * MAP_BLOCKSIZE + rel.Z) * ROW + 2 * rel.X;
			m_upload_buffer[i] |= (u32)it.second;
			m_upload_buffer[i + 1] |= (u32)(it.second >> 32);
		}
	}

	m_texture->uploadRegion(slot_index.X * ROW, slot_index.Z * MAP_BLOCKSIZE,
			slot_index.Y * MAP_BLOCKSIZE, ROW, MAP_BLOCKSIZE, MAP_BLOCKSIZE,
			m_upload_buffer.data());

	slot.blockpos = blockpos;
	slot.valid = true;
	if (lights != slot.lights) {
		slot.lights = std::move(lights);
		m_lights_dirty = true;
	}
}

void PointLightShadows::update(v3f camera_pos, v3s16 camera_offset)
{
	if (!m_enabled || !m_texture) {
		m_changed_blocks.clear();
		return;
	}

	// Recenter the volume once the camera gets near its border
	const v3s16 cam_block = getNodeBlockPos(floatToInt(camera_pos, BS));
	const v3s16 rel = cam_block - m_origin_block;
	constexpr s16 margin = 2;
	constexpr s16 rel_max = VOLUME_BLOCKS - 1 - margin;
	if (!m_has_origin ||
			rel.X < margin || rel.Y < margin || rel.Z < margin ||
			rel.X > rel_max || rel.Y > rel_max || rel.Z > rel_max) {
		m_origin_block = cam_block - v3s16(1, 1, 1) * (VOLUME_BLOCKS / 2);
		m_has_origin = true;
		m_lights_dirty = true;
	}

	const v3s16 origin_node = m_origin_block * MAP_BLOCKSIZE;
	m_origin_scene = (intToFloat(origin_node - camera_offset, 1.0f) - v3f(0.5f)) * BS;

	// Find the blocks to (re)write: those new in the volume and changed ones
	struct Todo {
		s32 dist;
		u32 slot;
		v3s16 blockpos;
		v3s16 slot_index;
	};
	std::vector<Todo> todo;
	for (s16 z = 0; z < VOLUME_BLOCKS; z++)
	for (s16 y = 0; y < VOLUME_BLOCKS; y++)
	for (s16 x = 0; x < VOLUME_BLOCKS; x++) {
		const v3s16 slot_index(x, y, z);
		const v3s16 bp = m_origin_block + v3s16(
				wrap(x - m_origin_block.X, VOLUME_BLOCKS),
				wrap(y - m_origin_block.Y, VOLUME_BLOCKS),
				wrap(z - m_origin_block.Z, VOLUME_BLOCKS));
		const u32 i = (z * VOLUME_BLOCKS + y) * VOLUME_BLOCKS + x;
		const Slot &slot = m_slots[i];
		if (slot.valid && slot.blockpos == bp && m_changed_blocks.count(bp) == 0)
			continue;
		const v3s16 d = bp - cam_block;
		todo.push_back({d.X * d.X + d.Y * d.Y + d.Z * d.Z, i, bp, slot_index});
	}
	m_changed_blocks.clear();

	std::sort(todo.begin(), todo.end(), [] (const Todo &a, const Todo &b) {
		return a.dist < b.dist;
	});
	for (size_t i = 0; i < todo.size(); i++) {
		if (i < MAX_BLOCKS_PER_FRAME) {
			fillSlot(m_slots[todo[i].slot], todo[i].blockpos, todo[i].slot_index);
		} else {
			// Next frame
			m_slots[todo[i].slot].valid = false;
		}
	}
	g_profiler->avg("PointLightShadows: blocks written", std::min(todo.size(), MAX_BLOCKS_PER_FRAME));

	if (m_lights_dirty)
		rebuildLightLists();

	updateEntities(camera_pos);
}

void PointLightShadows::rebuildLightLists()
{
	m_lights_dirty = false;

	constexpr u32 n_entries = CELLS * CELLS * CELLS * CELL_LIGHTS;
	std::vector<u32> entries(n_entries, 0);
	std::vector<u8> priority(n_entries, 0);

	const v3s16 origin_node = m_origin_block * MAP_BLOCKSIZE;
	// Manhattan distance from a node to the nearest node of a cell, per axis
	auto axis_dist = [] (s16 p, s16 cell) -> s16 {
		const s16 lo = cell * CELL, hi = lo + CELL - 1;
		return p < lo ? lo - p : (p > hi ? p - hi : 0);
	};

	u32 n_lights = 0;
	for (const Slot &slot : m_slots) {
		if (!slot.valid)
			continue;
		for (const Light &l : slot.lights) {
			const v3s16 p = l.pos - origin_node;
			if (p.X < 0 || p.Y < 0 || p.Z < 0 || p.X >= SIZE || p.Y >= SIZE || p.Z >= SIZE)
				continue;
			n_lights++;
			const s16 r = l.level - 1;
			const v3s16 cmin(std::max<s16>(p.X - r, 0) / CELL,
					std::max<s16>(p.Y - r, 0) / CELL, std::max<s16>(p.Z - r, 0) / CELL);
			const v3s16 cmax(std::min<s16>(p.X + r, SIZE - 1) / CELL,
					std::min<s16>(p.Y + r, SIZE - 1) / CELL, std::min<s16>(p.Z + r, SIZE - 1) / CELL);
			const u32 value = (u32)p.X | (u32)p.Y << 8 | (u32)p.Z << 16 | (u32)l.level << 24;

			for (s16 cy = cmin.Y; cy <= cmax.Y; cy++)
			for (s16 cz = cmin.Z; cz <= cmax.Z; cz++)
			for (s16 cx = cmin.X; cx <= cmax.X; cx++) {
				const s32 dist = axis_dist(p.X, cx) + axis_dist(p.Y, cy) + axis_dist(p.Z, cz);
				const s32 prio = (s32)l.level - dist;
				if (prio <= 0)
					continue;
				// Insert, strongest first
				const u32 base = ((cy * CELLS + cz) * CELLS + cx) * CELL_LIGHTS;
				u32 j = 0;
				while (j < CELL_LIGHTS && priority[base + j] >= prio)
					j++;
				if (j == CELL_LIGHTS)
					continue;
				for (u32 k = CELL_LIGHTS - 1; k > j; k--) {
					priority[base + k] = priority[base + k - 1];
					entries[base + k] = entries[base + k - 1];
				}
				priority[base + j] = prio;
				entries[base + j] = value;
			}
		}
	}

	for (u32 cell = 0; cell < m_cell_lit.size(); cell++)
		m_cell_lit[cell] = priority[cell * CELL_LIGHTS] > 0;

	// The entries are in texture memory order
	m_texture->uploadRegion(0, 0, SIZE, TEX_WIDTH, TEX_HEIGHT, CLUSTER_LAYERS,
			entries.data());
	g_profiler->avg("PointLightShadows: lights", n_lights);
}
