// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "catch.h"

#include "client/transform_interpolation.h"
#include "util/numeric.h"
#include <cmath>

static f32 rotation_distance_deg(const TransformQuat &a, const TransformQuat &b)
{
	return (b * a.conjugate()).log().getLength() * core::RADTODEG;
}

static TransformSnapshot snap(f64 t, v3f pos, v3f vel, v3f rot_deg)
{
	TransformSnapshot s;
	s.time = t;
	s.pos = pos;
	s.vel = vel;
	s.rot = TransformQuat::fromObjectRotation(rot_deg);
	return s;
}

TEST_CASE("transform interpolation")
{
	SECTION("object rotations survive the quaternion round trip") {
		const v3f rots[] = {
			{0, 0, 0}, {0, 90, 0}, {0, 359, 0}, {30, 200, 10},
			{-45, 10, 170}, {80, 300, -60}, {0, 180, 180},
		};
		for (v3f rot : rots) {
			TransformQuat q = TransformQuat::fromObjectRotation(rot);
			TransformQuat q2 = TransformQuat::fromObjectRotation(q.toObjectRotation());
			CHECK(rotation_distance_deg(q, q2) < 0.01f);

			// Same matrix as GenericCAO builds
			core::matrix4 a, b;
			setPitchYawRoll(a, -rot);
			q.toMatrix(b);
			for (int i : {0, 1, 2, 4, 5, 6, 8, 9, 10})
				CHECK(std::fabs(a[i] - b[i]) < 1e-5f);
		}
	}

	SECTION("irrlicht rotations match setRotationDegrees") {
		v3f rot(20, -70, 135);
		core::matrix4 a, b;
		a.setRotationDegrees(rot);
		TransformQuat::fromIrrlichtRotation(rot).toMatrix(b);
		for (int i : {0, 1, 2, 4, 5, 6, 8, 9, 10})
			CHECK(std::fabs(a[i] - b[i]) < 1e-5f);
	}

	SECTION("steady turning is played back at a steady rate") {
		// 10 degrees per 0.05 s step (Minecraft boat at full turn),
		// crossing 360 -> 0
		TransformInterpolator ip;
		for (int i = 0; i < 20; i++) {
			f32 yaw = std::fmod(300.0f + 10.0f * i, 360.0f);
			ip.push(snap(i * 0.05, v3f(0), v3f(0), v3f(0, yaw, 0)), -1.0);
		}
		f32 prev_yaw = 0.0f;
		for (int k = 0; k <= 100; k++) {
			f64 t = 0.1 + k * 0.007; // not aligned with the steps
			auto s = ip.sample(t);
			f32 expected = 300.0f + 200.0f * (f32)t;
			v3f rot = s.rot.toObjectRotation();
			CHECK(std::fabs(wrapDegrees_180(rot.Y - expected)) < 0.01f);
			CHECK(std::fabs(rot.X) < 0.01f);
			CHECK(std::fabs(wrapDegrees_180(rot.Z)) < 0.01f);
			if (k > 0) {
				// Constant angular speed: 200 deg/s * 7 ms
				CHECK(std::fabs(wrapDegrees_180(rot.Y - prev_yaw) - 1.4f) < 0.01f);
			}
			prev_yaw = rot.Y;
		}
	}

	SECTION("constant velocity and accelerated motion") {
		TransformInterpolator ip;
		for (int i = 0; i < 10; i++)
			ip.push(snap(i * 0.1, v3f(i * 2.0f, 0, 0), v3f(20, 0, 0), v3f(0)), -1.0);
		auto s = ip.sample(0.437);
		CHECK(std::fabs(s.pos.X - 8.74f) < 1e-3f);
		CHECK(std::fabs(s.vel.X - 20.0f) < 1e-2f);

		// Falling: p = -g t^2 / 2, v = -g t (exact for a cubic)
		TransformInterpolator fall;
		const f32 g = 98.0f;
		for (int i = 0; i < 10; i++) {
			f32 t = i * 0.05f;
			fall.push(snap(t, v3f(0, -0.5f * g * t * t, 0), v3f(0, -g * t, 0), v3f(0)), -1.0);
		}
		f32 t = 0.23f;
		auto f = fall.sample(t);
		CHECK(std::fabs(f.pos.Y + 0.5f * g * t * t) < 1e-3f);
	}

	SECTION("a pause is held instead of being spread out") {
		TransformInterpolator ip;
		ip.push(snap(0.0, v3f(0), v3f(0), v3f(0)), -1.0);
		// Nothing changed until 3.0, then the object moved within one step
		ip.push(snap(3.05, v3f(1, 0, 0), v3f(20, 0, 0), v3f(0, 10, 0)), 3.0);
		CHECK(ip.sample(1.5).pos.X == 0.0f);
		CHECK(ip.sample(2.99).pos.X == 0.0f);
		CHECK(ip.sample(3.025).pos.X > 0.0f);
		CHECK(ip.sample(3.1).pos.X == 1.0f);
	}

	SECTION("no overshoot when pushing against a wall") {
		TransformInterpolator ip;
		for (int i = 0; i < 5; i++)
			ip.push(snap(i * 0.05, v3f(5, 0, 0), v3f(40, 0, 0), v3f(0)), -1.0);
		for (int k = 0; k < 20; k++)
			CHECK(std::fabs(ip.sample(0.01 * k).pos.X - 5.0f) < 1e-4f);
	}

	SECTION("players: tangents from the movement") {
		TransformInterpolator ip;
		for (int i = 0; i < 10; i++) {
			TransformSnapshot s = snap(i * 0.1, v3f(i * 1.0f, 0, 0), v3f(0), v3f(0));
			s.has_vel = false;
			ip.push(s, -1.0);
		}
		CHECK(std::fabs(ip.sample(0.333).pos.X - 3.33f) < 1e-3f);
	}

	SECTION("clock follows the server and wraps around") {
		TransformInterpolationClock clock;
		u32 base = 0xFFFFFF00u; // wraps after 256 ms
		f64 first = clock.toServerTime(base);
		for (int i = 0; i < 200; i++) {
			u32 ms = base + i * 50;
			f64 t = clock.toServerTime(ms);
			CHECK(std::fabs((t - first) - i * 0.05) < 1e-6);
			// 60 FPS; packets arrive with up to two frames of jitter
			int arrive = i % 3;
			for (int f = 0; f < 3; f++) {
				if (f == arrive)
					clock.onSnapshot(t, 0.05f);
				clock.step(1.0f / 60.0f);
			}
		}
		f64 newest = clock.toServerTime(base + 199 * 50);
		f64 behind = newest - clock.getRenderTime();
		CHECK(behind > 0.0);
		CHECK(behind < 0.2);
	}

	// 60 FPS client, server steps every 50 ms arriving at once; returns the
	// largest playback advance in one frame after the pause, and how far
	// playback is behind the newest data at the end
	auto run_clock = [](bool idle) {
		TransformInterpolationClock clock;
		const f32 frame = 1.0f / 60.0f;
		f64 now = 0.0, server = 0.0, prev_server = 0.0;
		f64 last_render = -1.0, max_advance = 0.0;
		for (int i = 0; i < 120; i++) {
			// Step 60: a 250 ms server hitch, or (idle) 1 s in which the
			// server ran steps but nothing moved
			f64 gap = i == 60 ? (idle ? 1.0 : 0.25) : 0.05;
			server += gap;
			while (now + frame <= server) {
				clock.step(frame);
				now += frame;
				CHECK(clock.getRenderTime() >= last_render);
				if (i > 60 && last_render >= 0.0)
					max_advance = std::max(max_advance,
							clock.getRenderTime() - last_render);
				last_render = clock.getRenderTime();
			}
			f64 hold = idle && i == 60 ? server - 0.05 : prev_server;
			clock.onSnapshot(server, 0.05f, hold);
			CHECK(clock.getRenderTime() <= server);
			if (i == 60)
				max_advance = std::max(max_advance, clock.getRenderTime() - last_render);
			prev_server = server;
		}
		return std::make_pair(max_advance, server - clock.getRenderTime());
	};

	SECTION("clock waits through a server hitch instead of snapping ahead") {
		auto [max_advance, behind] = run_clock(false);
		// Never more than 10% faster than real time
		CHECK(max_advance <= 1.1 / 60.0 + 1e-6);
		CHECK(behind < 0.2);
	}

	SECTION("clock skips ahead after a pause in which nothing moved") {
		auto [max_advance, behind] = run_clock(true);
		CHECK(max_advance > 0.5);
		CHECK(behind < 0.2);
	}
}
