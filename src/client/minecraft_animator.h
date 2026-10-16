// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "animation_state.h"
#include "irr_v2d.h"
#include "irr_v3d.h"
#include <Transform.h>
#include <array>
#include <optional>

namespace scene {
	class AnimatedMeshSceneNode;
}

/*
	Procedural animation "minecraft_player": poses a player model made of
	Minecraft's model parts (see games/mineclonia/tools/mc_player_model.py)
	the way Minecraft Java Edition renders players.

	Minecraft 1.8 is followed (ModelBiped, ModelPlayer, RendererLivingEntity,
	RenderPlayer and their layers); what 1.8 doesn't have comes from 1.14
	(elytra, swimming and crawling, the riptide spin, crossbows, items in the
	left hand) and the spyglass from 1.17.

	The animation runs on Minecraft's 20 ticks per second, interpolated per
	frame like Minecraft's partial ticks.
*/
class MinecraftPlayerAnimator
{
public:
	struct Input {
		/// Feet position in nodes
		v3f position;
		/// Look yaw and object (scene node) yaw in degrees, Luanti convention
		f32 look_yaw = 0.0f;
		f32 object_yaw = 0.0f;
		/// Look pitch in radians, positive looks down
		f32 look_pitch = 0.0f;
		/// The local player (Minecraft offsets other sneaking players)
		bool local = false;
		bool on_ground = true;
		/// Yaw of the object ridden, degrees (Luanti)
		std::optional<f32> mount_yaw;
		/// Slim (Alex) arms: the held item is one pixel further inwards
		bool slim = false;
		/// Inventory preview (GuiInventory.drawEntityOnScreen): the cursor's
		/// offset from the eyes in Minecraft GUI pixels (30 per block), +X
		/// to the left and +Y up. The player turns towards it.
		std::optional<v2f> inventory_cursor;
		/// Inventory preview: Minecraft yaw (degrees) facing the viewer
		f32 inventory_yaw = 0.0f;
	};

	enum Joint {
		HEAD, BODY, ARM_RIGHT, ARM_LEFT, LEG_RIGHT, LEG_LEFT,
		ARMOR_ARM_RIGHT, ARMOR_ARM_LEFT, CAPE, ELYTRA_LEFT, ELYTRA_RIGHT,
		WIELD_ITEM, WIELD_ITEM_LEFT, JOINT_COUNT
	};
	static const char *jointName(Joint j);

	void setState(const AnimationState &state);
	const AnimationState &getState() const { return m_state; }

	/// Swings the arm (Minecraft: EntityLivingBase.swingItem)
	void swing();
	/// The object was hurt
	void hurt() { m_limb_swing_amount = 1.5f; }

	/// Local player: predicted digging and sneaking (the server's state
	/// arrives a round trip later)
	void setPredictedDigging(bool digging) { m_local_digging = digging; }
	void setPredictedSneaking(bool sneaking) { m_local_sneaking = sneaking; }

	/// Advances the animation by dtime seconds
	void step(f32 dtime, const Input &input);

	/// Joint transforms in the model's space (after the last step)
	std::array<core::Transform, JOINT_COUNT> computeJoints() const;

	/// Sets the joints of the model
	void apply(scene::AnimatedMeshSceneNode *node) const;

private:
	struct Tick {
		v3f pos; // Minecraft coordinates (blocks), +Z south
	};

	void tick();
	bool sneaking() const;
	bool digging() const;

	AnimationState m_state;
	Input m_input;
	bool m_have_input = false;
	std::optional<bool> m_local_digging, m_local_sneaking;

	// Tick timing
	f32 m_tick_time = 0.0f;
	f32 m_partial = 0.0f;
	u32 m_ticks = 0;

	// Minecraft entity state (tick values and the previous tick's)
	v3f m_pos, m_prev_pos;
	f32 m_yaw = 0.0f, m_prev_yaw = 0.0f; // rotationYaw (degrees, Minecraft)
	f32 m_head_yaw = 0.0f, m_prev_head_yaw = 0.0f;
	f32 m_pitch = 0.0f, m_prev_pitch = 0.0f; // degrees
	f32 m_body_yaw = 0.0f, m_prev_body_yaw = 0.0f; // renderYawOffset
	f32 m_limb_swing = 0.0f, m_limb_swing_amount = 0.0f, m_prev_limb_swing_amount = 0.0f;
	bool m_swing_in_progress = false;
	int m_swing_ticks = 0;
	f32 m_swing_progress = 0.0f, m_prev_swing_progress = 0.0f;
	f32 m_swim = 0.0f, m_prev_swim = 0.0f;
	int m_death_time = 0;
	int m_fall_flying_ticks = 0;
	int m_use_ticks = 0;
	AnimationState::ArmPose m_use_pose = AnimationState::ARM_EMPTY;
	v3f m_motion; // last tick's movement (blocks per tick)
	// Cape (EntityPlayer chasing position, camera bob)
	v3f m_chasing, m_prev_chasing;
	f32 m_camera_yaw = 0.0f, m_prev_camera_yaw = 0.0f;
	f32 m_walked = 0.0f, m_prev_walked = 0.0f;
	// Elytra wing angles, approached per frame (AbstractClientPlayer.elytraRot*)
	v3f m_elytra_rot{0.2617994f, 0.0f, -0.2617994f};
};
