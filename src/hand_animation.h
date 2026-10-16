// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "irrlichttypes.h"

// First-person hand animation state that mods control per player
// (see `ObjectRef:set_hand_animation` and friends in lua_api.md)

struct HandAnimationParams
{
	// Added to the swing duration of every swing, in seconds
	// (Minecraft's Haste and Mining Fatigue effects)
	f32 swing_duration_offset = 0.0f;
	// Items are not used up (Minecraft's creative mode): interactions that
	// swing the hand also lower the wielded item
	bool infinite_items = false;
};

// Minecraft's ItemUseAnimation
enum class ItemUseAnimation : u8
{
	NONE,
	EAT,
	DRINK,
	BLOCK,
	BOW,
	TRIDENT,
	CROSSBOW,
	SPYGLASS,
	TOOT_HORN,
	BRUSH,
	BUNDLE,
	SHIELD, // Minecraft's BLOCK with a shield: its blocking item model
	END, // Dummy for validity check
};

// An item being used (eaten, drawn, ...) for some time
struct ItemUse
{
	ItemUseAnimation animation = ItemUseAnimation::NONE;
	// Seconds until the use ends by itself, 0 = until stopped
	f32 duration = 0.0f;
	// Seconds until bows, crossbows and tridents are fully drawn, < 0 = default
	f32 charge_time = -1.0f;
	// Used with the other hand
	bool offhand = false;
};

enum HandAnimationAction : u8
{
	HAND_ANIMATION_SET_PARAMS,
	HAND_ANIMATION_SWING,
	HAND_ANIMATION_START_USE,
	HAND_ANIMATION_STOP_USE,
};
