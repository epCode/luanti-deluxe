// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "waterlogging.h"
#include "nodedef.h"
#include "constants.h"
#include <algorithm>

content_t node_liquid_content(const NodeDefManager *ndef, MapNode n)
{
	const ContentFeatures &f = ndef->get(n);
	if (f.isLiquid())
		return n.getContent();
	return f.waterlogged_liquid_id;
}

void waterlog_replacement(const NodeDefManager *ndef, MapNode replaced, MapNode &n)
{
	const ContentFeatures &f = ndef->get(n);
	if (!f.isLiquidContainer() || f.isWaterlogged())
		return;
	const ContentFeatures &fr = ndef->get(replaced);
	if (fr.liquid_type != LIQUID_SOURCE)
		return;
	const ContentFeatures &wet = ndef->get(f.waterlogged_alternative_id);
	if (wet.isWaterlogged() && ndef->get(wet.waterlogged_liquid_id)
			.liquid_alternative_source_id == fr.liquid_alternative_source_id)
		n.setContent(f.waterlogged_alternative_id);
}

namespace {

constexpr f32 EPS = 1e-4f;

// A rectangle on a node face, in the two coordinates across the face
struct FaceRect
{
	f32 u0, v0, u1, v1;
};

// The axis of a direction and the two axes across it
void face_axes(v3s16 dir, int &axis, int &ua, int &va)
{
	axis = dir.X ? 0 : dir.Y ? 1 : 2;
	ua = axis == 0 ? 1 : 0;
	va = axis == 2 ? 1 : 2;
}

f32 coord(const v3f &v, int axis)
{
	return axis == 0 ? v.X : axis == 1 ? v.Y : v.Z;
}

// VoxelShape.getFaceShape: the parts of the shape touching its side `dir`
void face_rects(const NodeShape &s, v3s16 dir, std::vector<FaceRect> &out)
{
	if (s.kind == NodeShape::EMPTY)
		return;
	if (s.kind == NodeShape::BLOCK) {
		out.push_back({-0.5f, -0.5f, 0.5f, 0.5f});
		return;
	}
	int axis, ua, va;
	face_axes(dir, axis, ua, va);
	const bool positive = dir.X + dir.Y + dir.Z > 0;
	for (const aabb3f &b : s.boxes) {
		bool touches = positive ? coord(b.MaxEdge, axis) >= 0.5f - EPS :
				coord(b.MinEdge, axis) <= -0.5f + EPS;
		if (!touches)
			continue;
		FaceRect r{
			std::max(coord(b.MinEdge, ua), -0.5f), std::max(coord(b.MinEdge, va), -0.5f),
			std::min(coord(b.MaxEdge, ua), 0.5f), std::min(coord(b.MaxEdge, va), 0.5f),
		};
		if (r.u1 - r.u0 > EPS && r.v1 - r.v0 > EPS)
			out.push_back(r);
	}
}

// Whether the rectangles cover `target` completely
bool rects_cover(const std::vector<FaceRect> &rects, const FaceRect &target)
{
	if (rects.empty())
		return false;
	std::vector<f32> us{target.u0, target.u1}, vs{target.v0, target.v1};
	for (const FaceRect &r : rects) {
		if (r.u0 > target.u0 && r.u0 < target.u1) us.push_back(r.u0);
		if (r.u1 > target.u0 && r.u1 < target.u1) us.push_back(r.u1);
		if (r.v0 > target.v0 && r.v0 < target.v1) vs.push_back(r.v0);
		if (r.v1 > target.v0 && r.v1 < target.v1) vs.push_back(r.v1);
	}
	std::sort(us.begin(), us.end());
	std::sort(vs.begin(), vs.end());
	for (size_t i = 0; i + 1 < us.size(); i++) {
		if (us[i + 1] - us[i] <= EPS)
			continue;
		f32 u = (us[i] + us[i + 1]) / 2;
		for (size_t j = 0; j + 1 < vs.size(); j++) {
			if (vs[j + 1] - vs[j] <= EPS)
				continue;
			f32 v = (vs[j] + vs[j + 1]) / 2;
			bool covered = false;
			for (const FaceRect &r : rects) {
				if (u > r.u0 - EPS && u < r.u1 + EPS && v > r.v0 - EPS && v < r.v1 + EPS) {
					covered = true;
					break;
				}
			}
			if (!covered)
				return false;
		}
	}
	return true;
}

const FaceRect FULL_FACE{-0.5f, -0.5f, 0.5f, 0.5f};

} // namespace

NodeShape NodeShape::fromBoxes(const std::vector<aabb3f> &boxes)
{
	NodeShape s;
	for (const aabb3f &b : boxes) {
		aabb3f nb(b.MinEdge / BS, b.MaxEdge / BS);
		if (nb.MinEdge.X <= -0.5f + EPS && nb.MinEdge.Y <= -0.5f + EPS &&
				nb.MinEdge.Z <= -0.5f + EPS && nb.MaxEdge.X >= 0.5f - EPS &&
				nb.MaxEdge.Y >= 0.5f - EPS && nb.MaxEdge.Z >= 0.5f - EPS)
			return NodeShape::block();
		if (nb.MaxEdge.X - nb.MinEdge.X > EPS && nb.MaxEdge.Y - nb.MinEdge.Y > EPS &&
				nb.MaxEdge.Z - nb.MinEdge.Z > EPS)
			s.boxes.push_back(nb);
	}
	s.kind = s.boxes.empty() ? EMPTY : BOXES;
	return s;
}

NodeShape node_collision_shape(const NodeDefManager *ndef, MapNode n, u8 neighbors)
{
	const ContentFeatures &f = ndef->get(n);
	if (!f.walkable)
		return NodeShape();
	std::vector<aabb3f> boxes;
	n.getCollisionBoxes(ndef, &boxes, neighbors);
	return NodeShape::fromBoxes(boxes);
}

bool shapes_merged_face_occludes(const NodeShape &a, const NodeShape &b, v3s16 dir)
{
	if (a.kind == NodeShape::BLOCK || b.kind == NodeShape::BLOCK)
		return true;
	std::vector<FaceRect> rects;
	face_rects(a, dir, rects);
	face_rects(b, -dir, rects);
	return rects_cover(rects, FULL_FACE);
}

bool shape_face_full(const NodeShape &s, v3s16 dir)
{
	if (s.kind != NodeShape::BOXES)
		return s.kind == NodeShape::BLOCK;
	std::vector<FaceRect> rects;
	face_rects(s, dir, rects);
	return rects_cover(rects, FULL_FACE);
}

bool shape_occludes_fluid_face(const NodeShape &occluder, v3s16 dir, f32 height)
{
	if (occluder.kind == NodeShape::EMPTY)
		return false;
	const bool full = height >= 1.0f;
	if (occluder.kind == NodeShape::BLOCK)
		return dir.Y <= 0 || full;
	// Shapes.blockOccludes with the fluid's box(0, 0, 0, 1, height, 1):
	// its top face only exists at full height
	if (dir.Y > 0 && !full)
		return false;
	std::vector<FaceRect> rects;
	face_rects(occluder, -dir, rects);
	FaceRect target = FULL_FACE;
	if (dir.Y == 0) {
		// Y is the first face axis across X faces and the second across Z faces
		if (dir.X)
			target.u1 = -0.5f + height;
		else
			target.v1 = -0.5f + height;
	}
	return rects_cover(rects, target);
}
