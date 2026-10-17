// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "catch.h"

#include "waterlogging.h"
#include "constants.h"

// Boxes in node units (-0.5 .. 0.5), as NodeShape::fromBoxes expects them
// in BS units
static NodeShape shape(std::initializer_list<aabb3f> boxes)
{
	std::vector<aabb3f> bs;
	for (aabb3f b : boxes)
		bs.emplace_back(b.MinEdge * BS, b.MaxEdge * BS);
	return NodeShape::fromBoxes(bs);
}

static const v3s16 UP(0, 1, 0), DOWN(0, -1, 0), EAST(1, 0, 0), WEST(-1, 0, 0),
		NORTH(0, 0, 1);

TEST_CASE("waterlogging shapes")
{
	const NodeShape empty;
	const NodeShape block = shape({{-0.5f, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f}});
	const NodeShape bottom_slab = shape({{-0.5f, -0.5f, -0.5f, 0.5f, 0.0f, 0.5f}});
	const NodeShape top_slab = shape({{-0.5f, 0.0f, -0.5f, 0.5f, 0.5f, 0.5f}});
	// Stair with its back (full height) towards +Z
	const NodeShape stair = shape({
		{-0.5f, -0.5f, -0.5f, 0.5f, 0.0f, 0.5f},
		{-0.5f, 0.0f, 0.0f, 0.5f, 0.5f, 0.5f},
	});

	SECTION("classification") {
		CHECK(block.kind == NodeShape::BLOCK);
		CHECK(empty.kind == NodeShape::EMPTY);
		CHECK(bottom_slab.kind == NodeShape::BOXES);
	}

	SECTION("full faces") {
		CHECK(shape_face_full(bottom_slab, DOWN));
		CHECK_FALSE(shape_face_full(bottom_slab, UP));
		CHECK_FALSE(shape_face_full(bottom_slab, EAST));
		CHECK(shape_face_full(top_slab, UP));
		CHECK(shape_face_full(stair, NORTH));
		CHECK_FALSE(shape_face_full(stair, -NORTH));
		CHECK(shape_face_full(block, WEST));
		CHECK_FALSE(shape_face_full(empty, WEST));
	}

	SECTION("mergedFaceOccludes") {
		// No liquid out of the bottom of a bottom slab
		CHECK(shapes_merged_face_occludes(bottom_slab, empty, DOWN));
		// Sideways between two bottom slabs it passes
		CHECK_FALSE(shapes_merged_face_occludes(bottom_slab, bottom_slab, EAST));
		// A bottom slab next to a top slab closes the face together
		CHECK(shapes_merged_face_occludes(bottom_slab, top_slab, EAST));
		CHECK(shapes_merged_face_occludes(top_slab, bottom_slab, WEST));
		// Down out of a top slab, into the slab below's top
		CHECK_FALSE(shapes_merged_face_occludes(top_slab, empty, DOWN));
		CHECK(shapes_merged_face_occludes(top_slab, bottom_slab, UP) ==
				shapes_merged_face_occludes(bottom_slab, top_slab, DOWN));
		// Stair back
		CHECK(shapes_merged_face_occludes(stair, empty, NORTH));
		CHECK_FALSE(shapes_merged_face_occludes(stair, empty, -NORTH));
		CHECK(shapes_merged_face_occludes(empty, block, EAST));
		CHECK_FALSE(shapes_merged_face_occludes(empty, empty, EAST));
	}

	SECTION("fluid faces hidden by a neighbour") {
		// Full blocks hide sides and the bottom, the top only at full height
		CHECK(shape_occludes_fluid_face(block, EAST, 8.0f / 9.0f));
		CHECK(shape_occludes_fluid_face(block, DOWN, 8.0f / 9.0f));
		CHECK_FALSE(shape_occludes_fluid_face(block, UP, 8.0f / 9.0f));
		CHECK(shape_occludes_fluid_face(block, UP, 1.0f));
		// A bottom slab next to the fluid hides only the lower half
		CHECK_FALSE(shape_occludes_fluid_face(bottom_slab, EAST, 8.0f / 9.0f));
		CHECK(shape_occludes_fluid_face(bottom_slab, EAST, 0.5f));
		// A top slab below covers the fluid's bottom face
		CHECK(shape_occludes_fluid_face(top_slab, DOWN, 8.0f / 9.0f));
		CHECK_FALSE(shape_occludes_fluid_face(bottom_slab, DOWN, 8.0f / 9.0f));
		CHECK_FALSE(shape_occludes_fluid_face(empty, EAST, 1.0f));
	}
}
