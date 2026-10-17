// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

/*
	Waterlogging: nodes that hold a liquid source (Minecraft's waterlogged
	block states, see `waterlogged_liquid` in lua_api.md), and Minecraft's
	shape tests for liquids (Shapes.mergedFaceOccludes and
	Shapes.blockOccludes) on Luanti node boxes.
*/

#pragma once

#include "irrlichttypes_bloated.h"
#include "mapnode.h"
#include <vector>

class NodeDefManager;

// The liquid in a node: the node itself for a liquid node, the held source
// for a waterlogged node, CONTENT_IGNORE for anything else
content_t node_liquid_content(const NodeDefManager *ndef, MapNode n);

// If `n` is a dry liquid container placed over a source of the liquid it
// can hold (`replaced`), turns it into its waterlogged form
void waterlog_replacement(const NodeDefManager *ndef, MapNode replaced, MapNode &n);

// Minecraft's VoxelShape: boxes in node coordinates (-0.5 .. 0.5)
struct NodeShape
{
	enum Kind : u8 { EMPTY, BLOCK, BOXES };
	Kind kind = EMPTY;
	std::vector<aabb3f> boxes;

	// From boxes in BS units (as MapNode::getCollisionBoxes returns them)
	static NodeShape fromBoxes(const std::vector<aabb3f> &boxes);
	static NodeShape block()
	{
		NodeShape s;
		s.kind = BLOCK;
		return s;
	}
};

// BlockState.getCollisionShape: empty for non-walkable nodes.
// `neighbors` as for MapNode::getCollisionBoxes.
NodeShape node_collision_shape(const NodeDefManager *ndef, MapNode n,
		u8 neighbors = 0);

// Shapes.mergedFaceOccludes: whether the face of `a` towards `dir` and the
// face of `b` (the node next to `a` in direction `dir`) towards `a`
// together cover the whole face between them.
bool shapes_merged_face_occludes(const NodeShape &a, const NodeShape &b, v3s16 dir);

// Whether the face of shape `s` towards `dir` alone covers it fully
bool shape_face_full(const NodeShape &s, v3s16 dir);

// FluidRenderer.isFaceOccludedByState: whether `occluder`, the node next to
// a fluid in direction `dir`, hides the fluid's face there. The fluid fills
// its node up to `height` (0..1).
bool shape_occludes_fluid_face(const NodeShape &occluder, v3s16 dir, f32 height);
