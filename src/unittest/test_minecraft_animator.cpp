// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "test.h"

#include "client/minecraft_animator.h"
#include <cmath>

/*
	The "minecraft_player" animation: the joint transforms against model
	points posed by hand from Minecraft's renderer (model space: pixels,
	+Y down, facing -Z; Luanti model: 10 units per node, 0.9375 scale,
	facing +Z).
*/

class TestMinecraftAnimator : public TestBase {
public:
	TestMinecraftAnimator() { TestManager::registerTestModule(this); }
	const char *getName() override { return "TestMinecraftAnimator"; }

	void runTests(IGameDef *gamedef) override;
	void testRestPose();
	void testHeadPitch();
	void testHeadYaw();
	void testWalk();
	void testHeldItem();
	void testOffhandCrossbow();
};

static TestMinecraftAnimator g_test_instance;

void TestMinecraftAnimator::runTests(IGameDef *gamedef)
{
	TEST(testRestPose);
	TEST(testHeadPitch);
	TEST(testHeadYaw);
	TEST(testWalk);
	TEST(testHeldItem);
	TEST(testOffhandCrossbow);
}

using MPA = MinecraftPlayerAnimator;

// Units per model pixel
static const f32 K = 9.375f / 16.0f;

// Model pixel position -> rest mesh position
static v3f rest(v3f p)
{
	return v3f(-p.X * K, (24.125f - p.Y) * K, -p.Z * K);
}

// Where a model point of a part (pixels relative to the part's rest pivot)
// ends up
static v3f posed(const core::Transform &t, v3f pivot_px, v3f point_px)
{
	v3f rel = rest(pivot_px + point_px) - rest(pivot_px);
	v3f out = rel;
	t.buildMatrix().transformVect(out);
	return out;
}

static bool close(v3f a, v3f b, f32 eps = 0.01f)
{
	return a.getDistanceFrom(b) < eps;
}

static MPA standing(f32 look_yaw = 0.0f, f32 pitch = 0.0f, int ticks = 3)
{
	MPA a;
	MPA::Input in;
	in.position = v3f(0, 10, 0);
	in.look_yaw = look_yaw;
	in.object_yaw = look_yaw;
	in.look_pitch = pitch;
	for (int i = 0; i < ticks; i++)
		a.step(0.05f, in);
	return a;
}

void TestMinecraftAnimator::testRestPose()
{
	MPA a = standing();
	auto j = a.computeJoints();
	// Head: pivot (0, 0, 0), no rotation; the top front corner of the head
	UASSERT(close(j[MPA::HEAD].translation, rest(v3f(0, 0, 0))));
	UASSERT(close(posed(j[MPA::HEAD], v3f(0, 0, 0), v3f(4, -8, -4)), rest(v3f(4, -8, -4))));
	// Legs: rotation point z = 0.1 when not sneaking
	UASSERT(close(j[MPA::LEG_RIGHT].translation, rest(v3f(-1.9f, 12, 0.1f))));
	UASSERT(close(posed(j[MPA::LEG_LEFT], v3f(1.9f, 12, 0), v3f(2, 12, -2)),
			rest(v3f(1.9f + 2, 24, 0.1f - 2))));
}

void TestMinecraftAnimator::testHeadPitch()
{
	// Looking down by 0.5 rad: Minecraft rotates the head part by xRot = 0.5
	MPA a = standing(0.0f, 0.5f);
	auto j = a.computeJoints();
	v3f face(0, -4, -4);
	f32 c = std::cos(0.5f), s = std::sin(0.5f);
	v3f expected(face.X, c * face.Y - s * face.Z, s * face.Y + c * face.Z);
	UASSERT(close(posed(j[MPA::HEAD], v3f(0, 0, 0), face), rest(expected)));
	// The face moved down and forwards in the Luanti model
	UASSERT(posed(j[MPA::HEAD], v3f(0, 0, 0), face).Y < rest(face).Y);
}

void TestMinecraftAnimator::testHeadYaw()
{
	// Standing still and turning: the body stays, the head follows the look
	// direction (the object's own +Z, since the object yaw is the look yaw)
	MPA a = standing(0.0f);
	MPA::Input in;
	in.position = v3f(0, 10, 0);
	in.look_yaw = 40.0f;
	in.object_yaw = 40.0f;
	// Rendering interpolates from the previous tick: two ticks to arrive
	a.step(0.05f, in);
	a.step(0.05f, in);
	a.step(0.0f, in);
	auto j = a.computeJoints();
	v3f nose = posed(j[MPA::HEAD], v3f(0, 0, 0), v3f(0, -4, -4)) - j[MPA::HEAD].translation;
	nose.Y = 0;
	nose.normalize();
	UASSERT(close(nose, v3f(0, 0, 1)));
	// The body still faces the old direction: 40° to the right of the look
	v3f chest = posed(j[MPA::BODY], v3f(0, 0, 0), v3f(0, 6, -2)) -
			posed(j[MPA::BODY], v3f(0, 0, 0), v3f(0, 6, 0));
	chest.normalize();
	f32 a40 = 40.0f * core::DEGTORAD;
	UASSERT(close(chest, v3f(std::sin(a40), 0, std::cos(a40))));
}

void TestMinecraftAnimator::testWalk()
{
	// Walking north at 4.3 blocks/s: after the limb swing settles, the legs
	// swing by 1.4 * limbSwingAmount * cos(limbSwing * 0.6662)
	MPA a;
	MPA::Input in;
	in.position = v3f(0, 10, 0);
	a.step(0.05f, in); // the first tick has no movement
	f32 limb = 0.0f, amount = 0.0f, prev_amount = 0.0f;
	for (int i = 0; i < 40; i++) {
		in.position.Z += 4.3f * 0.05f;
		a.step(0.05f, in);
		f32 f = std::min(4.3f * 0.05f * 4.0f, 1.0f);
		prev_amount = amount;
		amount += (f - amount) * 0.4f;
		limb += amount;
	}
	a.step(0.0f, in);
	auto j = a.computeJoints();
	// Partial tick 0: limbSwing - limbSwingAmount, the previous amount
	f32 x_rot = std::cos((limb - amount) * 0.6662f) * 1.4f * prev_amount;
	// Foot of the right leg, relative to its pivot
	v3f foot(0, 12, 0);
	f32 c = std::cos(x_rot), s = std::sin(x_rot);
	v3f expected(0, c * foot.Y, s * foot.Y);
	v3f got = posed(j[MPA::LEG_RIGHT], v3f(-1.9f, 12, 0), foot) - j[MPA::LEG_RIGHT].translation;
	v3f want = rest(expected + v3f(-1.9f, 12, 0.1f)) - rest(v3f(-1.9f, 12, 0.1f));
	UASSERT(close(got, want));
}

void TestMinecraftAnimator::testHeldItem()
{
	// A sword (handheld) in the right hand of a standing player: the blade
	// points forwards (+Z of the model), away from the hand
	MPA a;
	AnimationState st;
	st.right_arm = AnimationState::ARM_ITEM;
	st.right_item = AnimationState::ITEM_HANDHELD;
	a.setState(st);
	MPA::Input in;
	in.position = v3f(0, 10, 0);
	for (int i = 0; i < 3; i++)
		a.step(0.05f, in);
	auto j = a.computeJoints();
	// Tip and handle of a diagonal sword sprite in Luanti's wield item (20 units)
	v3f tip(8, 8, 0), handle(-8, -8, 0);
	j[MPA::WIELD_ITEM].buildMatrix().transformVect(tip);
	j[MPA::WIELD_ITEM].buildMatrix().transformVect(handle);
	v3f dir = tip - handle;
	UASSERT(dir.Z > std::abs(dir.X));
}

void TestMinecraftAnimator::testOffhandCrossbow()
{
	// A charged crossbow in the left hand is aimed: both arms forward, the
	// crossbow held level across the body in front of the chest (Minecraft's
	// crossbow model, not a flat item standing in the hand)
	MPA a;
	AnimationState st;
	st.left_arm = AnimationState::ARM_CROSSBOW_HOLD;
	st.left_item = AnimationState::ITEM_CROSSBOW;
	a.setState(st);
	MPA::Input in;
	in.position = v3f(0, 10, 0);
	for (int i = 0; i < 3; i++)
		a.step(0.05f, in);
	auto j = a.computeJoints();
	// Ends of the diagonal crossbow sprite in Luanti's wield item (20 units)
	v3f front(8, 8, 0), stock(-8, -8, 0);
	j[MPA::WIELD_ITEM_LEFT].buildMatrix().transformVect(front);
	j[MPA::WIELD_ITEM_LEFT].buildMatrix().transformVect(stock);
	v3f dir = front - stock;
	UASSERT(std::abs(dir.Y) < 0.2f * dir.getLength());
	v3f chest = rest(v3f(0, 6, 0));
	v3f mid = (front + stock) / 2;
	UASSERT(mid.Z > chest.Z + 3 && std::abs(mid.Y - chest.Y) < 3);
}
