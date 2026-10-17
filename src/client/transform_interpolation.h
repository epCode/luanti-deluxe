// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

/*
	Visual transform interpolation for active objects
	(object property `transform_interpolation`).

	The server stamps every position update with its simulation time and, for
	interpolated objects, sends an update at every send opportunity while
	anything changes. The client plays the received snapshots back slightly
	delayed on a clock that follows the server's, so position, velocity and
	rotation on all three axes are interpolated between two known states
	instead of being extrapolated or approached step by step. Turning stays
	smooth at any server tick rate.
*/

#pragma once

#include "irrlichttypes.h"
#include "irr_v3d.h"
#include <matrix4.h>
#include <deque>

// Unit quaternion (w, x, y, z), converted to and from the rotation part of
// an Irrlicht matrix with R[row][col] = M[row * 4 + col].
struct TransformQuat
{
	f32 w = 1.0f, x = 0.0f, y = 0.0f, z = 0.0f;

	TransformQuat() = default;
	TransformQuat(f32 w, f32 x, f32 y, f32 z) : w(w), x(x), y(y), z(z) {}

	static TransformQuat fromMatrix(const core::matrix4 &m);
	// Object rotation as used by GenericCAO (degrees, pitch/yaw/roll)
	static TransformQuat fromObjectRotation(v3f rot_deg);
	// Irrlicht euler rotation in degrees (attachment rotations)
	static TransformQuat fromIrrlichtRotation(v3f rot_deg);

	// Writes the rotation into the upper 3x3 of m, keeps the translation.
	void toMatrix(core::matrix4 &m) const;
	// Inverse of fromObjectRotation, wrapped to [0, 360)
	v3f toObjectRotation() const;

	TransformQuat operator*(const TransformQuat &o) const;
	TransformQuat conjugate() const { return {w, -x, -y, -z}; }
	void normalize();

	// Rotation vector (axis * angle in radians), shortest arc
	v3f log() const;
	static TransformQuat exp(v3f rotvec);

	static TransformQuat slerp(const TransformQuat &a, const TransformQuat &b, f32 t);
};

struct TransformSnapshot
{
	f64 time = 0.0;      // server time in seconds
	v3f pos;             // BS units
	v3f vel;             // BS units / s
	// false: velocity unknown (players), the movement between the
	// neighbouring snapshots gives the tangent instead
	bool has_vel = true;
	TransformQuat rot;
};

/*
	Playback clock, shared by all objects of a client environment so that
	objects stay in sync with each other. It tracks the offset between the
	client clock and the server timestamps (the fastest packet sets the
	baseline), the arrival jitter and the spacing of server updates, and plays
	back far enough behind the newest data that the next snapshot has
	normally arrived before it is needed.
*/
class TransformInterpolationClock
{
public:
	// Unwraps a 32-bit millisecond timestamp to server seconds.
	f64 toServerTime(u32 server_ms);
	// Records the arrival of a snapshot taken at server time `t`.
	void onSnapshot(f64 t, f32 send_interval);
	void step(f32 dtime);

	bool isValid() const { return m_valid; }
	f64 getRenderTime() const { return m_render_time; }
	// Playback delay behind the newest data the clock aims for, in seconds
	f32 getDelay() const { return m_delay; }

private:
	bool m_have_stamp = false;
	u32 m_last_raw = 0;
	f64 m_last_unwrapped = 0.0;

	f64 m_client_time = 0.0;
	bool m_valid = false;
	f64 m_offset = 0.0;      // client time - server time, baseline
	f64 m_newest = 0.0;      // newest server time seen
	f32 m_jitter = 0.0f;
	f32 m_spacing = 0.05f;   // time between server updates
	f32 m_delay = 0.06f;
	f64 m_render_time = 0.0;
};

/*
	Snapshot buffer of one object.
*/
class TransformInterpolator
{
public:
	bool empty() const { return m_snapshots.empty(); }
	void clear() { m_snapshots.clear(); }

	// Teleport: forget the history.
	void reset(const TransformSnapshot &s);
	// `hold_time`: the latest server time at which the object was known to
	// still be in the state of the previous snapshot (the server had nothing
	// to send then because nothing changed).
	void push(const TransformSnapshot &s, f64 hold_time);

	struct Sample {
		v3f pos;
		v3f vel;
		TransformQuat rot;
	};
	// Evaluates the transform at server time t and drops snapshots that are
	// no longer needed. Before the first snapshot and after the last one the
	// object holds still: a missing update means that nothing changed.
	Sample sample(f64 t);

	const TransformSnapshot &newest() const { return m_snapshots.back(); }

private:
	std::deque<TransformSnapshot> m_snapshots;
};
