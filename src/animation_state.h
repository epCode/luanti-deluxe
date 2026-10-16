// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "irrlichttypes.h"
#include <iostream>
#include <string_view>

/*
	Input of procedural object animations (object property
	`procedural_animation`), set by the server with
	ObjectRef:set_animation_state(). The client animates the model from
	this and from the object's own movement.
*/
struct AnimationState
{
	/// What an arm does (Minecraft's HumanoidModel.ArmPose)
	enum ArmPose : u8 {
		ARM_EMPTY,
		ARM_ITEM,
		ARM_BLOCK,
		ARM_BOW,
		ARM_THROW_SPEAR,
		ARM_CROSSBOW_CHARGE,
		ARM_CROSSBOW_HOLD,
		ARM_SPYGLASS,
		ARM_POSE_COUNT
	};

	/// How an item in hand is shown (Minecraft item model display types)
	enum ItemDisplay : u8 {
		ITEM_NONE,
		ITEM_GENERATED, ///< flat items
		ITEM_HANDHELD,  ///< tools and weapons
		ITEM_BLOCK,     ///< blocks
		ITEM_BOW,
		ITEM_CROSSBOW,
		ITEM_HANDHELD_ROD, ///< fishing rods
		ITEM_TRIDENT,
		ITEM_SPYGLASS,
		ITEM_DISPLAY_COUNT
	};

	bool sneaking = false;
	bool riding = false;
	bool sleeping = false;
	/// Swimming or crawling pose
	bool swimming = false;
	/// In water (the swimming pose follows the pitch), else crawling
	bool in_water = false;
	/// Gliding with an elytra
	bool fall_flying = false;
	/// Riptide spin attack
	bool spin_attack = false;
	bool dead = false;
	/// Hitting a node: the arm swings continuously
	bool digging = false;
	ArmPose right_arm = ARM_EMPTY;
	ArmPose left_arm = ARM_EMPTY;
	ItemDisplay right_item = ITEM_NONE;
	ItemDisplay left_item = ITEM_NONE;
	/// Yaw of the bed while sleeping, in degrees
	f32 sleep_yaw = 0.0f;
	/// Time it takes to charge the item in use (crossbow), in seconds
	f32 use_duration = 1.25f;
	/// Length of an arm swing in ticks (6, changed by haste and mining fatigue)
	u8 swing_duration = 6;
	/// Look pitch in radians (players: set by the engine)
	f32 look_pitch = 0.0f;

	void serialize(std::ostream &os) const;
	void deSerialize(std::istream &is);

	static const char *armPoseName(ArmPose pose);
	/// Returns ARM_POSE_COUNT for unknown names
	static ArmPose armPoseFromName(std::string_view name);
	static const char *itemDisplayName(ItemDisplay display);
	/// Returns ITEM_DISPLAY_COUNT for unknown names
	static ItemDisplay itemDisplayFromName(std::string_view name);

	bool operator==(const AnimationState &o) const
	{
		return sneaking == o.sneaking && riding == o.riding &&
				sleeping == o.sleeping && swimming == o.swimming &&
				in_water == o.in_water && fall_flying == o.fall_flying &&
				spin_attack == o.spin_attack && dead == o.dead &&
				digging == o.digging && right_arm == o.right_arm &&
				left_arm == o.left_arm && right_item == o.right_item &&
				left_item == o.left_item && sleep_yaw == o.sleep_yaw &&
				use_duration == o.use_duration &&
				swing_duration == o.swing_duration && look_pitch == o.look_pitch;
	}
};
