// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "animation_state.h"
#include "util/serialize.h"
#include "exceptions.h"

static const char *arm_pose_names[AnimationState::ARM_POSE_COUNT] = {
	"empty", "item", "block", "bow", "throw_spear",
	"crossbow_charge", "crossbow_hold", "spyglass",
};

static const char *item_display_names[AnimationState::ITEM_DISPLAY_COUNT] = {
	"none", "generated", "handheld", "block", "bow", "crossbow", "handheld_rod",
	"trident", "spyglass",
};

void AnimationState::serialize(std::ostream &os) const
{
	writeU8(os, 1); // version
	u16 flags = sneaking | riding << 1 | sleeping << 2 | swimming << 3 |
			in_water << 4 | fall_flying << 5 | spin_attack << 6 | dead << 7 |
			digging << 8;
	writeU16(os, flags);
	writeU8(os, right_arm);
	writeU8(os, left_arm);
	writeU8(os, right_item);
	writeU8(os, left_item);
	writeF32(os, sleep_yaw);
	writeF32(os, use_duration);
	writeU8(os, swing_duration);
	writeF32(os, look_pitch);
}

void AnimationState::deSerialize(std::istream &is)
{
	if (readU8(is) != 1)
		throw SerializationError("unsupported AnimationState version");
	u16 flags = readU16(is);
	sneaking = flags & 1;
	riding = flags & 2;
	sleeping = flags & 4;
	swimming = flags & 8;
	in_water = flags & 16;
	fall_flying = flags & 32;
	spin_attack = flags & 64;
	dead = flags & 128;
	digging = flags & 256;
	auto pose = [](u8 v) {
		return v < ARM_POSE_COUNT ? static_cast<ArmPose>(v) : ARM_EMPTY;
	};
	right_arm = pose(readU8(is));
	left_arm = pose(readU8(is));
	auto display = [](u8 v) {
		return v < ITEM_DISPLAY_COUNT ? static_cast<ItemDisplay>(v) : ITEM_NONE;
	};
	right_item = display(readU8(is));
	left_item = display(readU8(is));
	sleep_yaw = readF32(is);
	use_duration = readF32(is);
	swing_duration = readU8(is);
	look_pitch = readF32(is);
}

const char *AnimationState::armPoseName(ArmPose pose)
{
	return pose < ARM_POSE_COUNT ? arm_pose_names[pose] : "empty";
}

const char *AnimationState::itemDisplayName(ItemDisplay display)
{
	return display < ITEM_DISPLAY_COUNT ? item_display_names[display] : "none";
}

AnimationState::ItemDisplay AnimationState::itemDisplayFromName(std::string_view name)
{
	for (u8 i = 0; i < ITEM_DISPLAY_COUNT; i++)
		if (name == item_display_names[i])
			return static_cast<ItemDisplay>(i);
	return ITEM_DISPLAY_COUNT;
}

AnimationState::ArmPose AnimationState::armPoseFromName(std::string_view name)
{
	for (u8 i = 0; i < ARM_POSE_COUNT; i++)
		if (name == arm_pose_names[i])
			return static_cast<ArmPose>(i);
	return ARM_POSE_COUNT;
}
