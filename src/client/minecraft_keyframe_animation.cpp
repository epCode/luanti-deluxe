// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "minecraft_keyframe_animation.h"
#include <algorithm>
#include <cmath>

namespace mc_model
{

core::Transform Part::localTransform(f32 units) const
{
	core::Transform t;
	// The model's axes are negated in the Luanti model, which leaves
	// rotations and scales as they are
	t.translation = v3f(-x, -y, -z) * units;
	// Quaternionf.rotationZYX(zRot, yRot, xRot) = Rz * Ry * Rx. Irrlicht's
	// quaternions rotate the other way (Transform::buildMatrix uses the
	// transposed matrix).
	core::quaternion qx(std::sin(xRot / 2), 0, 0, std::cos(xRot / 2));
	core::quaternion qy(0, std::sin(yRot / 2), 0, std::cos(yRot / 2));
	core::quaternion qz(0, 0, std::sin(zRot / 2), std::cos(zRot / 2));
	// Hamilton product a * b
	auto mul = [](const core::quaternion &a, const core::quaternion &b) {
		return core::quaternion(
			a.W * b.X + a.X * b.W + a.Y * b.Z - a.Z * b.Y,
			a.W * b.Y - a.X * b.Z + a.Y * b.W + a.Z * b.X,
			a.W * b.Z + a.X * b.Y - a.Y * b.X + a.Z * b.W,
			a.W * b.W - a.X * b.X - a.Y * b.Y - a.Z * b.Z);
	};
	core::quaternion q = mul(mul(qz, qy), qx);
	t.rotation = core::quaternion(-q.X, -q.Y, -q.Z, q.W);
	t.rotation.normalize();
	t.scale = v3f(xScale, yScale, zScale);
	return t;
}

f32 catmullrom(f32 alpha, f32 p0, f32 p1, f32 p2, f32 p3)
{
	return 0.5f * (2.0f * p1 + (p2 - p0) * alpha +
			(2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3) * alpha * alpha +
			(3.0f * p1 - p0 - 3.0f * p2 + p3) * alpha * alpha * alpha);
}

// KeyframeAnimation.Entry.apply
static void apply_channel(const Channel &ch, Part *parts, f32 seconds, f32 target_scale)
{
	const Keyframe *kf = ch.keyframes;
	const int len = (int)ch.count;
	// Mth.binarySearch: the first keyframe at or after the time
	int from = 0, n = len;
	while (n > 0) {
		int half = n / 2;
		int middle = from + half;
		if (seconds <= kf[middle].timestamp) {
			n = half;
		} else {
			from = middle + 1;
			n -= half + 1;
		}
	}
	int prev = std::max(0, from - 1);
	int next = std::min(len - 1, prev + 1);
	const Keyframe &previous = kf[prev];
	const Keyframe &following = kf[next];
	f32 delta = seconds - previous.timestamp;
	f32 alpha = 0.0f;
	if (next != prev)
		alpha = std::clamp(delta / (following.timestamp - previous.timestamp), 0.0f, 1.0f);

	v3f v;
	if (following.interpolation == Interpolation::LINEAR) {
		// Vector3f.lerp (fma) and mul
		const v3f &p0 = previous.post_target, &p1 = following.pre_target;
		v = v3f(std::fma(p1.X - p0.X, alpha, p0.X),
				std::fma(p1.Y - p0.Y, alpha, p0.Y),
				std::fma(p1.Z - p0.Z, alpha, p0.Z)) * target_scale;
	} else {
		const v3f &p0 = kf[std::max(0, prev - 1)].post_target;
		const v3f &p1 = previous.post_target;
		const v3f &p2 = following.post_target;
		const v3f &p3 = kf[std::min(len - 1, next + 1)].post_target;
		v = v3f(catmullrom(alpha, p0.X, p1.X, p2.X, p3.X) * target_scale,
				catmullrom(alpha, p0.Y, p1.Y, p2.Y, p3.Y) * target_scale,
				catmullrom(alpha, p0.Z, p1.Z, p2.Z, p3.Z) * target_scale);
	}

	Part &part = parts[ch.part];
	switch (ch.target) {
	case Target::POSITION: part.offsetPos(v); break;
	case Target::ROTATION: part.offsetRotation(v); break;
	case Target::SCALE: part.offsetScale(v); break;
	}
}

void apply_animation(const AnimationDefinition &def, Part *parts,
		s64 millis_since_start, f32 target_scale)
{
	// getElapsedSeconds
	f32 seconds = (f32)millis_since_start / 1000.0f;
	if (def.looping)
		seconds = std::fmod(seconds, def.length);
	for (size_t i = 0; i < def.count; i++)
		apply_channel(def.channels[i], parts, seconds, target_scale);
}

void apply_animation(const AnimationDefinition &def, Part *parts,
		const AnimationState &state, f32 age_in_ticks, f32 speed_factor)
{
	if (state.isStarted())
		apply_animation(def, parts,
				(s64)((f32)state.getTimeInMillis(age_in_ticks) * speed_factor), 1.0f);
}

void apply_walk(const AnimationDefinition &def, Part *parts, f32 animation_pos,
		f32 animation_speed, f32 speed_factor, f32 scale_factor)
{
	s64 time = (s64)(animation_pos * 50.0f * speed_factor);
	f32 scale = std::min(animation_speed * scale_factor, 1.0f);
	apply_animation(def, parts, time, scale);
}

f32 WalkAnimationState::getSpeed(f32 partial) const
{
	return std::min(speed_old + partial * (speed - speed_old), 1.0f);
}

f32 wrap_degrees(f32 degrees)
{
	f32 d = std::fmod(degrees, 360.0f);
	if (d >= 180.0f)
		d -= 360.0f;
	if (d < -180.0f)
		d += 360.0f;
	return d;
}

f32 rot_lerp(f32 a, f32 from, f32 to)
{
	return from + a * wrap_degrees(to - from);
}

} // namespace mc_model
