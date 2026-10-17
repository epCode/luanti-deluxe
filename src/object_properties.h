// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2013 celeron55, Perttu Ahola <celeron55@gmail.com>

#pragma once

#include <optional>
#include <string>
#include "irrlichttypes_bloated.h"
#include <iostream>
#include <vector>
#include "util/pointabilities.h"
#include "mapnode.h"

struct EnumString;

enum ObjectVisual : u8 {
	OBJECTVISUAL_UNKNOWN,
	OBJECTVISUAL_SPRITE,
	OBJECTVISUAL_UPRIGHT_SPRITE,
	OBJECTVISUAL_CUBE,
	OBJECTVISUAL_MESH,
	OBJECTVISUAL_ITEM,
	OBJECTVISUAL_WIELDITEM,
	OBJECTVISUAL_NODE,
};

extern const EnumString es_ObjectVisual[];

enum class StepUpMode : u8 {
	LEGACY,
	FLOATY,
	RIGID,
};

extern const EnumString es_StepUpMode[];

struct ObjectProperties
{
	/* member variables ordered roughly by size */

	std::vector<std::string> textures;
	std::vector<video::SColor> colors; // Currently unused
	// Values are BS=1
	aabb3f collisionbox = aabb3f(-0.5f, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f);
	// Values are BS=1
	aabb3f selectionbox = aabb3f(-0.5f, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f);
	ObjectVisual visual = OBJECTVISUAL_SPRITE;
	std::string mesh;
	std::string damage_texture_modifier = "^[brighten";
	std::string nametag;
	std::string infotext;
	// For dropped items, this contains the serialized item.
	std::string wield_item;
	v3f visual_size = v3f(1, 1, 1);
	video::SColor nametag_color = video::SColor(255, 255, 255, 255);
	std::optional<video::SColor> nametag_bgcolor;
	v2s16 spritediv = v2s16(1, 1);
	v2s16 initial_sprite_basepos;
	f32 stepheight = 0.0f;
	float automatic_rotate = 0.0f;
	f32 automatic_face_movement_dir_offset = 0.0f;
	f32 automatic_face_movement_max_rotation_per_sec = -1.0f;
	float eye_height = 1.625f;
	float zoom_fov = 0.0f;
	std::optional<u32> nametag_fontsize;
	MapNode node = MapNode(CONTENT_IGNORE);
	u16 hp_max = 1;
	u16 breath_max = 0;
	s8 glow = 0;
	PointabilityType pointable = PointabilityType::POINTABLE;
	// In a future protocol these could be a flag field.
	bool physical = false;
	bool collideWithObjects = true;
	bool rotate_selectionbox = false;
	bool is_visible = true;
	bool makes_footstep_sound = false;
	bool automatic_face_movement_dir = false;
	bool backface_culling = true;
	bool static_save = true;
	bool use_texture_alpha = false;
	bool shaded = true;
	bool show_on_minimap = false;
	bool nametag_scale_z = false;
	StepUpMode step_up_mode = StepUpMode::LEGACY;
	// Whether the nametag shows through nodes
	bool nametag_see_through = true;
	// Maximum distance at which the nametag is shown (0 = unlimited)
	f32 nametag_range = 0.0f;
	// Procedural model animation done by the client ("" = none)
	std::string procedural_animation;
	// Client interpolates position, rotation, scale and attachment offsets
	// between server updates (see client/transform_interpolation.h)
	bool transform_interpolation = false;
	// Local players attached to this object turn their view with it
	bool turn_attached_players = false;
	// Max. yaw (degrees) between attached players' view and this object (0 = none)
	f32 attached_player_yaw_limit = 0.0f;
	// Liquids are not drawn inside this box (object space, rotates with the
	// object), like the water inside a Minecraft boat. Empty = none.
	aabb3f liquid_mask_box = aabb3f(0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f);

	ObjectProperties();

	std::string dump() const;

	bool operator==(const ObjectProperties &other) const;
	bool operator!=(const ObjectProperties &other) const {
		return !(*this == other);
	}

	/**
	 * Check limits of some important properties that'd cause exceptions later on.
	 * Errornous values are discarded after printing a warning.
	 * @return true if a problem was found
	*/
	bool validate();

	void serialize(std::ostream &os) const;
	void deSerialize(std::istream &is);
};
