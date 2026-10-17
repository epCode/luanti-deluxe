// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

// Entity shadows of point light shadows (point_light_entity_shadows), see
// pointlightshadows.h

#include "client/shadows/pointlightshadows.h"
#include "client/client.h"
#include "client/clientenvironment.h"
#include "client/clientobject.h"
#include "client/shader.h"
#include "log.h"
#include "mapblock.h"
#include "profiler.h"
#include "util/numeric.h"
#include <AnimatedMeshSceneNode.h>
#include <IMeshSceneNode.h>
#include <IMaterialRendererServices.h>
#include <IVideoDriver.h>
#include <SkinnedMesh.h>
#include <SSkinMeshBuffer.h>
#include <algorithm>
#include <optional>
#include <cmath>

// Entities looked at, nearest first
static constexpr size_t MAX_ENTITY_NODES = 64;
// Thinnest box: flat parts (capes, items) still cast shadows (scene units)
static constexpr f32 MIN_BOX_HALF_EXTENT = BS / 64.0f;
// Closest distance the shadow maps cover (scene units)
static constexpr f32 MAP_NEAR = 0.05f * BS;

namespace {

// Light source position of the shadow map being rendered
class EntityDepthUniformSetter : public IShaderUniformSetterRC
{
	CachedPixelShaderSetting<f32, 3> m_light_pos{"pointShadowLightPos"};
	CachedPixelShaderSetting<f32> m_inv_far{"pointShadowInvFar"};

public:
	// Set before rendering each light's shadow map
	static v3f current_light;

	void onSetUniforms(video::IMaterialRendererServices *services) override
	{
		m_light_pos.set(current_light, services);
		f32 inv_far = 1.0f / PointLightShadows::MAP_FAR;
		m_inv_far.set(&inv_far, services);
	}
};

v3f EntityDepthUniformSetter::current_light;

inline s16 wrap(s16 v, s16 n)
{
	return ((v % n) + n) % n;
}

// Cube faces: +X, -X, +Y, -Y, +Z, -Z (the shader picks them the same way)
const v3f FACE_DIRS[6] = {
	{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
};
const v3f FACE_UPS[6] = {
	{0, 1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {0, 1, 0}, {0, 1, 0},
};

// Calls f(buffer index, mesh buffer, transformation to scene coordinates,
// weights or nullptr, skin matrices) for each mesh buffer of a scene node
template <typename F>
void forEachBuffer(scene::ISceneNode *node, F &&f)
{
	const core::matrix4 &abs = node->getAbsoluteTransformation();
	scene::IMesh *mesh = nullptr;
	if (node->getType() == scene::ESNT_ANIMATED_MESH) {
		auto *anode = static_cast<scene::AnimatedMeshSceneNode *>(node);
		auto *sm = dynamic_cast<scene::SkinnedMesh *>(anode->getMesh());
		if (sm) {
			const auto &global = anode->getJointGlobalMatrices();
			std::vector<core::matrix4> skin;
			// Software skinned buffers hold the animated pose already
			const bool hw_skinning = sm->hasWeights() && !sm->useSoftwareSkinning() &&
					global.size() == sm->getAllJoints().size();
			if (hw_skinning)
				skin = sm->calculateSkinMatrices(global);
			for (u32 i = 0; i < sm->getMeshBufferCount(); i++) {
				auto *mb = static_cast<scene::SSkinMeshBuffer *>(sm->getMeshBuffer(i));
				const scene::WeightBuffer *weights = mb->getWeights();
				f(i, mb, abs * mb->Transformation, hw_skinning ? weights : nullptr, skin);
			}
			return;
		}
		mesh = anode->getMesh();
	} else if (node->getType() == scene::ESNT_MESH) {
		mesh = static_cast<scene::IMeshSceneNode *>(node)->getMesh();
	}
	if (!mesh)
		return;
	static const std::vector<core::matrix4> no_skin;
	for (u32 i = 0; i < mesh->getMeshBufferCount(); i++)
		f(i, mesh->getMeshBuffer(i), abs, nullptr, no_skin);
}

// Calls f(i0, i1, i2) for each triangle of a mesh buffer
template <typename F>
void forEachTriangle(const scene::IMeshBuffer *mb, F &&f)
{
	if (mb->getPrimitiveType() != scene::EPT_TRIANGLES)
		return;
	const u32 n = mb->getIndexCount();
	if (mb->getIndexType() == video::EIT_16BIT) {
		const u16 *idx = mb->getIndices();
		for (u32 i = 0; i + 2 < n; i += 3)
			f(idx[i], idx[i + 1], idx[i + 2]);
	} else {
		const u32 *idx = reinterpret_cast<const u32 *>(mb->getIndices());
		for (u32 i = 0; i + 2 < n; i += 3)
			f(idx[i], idx[i + 1], idx[i + 2]);
	}
}

video::ITexture *bufferTexture(scene::ISceneNode *node, u32 i)
{
	return i < node->getMaterialCount() ? node->getMaterial(i).getTexture(0) : nullptr;
}

}

bool PointLightShadows::AlphaMask::isOpaque(v2f uv) const
{
	if (opaque.empty())
		return true;
	const f32 u = uv.X - std::floor(uv.X);
	const f32 v = uv.Y - std::floor(uv.Y);
	const u32 x = std::min<u32>(u * width, width - 1);
	const u32 y = std::min<u32>(v * height, height - 1);
	return opaque[y * width + x];
}

const PointLightShadows::AlphaMask *PointLightShadows::getAlphaMask(video::ITexture *texture)
{
	if (!texture)
		return nullptr;
	auto it = m_alpha_masks.find(texture);
	if (it != m_alpha_masks.end())
		return &it->second;
	if (m_alpha_masks.size() > 1024)
		m_alpha_masks.clear();

	AlphaMask &mask = m_alpha_masks[texture];
	const auto format = texture->getColorFormat();
	if (format != video::ECF_A8R8G8B8 || texture->getType() != video::ETT_2D)
		return &mask; // treated as opaque
	const auto size = texture->getSize();
	const u32 *data = static_cast<const u32 *>(
			texture->lock(video::ETLM_READ_ONLY, 0, 0, video::ETLF_NONE));
	if (!data)
		return &mask;
	mask.width = size.Width;
	mask.height = size.Height;
	mask.opaque.resize(size.Width * size.Height);
	bool all_opaque = true;
	mask.any_opaque = false;
	for (u32 i = 0; i < mask.opaque.size(); i++) {
		mask.opaque[i] = (data[i] >> 24) >= 128;
		all_opaque &= mask.opaque[i];
		mask.any_opaque |= mask.opaque[i];
	}
	texture->unlock();
	if (all_opaque)
		mask.opaque.clear();
	return &mask;
}

bool PointLightShadows::AlphaMask::isTriangleOpaque(v2f a, v2f b, v2f c) const
{
	if (opaque.empty())
		return true;
	constexpr int N = 4;
	for (int i = 0; i <= N; i++)
	for (int j = 0; j <= N - i; j++) {
		// Slightly inside, off the edges shared with other faces
		const f32 u = (i + 0.2f) / (N + 0.6f), v = (j + 0.2f) / (N + 0.6f);
		if (isOpaque(a + (b - a) * u + (c - a) * v))
			return true;
	}
	return false;
}

const std::vector<std::pair<s32, aabb3f>> &PointLightShadows::getPartBoxes(
		scene::ISceneNode *node, scene::IMesh *mesh)
{
	// The same mesh looks different with other textures
	std::string key(reinterpret_cast<const char *>(&mesh), sizeof(mesh));
	for (u32 i = 0; i < mesh->getMeshBufferCount(); i++) {
		video::ITexture *t = bufferTexture(node, i);
		key.append(reinterpret_cast<const char *>(&t), sizeof(t));
	}
	auto it = m_part_boxes.find(key);
	if (it != m_part_boxes.end())
		return it->second;
	if (m_part_boxes.size() > 1024)
		m_part_boxes.clear();

	auto &parts = m_part_boxes[key];
	auto *sm = dynamic_cast<scene::SkinnedMesh *>(mesh);
	const bool skinned = sm && sm->hasWeights();
	std::vector<std::optional<aabb3f>> joint_boxes(sm ? sm->getAllJoints().size() : 0);
	auto add_point = [] (std::optional<aabb3f> &box, v3f p) {
		if (box)
			box->addInternalPoint(p);
		else
			box = aabb3f(p, p);
	};

	for (u32 i = 0; i < mesh->getMeshBufferCount(); i++) {
		scene::IMeshBuffer *mb = mesh->getMeshBuffer(i);
		const AlphaMask *mask = getAlphaMask(bufferTexture(node, i));
		if (mask && !mask->any_opaque)
			continue;
		const scene::WeightBuffer *weights = skinned ?
				static_cast<scene::SSkinMeshBuffer *>(mb)->getWeights() : nullptr;
		std::optional<aabb3f> buffer_box;
		forEachTriangle(mb, [&] (u32 i0, u32 i1, u32 i2) {
			if (mask && !mask->isTriangleOpaque(mb->getTCoords(i0),
					mb->getTCoords(i1), mb->getTCoords(i2)))
				return;
			for (u32 v : {i0, i1, i2}) {
				if (!weights) {
					add_point(buffer_box, mb->getPosition(v));
					continue;
				}
				// Static pose, in the space of each joint that moves it
				const v3f pos = weights->static_pose ?
						weights->static_pose[v].pos : mb->getPosition(v);
				for (u16 k = 0; k < scene::WeightBuffer::MAX_WEIGHTS_PER_VERTEX; k++) {
					if (weights->getWeights(v)[k] <= 0.0f)
						continue;
					const u16 j = weights->getJointIds(v)[k];
					const auto &inv = sm->getAllJoints()[j]->GlobalInversedMatrix;
					v3f p = pos;
					if (inv)
						inv->transformVect(p);
					add_point(joint_boxes[j], p);
				}
			}
		});
		if (buffer_box)
			parts.emplace_back(-1 - (s32)i, *buffer_box);
	}
	for (size_t j = 0; j < joint_boxes.size(); j++) {
		if (joint_boxes[j])
			parts.emplace_back((s32)j, *joint_boxes[j]);
	}
	return parts;
}

void PointLightShadows::setEntityMode(EntityMode mode)
{
	if (mode == m_entity_mode)
		return;
	const EntityMode old_mode = m_entity_mode;
	m_entity_mode = mode;
	m_box_count = 0;
	m_map_lights.fill(0.0f);
	if (old_mode == EntityMode::Voxels || mode == EntityMode::Voxels) {
		// Blocks keep (or drop) a copy of their masks when written: rewrite
		// them all, which also removes the entity voxels
		m_entity_voxels.clear();
		for (Slot &slot : m_slots)
			slot.valid = false;
	}
}

void PointLightShadows::collectEntityNodes(v3f camera_pos,
		std::vector<scene::ISceneNode *> &nodes)
{
	std::vector<DistanceSortedActiveObject> objects;
	m_client->getEnv().getActiveObjects(camera_pos, SIZE / 2 * BS, objects);
	std::sort(objects.begin(), objects.end());

	// Attached objects are separate objects, but their scene nodes are
	// children of their parent's
	std::unordered_set<scene::ISceneNode *> roots;
	for (const auto &o : objects) {
		if (scene::ISceneNode *n = o.obj->getSceneNode())
			roots.insert(n);
	}

	std::vector<scene::ISceneNode *> stack;
	for (const auto &o : objects) {
		scene::ISceneNode *root = o.obj->getSceneNode();
		if (!root || !root->isTrulyVisible())
			continue;
		stack.assign(1, root);
		while (!stack.empty() && nodes.size() < MAX_ENTITY_NODES) {
			scene::ISceneNode *n = stack.back();
			stack.pop_back();
			if (!n->isVisible() || (n != root && roots.count(n)))
				continue;
			const auto type = n->getType();
			if (type == scene::ESNT_MESH || type == scene::ESNT_ANIMATED_MESH)
				nodes.push_back(n);
			for (scene::ISceneNode *child : n->getChildren())
				stack.push_back(child);
		}
		if (nodes.size() >= MAX_ENTITY_NODES)
			break;
	}
}

bool PointLightShadows::reachesLight(const aabb3f &scene_box) const
{
	const v3f lo = (scene_box.MinEdge - m_origin_scene) / BS;
	const v3f hi = (scene_box.MaxEdge - m_origin_scene) / BS;
	auto cell = [] (f32 v) {
		return (s32)rangelim(std::floor(v / CELL), 0.0f, (f32)(CELLS - 1));
	};
	if (hi.X < 0 || hi.Y < 0 || hi.Z < 0 || lo.X >= SIZE || lo.Y >= SIZE || lo.Z >= SIZE)
		return false;
	for (s32 cy = cell(lo.Y); cy <= cell(hi.Y); cy++)
	for (s32 cz = cell(lo.Z); cz <= cell(hi.Z); cz++)
	for (s32 cx = cell(lo.X); cx <= cell(hi.X); cx++) {
		if (m_cell_lit[(cy * CELLS + cz) * CELLS + cx])
			return true;
	}
	return false;
}

void PointLightShadows::updateEntities(v3f camera_pos)
{
	if (m_entity_mode == EntityMode::None) {
		m_box_count = 0;
		return;
	}

	std::vector<scene::ISceneNode *> nodes;
	collectEntityNodes(camera_pos, nodes);

	switch (m_entity_mode) {
	case EntityMode::Boxes:
		updateEntityBoxes(nodes);
		break;
	case EntityMode::Voxels:
		updateEntityVoxels(nodes);
		break;
	case EntityMode::ShadowMaps:
		updateEntityShadowMaps(nodes);
		break;
	default:
		break;
	}
}

/*
	Boxes
*/

void PointLightShadows::computeBoxRows(const aabb3f &box, const core::matrix4 &box_transform,
		v3f volume_origin_scene, f32 rows[12])
{
	core::matrix4 inv;
	const v3f half = box.getExtent() * 0.5f;
	if (!box_transform.getInverse(inv) || half.X <= 0 || half.Y <= 0 || half.Z <= 0) {
		// Nothing is ever inside
		for (int i = 0; i < 12; i++)
			rows[i] = (i % 4 == 3) ? 10.0f : 0.0f;
		return;
	}
	const v3f center = box.getCenter();
	auto f = [&] (v3f v) {
		v3f p = volume_origin_scene + v * BS;
		inv.transformVect(p);
		p -= center;
		return v3f(p.X / half.X, p.Y / half.Y, p.Z / half.Z);
	};
	const v3f f0 = f(v3f(0, 0, 0));
	const v3f fx = f(v3f(1, 0, 0)) - f0;
	const v3f fy = f(v3f(0, 1, 0)) - f0;
	const v3f fz = f(v3f(0, 0, 1)) - f0;
	const f32 r[12] = {
		fx.X, fy.X, fz.X, f0.X,
		fx.Y, fy.Y, fz.Y, f0.Y,
		fx.Z, fy.Z, fz.Z, f0.Z,
	};
	std::copy(r, r + 12, rows);
}

void PointLightShadows::updateEntityBoxes(const std::vector<scene::ISceneNode *> &nodes)
{
	struct Candidate {
		f32 dist2;
		std::array<f32, 12> rows;
	};
	std::vector<Candidate> candidates;
	const v3f camera_scene = m_origin_scene + v3f(SIZE / 2 * BS);

	auto add = [&] (aabb3f box, const core::matrix4 &transform) {
		box.repair();
		if (box.getExtent().getLengthSQ() < 1e-6f)
			return; // empty: bones without vertices
		aabb3f scene_box = box;
		transform.transformBoxEx(scene_box);
		if (!reachesLight(scene_box))
			return;
		// Thicken flat boxes
		const v3f center = box.getCenter();
		v3f half = box.getExtent() * 0.5f;
		for (int k = 0; k < 3; k++) {
			v3f axis;
			axis[k] = 1.0f;
			const f32 scale = transform.rotateAndScaleVect(axis).getLength();
			if (scale > 0.0f && half[k] * scale < MIN_BOX_HALF_EXTENT)
				half[k] = MIN_BOX_HALF_EXTENT / scale;
		}
		Candidate c;
		c.dist2 = scene_box.getCenter().getDistanceFromSQ(camera_scene);
		computeBoxRows(aabb3f(center - half, center + half), transform, m_origin_scene,
				c.rows.data());
		candidates.push_back(c);
	};

	for (scene::ISceneNode *node : nodes) {
		const core::matrix4 &abs = node->getAbsoluteTransformation();
		scene::SkinnedMesh *sm = nullptr;
		scene::IMesh *mesh = nullptr;
		std::vector<core::matrix4> global;
		if (node->getType() == scene::ESNT_ANIMATED_MESH) {
			auto *anode = static_cast<scene::AnimatedMeshSceneNode *>(node);
			mesh = anode->getMesh();
			sm = dynamic_cast<scene::SkinnedMesh *>(mesh);
			if (sm) {
				global = anode->getJointGlobalMatrices();
				if (global.size() != sm->getAllJoints().size())
					continue;
			}
		} else if (node->getType() == scene::ESNT_MESH) {
			mesh = static_cast<scene::IMeshSceneNode *>(node)->getMesh();
		}
		if (!mesh)
			continue;
		for (const auto &part : getPartBoxes(node, mesh)) {
			const s32 id = part.first;
			if (id >= 0) {
				add(part.second, abs * global[id]);
			} else {
				const u32 i = -1 - id;
				core::matrix4 transform = abs;
				if (sm)
					transform *= static_cast<scene::SSkinMeshBuffer *>(sm->getMeshBuffer(i))->Transformation;
				add(part.second, transform);
			}
		}
	}

	// The nearest ones
	std::sort(candidates.begin(), candidates.end(),
			[] (const Candidate &a, const Candidate &b) { return a.dist2 < b.dist2; });
	m_box_count = std::min<u32>(candidates.size(), MAX_BOXES);
	for (u32 i = 0; i < m_box_count; i++)
		std::copy(candidates[i].rows.begin(), candidates[i].rows.end(), &m_box_rows[12 * i]);
	g_profiler->avg("PointLightShadows: entity boxes", m_box_count);
}

/*
	Voxels
*/

// Squared distance from p to the segment a-b
static f32 segmentDistanceSQ(v3f p, v3f a, v3f b)
{
	const v3f ab = b - a;
	const f32 len2 = ab.getLengthSQ();
	const f32 t = len2 > 0.0f ? rangelim((p - a).dotProduct(ab) / len2, 0.0f, 1.0f) : 0.0f;
	return (a + ab * t - p).getLengthSQ();
}

void PointLightShadows::rasterizeTriangle(v3f a, v3f b, v3f c, v3f normal,
		std::unordered_map<v3s16, u64> &voxels,
		const AlphaMask *mask, v2f ta, v2f tb, v2f tc)
{
	if (mask && mask->opaque.empty())
		mask = nullptr;
	if (normal.getLengthSQ() < 1e-12f)
		return;
	normal.normalize();
	// A sub-voxel is filled if its center lies just behind the surface (at
	// most this deep), like a solid voxelization: shapes keep their size
	constexpr f32 DEPTH = 1.0f;
	// and its projection onto the plane of the triangle is in the triangle
	// (neighboring triangles cover the rest)
	constexpr f32 SIDEWAYS = 0.01f;

	// Barycentric coordinates in the plane of the triangle
	const v3f e0 = b - a, e1 = c - a;
	const f32 d00 = e0.dotProduct(e0), d01 = e0.dotProduct(e1), d11 = e1.dotProduct(e1);
	const f32 denom = d00 * d11 - d01 * d01;
	if (std::fabs(denom) < 1e-12f)
		return; // degenerate

	// Centers that can qualify
	aabb3f box(a);
	box.addInternalPoint(b);
	box.addInternalPoint(c);
	const v3f deep = normal * -DEPTH;
	box.addInternalBox(aabb3f(box.MinEdge + deep, box.MaxEdge + deep));
	const s32 x0 = std::floor(box.MinEdge.X - SIDEWAYS - 0.5f), x1 = std::floor(box.MaxEdge.X + SIDEWAYS - 0.5f);
	const s32 y0 = std::floor(box.MinEdge.Y - SIDEWAYS - 0.5f), y1 = std::floor(box.MaxEdge.Y + SIDEWAYS - 0.5f);
	const s32 z0 = std::floor(box.MinEdge.Z - SIDEWAYS - 0.5f), z1 = std::floor(box.MaxEdge.Z + SIDEWAYS - 0.5f);

	v3s16 last_node(S16_MIN, S16_MIN, S16_MIN);
	u64 *last_mask = nullptr;
	for (s32 sz = z0; sz <= z1; sz++)
	for (s32 sy = y0; sy <= y1; sy++)
	for (s32 sx = x0; sx <= x1; sx++) {
		const v3f center(sx + 0.5f, sy + 0.5f, sz + 0.5f);
		const f32 behind = (a - center).dotProduct(normal);
		if (behind < -0.02f || behind > DEPTH)
			continue;
		const v3f p = center + normal * behind - a;
		const f32 d20 = p.dotProduct(e0), d21 = p.dotProduct(e1);
		f32 v = (d11 * d20 - d01 * d21) / denom;
		f32 w = (d00 * d21 - d01 * d20) / denom;
		if (v < 0.0f || w < 0.0f || v + w > 1.0f) {
			// Outside: close enough to an edge?
			const v3f q = center + normal * behind;
			const f32 dist2 = std::min({segmentDistanceSQ(q, a, b),
					segmentDistanceSQ(q, b, c), segmentDistanceSQ(q, c, a)});
			if (dist2 > SIDEWAYS * SIDEWAYS)
				continue;
			// The nearest point of the triangle for the texture
			v = rangelim(v, 0.0f, 1.0f);
			w = rangelim(w, 0.0f, 1.0f - v);
		}
		if (mask && !mask->isOpaque(ta + (tb - ta) * v + (tc - ta) * w))
			continue;
		const v3s16 node(sx >> 2, sy >> 2, sz >> 2);
		if (node != last_node) {
			last_node = node;
			last_mask = &voxels[node];
		}
		*last_mask |= (u64)1 << ((sx & 3) + 4 * (sy & 3) + 16 * (sz & 3));
	}
}

void PointLightShadows::updateEntityVoxels(const std::vector<scene::ISceneNode *> &nodes)
{
	std::unordered_map<v3s16, u64> voxels;
	const v3f origin_node = intToFloat(m_origin_block * MAP_BLOCKSIZE, 1.0f);
	std::vector<v3f> verts, normals;

	for (scene::ISceneNode *node : nodes) {
		if (!reachesLight(node->getTransformedBoundingBox()))
			continue;
		forEachBuffer(node, [&] (u32 buf, scene::IMeshBuffer *mb, const core::matrix4 &transform,
				const scene::WeightBuffer *weights, const std::vector<core::matrix4> &skin) {
			if (mb->getPrimitiveType() != scene::EPT_TRIANGLES)
				return;
			const AlphaMask *mask = getAlphaMask(bufferTexture(node, buf));
			if (mask && !mask->any_opaque)
				return;
			const u32 n_verts = mb->getVertexCount();
			verts.resize(n_verts);
			normals.resize(n_verts);
			for (u32 i = 0; i < n_verts; i++) {
				v3f p = mb->getPosition(i);
				v3f normal = mb->getNormal(i);
				if (weights)
					weights->skinVertex(i, p, normal, skin);
				transform.transformVect(p);
				// Absolute sub-voxel coordinates
				verts[i] = ((p - m_origin_scene) / BS + origin_node) * 4.0f;
				normals[i] = transform.rotateAndScaleVect(normal);
				normals[i].normalize();
			}
			forEachTriangle(mb, [&] (u32 i0, u32 i1, u32 i2) {
				// Outwards, as the vertex normals say
				v3f normal = normals[i0] + normals[i1] + normals[i2];
				if (normal.getLengthSQ() < 1e-6f)
					normal = (verts[i1] - verts[i0]).crossProduct(verts[i2] - verts[i0]);
				rasterizeTriangle(verts[i0], verts[i1], verts[i2], normal, voxels, mask,
						mb->getTCoords(i0), mb->getTCoords(i1), mb->getTCoords(i2));
			});
		});
	}

	// Rewrite the nodes that changed
	std::vector<v3s16> changed;
	for (const auto &it : voxels) {
		auto old = m_entity_voxels.find(it.first);
		if (old == m_entity_voxels.end() || old->second != it.second)
			changed.push_back(it.first);
	}
	for (const auto &it : m_entity_voxels) {
		if (voxels.count(it.first) == 0)
			changed.push_back(it.first);
	}
	m_entity_voxels = std::move(voxels);
	uploadVoxelNodes(changed);
	g_profiler->avg("PointLightShadows: entity voxel nodes", m_entity_voxels.size());
}

void PointLightShadows::uploadVoxelNodes(const std::vector<v3s16> &nodes)
{
	// Changed area of each block
	struct Area {
		v3s16 lo, hi;
	};
	std::unordered_map<u32, Area> areas;
	for (v3s16 p : nodes) {
		const v3s16 bp = getNodeBlockPos(p);
		const v3s16 si(wrap(bp.X, VOLUME_BLOCKS), wrap(bp.Y, VOLUME_BLOCKS), wrap(bp.Z, VOLUME_BLOCKS));
		const u32 i = (si.Z * VOLUME_BLOCKS + si.Y) * VOLUME_BLOCKS + si.X;
		const Slot &slot = m_slots[i];
		// Blocks not written yet get the entity voxels when they are
		if (!slot.valid || slot.blockpos != bp || slot.map_masks.empty())
			continue;
		const v3s16 rel = p - bp * MAP_BLOCKSIZE;
		auto it = areas.find(i);
		if (it == areas.end()) {
			areas.emplace(i, Area{rel, rel});
		} else {
			it->second.lo = componentwise_min(it->second.lo, rel);
			it->second.hi = componentwise_max(it->second.hi, rel);
		}
	}

	std::vector<u32> data;
	for (const auto &it : areas) {
		const Slot &slot = m_slots[it.first];
		const Area &a = it.second;
		const v3s16 size = a.hi - a.lo + 1;
		data.resize(2 * size.X * size.Y * size.Z);
		const v3s16 base = slot.blockpos * MAP_BLOCKSIZE;
		u32 k = 0;
		for (s16 y = a.lo.Y; y <= a.hi.Y; y++)
		for (s16 z = a.lo.Z; z <= a.hi.Z; z++)
		for (s16 x = a.lo.X; x <= a.hi.X; x++) {
			u64 mask = slot.map_masks[(y * MAP_BLOCKSIZE + z) * MAP_BLOCKSIZE + x];
			auto e = m_entity_voxels.find(base + v3s16(x, y, z));
			if (e != m_entity_voxels.end())
				mask |= e->second;
			data[k++] = (u32)mask;
			data[k++] = (u32)(mask >> 32);
		}
		const u32 sx = it.first % VOLUME_BLOCKS;
		const u32 sy = it.first / VOLUME_BLOCKS % VOLUME_BLOCKS;
		const u32 sz = it.first / (VOLUME_BLOCKS * VOLUME_BLOCKS);
		m_texture->uploadRegion(sx * 2 * MAP_BLOCKSIZE + 2 * a.lo.X,
				sz * MAP_BLOCKSIZE + a.lo.Z, sy * MAP_BLOCKSIZE + a.lo.Y,
				2 * size.X, size.Z, size.Y, data.data());
	}
}

/*
	Shadow maps
*/

void PointLightShadows::createEntityMapTexture()
{
	if (!m_driver->queryFeature(video::EVDF_RENDER_TO_FLOAT_TEXTURE)) {
		warningstream << "Point light shadow maps need float render targets, "
				"they are not available." << std::endl;
		return;
	}
	const core::dimension2du size(6 * MAP_FACE_SIZE, MAP_LIGHTS * MAP_FACE_SIZE);
	m_entity_map = m_driver->addRenderTargetTexture(size, "point_shadow_entities",
			video::ECF_R32F);
	if (!m_entity_map)
		m_entity_map = m_driver->addRenderTargetTexture(size, "point_shadow_entities",
				video::ECF_R16F);
}

bool PointLightShadows::initEntityMaps()
{
	if (m_entity_map_material > 0)
		return true;
	if (m_entity_maps_failed || !m_shsrc || !m_entity_map)
		return false;
	m_entity_maps_failed = true;

	ShaderConstants consts;
	const auto max_joints = m_driver->getMaxJointTransforms();
	if (max_joints > 0) {
		consts["USE_SKINNING"] = 1;
		consts["MAX_JOINTS"] = max_joints;
	}
	auto *cb = new EntityDepthUniformSetter();
	const u32 shader = m_shsrc->getShader("shadow/point_entity", consts,
			video::EMT_SOLID, cb);
	cb->drop();
	m_entity_map_material = m_shsrc->getShaderInfo(shader).material;
	if (m_entity_map_material <= 0)
		return false;

	m_face_projection.buildProjectionMatrixPerspectiveFovLH(core::PI / 2.0f, 1.0f,
			MAP_NEAR, MAP_FAR);
	for (int f = 0; f < 6; f++) {
		m_face_views[f].buildCameraLookAtMatrixLH(v3f(0, 0, 0), FACE_DIRS[f], FACE_UPS[f]);
		core::matrix4 view_proj = m_face_projection;
		view_proj *= m_face_views[f];
		std::copy(view_proj.pointer(), view_proj.pointer() + 16, &m_map_faces[16 * f]);
	}
	m_entity_maps_failed = false;
	return true;
}

void PointLightShadows::updateEntityShadowMaps(const std::vector<scene::ISceneNode *> &nodes)
{
	m_map_lights.fill(0.0f);
	if (!initEntityMaps())
		return;

	// Entities in volume coordinates
	std::vector<aabb3f> boxes;
	boxes.reserve(nodes.size());
	for (scene::ISceneNode *node : nodes) {
		aabb3f b = node->getTransformedBoundingBox();
		boxes.emplace_back((b.MinEdge - m_origin_scene) / BS, (b.MaxEdge - m_origin_scene) / BS);
	}

	// The light sources nearest to the camera that reach an entity
	struct Choice {
		f32 dist2;
		v3s16 pos; // volume coordinates
		std::vector<u32> nodes;
	};
	std::vector<Choice> choices;
	const v3s16 origin_node = m_origin_block * MAP_BLOCKSIZE;
	const v3f camera = v3f(SIZE / 2);
	if (!nodes.empty()) {
		for (const Slot &slot : m_slots) {
			if (!slot.valid)
				continue;
			for (const Light &l : slot.lights) {
				const v3s16 p = l.pos - origin_node;
				if (p.X < 0 || p.Y < 0 || p.Z < 0 || p.X >= SIZE || p.Y >= SIZE || p.Z >= SIZE)
					continue;
				const v3f c = intToFloat(p, 1.0f) + 0.5f;
				Choice choice{c.getDistanceFromSQ(camera), p, {}};
				for (u32 i = 0; i < boxes.size(); i++) {
					const aabb3f &b = boxes[i];
					// Manhattan distance to the box
					const f32 d = std::max({b.MinEdge.X - c.X, c.X - b.MaxEdge.X, 0.0f}) +
							std::max({b.MinEdge.Y - c.Y, c.Y - b.MaxEdge.Y, 0.0f}) +
							std::max({b.MinEdge.Z - c.Z, c.Z - b.MaxEdge.Z, 0.0f});
					if (d < l.level)
						choice.nodes.push_back(i);
				}
				if (!choice.nodes.empty())
					choices.push_back(std::move(choice));
			}
		}
	}
	std::sort(choices.begin(), choices.end(),
			[] (const Choice &a, const Choice &b) { return a.dist2 < b.dist2; });
	if (choices.size() > MAP_LIGHTS)
		choices.resize(MAP_LIGHTS);
	g_profiler->avg("PointLightShadows: shadow mapped lights", choices.size());

	if (choices.empty()) {
		m_entity_map_clear = true;
		return;
	}

	m_driver->setRenderTarget(m_entity_map, video::ECBF_COLOR | video::ECBF_DEPTH,
			video::SColor(255, 255, 255, 255));
	m_entity_map_clear = false;

	struct SavedMaterial {
		video::E_MATERIAL_TYPE type;
		bool backface, frontface;
		video::E_BLEND_OPERATION blend;
		u8 zwrite;
	};
	std::vector<SavedMaterial> saved;

	for (size_t s = 0; s < choices.size(); s++) {
		const Choice &choice = choices[s];
		const v3f light_scene = m_origin_scene + (intToFloat(choice.pos, 1.0f) + 0.5f) * BS;
		m_map_lights[4 * s + 0] = choice.pos.X;
		m_map_lights[4 * s + 1] = choice.pos.Y;
		m_map_lights[4 * s + 2] = choice.pos.Z;
		m_map_lights[4 * s + 3] = 1.0f;
		EntityDepthUniformSetter::current_light = light_scene;

		for (int f = 0; f < 6; f++) {
			m_driver->setViewPort(core::recti(f * MAP_FACE_SIZE, s * MAP_FACE_SIZE,
					(f + 1) * MAP_FACE_SIZE, (s + 1) * MAP_FACE_SIZE));
			core::matrix4 view;
			view.buildCameraLookAtMatrixLH(light_scene, light_scene + FACE_DIRS[f], FACE_UPS[f]);
			m_driver->setTransform(video::ETS_VIEW, view);
			m_driver->setTransform(video::ETS_PROJECTION, m_face_projection);

			for (u32 i : choice.nodes) {
				scene::ISceneNode *node = nodes[i];
				const u32 n_materials = node->getMaterialCount();
				saved.clear();
				for (u32 m = 0; m < n_materials; m++) {
					video::SMaterial &mat = node->getMaterial(m);
					saved.push_back({mat.MaterialType, mat.BackfaceCulling,
							mat.FrontfaceCulling, mat.BlendOperation, mat.ZWriteEnable});
					mat.MaterialType = (video::E_MATERIAL_TYPE)m_entity_map_material;
					// Both sides: flat parts are single sided
					mat.BackfaceCulling = false;
					mat.FrontfaceCulling = false;
					mat.BlendOperation = video::EBO_NONE;
					mat.ZWriteEnable = video::EZW_ON;
				}
				m_driver->setTransform(video::ETS_WORLD, node->getAbsoluteTransformation());
				node->render();
				for (u32 m = 0; m < n_materials; m++) {
					video::SMaterial &mat = node->getMaterial(m);
					mat.MaterialType = saved[m].type;
					mat.BackfaceCulling = saved[m].backface;
					mat.FrontfaceCulling = saved[m].frontface;
					mat.BlendOperation = saved[m].blend;
					mat.ZWriteEnable = (video::E_ZWRITE)saved[m].zwrite;
				}
			}
		}
	}
	m_driver->setRenderTarget(nullptr, 0);
}
