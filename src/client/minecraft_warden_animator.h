// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "animation_state.h"
#include "minecraft_keyframe_animation.h"
#include "irr_v3d.h"
#include <EMaterialTypes.h>
#include <Transform.h>
#include <array>

namespace scene {
	class AnimatedMeshSceneNode;
}

/*
	Procedural animation "minecraft_warden": poses the warden model made of
	Minecraft's model parts (games/mineclonia/tools/mc_warden_model.py) and
	shows its emissive layers the way Minecraft Java Edition 26.3 renders
	the warden (WardenModel, WardenAnimation, WardenRenderer, the client
	side of Warden and LivingEntity).

	The animation runs on Minecraft's 20 ticks per second, interpolated per
	frame like Minecraft's partial ticks.
*/
class MinecraftWardenAnimator
{
public:
	struct Input {
		/// Feet position in nodes
		v3f position;
		/// Riding something (Minecraft: no walk animation)
		bool attached = false;
		/// Lightmap lighting is enabled (otherwise the layers can't be
		/// translucent)
		bool lightmap = true;
	};

	/// The model parts (= joints)
	enum Joint {
		BONE, BODY, HEAD, RIGHT_TENDRIL, LEFT_TENDRIL, RIGHT_RIBCAGE,
		LEFT_RIBCAGE, RIGHT_ARM, LEFT_ARM, RIGHT_LEG, LEFT_LEG, JOINT_COUNT
	};
	static const char *jointName(Joint j);
	static Joint parentOf(Joint j);

	/// Mesh buffers: the base model and the emissive layers (WardenRenderer)
	enum Layer {
		LAYER_BASE, LAYER_BIOLUMINESCENT, LAYER_SPOTS_1, LAYER_SPOTS_2,
		LAYER_TENDRILS, LAYER_HEART, LAYER_COUNT
	};

	/// A pose change starts the pose's animation (Warden.onSyncedDataUpdated)
	void setState(const AnimationState &state);
	const AnimationState &getState() const { return m_state; }

	/// Warden.handleEntityEvent: 4 attack, 61 tendril twitch, 62 sonic boom
	void entityEvent(u8 id);
	/// LivingEntity.handleDamageEvent
	void hurt() { m_walk.speed = 1.5f; }

	/// Advances the animation by dtime seconds
	void step(f32 dtime, const Input &input);

	/// Model parts after WardenModel.setupAnim (after the last step)
	std::array<mc_model::Part, JOINT_COUNT> computeParts() const;
	/// Joint transforms relative to the parent joints
	std::array<core::Transform, JOINT_COUNT> computeJoints() const;
	/// Alpha of each layer (the base is 1)
	std::array<f32, LAYER_COUNT> layerAlphas() const;

	/// Makes the layer materials translucent; call after the node's
	/// materials and textures are set. The layer material type must be the
	/// object shader's alpha blended variant.
	void setupMaterials(scene::AnimatedMeshSceneNode *node,
			video::E_MATERIAL_TYPE layer_material);

	/// Sets the joints and the layer materials' alpha
	void apply(scene::AnimatedMeshSceneNode *node) const;

	/// Ticks since the object appeared (Entity.tickCount)
	s32 getTickCount() const { return m_ticks; }

private:
	void tick();

	AnimationState m_state;
	Input m_input;
	bool m_have_input = false;

	// Tick timing
	f32 m_tick_time = 0.0f;
	f32 m_partial = 0.0f;
	s32 m_ticks = 0;

	// Entity state (tick values and the previous tick's), Minecraft degrees
	v3f m_pos, m_prev_pos;
	f32 m_head_yaw = 0.0f, m_prev_head_yaw = 0.0f; // relative to the body
	f32 m_pitch = 0.0f, m_prev_pitch = 0.0f;
	// Rotation targets, approached in 3 ticks (LivingEntity.lerpHeadTo,
	// InterpolationHandler)
	f32 m_head_yaw_target = 0.0f, m_pitch_target = 0.0f;
	int m_head_steps = 0, m_pitch_steps = 0;
	mc_model::WalkAnimationState m_walk;
	int m_death_time = 0;

	// Warden
	int m_tendril = 0, m_prev_tendril = 0;
	int m_heart = 0, m_prev_heart = 0;
	mc_model::AnimationState m_roar, m_sniff, m_emerge, m_digging, m_attack,
			m_sonic_boom;
};
