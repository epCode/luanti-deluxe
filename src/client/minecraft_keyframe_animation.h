// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "irrlichttypes.h"
#include "irr_v3d.h"
#include <Transform.h>
#include <climits>
#include <cstddef>

/*
	Minecraft's model parts and keyframe animations (Java Edition 26.3:
	ModelPart, PartPose, KeyframeAnimation, AnimationChannel, Keyframe,
	AnimationDefinition, KeyframeAnimations, AnimationState), shared by the
	procedural animations of Minecraft models.

	Units as in Minecraft: part positions in model pixels (+Y down, the
	model facing -Z), angles in radians, times in seconds.
*/
namespace mc_model
{

/// ModelPart: the pose of one part relative to its parent
struct Part
{
	f32 x = 0, y = 0, z = 0;
	f32 xRot = 0, yRot = 0, zRot = 0;
	f32 xScale = 1, yScale = 1, zScale = 1;

	void offsetPos(v3f v) { x += v.X; y += v.Y; z += v.Z; }
	void offsetRotation(v3f v) { xRot += v.X; yRot += v.Y; zRot += v.Z; }
	void offsetScale(v3f v) { xScale += v.X; yScale += v.Y; zScale += v.Z; }

	/// Transform relative to the parent part in a Luanti model made with
	/// `units` mesh units per model pixel (the model's axes negated, see
	/// games/mineclonia/tools/mc_warden_model.py): ModelPart.translateAndRotate
	core::Transform localTransform(f32 units) const;
};

enum class Interpolation : u8 { LINEAR, CATMULLROM };
enum class Target : u8 { POSITION, ROTATION, SCALE };

struct Keyframe
{
	f32 timestamp;
	v3f pre_target, post_target;
	Interpolation interpolation;
};

struct Channel
{
	/// Index of the animated part
	u8 part;
	Target target;
	const Keyframe *keyframes;
	size_t count;
};

struct AnimationDefinition
{
	f32 length; // seconds
	bool looping;
	const Channel *channels;
	size_t count;
};

/// KeyframeAnimations.posVec, degreeVec and scaleVec
constexpr v3f pos_vec(f32 x, f32 y, f32 z) { return v3f(x, -y, z); }
constexpr v3f deg_vec(f32 x, f32 y, f32 z)
{
	constexpr f32 d = (f32)(3.14159265358979323846 / 180.0);
	return v3f(x * d, y * d, z * d);
}
constexpr v3f scale_vec(double x, double y, double z)
{
	return v3f((f32)(x - 1.0), (f32)(y - 1.0), (f32)(z - 1.0));
}

/// Mth.catmullrom
f32 catmullrom(f32 alpha, f32 p0, f32 p1, f32 p2, f32 p3);

/// KeyframeAnimation.apply(millisSinceStart, targetScale): adds the
/// animation's offsets to the parts
void apply_animation(const AnimationDefinition &def, Part *parts,
		s64 millis_since_start, f32 target_scale = 1.0f);

/// Minecraft's AnimationState (net.minecraft.world.entity): the tick an
/// animation started at
struct AnimationState
{
	static constexpr s32 STOPPED = INT_MIN;
	s32 start_tick = STOPPED;

	void start(s32 tick_count) { start_tick = tick_count; }
	void startIfStopped(s32 tick_count)
	{
		if (!isStarted())
			start(tick_count);
	}
	void animateWhen(bool condition, s32 tick_count)
	{
		if (condition)
			startIfStopped(tick_count);
		else
			stop();
	}
	void stop() { start_tick = STOPPED; }
	bool isStarted() const { return start_tick != STOPPED; }
	s64 getTimeInMillis(f32 age_in_ticks) const
	{
		f32 time_in_ticks = age_in_ticks - (f32)start_tick;
		return (s64)(time_in_ticks * 50.0f);
	}
};

/// KeyframeAnimation.apply(AnimationState, currentTime, speedFactor)
void apply_animation(const AnimationDefinition &def, Part *parts,
		const AnimationState &state, f32 age_in_ticks, f32 speed_factor = 1.0f);

/// KeyframeAnimation.applyWalk
void apply_walk(const AnimationDefinition &def, Part *parts, f32 animation_pos,
		f32 animation_speed, f32 speed_factor, f32 scale_factor);

/// Minecraft's WalkAnimationState
struct WalkAnimationState
{
	f32 speed_old = 0, speed = 0, position = 0, position_scale = 1;

	void update(f32 target_speed, f32 factor, f32 pos_scale)
	{
		speed_old = speed;
		speed += (target_speed - speed) * factor;
		position += speed;
		position_scale = pos_scale;
	}
	void stop() { speed_old = speed = position = 0; }
	f32 getSpeed(f32 partial) const;
	f32 getPosition(f32 partial) const
	{
		return (position - speed * (1.0f - partial)) * position_scale;
	}
};

/// Mth.wrapDegrees
f32 wrap_degrees(f32 degrees);
/// Mth.rotLerp
f32 rot_lerp(f32 a, f32 from, f32 to);

} // namespace mc_model
