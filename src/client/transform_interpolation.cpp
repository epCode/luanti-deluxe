// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "transform_interpolation.h"
#include "util/numeric.h"
#include <algorithm>
#include <cmath>

/*
	TransformQuat
*/

TransformQuat TransformQuat::fromMatrix(const core::matrix4 &m)
{
	const f32 *M = m.pointer();
	auto R = [M](int r, int c) { return M[r * 4 + c]; };
	TransformQuat q;
	f32 trace = R(0, 0) + R(1, 1) + R(2, 2);
	if (trace > 0.0f) {
		f32 s = std::sqrt(trace + 1.0f) * 2.0f;
		q.w = 0.25f * s;
		q.x = (R(2, 1) - R(1, 2)) / s;
		q.y = (R(0, 2) - R(2, 0)) / s;
		q.z = (R(1, 0) - R(0, 1)) / s;
	} else if (R(0, 0) > R(1, 1) && R(0, 0) > R(2, 2)) {
		f32 s = std::sqrt(1.0f + R(0, 0) - R(1, 1) - R(2, 2)) * 2.0f;
		q.w = (R(2, 1) - R(1, 2)) / s;
		q.x = 0.25f * s;
		q.y = (R(0, 1) + R(1, 0)) / s;
		q.z = (R(0, 2) + R(2, 0)) / s;
	} else if (R(1, 1) > R(2, 2)) {
		f32 s = std::sqrt(1.0f + R(1, 1) - R(0, 0) - R(2, 2)) * 2.0f;
		q.w = (R(0, 2) - R(2, 0)) / s;
		q.x = (R(0, 1) + R(1, 0)) / s;
		q.y = 0.25f * s;
		q.z = (R(1, 2) + R(2, 1)) / s;
	} else {
		f32 s = std::sqrt(1.0f + R(2, 2) - R(0, 0) - R(1, 1)) * 2.0f;
		q.w = (R(1, 0) - R(0, 1)) / s;
		q.x = (R(0, 2) + R(2, 0)) / s;
		q.y = (R(1, 2) + R(2, 1)) / s;
		q.z = 0.25f * s;
	}
	q.normalize();
	return q;
}

TransformQuat TransformQuat::fromObjectRotation(v3f rot_deg)
{
	// Same as GenericCAO::updateNodePos
	core::matrix4 m;
	setPitchYawRoll(m, -rot_deg);
	return fromMatrix(m);
}

TransformQuat TransformQuat::fromIrrlichtRotation(v3f rot_deg)
{
	core::matrix4 m;
	m.setRotationDegrees(rot_deg);
	return fromMatrix(m);
}

void TransformQuat::toMatrix(core::matrix4 &m) const
{
	f32 *M = m.pointer();
	auto set = [M](int r, int c, f32 v) { M[r * 4 + c] = v; };
	set(0, 0, 1.0f - 2.0f * (y * y + z * z));
	set(0, 1, 2.0f * (x * y - z * w));
	set(0, 2, 2.0f * (x * z + y * w));
	set(1, 0, 2.0f * (x * y + z * w));
	set(1, 1, 1.0f - 2.0f * (x * x + z * z));
	set(1, 2, 2.0f * (y * z - x * w));
	set(2, 0, 2.0f * (x * z - y * w));
	set(2, 1, 2.0f * (y * z + x * w));
	set(2, 2, 1.0f - 2.0f * (x * x + y * y));
}

v3f TransformQuat::toObjectRotation() const
{
	core::matrix4 m;
	toMatrix(m);
	return wrapDegrees_0_360_v3f(-getPitchYawRoll(m));
}

TransformQuat TransformQuat::operator*(const TransformQuat &o) const
{
	return {
		w * o.w - x * o.x - y * o.y - z * o.z,
		w * o.x + x * o.w + y * o.z - z * o.y,
		w * o.y - x * o.z + y * o.w + z * o.x,
		w * o.z + x * o.y - y * o.x + z * o.w,
	};
}

void TransformQuat::normalize()
{
	f32 len = std::sqrt(w * w + x * x + y * y + z * z);
	if (len < 1e-12f) {
		*this = TransformQuat();
		return;
	}
	w /= len; x /= len; y /= len; z /= len;
}

v3f TransformQuat::log() const
{
	// q and -q are the same rotation: take the shorter way round
	f32 sw = w, sx = x, sy = y, sz = z;
	if (sw < 0.0f) {
		sw = -sw; sx = -sx; sy = -sy; sz = -sz;
	}
	f32 vlen = std::sqrt(sx * sx + sy * sy + sz * sz);
	if (vlen < 1e-7f)
		return v3f(sx, sy, sz) * 2.0f;
	f32 angle = 2.0f * std::atan2(vlen, sw);
	return v3f(sx, sy, sz) * (angle / vlen);
}

TransformQuat TransformQuat::exp(v3f r)
{
	f32 angle = r.getLength();
	if (angle < 1e-7f) {
		TransformQuat q(1.0f, r.X * 0.5f, r.Y * 0.5f, r.Z * 0.5f);
		q.normalize();
		return q;
	}
	f32 s = std::sin(angle * 0.5f) / angle;
	return {std::cos(angle * 0.5f), r.X * s, r.Y * s, r.Z * s};
}

TransformQuat TransformQuat::slerp(const TransformQuat &a, const TransformQuat &b, f32 t)
{
	TransformQuat q = exp((b * a.conjugate()).log() * t) * a;
	q.normalize();
	return q;
}

/*
	TransformInterpolationClock
*/

f64 TransformInterpolationClock::toServerTime(u32 server_ms)
{
	if (!m_have_stamp) {
		m_have_stamp = true;
		m_last_raw = server_ms;
		m_last_unwrapped = server_ms / 1000.0;
		return m_last_unwrapped;
	}
	// Signed difference: survives the wrap-around and reordered packets
	s32 diff = (s32)(server_ms - m_last_raw);
	f64 t = m_last_unwrapped + diff / 1000.0;
	if (diff > 0) {
		m_last_raw = server_ms;
		m_last_unwrapped = t;
	}
	return t;
}

void TransformInterpolationClock::onSnapshot(f64 t, f32 send_interval)
{
	f64 offset = m_client_time - t;
	if (!m_valid) {
		m_valid = true;
		m_offset = offset;
		m_newest = t;
		m_jitter = 0.0f;
		if (send_interval > 0.0f)
			m_spacing = rangelim(send_interval, 0.001f, 1.0f);
		m_delay = m_spacing + 0.01f;
		m_render_time = t - m_delay;
		return;
	}

	// A faster packet than any before: that is the real offset
	if (offset < m_offset)
		m_offset = offset;
	m_jitter = std::max(m_jitter, (f32)(offset - m_offset));

	if (t <= m_newest + 1e-6)
		return; // another object of the same server step

	// Once per server step: time between updates (long pauses mean that
	// nothing moved), slow adaption to a server that runs behind real time,
	// and slowly forgetting old jitter. The delay only changes here, so
	// that playback runs at a steady speed between updates.
	f32 max_spacing = std::max(send_interval, 0.001f) * 2.0f;
	f32 spacing = std::min((f32)(t - m_newest), max_spacing);
	if (spacing > m_spacing)
		m_spacing = spacing;
	else
		m_spacing += (spacing - m_spacing) * 0.02f;
	m_newest = t;
	m_offset += (offset - m_offset) * 0.002;
	m_jitter *= 0.99f;
	m_delay = std::min(m_spacing + m_jitter + 0.01f, 1.0f);
}

void TransformInterpolationClock::step(f32 dtime)
{
	m_client_time += dtime;
	if (!m_valid)
		return;

	f64 target = m_client_time - m_offset - m_delay;
	f64 err = target - m_render_time;
	if (std::fabs(err) > 0.5) {
		m_render_time = target;
		return;
	}
	// Run up to 10% faster or slower until the target is reached, ignoring
	// errors below the resolution of frame and packet timing; never run
	// backwards.
	f64 rate = 1.0;
	if (std::fabs(err) > 0.002)
		rate = rangelim(1.0 + err * 2.0, 0.9, 1.1);
	m_render_time += dtime * rate;
}

/*
	TransformInterpolator
*/

void TransformInterpolator::reset(const TransformSnapshot &s)
{
	m_snapshots.clear();
	m_snapshots.push_back(s);
}

void TransformInterpolator::push(const TransformSnapshot &s, f64 hold_time)
{
	if (m_snapshots.empty()) {
		m_snapshots.push_back(s);
		return;
	}
	const TransformSnapshot &last = m_snapshots.back();
	if (s.time < last.time - 1e-6)
		return; // reordered packet, superseded
	if (s.time <= last.time + 1e-6) {
		m_snapshots.back() = s; // several updates in one server step
		return;
	}
	if (hold_time > last.time + 1e-4 && hold_time < s.time - 1e-4) {
		// The object stood still until hold_time: don't spread the next
		// movement over the whole pause.
		TransformSnapshot hold = last;
		hold.time = hold_time;
		hold.vel = v3f(0.0f);
		m_snapshots.push_back(hold);
	}
	m_snapshots.push_back(s);
	while (m_snapshots.size() > 64)
		m_snapshots.pop_front();
}

// Limits a Hermite tangent so that the curve can't overshoot noticeably
// (Fritsch-Carlson bound: three times the chord).
static v3f limit_tangent(v3f tangent, f32 chord_length)
{
	f32 limit = 3.0f * chord_length;
	f32 len = tangent.getLength();
	if (len > limit)
		return len > 1e-9f ? tangent * (limit / len) : v3f(0.0f);
	return tangent;
}

TransformInterpolator::Sample TransformInterpolator::sample(f64 t)
{
	Sample out;
	if (m_snapshots.empty())
		return out;

	// Keep one snapshot before the current segment for the rotation tangent
	while (m_snapshots.size() >= 3 && m_snapshots[2].time <= t)
		m_snapshots.pop_front();

	const TransformSnapshot &first = m_snapshots.front();
	const TransformSnapshot &last = m_snapshots.back();
	if (t <= first.time || m_snapshots.size() == 1) {
		const TransformSnapshot &s = t <= first.time ? first : last;
		out.pos = s.pos;
		out.vel = v3f(0.0f);
		out.rot = s.rot;
		return out;
	}
	if (t >= last.time) {
		out.pos = last.pos;
		out.vel = v3f(0.0f);
		out.rot = last.rot;
		return out;
	}

	size_t i = 0;
	while (i + 1 < m_snapshots.size() && m_snapshots[i + 1].time <= t)
		i++;
	const TransformSnapshot &a = m_snapshots[i];
	const TransformSnapshot &b = m_snapshots[i + 1];
	f32 dt = b.time - a.time;
	f32 s = rangelim((f32)((t - a.time) / dt), 0.0f, 1.0f);

	f32 s2 = s * s, s3 = s2 * s;
	f32 h00 = 2 * s3 - 3 * s2 + 1, h10 = s3 - 2 * s2 + s;
	f32 h01 = -2 * s3 + 3 * s2,    h11 = s3 - s2;
	f32 d00 = 6 * s2 - 6 * s,      d10 = 3 * s2 - 4 * s + 1;
	f32 d01 = -6 * s2 + 6 * s,     d11 = 3 * s2 - 2 * s;

	// Position: cubic Hermite with the velocities the server reported
	v3f chord = b.pos - a.pos;
	f32 chord_len = chord.getLength();
	v3f ta = a.vel * dt, tb = b.vel * dt;
	if (!a.has_vel || !b.has_vel) {
		// Same scheme as for the rotation below
		tb = chord;
		ta = chord;
		if (i > 0) {
			const TransformSnapshot &p = m_snapshots[i - 1];
			f32 dtp = a.time - p.time;
			if (dtp > 1e-4f)
				ta = (a.pos - p.pos) * (dt / dtp);
		}
	}
	ta = limit_tangent(ta, chord_len);
	tb = limit_tangent(tb, chord_len);
	out.pos = a.pos * h00 + ta * h10 + b.pos * h01 + tb * h11;
	out.vel = (a.pos * d00 + ta * d10 + b.pos * d01 + tb * d11) / dt;

	// Rotation: Hermite in the tangent space of a's rotation. The angular
	// velocity at a snapshot is the one of the segment that ends there, so
	// consecutive segments join without a kink (exact for steady turning).
	v3f c = (b.rot * a.rot.conjugate()).log();
	v3f ma = c;
	if (i > 0) {
		const TransformSnapshot &p = m_snapshots[i - 1];
		f32 dtp = a.time - p.time;
		if (dtp > 1e-4f)
			ma = (a.rot * p.rot.conjugate()).log() * (dt / dtp);
	}
	ma = limit_tangent(ma, c.getLength());
	v3f v = ma * h10 + c * (h01 + h11);
	out.rot = TransformQuat::exp(v) * a.rot;
	out.rot.normalize();
	return out;
}
