// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "test.h"

#include "client/minecraft_warden_animator.h"
#include <cmath>

/*
	The "minecraft_warden" animation and the port of Minecraft's keyframe
	animations, against values computed by hand from the Java code
	(WardenModel, WardenAnimation, KeyframeAnimation, AnimationChannel,
	Mth.catmullrom, WalkAnimationState, Warden).
*/

class TestMinecraftWardenAnimator : public TestBase {
public:
	TestMinecraftWardenAnimator() { TestManager::registerTestModule(this); }
	const char *getName() override { return "TestMinecraftWardenAnimator"; }

	void runTests(IGameDef *gamedef) override;
	void testKeyframes();
	void testEmerge();
	void testDigLinear();
	void testWalk();
	void testHeadJoint();
	void testHeartbeat();
	void testEntityEvents();
	void testStateSerialization();
};

static TestMinecraftWardenAnimator g_test_instance;

void TestMinecraftWardenAnimator::runTests(IGameDef *gamedef)
{
	TEST(testKeyframes);
	TEST(testEmerge);
	TEST(testDigLinear);
	TEST(testWalk);
	TEST(testHeadJoint);
	TEST(testHeartbeat);
	TEST(testEntityEvents);
	TEST(testStateSerialization);
}

using MWA = MinecraftWardenAnimator;
using namespace mc_model;

static bool near(f32 a, f32 b, f32 eps = 1e-4f)
{
	return std::fabs(a - b) < eps;
}

static MWA::Input at(v3f pos)
{
	MWA::Input in;
	in.position = pos;
	return in;
}

void TestMinecraftWardenAnimator::testKeyframes()
{
	// A rotation channel: catmull-rom, then linear, then held
	static const Keyframe kf[] = {
		{0.0f, deg_vec(0, 0, 0), deg_vec(0, 0, 0), Interpolation::CATMULLROM},
		{1.0f, deg_vec(90, 0, 0), deg_vec(90, 0, 0), Interpolation::CATMULLROM},
		{2.0f, deg_vec(0, 0, 0), deg_vec(0, 0, 0), Interpolation::LINEAR},
	};
	static const Channel ch[] = {{0, Target::ROTATION, kf, 3}};
	const AnimationDefinition def{2.0f, false, ch, 1};
	const AnimationDefinition loop{2.0f, true, ch, 1};
	const f32 d90 = 90.0f * core::DEGTORAD;

	Part p;
	// Before the start: the first keyframe
	apply_animation(def, &p, -100);
	UASSERT(near(p.xRot, 0.0f));
	// t = 0.5: catmullrom(0.5, 0, 0, 90°, 0) = 0.5 (90° * 0.5 + (4 * 90°) * 0.25 - (3 * 90°) * 0.125)
	p = Part();
	apply_animation(def, &p, 500);
	UASSERT(near(p.xRot, 0.5f * (0.5f * d90 + d90 - 0.375f * d90)));
	// t = 1.5: linear (the next keyframe's interpolation) halfway
	p = Part();
	apply_animation(def, &p, 1500);
	UASSERT(near(p.xRot, 0.5f * d90));
	// After the end: the last keyframe
	p = Part();
	apply_animation(def, &p, 5000);
	UASSERT(near(p.xRot, 0.0f));
	// Looping: 2.5 s is 0.5 s; scaled by the target scale
	p = Part();
	apply_animation(loop, &p, 2500, 2.0f);
	UASSERT(near(p.xRot, 2.0f * 0.5f * (0.5f * d90 + d90 - 0.375f * d90)));
	// Offsets add to the pose
	p = Part();
	p.xRot = 1.0f;
	apply_animation(def, &p, 1000);
	UASSERT(near(p.xRot, 1.0f + d90));

	// posVec flips Y, scaleVec subtracts 1
	UASSERT(pos_vec(1, 2, 3) == v3f(1, -2, 3));
	UASSERT(scale_vec(1.5, 1, 0.5) == v3f(0.5f, 0, -0.5f));

	// AnimationState times: ticks to milliseconds, truncated
	mc_model::AnimationState st;
	UASSERT(!st.isStarted());
	st.start(10);
	UASSERT(st.getTimeInMillis(12.5f) == 125);
	st.startIfStopped(20);
	UASSERT(st.start_tick == 10);
	st.stop();
	UASSERT(!st.isStarted());
}

void TestMinecraftWardenAnimator::testEmerge()
{
	// Appearing while emerging starts the emerge animation at tick 0
	MWA a;
	::AnimationState s;
	s.pose = ::AnimationState::POSE_EMERGING;
	a.setState(s);
	for (int i = 0; i < 5; i++)
		a.step(0.05f, at(v3f(0, 10, 0)));
	a.step(0.0255f, at(v3f(0, 10, 0))); // age 5.51 ticks: 275 ms
	auto p = a.computeParts();
	UASSERT(near(p[MWA::BODY].zRot, -0.21468160f));
	UASSERT(near(p[MWA::BODY].xRot, 0.02131311f));
	UASSERT(near(p[MWA::BODY].y, 39.829022f, 1e-3f));
	UASSERT(near(p[MWA::HEAD].x, -4.8153555f, 1e-3f));
	UASSERT(near(p[MWA::HEAD].y, -6.3788862f, 1e-3f));
}

void TestMinecraftWardenAnimator::testDigLinear()
{
	// The dig animation, started by a pose change at tick 0, at 4.375 s:
	// the body rotation's last keyframe is linear
	MWA a;
	::AnimationState s;
	s.pose = ::AnimationState::POSE_DIGGING;
	a.setState(s);
	for (int i = 0; i < 87; i++)
		a.step(0.05f, at(v3f(0, 10, 0)));
	a.step(0.0255f, at(v3f(0, 10, 0))); // age 87.51 ticks: 4375 ms
	auto p = a.computeParts();
	UASSERT(near(p[MWA::BODY].xRot, 2.4401907f, 1e-3f));
	UASSERT(near(p[MWA::BODY].yRot, 0.0768916f, 1e-3f));
	UASSERT(near(p[MWA::BODY].zRot, -0.0620641f, 1e-3f));
	// A second pose change to the same pose doesn't restart it
	a.setState(s);
	UASSERT(near(a.computeParts()[MWA::BODY].xRot, 2.4401907f, 1e-3f));
}

void TestMinecraftWardenAnimator::testWalk()
{
	// 0.1 blocks per tick for 30 ticks
	MWA a;
	a.step(0.0f, at(v3f(0, 10, 0)));
	for (int i = 1; i <= 30; i++)
		a.step(0.05f, at(v3f(0.1f * i, 10, 0)));
	auto p = a.computeParts();
	UASSERT(near(p[MWA::LEFT_LEG].xRot, -0.49732834f, 1e-3f));
	UASSERT(near(p[MWA::RIGHT_LEG].xRot, 0.49732834f, 1e-3f));
	UASSERT(near(p[MWA::LEFT_ARM].xRot, 0.39786267f, 1e-3f));
	UASSERT(near(p[MWA::RIGHT_ARM].xRot, 0.04129518f, 1e-3f));
	UASSERT(near(p[MWA::BODY].xRot, -0.37287965f, 1e-3f));
	// Arms keep their rest position
	UASSERT(p[MWA::LEFT_ARM].x == 13.0f && p[MWA::RIGHT_ARM].z == 1.0f);
}

void TestMinecraftWardenAnimator::testHeadJoint()
{
	// Looking down by 0.3 rad at age 3: a corner of the head ends up where
	// Minecraft's renderer puts it (Luanti model, 10 units per node)
	MWA a;
	::AnimationState s;
	s.look_pitch = 0.3f;
	a.setState(s);
	for (int i = 0; i < 3; i++)
		a.step(0.05f, at(v3f(0, 10, 0)));
	auto j = a.computeJoints();
	core::matrix4 m = j[MWA::BONE].buildMatrix() * j[MWA::BODY].buildMatrix() *
			j[MWA::HEAD].buildMatrix();
	// The corner relative to the head's pivot in the mesh: (-8, -16, -5) pixels
	v3f v(5.0f, 10.0f, 3.125f);
	m.transformVect(v);
	UASSERT(v.getDistanceFrom(v3f(4.3794847f, 29.938112f, 6.4950509f)) < 1e-3f);
	// The head joint's own rest position (no rotations above it)
	UASSERT(j[MWA::HEAD].translation.equals(v3f(0, 13 * 0.625f, 0)));
}

void TestMinecraftWardenAnimator::testHeartbeat()
{
	// Calm: a beat every 40 ticks, the heart layer fades in 10 ticks
	MWA a;
	for (int i = 0; i < 40; i++)
		a.step(0.05f, at(v3f(0, 10, 0)));
	auto alpha = a.layerAlphas();
	UASSERT(near(alpha[MWA::LAYER_HEART], 1.0f));
	a.step(0.025f, at(v3f(0, 10, 0)));
	UASSERT(near(a.layerAlphas()[MWA::LAYER_HEART], 0.95f));
	// Angry (80 and more): every 10 ticks
	MWA b;
	::AnimationState s;
	s.anger = 80;
	b.setState(s);
	for (int i = 0; i < 9; i++)
		b.step(0.05f, at(v3f(0, 10, 0)));
	UASSERT(near(b.layerAlphas()[MWA::LAYER_HEART], 0.0f));
	b.step(0.05f, at(v3f(0, 10, 0)));
	UASSERT(near(b.layerAlphas()[MWA::LAYER_HEART], 1.0f));
	// Pulsating spots at age 10: max(0, cos(0.45) * 0.25) and the opposite phase
	auto sp = b.layerAlphas();
	UASSERT(near(sp[MWA::LAYER_SPOTS_1], std::cos(0.45f) * 0.25f));
	UASSERT(near(sp[MWA::LAYER_SPOTS_2], 0.0f));
	UASSERT(near(sp[MWA::LAYER_BIOLUMINESCENT], 1.0f));
}

void TestMinecraftWardenAnimator::testEntityEvents()
{
	MWA a;
	a.step(0.05f, at(v3f(0, 10, 0)));
	// 61: tendrils twitch, the layer rises over the rest of the tick
	a.entityEvent(61);
	UASSERT(near(a.layerAlphas()[MWA::LAYER_TENDRILS], 0.0f));
	a.step(0.025f, at(v3f(0, 10, 0)));
	UASSERT(near(a.layerAlphas()[MWA::LAYER_TENDRILS], 0.5f));
	a.step(0.025f, at(v3f(0, 10, 0))); // tick: 10 -> 9
	UASSERT(near(a.layerAlphas()[MWA::LAYER_TENDRILS], 1.0f));

	// 4 after roaring: the roar stops, the attack plays (0.33333 s)
	MWA b;
	::AnimationState s;
	s.pose = ::AnimationState::POSE_ROARING;
	b.setState(s);
	for (int i = 0; i < 20; i++)
		b.step(0.05f, at(v3f(0, 10, 0)));
	f32 roaring = b.computeParts()[MWA::HEAD].xRot;
	b.entityEvent(4);
	MWA idle;
	for (int i = 0; i < 20; i++)
		idle.step(0.05f, at(v3f(0, 10, 0)));
	// At the attack's start every channel is at its first keyframe (0)
	UASSERT(near(b.computeParts()[MWA::HEAD].xRot, idle.computeParts()[MWA::HEAD].xRot));
	UASSERT(!near(roaring, idle.computeParts()[MWA::HEAD].xRot, 1e-3f));
}

void TestMinecraftWardenAnimator::testStateSerialization()
{
	::AnimationState s;
	s.pose = ::AnimationState::POSE_SNIFFING;
	s.anger = 123;
	s.head_yaw = 0.5f;
	s.look_pitch = -0.25f;
	std::ostringstream os(std::ios::binary);
	s.serialize(os);
	std::istringstream is(os.str(), std::ios::binary);
	::AnimationState r;
	r.deSerialize(is);
	UASSERT(r == s);

	// Data of older servers ends before the new fields
	std::string old = os.str().substr(0, os.str().size() - 7);
	std::istringstream is2(old, std::ios::binary);
	::AnimationState r2;
	r2.deSerialize(is2);
	UASSERT(r2.pose == ::AnimationState::POSE_STANDING && r2.anger == 0 &&
			r2.look_pitch == -0.25f);

	UASSERT(::AnimationState::poseFromName("roaring") == ::AnimationState::POSE_ROARING);
	UASSERT(::AnimationState::poseFromName("flying") == ::AnimationState::POSE_COUNT);
}
