// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "minecraft_warden_animator.h"
#include <AnimatedMeshSceneNode.h>
#include <BoneSceneNode.h>
#include <IAnimatedMesh.h>
#include <SMaterial.h>
#include <algorithm>
#include <cmath>

/*
	Names follow Minecraft's code: angles of model parts in radians, entity
	rotations in degrees, positions of model parts in pixels with +Y down,
	the model facing -Z. A Luanti yaw φ is the Minecraft yaw 180° - φ, so
	yaws relative to the object change their sign.
*/

using mc_model::AnimationDefinition;
using mc_model::Channel;
using mc_model::Interpolation;
using mc_model::Keyframe;
using mc_model::Target;
using mc_model::apply_animation;
using mc_model::deg_vec;
using mc_model::pos_vec;
using mc_model::rot_lerp;
using mc_model::wrap_degrees;

static constexpr f32 PI_F = 3.14159265358979323846f;
static constexpr f32 TICK = 0.05f;
// Mesh units per model pixel (10 units per node)
static constexpr f32 UNITS = 10.0f / 16.0f;

namespace {

// Indices of the parts in the animation tables
struct P {
	enum : u8 {
		BONE = MinecraftWardenAnimator::BONE,
		BODY = MinecraftWardenAnimator::BODY,
		HEAD = MinecraftWardenAnimator::HEAD,
		RIGHT_TENDRIL = MinecraftWardenAnimator::RIGHT_TENDRIL,
		LEFT_TENDRIL = MinecraftWardenAnimator::LEFT_TENDRIL,
		RIGHT_RIBCAGE = MinecraftWardenAnimator::RIGHT_RIBCAGE,
		LEFT_RIBCAGE = MinecraftWardenAnimator::LEFT_RIBCAGE,
		RIGHT_ARM = MinecraftWardenAnimator::RIGHT_ARM,
		LEFT_ARM = MinecraftWardenAnimator::LEFT_ARM,
		RIGHT_LEG = MinecraftWardenAnimator::RIGHT_LEG,
		LEFT_LEG = MinecraftWardenAnimator::LEFT_LEG,
	};
};

constexpr Interpolation LINEAR = Interpolation::LINEAR;
constexpr Interpolation CATMULLROM = Interpolation::CATMULLROM;

/*
	WardenAnimation (Minecraft 26.3), converted from the decompiled source.
	The channels of a part's target add up, so their order doesn't matter.
*/
static const Keyframe warden_emerge_0[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.52f, deg_vec(0.0F, 0.0F, -22.5F), deg_vec(0.0F, 0.0F, -22.5F), CATMULLROM},
	{1.2f, deg_vec(0.0F, 0.0F, -7.5F), deg_vec(0.0F, 0.0F, -7.5F), CATMULLROM},
	{1.68f, deg_vec(0.0F, 0.0F, 10.0F), deg_vec(0.0F, 0.0F, 10.0F), CATMULLROM},
	{1.8f, deg_vec(0.0F, 0.0F, 10.0F), deg_vec(0.0F, 0.0F, 10.0F), CATMULLROM},
	{2.28f, deg_vec(0.0F, 0.0F, 10.0F), deg_vec(0.0F, 0.0F, 10.0F), CATMULLROM},
	{2.88f, deg_vec(0.0F, 0.0F, 10.0F), deg_vec(0.0F, 0.0F, 10.0F), CATMULLROM},
	{3.76f, deg_vec(25.0F, 0.0F, -7.5F), deg_vec(25.0F, 0.0F, -7.5F), CATMULLROM},
	{3.92f, deg_vec(35.0F, 0.0F, -7.5F), deg_vec(35.0F, 0.0F, -7.5F), CATMULLROM},
	{4.08f, deg_vec(25.0F, 0.0F, -7.5F), deg_vec(25.0F, 0.0F, -7.5F), CATMULLROM},
	{4.44f, deg_vec(47.5F, 0.0F, 0.0F), deg_vec(47.5F, 0.0F, 0.0F), CATMULLROM},
	{4.56f, deg_vec(47.5F, 0.0F, 0.0F), deg_vec(47.5F, 0.0F, 0.0F), CATMULLROM},
	{4.68f, deg_vec(47.5F, 0.0F, 0.0F), deg_vec(47.5F, 0.0F, 0.0F), CATMULLROM},
	{5.0f, deg_vec(70.0F, 0.0F, 2.5F), deg_vec(70.0F, 0.0F, 2.5F), CATMULLROM},
	{5.8f, deg_vec(70.0F, 0.0F, 2.5F), deg_vec(70.0F, 0.0F, 2.5F), CATMULLROM},
	{6.64f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_emerge_1[] = {
	{0.0f, pos_vec(0.0F, -63.0F, 0.0F), pos_vec(0.0F, -63.0F, 0.0F), CATMULLROM},
	{0.52f, pos_vec(0.0F, -56.0F, 0.0F), pos_vec(0.0F, -56.0F, 0.0F), CATMULLROM},
	{1.2f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{1.68f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{1.8f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{2.28f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{2.88f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{3.16f, pos_vec(0.0F, -27.0F, 0.0F), pos_vec(0.0F, -27.0F, 0.0F), CATMULLROM},
	{3.76f, pos_vec(0.0F, -14.0F, 0.0F), pos_vec(0.0F, -14.0F, 0.0F), CATMULLROM},
	{3.92f, pos_vec(0.0F, -11.0F, 0.0F), pos_vec(0.0F, -11.0F, 0.0F), CATMULLROM},
	{4.08f, pos_vec(0.0F, -14.0F, 0.0F), pos_vec(0.0F, -14.0F, 0.0F), CATMULLROM},
	{4.44f, pos_vec(0.0F, -6.0F, -3.0F), pos_vec(0.0F, -6.0F, -3.0F), CATMULLROM},
	{4.56f, pos_vec(0.0F, -4.0F, -3.0F), pos_vec(0.0F, -4.0F, -3.0F), CATMULLROM},
	{4.68f, pos_vec(0.0F, -6.0F, -3.0F), pos_vec(0.0F, -6.0F, -3.0F), CATMULLROM},
	{5.0f, pos_vec(0.0F, -3.0F, -4.0F), pos_vec(0.0F, -3.0F, -4.0F), CATMULLROM},
	{5.8f, pos_vec(0.0F, -3.0F, -4.0F), pos_vec(0.0F, -3.0F, -4.0F), CATMULLROM},
	{6.64f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_emerge_2[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.52f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.92f, deg_vec(0.74F, 0.0F, -40.38F), deg_vec(0.74F, 0.0F, -40.38F), CATMULLROM},
	{1.16f, deg_vec(-67.5F, 0.0F, -2.5F), deg_vec(-67.5F, 0.0F, -2.5F), CATMULLROM},
	{1.24f, deg_vec(-67.5F, 0.0F, -2.5F), deg_vec(-67.5F, 0.0F, -2.5F), CATMULLROM},
	{1.32f, deg_vec(-47.5F, 0.0F, -2.5F), deg_vec(-47.5F, 0.0F, -2.5F), CATMULLROM},
	{1.4f, deg_vec(-67.5F, 0.0F, -2.5F), deg_vec(-67.5F, 0.0F, -2.5F), CATMULLROM},
	{1.68f, deg_vec(-67.5F, 0.0F, 15.0F), deg_vec(-67.5F, 0.0F, 15.0F), CATMULLROM},
	{1.76f, deg_vec(-67.5F, 0.0F, -5.0F), deg_vec(-67.5F, 0.0F, -5.0F), CATMULLROM},
	{1.84f, deg_vec(-52.5F, 0.0F, -5.0F), deg_vec(-52.5F, 0.0F, -5.0F), CATMULLROM},
	{1.92f, deg_vec(-67.5F, 0.0F, -5.0F), deg_vec(-67.5F, 0.0F, -5.0F), CATMULLROM},
	{2.64f, deg_vec(-17.5F, 0.0F, -10.0F), deg_vec(-17.5F, 0.0F, -10.0F), CATMULLROM},
	{3.76f, deg_vec(70.0F, 0.0F, 12.5F), deg_vec(70.0F, 0.0F, 12.5F), CATMULLROM},
	{4.04f, deg_vec(70.0F, 0.0F, 12.5F), deg_vec(70.0F, 0.0F, 12.5F), CATMULLROM},
	{4.12f, deg_vec(80.0F, 0.0F, 12.5F), deg_vec(80.0F, 0.0F, 12.5F), CATMULLROM},
	{4.24f, deg_vec(70.0F, 0.0F, 12.5F), deg_vec(70.0F, 0.0F, 12.5F), CATMULLROM},
	{5.0f, deg_vec(77.5F, 0.0F, -2.5F), deg_vec(77.5F, 0.0F, -2.5F), CATMULLROM},
	{6.64f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_emerge_3[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.52f, pos_vec(-8.0F, -11.0F, 0.0F), pos_vec(-8.0F, -11.0F, 0.0F), CATMULLROM},
	{0.92f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.24f, pos_vec(0.0F, 0.47F, -0.95F), pos_vec(0.0F, 0.47F, -0.95F), CATMULLROM},
	{1.32f, pos_vec(0.0F, 0.47F, -0.95F), pos_vec(0.0F, 0.47F, -0.95F), CATMULLROM},
	{1.4f, pos_vec(0.0F, 0.47F, -0.95F), pos_vec(0.0F, 0.47F, -0.95F), CATMULLROM},
	{1.68f, pos_vec(0.0F, 1.0F, -2.0F), pos_vec(0.0F, 1.0F, -2.0F), CATMULLROM},
	{1.76f, pos_vec(0.0F, 1.0F, -2.0F), pos_vec(0.0F, 1.0F, -2.0F), CATMULLROM},
	{1.84f, pos_vec(0.0F, 1.0F, -2.0F), pos_vec(0.0F, 1.0F, -2.0F), CATMULLROM},
	{1.92f, pos_vec(0.0F, 1.0F, -2.0F), pos_vec(0.0F, 1.0F, -2.0F), CATMULLROM},
	{2.64f, pos_vec(0.0F, -2.0F, -2.0F), pos_vec(0.0F, -2.0F, -2.0F), CATMULLROM},
	{3.76f, pos_vec(0.0F, -4.0F, 1.0F), pos_vec(0.0F, -4.0F, 1.0F), CATMULLROM},
	{4.04f, pos_vec(0.0F, -1.0F, 1.0F), pos_vec(0.0F, -1.0F, 1.0F), CATMULLROM},
	{4.12f, pos_vec(0.0F, -1.0F, 1.0F), pos_vec(0.0F, -1.0F, 1.0F), CATMULLROM},
	{4.24f, pos_vec(0.0F, -1.0F, 1.0F), pos_vec(0.0F, -1.0F, 1.0F), CATMULLROM},
	{5.0f, pos_vec(0.0F, -1.0F, 1.0F), pos_vec(0.0F, -1.0F, 1.0F), CATMULLROM},
	{6.64f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_emerge_4[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.52f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.2f, deg_vec(-152.5F, 2.5F, 7.5F), deg_vec(-152.5F, 2.5F, 7.5F), CATMULLROM},
	{1.68f, deg_vec(-180.0F, 12.5F, -10.0F), deg_vec(-180.0F, 12.5F, -10.0F), CATMULLROM},
	{1.8f, deg_vec(-90.0F, 12.5F, -10.0F), deg_vec(-90.0F, 12.5F, -10.0F), CATMULLROM},
	{2.28f, deg_vec(-90.0F, 12.5F, -10.0F), deg_vec(-90.0F, 12.5F, -10.0F), CATMULLROM},
	{2.88f, deg_vec(-90.0F, 12.5F, -10.0F), deg_vec(-90.0F, 12.5F, -10.0F), CATMULLROM},
	{3.08f, deg_vec(-95.0F, 12.5F, -10.0F), deg_vec(-95.0F, 12.5F, -10.0F), CATMULLROM},
	{3.24f, deg_vec(-83.93F, 3.93F, 5.71F), deg_vec(-83.93F, 3.93F, 5.71F), CATMULLROM},
	{3.36f, deg_vec(-80.0F, 7.5F, 17.5F), deg_vec(-80.0F, 7.5F, 17.5F), CATMULLROM},
	{3.76f, deg_vec(-67.5F, 2.5F, 0.0F), deg_vec(-67.5F, 2.5F, 0.0F), CATMULLROM},
	{4.08f, deg_vec(-67.5F, 2.5F, 0.0F), deg_vec(-67.5F, 2.5F, 0.0F), CATMULLROM},
	{4.44f, deg_vec(-55.0F, 2.5F, 0.0F), deg_vec(-55.0F, 2.5F, 0.0F), CATMULLROM},
	{4.56f, deg_vec(-60.0F, 2.5F, 0.0F), deg_vec(-60.0F, 2.5F, 0.0F), CATMULLROM},
	{4.68f, deg_vec(-55.0F, 2.5F, 0.0F), deg_vec(-55.0F, 2.5F, 0.0F), CATMULLROM},
	{5.0f, deg_vec(-67.5F, 0.0F, 0.0F), deg_vec(-67.5F, 0.0F, 0.0F), CATMULLROM},
	{5.56f, deg_vec(-50.45F, 0.0F, 2.69F), deg_vec(-50.45F, 0.0F, 2.69F), CATMULLROM},
	{6.08f, deg_vec(-62.72F, 0.0F, 4.3F), deg_vec(-62.72F, 0.0F, 4.3F), CATMULLROM},
	{6.64f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_emerge_5[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.52f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.2f, pos_vec(0.0F, -21.0F, 9.0F), pos_vec(0.0F, -21.0F, 9.0F), CATMULLROM},
	{1.68f, pos_vec(2.0F, -2.0F, 0.0F), pos_vec(2.0F, -2.0F, 0.0F), CATMULLROM},
	{1.8f, pos_vec(2.0F, 0.0F, 0.0F), pos_vec(2.0F, 0.0F, 0.0F), CATMULLROM},
	{2.28f, pos_vec(2.0F, 0.0F, 0.0F), pos_vec(2.0F, 0.0F, 0.0F), CATMULLROM},
	{2.88f, pos_vec(2.0F, 0.0F, 0.0F), pos_vec(2.0F, 0.0F, 0.0F), CATMULLROM},
	{3.08f, pos_vec(2.0F, -2.0F, 0.0F), pos_vec(2.0F, -2.0F, 0.0F), CATMULLROM},
	{3.24f, pos_vec(2.0F, 2.71F, 3.86F), pos_vec(2.0F, 2.71F, 3.86F), CATMULLROM},
	{3.36f, pos_vec(2.0F, 1.0F, 5.0F), pos_vec(2.0F, 1.0F, 5.0F), CATMULLROM},
	{3.76f, pos_vec(2.0F, 3.0F, 3.0F), pos_vec(2.0F, 3.0F, 3.0F), CATMULLROM},
	{4.08f, pos_vec(2.0F, 3.0F, 3.0F), pos_vec(2.0F, 3.0F, 3.0F), CATMULLROM},
	{4.44f, pos_vec(2.67F, 4.0F, 0.0F), pos_vec(2.67F, 4.0F, 0.0F), CATMULLROM},
	{4.56f, pos_vec(2.67F, 0.0F, 0.0F), pos_vec(2.67F, 0.0F, 0.0F), CATMULLROM},
	{4.68f, pos_vec(2.67F, 4.0F, 0.0F), pos_vec(2.67F, 4.0F, 0.0F), CATMULLROM},
	{5.0f, pos_vec(0.67F, 3.0F, 4.0F), pos_vec(0.67F, 3.0F, 4.0F), CATMULLROM},
	{6.64f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_emerge_6[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.12f, deg_vec(-167.5F, -17.5F, -7.5F), deg_vec(-167.5F, -17.5F, -7.5F), CATMULLROM},
	{0.6f, deg_vec(-167.5F, -17.5F, -7.5F), deg_vec(-167.5F, -17.5F, -7.5F), CATMULLROM},
	{0.88f, deg_vec(-175.0F, -17.5F, 15.0F), deg_vec(-175.0F, -17.5F, 15.0F), CATMULLROM},
	{1.16f, deg_vec(-190.0F, -17.5F, 5.0F), deg_vec(-190.0F, -17.5F, 5.0F), CATMULLROM},
	{1.28f, deg_vec(-90.0F, -5.0F, 5.0F), deg_vec(-90.0F, -5.0F, 5.0F), CATMULLROM},
	{1.68f, deg_vec(-90.0F, -17.5F, -12.5F), deg_vec(-90.0F, -17.5F, -12.5F), CATMULLROM},
	{1.8f, deg_vec(-90.0F, -17.5F, -12.5F), deg_vec(-90.0F, -17.5F, -12.5F), CATMULLROM},
	{2.28f, deg_vec(-90.0F, -17.5F, -12.5F), deg_vec(-90.0F, -17.5F, -12.5F), CATMULLROM},
	{2.88f, deg_vec(-90.0F, -17.5F, -12.5F), deg_vec(-90.0F, -17.5F, -12.5F), CATMULLROM},
	{3.04f, deg_vec(-81.29F, -10.64F, -14.21F), deg_vec(-81.29F, -10.64F, -14.21F), CATMULLROM},
	{3.16f, deg_vec(-83.5F, -5.5F, -15.5F), deg_vec(-83.5F, -5.5F, -15.5F), CATMULLROM},
	{3.76f, deg_vec(-62.5F, -7.5F, 5.0F), deg_vec(-62.5F, -7.5F, 5.0F), CATMULLROM},
	{3.92f, deg_vec(-58.75F, -3.75F, 5.0F), deg_vec(-58.75F, -3.75F, 5.0F), CATMULLROM},
	{4.08f, deg_vec(-55.0F, 0.0F, 0.0F), deg_vec(-55.0F, 0.0F, 0.0F), CATMULLROM},
	{4.44f, deg_vec(-52.5F, 0.0F, 5.0F), deg_vec(-52.5F, 0.0F, 5.0F), CATMULLROM},
	{4.56f, deg_vec(-50.0F, 0.0F, 5.0F), deg_vec(-50.0F, 0.0F, 5.0F), CATMULLROM},
	{4.68f, deg_vec(-52.5F, 0.0F, 5.0F), deg_vec(-52.5F, 0.0F, 5.0F), CATMULLROM},
	{5.0f, deg_vec(-72.5F, -2.5F, 5.0F), deg_vec(-72.5F, -2.5F, 5.0F), CATMULLROM},
	{5.56f, deg_vec(-57.5F, -4.54F, 2.99F), deg_vec(-57.5F, -4.54F, 2.99F), CATMULLROM},
	{6.08f, deg_vec(-70.99F, -5.77F, 1.78F), deg_vec(-70.99F, -5.77F, 1.78F), CATMULLROM},
	{6.64f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_emerge_7[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.12f, pos_vec(0.0F, -8.0F, 0.0F), pos_vec(0.0F, -8.0F, 0.0F), CATMULLROM},
	{0.6f, pos_vec(0.0F, -8.0F, 0.0F), pos_vec(0.0F, -8.0F, 0.0F), CATMULLROM},
	{0.88f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.2f, pos_vec(-2.0F, 0.0F, 0.0F), pos_vec(-2.0F, 0.0F, 0.0F), CATMULLROM},
	{1.68f, pos_vec(-4.0F, 3.0F, 0.0F), pos_vec(-4.0F, 3.0F, 0.0F), CATMULLROM},
	{1.8f, pos_vec(-4.0F, 3.0F, 0.0F), pos_vec(-4.0F, 3.0F, 0.0F), CATMULLROM},
	{2.28f, pos_vec(-4.0F, 3.0F, 0.0F), pos_vec(-4.0F, 3.0F, 0.0F), CATMULLROM},
	{2.88f, pos_vec(-4.0F, 3.0F, 0.0F), pos_vec(-4.0F, 3.0F, 0.0F), CATMULLROM},
	{3.04f, pos_vec(-3.23F, 5.7F, 4.97F), pos_vec(-3.23F, 5.7F, 4.97F), CATMULLROM},
	{3.16f, pos_vec(-1.49F, 2.22F, 5.25F), pos_vec(-1.49F, 2.22F, 5.25F), CATMULLROM},
	{3.76f, pos_vec(-1.14F, 1.71F, 1.86F), pos_vec(-1.14F, 1.71F, 1.86F), CATMULLROM},
	{3.92f, pos_vec(-1.14F, 1.21F, 3.86F), pos_vec(-1.14F, 1.21F, 3.86F), CATMULLROM},
	{4.08f, pos_vec(-1.14F, 2.71F, 4.86F), pos_vec(-1.14F, 2.71F, 4.86F), CATMULLROM},
	{4.44f, pos_vec(-1.0F, 1.0F, 3.0F), pos_vec(-1.0F, 1.0F, 3.0F), CATMULLROM},
	{4.56f, pos_vec(0.0F, 1.0F, 1.0F), pos_vec(0.0F, 1.0F, 1.0F), CATMULLROM},
	{4.68f, pos_vec(0.0F, 1.0F, 3.0F), pos_vec(0.0F, 1.0F, 3.0F), CATMULLROM},
	{5.0f, pos_vec(-2.0F, 0.0F, 4.0F), pos_vec(-2.0F, 0.0F, 4.0F), CATMULLROM},
	{6.64f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_emerge_8[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.52f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{2.28f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{2.88f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{3.36f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{4.32f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{4.48f, deg_vec(55.0F, 0.0F, 0.0F), deg_vec(55.0F, 0.0F, 0.0F), CATMULLROM},
	{4.6f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{5.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{5.8f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{6.64f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_emerge_9[] = {
	{0.0f, pos_vec(0.0F, -63.0F, 0.0F), pos_vec(0.0F, -63.0F, 0.0F), CATMULLROM},
	{0.52f, pos_vec(0.0F, -56.0F, 0.0F), pos_vec(0.0F, -56.0F, 0.0F), CATMULLROM},
	{1.2f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{1.68f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{1.8f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{2.28f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{2.88f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{3.36f, pos_vec(0.0F, -22.0F, 0.0F), pos_vec(0.0F, -22.0F, 0.0F), CATMULLROM},
	{3.76f, pos_vec(0.0F, -12.28F, 2.48F), pos_vec(0.0F, -12.28F, 2.48F), CATMULLROM},
	{3.92f, pos_vec(0.0F, -9.28F, 2.48F), pos_vec(0.0F, -9.28F, 2.48F), CATMULLROM},
	{4.08f, pos_vec(0.0F, -12.28F, 2.48F), pos_vec(0.0F, -12.28F, 2.48F), CATMULLROM},
	{4.32f, pos_vec(0.0F, -4.14F, 4.14F), pos_vec(0.0F, -4.14F, 4.14F), CATMULLROM},
	{4.48f, pos_vec(0.0F, -0.57F, -8.43F), pos_vec(0.0F, -0.57F, -8.43F), CATMULLROM},
	{4.6f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{5.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{5.8f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{6.64f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_emerge_10[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.52f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{2.28f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{2.88f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{3.36f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{3.84f, deg_vec(20.0F, 0.0F, -17.5F), deg_vec(20.0F, 0.0F, -17.5F), CATMULLROM},
	{4.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{4.68f, deg_vec(20.0F, 0.0F, 0.0F), deg_vec(20.0F, 0.0F, 0.0F), CATMULLROM},
	{4.84f, deg_vec(10.0F, 0.0F, 0.0F), deg_vec(10.0F, 0.0F, 0.0F), CATMULLROM},
	{5.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{5.8f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{6.64f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_emerge_11[] = {
	{0.0f, pos_vec(0.0F, -63.0F, 0.0F), pos_vec(0.0F, -63.0F, 0.0F), CATMULLROM},
	{0.52f, pos_vec(0.0F, -56.0F, 0.0F), pos_vec(0.0F, -56.0F, 0.0F), CATMULLROM},
	{1.2f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{1.68f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{1.8f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{2.28f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{2.88f, pos_vec(0.0F, -32.0F, 0.0F), pos_vec(0.0F, -32.0F, 0.0F), CATMULLROM},
	{3.36f, pos_vec(0.0F, -22.0F, 0.0F), pos_vec(0.0F, -22.0F, 0.0F), CATMULLROM},
	{3.84f, pos_vec(-4.0F, 2.0F, -7.0F), pos_vec(-4.0F, 2.0F, -7.0F), CATMULLROM},
	{4.0f, pos_vec(-4.0F, 0.0F, -5.0F), pos_vec(-4.0F, 0.0F, -5.0F), CATMULLROM},
	{4.68f, pos_vec(-4.0F, 0.0F, -9.0F), pos_vec(-4.0F, 0.0F, -9.0F), CATMULLROM},
	{4.84f, pos_vec(-2.0F, 2.0F, -3.5F), pos_vec(-2.0F, 2.0F, -3.5F), CATMULLROM},
	{5.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{5.8f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{6.64f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Channel warden_emerge_channels[] = {
	{P::BODY, Target::ROTATION, warden_emerge_0, std::size(warden_emerge_0)},
	{P::BODY, Target::POSITION, warden_emerge_1, std::size(warden_emerge_1)},
	{P::HEAD, Target::ROTATION, warden_emerge_2, std::size(warden_emerge_2)},
	{P::HEAD, Target::POSITION, warden_emerge_3, std::size(warden_emerge_3)},
	{P::RIGHT_ARM, Target::ROTATION, warden_emerge_4, std::size(warden_emerge_4)},
	{P::RIGHT_ARM, Target::POSITION, warden_emerge_5, std::size(warden_emerge_5)},
	{P::LEFT_ARM, Target::ROTATION, warden_emerge_6, std::size(warden_emerge_6)},
	{P::LEFT_ARM, Target::POSITION, warden_emerge_7, std::size(warden_emerge_7)},
	{P::RIGHT_LEG, Target::ROTATION, warden_emerge_8, std::size(warden_emerge_8)},
	{P::RIGHT_LEG, Target::POSITION, warden_emerge_9, std::size(warden_emerge_9)},
	{P::LEFT_LEG, Target::ROTATION, warden_emerge_10, std::size(warden_emerge_10)},
	{P::LEFT_LEG, Target::POSITION, warden_emerge_11, std::size(warden_emerge_11)},
};
static const Keyframe warden_dig_0[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.25f, deg_vec(4.13441F, 0.94736F, 1.2694F), deg_vec(4.13441F, 0.94736F, 1.2694F), CATMULLROM},
	{0.5f, deg_vec(50.0F, 0.0F, 0.0F), deg_vec(50.0F, 0.0F, 0.0F), CATMULLROM},
	{0.7083f, deg_vec(54.45407F, -13.53935F, -18.14183F), deg_vec(54.45407F, -13.53935F, -18.14183F), CATMULLROM},
	{1.0417f, deg_vec(59.46442F, -10.8885F, 35.7954F), deg_vec(59.46442F, -10.8885F, 35.7954F), CATMULLROM},
	{1.3333f, deg_vec(82.28261F, 0.0F, 0.0F), deg_vec(82.28261F, 0.0F, 0.0F), CATMULLROM},
	{1.625f, deg_vec(53.23606F, 10.04715F, -29.72932F), deg_vec(53.23606F, 10.04715F, -29.72932F), CATMULLROM},
	{2.2083f, deg_vec(-17.71739F, 0.0F, 0.0F), deg_vec(-17.71739F, 0.0F, 0.0F), CATMULLROM},
	{2.5417f, deg_vec(112.28261F, 0.0F, 0.0F), deg_vec(112.28261F, 0.0F, 0.0F), CATMULLROM},
	{2.6667f, deg_vec(116.06889F, 5.11581F, -24.50117F), deg_vec(116.06889F, 5.11581F, -24.50117F), CATMULLROM},
	{2.8333f, deg_vec(121.56244F, -4.17248F, 19.57737F), deg_vec(121.56244F, -4.17248F, 19.57737F), CATMULLROM},
	{3.0417f, deg_vec(138.5689F, 5.11581F, -24.50117F), deg_vec(138.5689F, 5.11581F, -24.50117F), CATMULLROM},
	{3.25f, deg_vec(144.06244F, -4.17248F, 19.57737F), deg_vec(144.06244F, -4.17248F, 19.57737F), CATMULLROM},
	{3.375f, deg_vec(147.28261F, 0.0F, 0.0F), deg_vec(147.28261F, 0.0F, 0.0F), CATMULLROM},
	{3.625f, deg_vec(147.28261F, 0.0F, 0.0F), deg_vec(147.28261F, 0.0F, 0.0F), CATMULLROM},
	{3.875f, deg_vec(134.36221F, 8.81113F, -8.90172F), deg_vec(134.36221F, 8.81113F, -8.90172F), CATMULLROM},
	{4.0417f, deg_vec(132.05966F, -8.35927F, 9.70506F), deg_vec(132.05966F, -8.35927F, 9.70506F), CATMULLROM},
	{4.25f, deg_vec(134.36221F, 8.81113F, -8.90172F), deg_vec(134.36221F, 8.81113F, -8.90172F), CATMULLROM},
	{4.5f, deg_vec(147.5F, 0.0F, 0.0F), deg_vec(147.5F, 0.0F, 0.0F), LINEAR},
};
static const Keyframe warden_dig_1[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.5f, pos_vec(0.0F, -16.48454F, -6.5784F), pos_vec(0.0F, -16.48454F, -6.5784F), CATMULLROM},
	{0.7083f, pos_vec(0.0F, -16.48454F, -6.5784F), pos_vec(0.0F, -16.48454F, -6.5784F), CATMULLROM},
	{1.0417f, pos_vec(0.0F, -16.97F, -7.11F), pos_vec(0.0F, -16.97F, -7.11F), CATMULLROM},
	{1.625f, pos_vec(0.0F, -13.97F, -7.11F), pos_vec(0.0F, -13.97F, -7.11F), CATMULLROM},
	{2.2083f, pos_vec(0.0F, -11.48454F, -0.5784F), pos_vec(0.0F, -11.48454F, -0.5784F), CATMULLROM},
	{2.5417f, pos_vec(0.0F, -16.48454F, -6.5784F), pos_vec(0.0F, -16.48454F, -6.5784F), CATMULLROM},
	{2.6667f, pos_vec(0.0F, -20.27F, -5.42F), pos_vec(0.0F, -20.27F, -5.42F), CATMULLROM},
	{3.375f, pos_vec(0.0F, -21.48454F, -5.5784F), pos_vec(0.0F, -21.48454F, -5.5784F), CATMULLROM},
	{4.0417f, pos_vec(0.0F, -22.48454F, -5.5784F), pos_vec(0.0F, -22.48454F, -5.5784F), CATMULLROM},
	{4.5f, pos_vec(0.0F, -40.0F, -8.0F), pos_vec(0.0F, -40.0F, -8.0F), LINEAR},
};
static const Keyframe warden_dig_2[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.6667f, deg_vec(12.5F, 0.0F, 0.0F), deg_vec(12.5F, 0.0F, 0.0F), CATMULLROM},
	{1.2083f, deg_vec(12.5F, 0.0F, 0.0F), deg_vec(12.5F, 0.0F, 0.0F), CATMULLROM},
	{1.75f, deg_vec(45.0F, 0.0F, 0.0F), deg_vec(45.0F, 0.0F, 0.0F), CATMULLROM},
	{2.375f, deg_vec(-22.5F, 0.0F, 0.0F), deg_vec(-22.5F, 0.0F, 0.0F), CATMULLROM},
	{2.5417f, deg_vec(67.5F, 0.0F, 0.0F), deg_vec(67.5F, 0.0F, 0.0F), CATMULLROM},
	{4.375f, deg_vec(67.5F, 0.0F, 0.0F), deg_vec(67.5F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_dig_3[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{4.375f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), LINEAR},
};
static const Keyframe warden_dig_4[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.5f, deg_vec(-101.8036F, -21.29587F, 30.61478F), deg_vec(-101.8036F, -21.29587F, 30.61478F), CATMULLROM},
	{0.7083f, deg_vec(-101.8036F, -21.29587F, 30.61478F), deg_vec(-101.8036F, -21.29587F, 30.61478F), CATMULLROM},
	{1.0f, deg_vec(48.7585F, -17.61941F, 9.9865F), deg_vec(48.7585F, -17.61941F, 9.9865F), CATMULLROM},
	{1.1667f, deg_vec(48.7585F, -17.61941F, 9.9865F), deg_vec(48.7585F, -17.61941F, 9.9865F), CATMULLROM},
	{1.4583f, deg_vec(-101.8036F, -21.29587F, 30.61478F), deg_vec(-101.8036F, -21.29587F, 30.61478F), CATMULLROM},
	{1.75f, deg_vec(-89.04994F, -4.19657F, -1.47845F), deg_vec(-89.04994F, -4.19657F, -1.47845F), CATMULLROM},
	{2.2083f, deg_vec(-158.30728F, 3.7152F, -1.52352F), deg_vec(-158.30728F, 3.7152F, -1.52352F), CATMULLROM},
	{2.5417f, deg_vec(-89.04994F, -4.19657F, -1.47845F), deg_vec(-89.04994F, -4.19657F, -1.47845F), CATMULLROM},
	{4.375f, deg_vec(-120.0F, 0.0F, 0.0F), deg_vec(-120.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_dig_5[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.7083f, pos_vec(2.22F, 0.0F, 0.86F), pos_vec(2.22F, 0.0F, 0.86F), CATMULLROM},
	{1.0f, pos_vec(3.12F, 0.0F, 4.29F), pos_vec(3.12F, 0.0F, 4.29F), CATMULLROM},
	{2.2083f, pos_vec(1.0F, 0.0F, 4.0F), pos_vec(1.0F, 0.0F, 4.0F), CATMULLROM},
	{4.375f, pos_vec(0.0F, 0.0F, 4.0F), pos_vec(0.0F, 0.0F, 4.0F), CATMULLROM},
};
static const Keyframe warden_dig_6[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.2917f, deg_vec(-63.89288F, -0.52011F, 2.09491F), deg_vec(-63.89288F, -0.52011F, 2.09491F), CATMULLROM},
	{0.5f, deg_vec(-63.89288F, -0.52011F, 2.09491F), deg_vec(-63.89288F, -0.52011F, 2.09491F), CATMULLROM},
	{0.7083f, deg_vec(-62.87857F, 15.15061F, 9.97445F), deg_vec(-62.87857F, 15.15061F, 9.97445F), CATMULLROM},
	{0.9167f, deg_vec(-86.93642F, 17.45026F, 4.05284F), deg_vec(-86.93642F, 17.45026F, 4.05284F), CATMULLROM},
	{1.1667f, deg_vec(-86.93642F, 17.45026F, 4.05284F), deg_vec(-86.93642F, 17.45026F, 4.05284F), CATMULLROM},
	{1.4583f, deg_vec(-86.93642F, 17.45026F, 4.05284F), deg_vec(-86.93642F, 17.45026F, 4.05284F), CATMULLROM},
	{1.6667f, deg_vec(63.0984F, 8.83573F, -8.71284F), deg_vec(63.0984F, 8.83573F, -8.71284F), CATMULLROM},
	{1.8333f, deg_vec(35.5984F, 8.83573F, -8.71284F), deg_vec(35.5984F, 8.83573F, -8.71284F), CATMULLROM},
	{2.2083f, deg_vec(-153.27473F, -0.02953F, 3.5235F), deg_vec(-153.27473F, -0.02953F, 3.5235F), CATMULLROM},
	{2.5417f, deg_vec(-87.07754F, -0.02625F, 3.132F), deg_vec(-87.07754F, -0.02625F, 3.132F), CATMULLROM},
	{4.375f, deg_vec(-120.0F, 0.0F, 0.0F), deg_vec(-120.0F, 0.0F, 0.0F), LINEAR},
};
static const Keyframe warden_dig_7[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.5f, pos_vec(-0.28F, 5.0F, 10.0F), pos_vec(-0.28F, 5.0F, 10.0F), CATMULLROM},
	{0.7083f, pos_vec(-1.51F, 4.35F, 4.33F), pos_vec(-1.51F, 4.35F, 4.33F), CATMULLROM},
	{0.9167f, pos_vec(-0.6F, 3.61F, 4.63F), pos_vec(-0.6F, 3.61F, 4.63F), CATMULLROM},
	{1.1667f, pos_vec(-0.6F, 3.61F, 0.63F), pos_vec(-0.6F, 3.61F, 0.63F), CATMULLROM},
	{1.6667f, pos_vec(-2.85F, -0.1F, 3.33F), pos_vec(-2.85F, -0.1F, 3.33F), CATMULLROM},
	{2.2083f, pos_vec(-1.0F, 0.0F, 4.0F), pos_vec(-1.0F, 0.0F, 4.0F), CATMULLROM},
	{4.375f, pos_vec(0.0F, 0.0F, 4.0F), pos_vec(0.0F, 0.0F, 4.0F), LINEAR},
};
static const Keyframe warden_dig_8[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.5f, deg_vec(113.27F, 0.0F, 0.0F), deg_vec(113.27F, 0.0F, 0.0F), CATMULLROM},
	{0.7083f, deg_vec(113.27F, 0.0F, 0.0F), deg_vec(113.27F, 0.0F, 0.0F), CATMULLROM},
	{3.3333f, deg_vec(113.27F, 0.0F, 0.0F), deg_vec(113.27F, 0.0F, 0.0F), CATMULLROM},
	{3.5833f, deg_vec(182.5F, 0.0F, 0.0F), deg_vec(182.5F, 0.0F, 0.0F), CATMULLROM},
	{3.8333f, deg_vec(120.0F, 0.0F, 0.0F), deg_vec(120.0F, 0.0F, 0.0F), CATMULLROM},
	{4.0833f, deg_vec(182.5F, 0.0F, 0.0F), deg_vec(182.5F, 0.0F, 0.0F), CATMULLROM},
	{4.2917f, deg_vec(120.0F, 0.0F, 0.0F), deg_vec(120.0F, 0.0F, 0.0F), CATMULLROM},
	{4.5f, deg_vec(90.0F, 0.0F, 0.0F), deg_vec(90.0F, 0.0F, 0.0F), LINEAR},
};
static const Keyframe warden_dig_9[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.5f, pos_vec(0.0F, -13.98F, -2.37F), pos_vec(0.0F, -13.98F, -2.37F), CATMULLROM},
	{0.7083f, pos_vec(0.0F, -13.98F, -2.37F), pos_vec(0.0F, -13.98F, -2.37F), CATMULLROM},
	{3.3333f, pos_vec(0.0F, -13.98F, -2.37F), pos_vec(0.0F, -13.98F, -2.37F), CATMULLROM},
	{3.5833f, pos_vec(0.0F, -7.0F, -3.0F), pos_vec(0.0F, -7.0F, -3.0F), CATMULLROM},
	{3.8333f, pos_vec(0.0F, -9.0F, -3.0F), pos_vec(0.0F, -9.0F, -3.0F), CATMULLROM},
	{4.0833f, pos_vec(0.0F, -16.71F, -3.69F), pos_vec(0.0F, -16.71F, -3.69F), CATMULLROM},
	{4.2917f, pos_vec(0.0F, -28.0F, -5.0F), pos_vec(0.0F, -28.0F, -5.0F), LINEAR},
};
static const Keyframe warden_dig_10[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.5f, deg_vec(114.98F, 0.0F, 0.0F), deg_vec(114.98F, 0.0F, 0.0F), CATMULLROM},
	{0.7083f, deg_vec(114.98F, 0.0F, 0.0F), deg_vec(114.98F, 0.0F, 0.0F), CATMULLROM},
	{3.3333f, deg_vec(114.98F, 0.0F, 0.0F), deg_vec(114.98F, 0.0F, 0.0F), CATMULLROM},
	{3.5833f, deg_vec(90.0F, 0.0F, 0.0F), deg_vec(90.0F, 0.0F, 0.0F), CATMULLROM},
	{3.8333f, deg_vec(172.5F, 0.0F, 0.0F), deg_vec(172.5F, 0.0F, 0.0F), CATMULLROM},
	{4.0833f, deg_vec(90.0F, 0.0F, 0.0F), deg_vec(90.0F, 0.0F, 0.0F), CATMULLROM},
	{4.2917f, deg_vec(197.5F, 0.0F, 0.0F), deg_vec(197.5F, 0.0F, 0.0F), CATMULLROM},
	{4.5f, deg_vec(90.0F, 0.0F, 0.0F), deg_vec(90.0F, 0.0F, 0.0F), LINEAR},
};
static const Keyframe warden_dig_11[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.5f, pos_vec(0.0F, -14.01F, -2.35F), pos_vec(0.0F, -14.01F, -2.35F), CATMULLROM},
	{0.7083f, pos_vec(0.0F, -14.01F, -2.35F), pos_vec(0.0F, -14.01F, -2.35F), CATMULLROM},
	{3.3333f, pos_vec(0.0F, -14.01F, -2.35F), pos_vec(0.0F, -14.01F, -2.35F), CATMULLROM},
	{3.5833f, pos_vec(0.0F, -5.0F, -4.0F), pos_vec(0.0F, -5.0F, -4.0F), CATMULLROM},
	{3.8333f, pos_vec(0.0F, -7.0F, -4.0F), pos_vec(0.0F, -7.0F, -4.0F), CATMULLROM},
	{4.0833f, pos_vec(0.0F, -15.5F, -3.76F), pos_vec(0.0F, -15.5F, -3.76F), CATMULLROM},
	{4.2917f, pos_vec(0.0F, -28.0F, -5.0F), pos_vec(0.0F, -28.0F, -5.0F), LINEAR},
};
static const Channel warden_dig_channels[] = {
	{P::BODY, Target::ROTATION, warden_dig_0, std::size(warden_dig_0)},
	{P::BODY, Target::POSITION, warden_dig_1, std::size(warden_dig_1)},
	{P::HEAD, Target::ROTATION, warden_dig_2, std::size(warden_dig_2)},
	{P::HEAD, Target::POSITION, warden_dig_3, std::size(warden_dig_3)},
	{P::RIGHT_ARM, Target::ROTATION, warden_dig_4, std::size(warden_dig_4)},
	{P::RIGHT_ARM, Target::POSITION, warden_dig_5, std::size(warden_dig_5)},
	{P::LEFT_ARM, Target::ROTATION, warden_dig_6, std::size(warden_dig_6)},
	{P::LEFT_ARM, Target::POSITION, warden_dig_7, std::size(warden_dig_7)},
	{P::RIGHT_LEG, Target::ROTATION, warden_dig_8, std::size(warden_dig_8)},
	{P::RIGHT_LEG, Target::POSITION, warden_dig_9, std::size(warden_dig_9)},
	{P::LEFT_LEG, Target::ROTATION, warden_dig_10, std::size(warden_dig_10)},
	{P::LEFT_LEG, Target::POSITION, warden_dig_11, std::size(warden_dig_11)},
};
static const Keyframe warden_roar_0[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.24f, deg_vec(-25.0F, 0.0F, 0.0F), deg_vec(-25.0F, 0.0F, 0.0F), CATMULLROM},
	{1.6f, deg_vec(32.5F, 0.0F, -7.5F), deg_vec(32.5F, 0.0F, -7.5F), CATMULLROM},
	{1.84f, deg_vec(38.33F, 0.0F, 2.99F), deg_vec(38.33F, 0.0F, 2.99F), CATMULLROM},
	{2.08f, deg_vec(40.97F, 0.0F, -4.3F), deg_vec(40.97F, 0.0F, -4.3F), CATMULLROM},
	{2.36f, deg_vec(44.41F, 0.0F, 6.29F), deg_vec(44.41F, 0.0F, 6.29F), CATMULLROM},
	{3.0f, deg_vec(47.5F, 0.0F, 0.0F), deg_vec(47.5F, 0.0F, 0.0F), CATMULLROM},
	{4.2f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_roar_1[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.24f, pos_vec(0.0F, -1.0F, 3.0F), pos_vec(0.0F, -1.0F, 3.0F), CATMULLROM},
	{1.6f, pos_vec(0.0F, -3.0F, -6.0F), pos_vec(0.0F, -3.0F, -6.0F), CATMULLROM},
	{3.0f, pos_vec(0.0F, -3.0F, -6.0F), pos_vec(0.0F, -3.0F, -6.0F), CATMULLROM},
	{4.2f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_roar_2[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.24f, deg_vec(-32.5F, 0.0F, 0.0F), deg_vec(-32.5F, 0.0F, 0.0F), CATMULLROM},
	{1.6f, deg_vec(-32.5F, 0.0F, -27.5F), deg_vec(-32.5F, 0.0F, -27.5F), CATMULLROM},
	{1.8f, deg_vec(-32.5F, 0.0F, 26.0F), deg_vec(-32.5F, 0.0F, 26.0F), CATMULLROM},
	{2.04f, deg_vec(-32.5F, 0.0F, -27.5F), deg_vec(-32.5F, 0.0F, -27.5F), CATMULLROM},
	{2.44f, deg_vec(-32.5F, 0.0F, 26.0F), deg_vec(-32.5F, 0.0F, 26.0F), CATMULLROM},
	{2.84f, deg_vec(-5.0F, 0.0F, -12.5F), deg_vec(-5.0F, 0.0F, -12.5F), CATMULLROM},
	{4.2f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_roar_3[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.24f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.6f, pos_vec(0.0F, -2.0F, -6.0F), pos_vec(0.0F, -2.0F, -6.0F), CATMULLROM},
	{2.2f, pos_vec(0.0F, -2.0F, -6.0F), pos_vec(0.0F, -2.0F, -6.0F), CATMULLROM},
	{2.48f, pos_vec(0.0F, -2.0F, -6.0F), pos_vec(0.0F, -2.0F, -6.0F), CATMULLROM},
	{4.2f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_roar_4[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.72f, deg_vec(-120.0F, 0.0F, -20.0F), deg_vec(-120.0F, 0.0F, -20.0F), CATMULLROM},
	{1.24f, deg_vec(-77.5F, 3.75F, 15.0F), deg_vec(-77.5F, 3.75F, 15.0F), CATMULLROM},
	{1.48f, deg_vec(67.5F, -32.5F, 20.0F), deg_vec(67.5F, -32.5F, 20.0F), CATMULLROM},
	{2.48f, deg_vec(37.5F, -32.5F, 25.0F), deg_vec(37.5F, -32.5F, 25.0F), CATMULLROM},
	{2.88f, deg_vec(27.6F, -17.1F, 32.5F), deg_vec(27.6F, -17.1F, 32.5F), CATMULLROM},
	{4.2f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_roar_5[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.72f, pos_vec(3.0F, -2.0F, 0.0F), pos_vec(3.0F, -2.0F, 0.0F), CATMULLROM},
	{1.48f, pos_vec(4.0F, -2.0F, 0.0F), pos_vec(4.0F, -2.0F, 0.0F), CATMULLROM},
	{2.48f, pos_vec(4.0F, -2.0F, 0.0F), pos_vec(4.0F, -2.0F, 0.0F), CATMULLROM},
	{4.2f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_roar_6[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.72f, deg_vec(-125.0F, 0.0F, 20.0F), deg_vec(-125.0F, 0.0F, 20.0F), CATMULLROM},
	{1.24f, deg_vec(-76.25F, -17.5F, -7.5F), deg_vec(-76.25F, -17.5F, -7.5F), CATMULLROM},
	{1.48f, deg_vec(62.5F, 42.5F, -12.5F), deg_vec(62.5F, 42.5F, -12.5F), CATMULLROM},
	{2.48f, deg_vec(37.5F, 27.5F, -27.5F), deg_vec(37.5F, 27.5F, -27.5F), CATMULLROM},
	{2.88f, deg_vec(25.0F, 18.4F, -30.0F), deg_vec(25.0F, 18.4F, -30.0F), CATMULLROM},
	{4.2f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_roar_7[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.72f, pos_vec(-3.0F, -2.0F, 0.0F), pos_vec(-3.0F, -2.0F, 0.0F), CATMULLROM},
	{1.48f, pos_vec(-4.0F, -2.0F, 0.0F), pos_vec(-4.0F, -2.0F, 0.0F), CATMULLROM},
	{2.48f, pos_vec(-4.0F, -2.0F, 0.0F), pos_vec(-4.0F, -2.0F, 0.0F), CATMULLROM},
	{4.2f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Channel warden_roar_channels[] = {
	{P::BODY, Target::ROTATION, warden_roar_0, std::size(warden_roar_0)},
	{P::BODY, Target::POSITION, warden_roar_1, std::size(warden_roar_1)},
	{P::HEAD, Target::ROTATION, warden_roar_2, std::size(warden_roar_2)},
	{P::HEAD, Target::POSITION, warden_roar_3, std::size(warden_roar_3)},
	{P::RIGHT_ARM, Target::ROTATION, warden_roar_4, std::size(warden_roar_4)},
	{P::RIGHT_ARM, Target::POSITION, warden_roar_5, std::size(warden_roar_5)},
	{P::LEFT_ARM, Target::ROTATION, warden_roar_6, std::size(warden_roar_6)},
	{P::LEFT_ARM, Target::POSITION, warden_roar_7, std::size(warden_roar_7)},
};
static const Keyframe warden_sniff_0[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.56f, deg_vec(17.5F, 32.5F, 0.0F), deg_vec(17.5F, 32.5F, 0.0F), CATMULLROM},
	{0.96f, deg_vec(0.0F, 32.5F, 0.0F), deg_vec(0.0F, 32.5F, 0.0F), CATMULLROM},
	{2.2f, deg_vec(10.0F, 0.0F, 0.0F), deg_vec(10.0F, 0.0F, 0.0F), CATMULLROM},
	{2.8f, deg_vec(10.0F, -30.0F, 0.0F), deg_vec(10.0F, -30.0F, 0.0F), CATMULLROM},
	{3.32f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_sniff_1[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.68f, deg_vec(0.0F, 40.0F, 0.0F), deg_vec(0.0F, 40.0F, 0.0F), CATMULLROM},
	{0.96f, deg_vec(-22.5F, 40.0F, 0.0F), deg_vec(-22.5F, 40.0F, 0.0F), CATMULLROM},
	{1.24f, deg_vec(0.0F, 20.0F, 0.0F), deg_vec(0.0F, 20.0F, 0.0F), CATMULLROM},
	{1.52f, deg_vec(-35.0F, 20.0F, 0.0F), deg_vec(-35.0F, 20.0F, 0.0F), CATMULLROM},
	{1.76f, deg_vec(0.0F, 20.0F, 0.0F), deg_vec(0.0F, 20.0F, 0.0F), CATMULLROM},
	{2.28f, deg_vec(0.0F, -20.0F, 0.0F), deg_vec(0.0F, -20.0F, 0.0F), CATMULLROM},
	{2.88f, deg_vec(0.0F, -20.0F, 0.0F), deg_vec(0.0F, -20.0F, 0.0F), CATMULLROM},
	{3.32f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_sniff_2[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.96f, deg_vec(17.5F, 0.0F, 0.0F), deg_vec(17.5F, 0.0F, 0.0F), CATMULLROM},
	{2.2f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{2.76f, deg_vec(-15.0F, 0.0F, 0.0F), deg_vec(-15.0F, 0.0F, 0.0F), CATMULLROM},
	{3.32f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_sniff_3[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.96f, deg_vec(-15.0F, 0.0F, 0.0F), deg_vec(-15.0F, 0.0F, 0.0F), CATMULLROM},
	{2.2f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{2.76f, deg_vec(17.5F, 0.0F, 0.0F), deg_vec(17.5F, 0.0F, 0.0F), CATMULLROM},
	{3.32f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Channel warden_sniff_channels[] = {
	{P::BODY, Target::ROTATION, warden_sniff_0, std::size(warden_sniff_0)},
	{P::HEAD, Target::ROTATION, warden_sniff_1, std::size(warden_sniff_1)},
	{P::RIGHT_ARM, Target::ROTATION, warden_sniff_2, std::size(warden_sniff_2)},
	{P::LEFT_ARM, Target::ROTATION, warden_sniff_3, std::size(warden_sniff_3)},
};
static const Keyframe warden_attack_0[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.0417f, deg_vec(-22.5F, 0.0F, 0.0F), deg_vec(-22.5F, 0.0F, 0.0F), CATMULLROM},
	{0.2083f, deg_vec(22.5F, 0.0F, 0.0F), deg_vec(22.5F, 0.0F, 0.0F), CATMULLROM},
	{0.3333f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_attack_1[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.0417f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.2083f, pos_vec(0.0F, -1.0F, -2.0F), pos_vec(0.0F, -1.0F, -2.0F), CATMULLROM},
	{0.3333f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_attack_2[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.0417f, deg_vec(22.5F, 0.0F, 0.0F), deg_vec(22.5F, 0.0F, 0.0F), CATMULLROM},
	{0.25f, deg_vec(-30.17493F, 0.0F, 0.0F), deg_vec(-30.17493F, 0.0F, 0.0F), CATMULLROM},
	{0.3333f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_attack_3[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.0417f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.25f, pos_vec(0.0F, -2.0F, -2.0F), pos_vec(0.0F, -2.0F, -2.0F), CATMULLROM},
	{0.3333f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_attack_4[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.0417f, deg_vec(-120.36119F, 40.78947F, -20.94102F), deg_vec(-120.36119F, 40.78947F, -20.94102F), CATMULLROM},
	{0.1667f, deg_vec(-90.0F, -45.0F, 0.0F), deg_vec(-90.0F, -45.0F, 0.0F), CATMULLROM},
	{0.3333f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_attack_5[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.0417f, pos_vec(4.0F, 0.0F, 5.0F), pos_vec(4.0F, 0.0F, 5.0F), CATMULLROM},
	{0.1667f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.3333f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_attack_6[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.0417f, deg_vec(-120.36119F, -40.78947F, 20.94102F), deg_vec(-120.36119F, -40.78947F, 20.94102F), CATMULLROM},
	{0.1667f, deg_vec(-61.1632F, 42.85882F, 11.52421F), deg_vec(-61.1632F, 42.85882F, 11.52421F), CATMULLROM},
	{0.3333f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_attack_7[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.0417f, pos_vec(-4.0F, 0.0F, 5.0F), pos_vec(-4.0F, 0.0F, 5.0F), CATMULLROM},
	{0.1667f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.3333f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Channel warden_attack_channels[] = {
	{P::BODY, Target::ROTATION, warden_attack_0, std::size(warden_attack_0)},
	{P::BODY, Target::POSITION, warden_attack_1, std::size(warden_attack_1)},
	{P::HEAD, Target::ROTATION, warden_attack_2, std::size(warden_attack_2)},
	{P::HEAD, Target::POSITION, warden_attack_3, std::size(warden_attack_3)},
	{P::RIGHT_ARM, Target::ROTATION, warden_attack_4, std::size(warden_attack_4)},
	{P::RIGHT_ARM, Target::POSITION, warden_attack_5, std::size(warden_attack_5)},
	{P::LEFT_ARM, Target::ROTATION, warden_attack_6, std::size(warden_attack_6)},
	{P::LEFT_ARM, Target::POSITION, warden_attack_7, std::size(warden_attack_7)},
};
static const Keyframe warden_sonic_boom_0[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.0833f, deg_vec(47.5F, 0.0F, 0.0F), deg_vec(47.5F, 0.0F, 0.0F), CATMULLROM},
	{1.625f, deg_vec(55.0F, 0.0F, 0.0F), deg_vec(55.0F, 0.0F, 0.0F), CATMULLROM},
	{1.9167f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{2.0f, deg_vec(-32.5F, 0.0F, 0.0F), deg_vec(-32.5F, 0.0F, 0.0F), CATMULLROM},
	{2.4583f, deg_vec(-32.5F, 0.0F, 0.0F), deg_vec(-32.5F, 0.0F, 0.0F), CATMULLROM},
	{2.7083f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{2.875f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_sonic_boom_1[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.0833f, pos_vec(0.0F, -3.0F, 0.0F), pos_vec(0.0F, -3.0F, 0.0F), CATMULLROM},
	{1.625f, pos_vec(0.0F, -4.0F, -1.0F), pos_vec(0.0F, -4.0F, -1.0F), CATMULLROM},
	{1.9167f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{2.7083f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{2.875f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_sonic_boom_2[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.5417f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.7917f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.875f, deg_vec(0.0F, 125.0F, 0.0F), deg_vec(0.0F, 125.0F, 0.0F), CATMULLROM},
	{2.5f, deg_vec(0.0F, 125.0F, 0.0F), deg_vec(0.0F, 125.0F, 0.0F), CATMULLROM},
	{2.6667f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_sonic_boom_3[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.5417f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.7917f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.875f, deg_vec(0.0F, -125.0F, 0.0F), deg_vec(0.0F, -125.0F, 0.0F), CATMULLROM},
	{2.5f, deg_vec(0.0F, -125.0F, 0.0F), deg_vec(0.0F, -125.0F, 0.0F), CATMULLROM},
	{2.6667f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_sonic_boom_4[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.0f, deg_vec(67.5F, 0.0F, 0.0F), deg_vec(67.5F, 0.0F, 0.0F), CATMULLROM},
	{1.75f, deg_vec(80.0F, 0.0F, 0.0F), deg_vec(80.0F, 0.0F, 0.0F), CATMULLROM},
	{1.9167f, deg_vec(-45.0F, 0.0F, 0.0F), deg_vec(-45.0F, 0.0F, 0.0F), CATMULLROM},
	{2.5f, deg_vec(-45.0F, 0.0F, 0.0F), deg_vec(-45.0F, 0.0F, 0.0F), CATMULLROM},
	{2.7083f, deg_vec(-45.0F, 0.0F, 0.0F), deg_vec(-45.0F, 0.0F, 0.0F), CATMULLROM},
	{2.875f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_sonic_boom_5[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.9167f, pos_vec(0.0F, 0.0F, -3.0F), pos_vec(0.0F, 0.0F, -3.0F), CATMULLROM},
	{2.5f, pos_vec(0.0F, 0.0F, -3.0F), pos_vec(0.0F, 0.0F, -3.0F), CATMULLROM},
	{2.7083f, pos_vec(0.0F, 0.0F, -3.0F), pos_vec(0.0F, 0.0F, -3.0F), CATMULLROM},
	{2.875f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_sonic_boom_6[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.875f, deg_vec(-42.28659F, -32.69813F, -5.00825F), deg_vec(-42.28659F, -32.69813F, -5.00825F), CATMULLROM},
	{1.1667f, deg_vec(-29.83757F, -35.39626F, -45.28089F), deg_vec(-29.83757F, -35.39626F, -45.28089F), CATMULLROM},
	{1.3333f, deg_vec(-29.83757F, -35.39626F, -45.28089F), deg_vec(-29.83757F, -35.39626F, -45.28089F), CATMULLROM},
	{1.6667f, deg_vec(-72.28659F, -32.69813F, -5.00825F), deg_vec(-72.28659F, -32.69813F, -5.00825F), CATMULLROM},
	{1.8333f, deg_vec(35.26439F, -30.0F, 35.26439F), deg_vec(35.26439F, -30.0F, 35.26439F), CATMULLROM},
	{1.9167f, deg_vec(73.75484F, -13.0931F, 19.20518F), deg_vec(73.75484F, -13.0931F, 19.20518F), CATMULLROM},
	{2.5f, deg_vec(73.75484F, -13.0931F, 19.20518F), deg_vec(73.75484F, -13.0931F, 19.20518F), CATMULLROM},
	{2.75f, deg_vec(58.20713F, -21.1064F, 28.7261F), deg_vec(58.20713F, -21.1064F, 28.7261F), CATMULLROM},
	{3.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_sonic_boom_7[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.8333f, pos_vec(3.0F, 0.0F, 0.0F), pos_vec(3.0F, 0.0F, 0.0F), CATMULLROM},
	{2.75f, pos_vec(3.0F, 0.0F, 0.0F), pos_vec(3.0F, 0.0F, 0.0F), CATMULLROM},
	{3.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_sonic_boom_8[] = {
	{0.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{0.875f, deg_vec(-33.80694F, 32.31058F, 6.87997F), deg_vec(-33.80694F, 32.31058F, 6.87997F), CATMULLROM},
	{1.1667f, deg_vec(-17.87827F, 34.62115F, 49.02433F), deg_vec(-17.87827F, 34.62115F, 49.02433F), CATMULLROM},
	{1.3333f, deg_vec(-17.87827F, 34.62115F, 49.02433F), deg_vec(-17.87827F, 34.62115F, 49.02433F), CATMULLROM},
	{1.6667f, deg_vec(-51.30694F, 32.31058F, 6.87997F), deg_vec(-51.30694F, 32.31058F, 6.87997F), CATMULLROM},
	{1.8333f, deg_vec(35.26439F, 30.0F, -35.26439F), deg_vec(35.26439F, 30.0F, -35.26439F), CATMULLROM},
	{1.9167f, deg_vec(73.75484F, 13.0931F, -19.20518F), deg_vec(73.75484F, 13.0931F, -19.20518F), CATMULLROM},
	{2.5f, deg_vec(73.75484F, 13.0931F, -19.20518F), deg_vec(73.75484F, 13.0931F, -19.20518F), CATMULLROM},
	{2.75f, deg_vec(58.20713F, 21.1064F, -28.7261F), deg_vec(58.20713F, 21.1064F, -28.7261F), CATMULLROM},
	{3.0f, deg_vec(0.0F, 0.0F, 0.0F), deg_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Keyframe warden_sonic_boom_9[] = {
	{0.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
	{1.8333f, pos_vec(-3.0F, 0.0F, 0.0F), pos_vec(-3.0F, 0.0F, 0.0F), CATMULLROM},
	{2.75f, pos_vec(-3.0F, 0.0F, 0.0F), pos_vec(-3.0F, 0.0F, 0.0F), CATMULLROM},
	{3.0f, pos_vec(0.0F, 0.0F, 0.0F), pos_vec(0.0F, 0.0F, 0.0F), CATMULLROM},
};
static const Channel warden_sonic_boom_channels[] = {
	{P::BODY, Target::ROTATION, warden_sonic_boom_0, std::size(warden_sonic_boom_0)},
	{P::BODY, Target::POSITION, warden_sonic_boom_1, std::size(warden_sonic_boom_1)},
	{P::RIGHT_RIBCAGE, Target::ROTATION, warden_sonic_boom_2, std::size(warden_sonic_boom_2)},
	{P::LEFT_RIBCAGE, Target::ROTATION, warden_sonic_boom_3, std::size(warden_sonic_boom_3)},
	{P::HEAD, Target::ROTATION, warden_sonic_boom_4, std::size(warden_sonic_boom_4)},
	{P::HEAD, Target::POSITION, warden_sonic_boom_5, std::size(warden_sonic_boom_5)},
	{P::RIGHT_ARM, Target::ROTATION, warden_sonic_boom_6, std::size(warden_sonic_boom_6)},
	{P::RIGHT_ARM, Target::POSITION, warden_sonic_boom_7, std::size(warden_sonic_boom_7)},
	{P::LEFT_ARM, Target::ROTATION, warden_sonic_boom_8, std::size(warden_sonic_boom_8)},
	{P::LEFT_ARM, Target::POSITION, warden_sonic_boom_9, std::size(warden_sonic_boom_9)},
};
static const AnimationDefinition WARDEN_EMERGE = {6.68f, false, warden_emerge_channels, std::size(warden_emerge_channels)};
static const AnimationDefinition WARDEN_DIG = {5.0f, false, warden_dig_channels, std::size(warden_dig_channels)};
static const AnimationDefinition WARDEN_ROAR = {4.2f, false, warden_roar_channels, std::size(warden_roar_channels)};
static const AnimationDefinition WARDEN_SNIFF = {4.16f, false, warden_sniff_channels, std::size(warden_sniff_channels)};
static const AnimationDefinition WARDEN_ATTACK = {0.33333f, false, warden_attack_channels, std::size(warden_attack_channels)};
static const AnimationDefinition WARDEN_SONIC_BOOM = {3.0f, false, warden_sonic_boom_channels, std::size(warden_sonic_boom_channels)};

} // namespace

const char *MinecraftWardenAnimator::jointName(Joint j)
{
	static const char *names[JOINT_COUNT] = {
		"bone", "body", "head", "right_tendril", "left_tendril", "right_ribcage",
		"left_ribcage", "right_arm", "left_arm", "right_leg", "left_leg",
	};
	return names[j];
}

MinecraftWardenAnimator::Joint MinecraftWardenAnimator::parentOf(Joint j)
{
	switch (j) {
	case BONE: return JOINT_COUNT;
	case BODY: case RIGHT_LEG: case LEFT_LEG: return BONE;
	case HEAD: case RIGHT_RIBCAGE: case LEFT_RIBCAGE: case RIGHT_ARM: case LEFT_ARM:
		return BODY;
	case RIGHT_TENDRIL: case LEFT_TENDRIL: return HEAD;
	default: return JOINT_COUNT;
	}
}

// WardenModel.createBodyLayer: the parts' initial poses (PartPose.offset)
static std::array<mc_model::Part, MinecraftWardenAnimator::JOINT_COUNT> initial_pose()
{
	using W = MinecraftWardenAnimator;
	std::array<mc_model::Part, W::JOINT_COUNT> p;
	auto offset = [&](W::Joint j, f32 x, f32 y, f32 z) {
		p[j].x = x; p[j].y = y; p[j].z = z;
	};
	offset(W::BONE, 0, 24, 0);
	offset(W::BODY, 0, -21, 0);
	offset(W::RIGHT_RIBCAGE, -7, -2, -4);
	offset(W::LEFT_RIBCAGE, 7, -2, -4);
	offset(W::HEAD, 0, -13, 0);
	offset(W::RIGHT_TENDRIL, -8, -12, 0);
	offset(W::LEFT_TENDRIL, 8, -12, 0);
	offset(W::RIGHT_ARM, -13, -13, 1);
	offset(W::LEFT_ARM, 13, -13, 1);
	offset(W::RIGHT_LEG, -5.9f, -13, 0);
	offset(W::LEFT_LEG, 5.9f, -13, 0);
	return p;
}

void MinecraftWardenAnimator::setState(const AnimationState &state)
{
	// Warden.onSyncedDataUpdated (DATA_POSE)
	if (state.pose != m_state.pose) {
		switch (state.pose) {
		case AnimationState::POSE_EMERGING: m_emerge.start(m_ticks); break;
		case AnimationState::POSE_DIGGING: m_digging.start(m_ticks); break;
		case AnimationState::POSE_ROARING: m_roar.start(m_ticks); break;
		case AnimationState::POSE_SNIFFING: m_sniff.start(m_ticks); break;
		default: break;
		}
	}
	m_state = state;
}

void MinecraftWardenAnimator::entityEvent(u8 id)
{
	// Warden.handleEntityEvent
	if (id == 4) {
		m_roar.stop();
		m_attack.start(m_ticks);
	} else if (id == 61) {
		m_tendril = 10;
	} else if (id == 62) {
		m_sonic_boom.start(m_ticks);
	}
}

static v3f to_minecraft(v3f p)
{
	return v3f(p.X, p.Y, -p.Z);
}

// Minecraft degrees of the state's head yaw and pitch
static f32 state_head_yaw(const AnimationState &s)
{
	return -s.head_yaw * 180.0f / PI_F;
}

static f32 state_pitch(const AnimationState &s)
{
	return s.look_pitch * 180.0f / PI_F;
}

void MinecraftWardenAnimator::step(f32 dtime, const Input &input)
{
	m_input = input;
	if (!m_have_input) {
		m_have_input = true;
		m_pos = m_prev_pos = to_minecraft(input.position);
		m_head_yaw = m_prev_head_yaw = m_head_yaw_target = state_head_yaw(m_state);
		m_pitch = m_prev_pitch = m_pitch_target = state_pitch(m_state);
	}

	m_tick_time += dtime;
	int n = 0;
	while (m_tick_time >= TICK) {
		m_tick_time -= TICK;
		tick();
		if (++n >= 10) {
			m_tick_time = 0.0f;
			break;
		}
	}
	m_partial = m_tick_time / TICK;
}

void MinecraftWardenAnimator::tick()
{
	// Entity.commonTick: previous values, the new position, tickCount
	m_prev_pos = m_pos;
	m_prev_head_yaw = m_head_yaw;
	m_prev_pitch = m_pitch;
	m_pos = to_minecraft(m_input.position);
	m_ticks++;

	// Rotation updates arrive like ClientboundRotateHeadPacket and the
	// entity's interpolation: approached in 3 ticks
	f32 yaw = state_head_yaw(m_state), pitch = state_pitch(m_state);
	if (yaw != m_head_yaw_target) {
		m_head_yaw_target = yaw;
		m_head_steps = 3;
	}
	if (pitch != m_pitch_target) {
		m_pitch_target = pitch;
		m_pitch_steps = 3;
	}
	if (m_head_steps > 0) {
		m_head_yaw = rot_lerp(1.0f / m_head_steps, m_head_yaw, m_head_yaw_target);
		m_head_steps--;
	}
	if (m_pitch_steps > 0) {
		m_pitch += (m_pitch_target - m_pitch) / m_pitch_steps;
		m_pitch_steps--;
	}
	m_prev_head_yaw = m_head_yaw + wrap_degrees(m_prev_head_yaw - m_head_yaw);

	// LivingEntity.calculateEntityAnimation (horizontal movement)
	if (m_input.attached || m_state.dead) {
		m_walk.stop();
	} else {
		f32 dx = m_pos.X - m_prev_pos.X, dz = m_pos.Z - m_prev_pos.Z;
		f32 distance = std::sqrt(dx * dx + dz * dz);
		m_walk.update(std::min(distance * 4.0f, 1.0f), 0.4f, 1.0f);
	}

	// LivingEntity.tickDeath
	if (m_state.dead)
		m_death_time = std::min(m_death_time + 1, 20);
	else
		m_death_time = 0;

	// Warden.tick (client)
	f32 anger = std::clamp((f32)m_state.anger / 80.0f, 0.0f, 1.0f);
	int heartbeat_delay = 40 - (int)std::floor(anger * 30.0f);
	if (m_ticks % heartbeat_delay == 0)
		m_heart = 10;
	m_prev_tendril = m_tendril;
	if (m_tendril > 0)
		m_tendril--;
	m_prev_heart = m_heart;
	if (m_heart > 0)
		m_heart--;
}

std::array<mc_model::Part, MinecraftWardenAnimator::JOINT_COUNT>
MinecraftWardenAnimator::computeParts() const
{
	const f32 p = m_partial;
	const f32 age = m_ticks + p;

	// LivingEntityRenderer.extractRenderState
	const f32 y_rot = wrap_degrees(rot_lerp(p, m_prev_head_yaw, m_head_yaw));
	const f32 x_rot = m_prev_pitch + p * (m_pitch - m_prev_pitch);
	f32 walk_pos = 0.0f, walk_speed = 0.0f;
	if (!m_input.attached && !m_state.dead) {
		walk_pos = m_walk.getPosition(p);
		walk_speed = m_walk.getSpeed(p);
	}
	// Warden.getTendrilAnimation
	const f32 tendril = (m_prev_tendril + p * (m_tendril - m_prev_tendril)) / 10.0f;

	// WardenModel.setupAnim, after resetPose
	auto parts = initial_pose();
	auto &head = parts[HEAD], &body = parts[BODY];

	// animateHeadLookTarget
	head.xRot = x_rot * (PI_F / 180.0f);
	head.yRot = y_rot * (PI_F / 180.0f);

	// animateWalk
	{
		f32 speed_modifier = std::min(0.5f, 3.0f * walk_speed);
		f32 adjusted_pos = walk_pos * 0.8662f;
		f32 c = std::cos(adjusted_pos);
		f32 s = std::sin(adjusted_pos);
		f32 speed_min = std::min(0.35f, speed_modifier);
		head.zRot += 0.3f * s * speed_modifier;
		head.xRot = head.xRot + 1.2f * std::cos(adjusted_pos + PI_F / 2) * speed_min;
		body.zRot = 0.1f * s * speed_modifier;
		body.xRot = 1.0f * c * speed_min;
		parts[LEFT_LEG].xRot = 1.0f * c * speed_modifier;
		parts[RIGHT_LEG].xRot = 1.0f * std::cos(adjusted_pos + PI_F) * speed_modifier;
		parts[LEFT_ARM].xRot = -(0.8f * c * speed_modifier);
		parts[LEFT_ARM].zRot = 0.0f;
		parts[RIGHT_ARM].xRot = -(0.8f * s * speed_modifier);
		parts[RIGHT_ARM].zRot = 0.0f;
		// resetArmPoses
		parts[LEFT_ARM].yRot = 0.0f;
		parts[LEFT_ARM].z = 1.0f;
		parts[LEFT_ARM].x = 13.0f;
		parts[LEFT_ARM].y = -13.0f;
		parts[RIGHT_ARM].yRot = 0.0f;
		parts[RIGHT_ARM].z = 1.0f;
		parts[RIGHT_ARM].x = -13.0f;
		parts[RIGHT_ARM].y = -13.0f;
	}

	// animateIdlePose
	{
		f32 scaled_age = age * 0.1f;
		f32 c = std::cos(scaled_age);
		f32 s = std::sin(scaled_age);
		head.zRot += 0.06f * c;
		head.xRot += 0.06f * s;
		body.zRot += 0.025f * s;
		body.xRot += 0.025f * c;
	}

	// animateTendrils
	{
		f32 x = tendril * (f32)(std::cos(age * 2.25) * PI_F * 0.1f);
		parts[LEFT_TENDRIL].xRot = x;
		parts[RIGHT_TENDRIL].xRot = -x;
	}

	apply_animation(WARDEN_ATTACK, parts.data(), m_attack, age);
	apply_animation(WARDEN_SONIC_BOOM, parts.data(), m_sonic_boom, age);
	apply_animation(WARDEN_DIG, parts.data(), m_digging, age);
	apply_animation(WARDEN_EMERGE, parts.data(), m_emerge, age);
	apply_animation(WARDEN_ROAR, parts.data(), m_roar, age);
	apply_animation(WARDEN_SNIFF, parts.data(), m_sniff, age);
	return parts;
}

std::array<core::Transform, MinecraftWardenAnimator::JOINT_COUNT>
MinecraftWardenAnimator::computeJoints() const
{
	auto parts = computeParts();
	std::array<core::Transform, JOINT_COUNT> joints;
	for (int j = 0; j < JOINT_COUNT; j++)
		joints[j] = parts[j].localTransform(UNITS);

	/*
		The root part: LivingEntityRenderer.submit and setupRotations. The
		scene node already has the object's yaw, which is the body's.
		Model space to the Luanti model: scale(-1, -1, 1), the Z axis turned
		to north (scale(1, 1, -1)) and the model pixels (scale(-UNITS)) make
		the identity, the model is lifted by 1.501 blocks and dying entities
		fall over around Z (which the axis changes leave as it is).
		The bone part is never rotated, so its rotation is the fall's.
	*/
	mc_model::Part root = parts[BONE];
	f32 fall = 0.0f;
	if (m_death_time > 0) {
		fall = std::sqrt((m_death_time + m_partial - 1.0f) / 20.0f * 1.6f);
		fall = std::min(fall, 1.0f) * 90.0f * (PI_F / 180.0f);
	}
	root.zRot += fall;
	core::Transform t = root.localTransform(UNITS);
	v3f lifted = t.translation + v3f(0.0f, 1.501f * 10.0f, 0.0f);
	f32 c = std::cos(fall), s = std::sin(fall);
	t.translation = v3f(c * lifted.X - s * lifted.Y, s * lifted.X + c * lifted.Y, lifted.Z);
	joints[BONE] = t;
	return joints;
}

std::array<f32, MinecraftWardenAnimator::LAYER_COUNT> MinecraftWardenAnimator::layerAlphas() const
{
	const f32 p = m_partial;
	const f32 age = m_ticks + p;
	std::array<f32, LAYER_COUNT> a;
	a[LAYER_BASE] = 1.0f;
	a[LAYER_BIOLUMINESCENT] = 1.0f;
	a[LAYER_SPOTS_1] = std::max(0.0f, std::cos(age * 0.045f) * 0.25f);
	a[LAYER_SPOTS_2] = std::max(0.0f, std::cos(age * 0.045f + PI_F) * 0.25f);
	a[LAYER_TENDRILS] = (m_prev_tendril + p * (m_tendril - m_prev_tendril)) / 10.0f;
	a[LAYER_HEART] = (m_prev_heart + p * (m_heart - m_prev_heart)) / 10.0f;
	return a;
}

void MinecraftWardenAnimator::setupMaterials(scene::AnimatedMeshSceneNode *node,
		video::E_MATERIAL_TYPE layer_material)
{
	if (!node)
		return;
	// RenderTypes.entityTranslucentEmissive: translucent, depth test
	// less or equal (the layers have the base's geometry), no depth writes
	u32 n = std::min<u32>(node->getMaterialCount(), LAYER_COUNT);
	for (u32 i = LAYER_BIOLUMINESCENT; i < n; i++) {
		video::SMaterial &m = node->getMaterial(i);
		m.MaterialType = layer_material;
		m.ZBuffer = video::ECFN_LESSEQUAL;
		m.ZWriteEnable = video::EZW_OFF;
	}
	apply(node);
}

void MinecraftWardenAnimator::apply(scene::AnimatedMeshSceneNode *node) const
{
	if (!node || !node->getMesh())
		return;
	if (node->getMesh()->getMeshType() == scene::EAMT_SKINNED) {
		auto joints = computeJoints();
		for (int j = 0; j < JOINT_COUNT; j++) {
			if (auto *bone = node->getJointNode(jointName((Joint)j)))
				bone->setTransform(joints[j]);
		}
	}

	/*
		LivingEntityEmissiveLayer: drawn unless the alpha is about 0, with
		the color ARGB.white(alpha). The EMISSIVE entity shader doesn't use
		the lightmap: blue 255 in the material color tells the object shader
		so (lightmap lighting: red and green are the light levels, blue is
		0 otherwise). Without lightmap lighting the alpha can't be passed:
		layers at alpha 0.5 and more are drawn opaque and full bright.
	*/
	auto alphas = layerAlphas();
	u32 n = std::min<u32>(node->getMaterialCount(), LAYER_COUNT);
	for (u32 i = LAYER_BIOLUMINESCENT; i < n; i++) {
		video::SMaterial &m = node->getMaterial(i);
		f32 a = alphas[i];
		bool visible = m_input.lightmap ? a > 1.0e-5f : a >= 0.5f;
		m.ColorMask = visible ? video::ECP_ALL : video::ECP_NONE;
		u32 a8 = (u32)std::clamp((int)std::floor(a * 255.0f), 0, 255);
		m.ColorParam = m_input.lightmap ? video::SColor(a8, 255, 255, 255) :
				video::SColor(255, 255, 255, 255);
	}
}
