// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "minecraft_animator.h"
#include <AnimatedMeshSceneNode.h>
#include <BoneSceneNode.h>
#include <IAnimatedMesh.h>
#include <algorithm>
#include <cmath>

/*
	Names follow Minecraft's code: angles of model parts in radians,
	entity rotations in degrees, positions of model parts in pixels with +Y
	down, the model facing -Z. Entity positions use Minecraft's axes
	(+Z south): a Luanti position (x, y, z) is (x, y, -z), and a Luanti yaw
	φ is the Minecraft yaw 180° - φ.
*/

static constexpr double PI = 3.14159265358979323846;
static constexpr f32 PI_F = (f32)PI;
static constexpr f32 TICK = 0.05f;

namespace {

// 4x4 matrix acting on column vectors
struct M4
{
	double m[4][4];

	static M4 identity()
	{
		M4 r{};
		for (int i = 0; i < 4; i++)
			r.m[i][i] = 1;
		return r;
	}

	M4 operator*(const M4 &o) const
	{
		M4 r{};
		for (int i = 0; i < 4; i++)
		for (int j = 0; j < 4; j++)
		for (int k = 0; k < 4; k++)
			r.m[i][j] += m[i][k] * o.m[k][j];
		return r;
	}

	static M4 translate(double x, double y, double z)
	{
		M4 r = identity();
		r.m[0][3] = x; r.m[1][3] = y; r.m[2][3] = z;
		return r;
	}

	static M4 scale(double x, double y, double z)
	{
		M4 r = identity();
		r.m[0][0] = x; r.m[1][1] = y; r.m[2][2] = z;
		return r;
	}

	// glRotate about a coordinate axis, angle in radians
	static M4 rotX(double a)
	{
		M4 r = identity();
		double c = std::cos(a), s = std::sin(a);
		r.m[1][1] = c; r.m[1][2] = -s; r.m[2][1] = s; r.m[2][2] = c;
		return r;
	}
	static M4 rotY(double a)
	{
		M4 r = identity();
		double c = std::cos(a), s = std::sin(a);
		r.m[0][0] = c; r.m[0][2] = s; r.m[2][0] = -s; r.m[2][2] = c;
		return r;
	}
	static M4 rotZ(double a)
	{
		M4 r = identity();
		double c = std::cos(a), s = std::sin(a);
		r.m[0][0] = c; r.m[0][1] = -s; r.m[1][0] = s; r.m[1][1] = c;
		return r;
	}
	static M4 rotXDeg(double a) { return rotX(a * PI / 180); }
	static M4 rotYDeg(double a) { return rotY(a * PI / 180); }
	static M4 rotZDeg(double a) { return rotZ(a * PI / 180); }
};

// A model part (ModelRenderer): rotation point and angles
struct Part
{
	f32 x = 0, y = 0, z = 0;
	f32 xRot = 0, yRot = 0, zRot = 0;

	// ModelRenderer.render/postRender: translate, then rotate Z, Y, X
	M4 matrix() const
	{
		return M4::translate(x / 16.0, y / 16.0, z / 16.0) *
				M4::rotZ(zRot) * M4::rotY(yRot) * M4::rotX(xRot);
	}
};

// MathHelper.wrapAngleTo180_float
f32 wrap_degrees(f32 f)
{
	f = std::fmod(f, 360.0f);
	if (f >= 180.0f)
		f -= 360.0f;
	if (f < -180.0f)
		f += 360.0f;
	return f;
}

// RendererLivingEntity.interpolateRotation
f32 interpolate_rotation(f32 prev, f32 cur, f32 partial)
{
	f32 d = cur - prev;
	while (d < -180.0f)
		d += 360.0f;
	while (d >= 180.0f)
		d -= 360.0f;
	return prev + partial * d;
}

// HumanoidModel.rotlerpRad (1.14)
f32 rotlerp_rad(f32 a, f32 b, f32 t)
{
	f32 d = std::fmod(b - a, 2 * PI_F);
	if (d < -PI_F)
		d += 2 * PI_F;
	if (d >= PI_F)
		d -= 2 * PI_F;
	return a + t * d;
}

f32 quadratic_arm_update(f32 f)
{
	return -65.0f * f + f * f;
}

f32 lerp(f32 t, f32 a, f32 b)
{
	return a + t * (b - a);
}

// Keeps a continuous angle: the value equal to `angle` (mod 360) nearest to `near`
f32 continuous_degrees(f32 near, f32 angle)
{
	return near + wrap_degrees(angle - near);
}

core::Transform to_transform(const M4 &j_in)
{
	core::Transform t;
	t.translation = v3f(j_in.m[0][3], j_in.m[1][3], j_in.m[2][3]);
	// Uniform scale (items in hand)
	const auto &a = j_in.m;
	double det = a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) -
			a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
			a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]);
	double scale = std::cbrt(det);
	M4 j = j_in;
	if (std::abs(scale - 1.0) > 1e-6 && scale > 0) {
		for (int r = 0; r < 3; r++)
		for (int c = 0; c < 3; c++)
			j.m[r][c] /= scale;
		t.scale = v3f(scale);
	}
	// Rotation matrix to quaternion (Irrlicht's quaternions rotate the other
	// way: Transform::buildMatrix uses the transposed matrix)
	const auto &r = j.m;
	double tr = r[0][0] + r[1][1] + r[2][2];
	double x, y, z, w;
	if (tr > 0) {
		double s = std::sqrt(tr + 1.0) * 2;
		w = 0.25 * s;
		x = (r[2][1] - r[1][2]) / s;
		y = (r[0][2] - r[2][0]) / s;
		z = (r[1][0] - r[0][1]) / s;
	} else if (r[0][0] > r[1][1] && r[0][0] > r[2][2]) {
		double s = std::sqrt(1.0 + r[0][0] - r[1][1] - r[2][2]) * 2;
		w = (r[2][1] - r[1][2]) / s;
		x = 0.25 * s;
		y = (r[0][1] + r[1][0]) / s;
		z = (r[0][2] + r[2][0]) / s;
	} else if (r[1][1] > r[2][2]) {
		double s = std::sqrt(1.0 + r[1][1] - r[0][0] - r[2][2]) * 2;
		w = (r[0][2] - r[2][0]) / s;
		x = (r[0][1] + r[1][0]) / s;
		y = 0.25 * s;
		z = (r[1][2] + r[2][1]) / s;
	} else {
		double s = std::sqrt(1.0 + r[2][2] - r[0][0] - r[1][1]) * 2;
		w = (r[1][0] - r[0][1]) / s;
		x = (r[0][2] + r[2][0]) / s;
		y = (r[1][2] + r[2][1]) / s;
		z = 0.25 * s;
	}
	t.rotation = core::quaternion(-x, -y, -z, w);
	t.rotation.normalize();
	return t;
}

// Luanti's wield item visual at visual_size 1: flat items are 20 units
// wide, blocks 15, centered, front facing -Z
M4 luanti_item(AnimationState::ItemDisplay display)
{
	double unit = display == AnimationState::ITEM_BLOCK ? 15.0 : 20.0;
	return M4::scale(1 / unit, 1 / unit, -1 / unit);
}

struct ItemDisplayTransform
{
	double rot[3], trans[3], scale;
};

// Item models' "thirdperson" display (Minecraft 1.8)
const ItemDisplayTransform &display_18(AnimationState::ItemDisplay d)
{
	static const ItemDisplayTransform generated{{-90, 0, 0}, {0, 1, -3}, 0.55};
	static const ItemDisplayTransform handheld{{0, 90, -35}, {0, 1.25, -3.5}, 0.85};
	static const ItemDisplayTransform block{{10, -45, 170}, {0, 1.5, -2.75}, 0.375};
	static const ItemDisplayTransform bow{{5, 80, -45}, {0.75, 0, 0.25}, 1.0};
	static const ItemDisplayTransform rod{{180, 90, -35}, {0, 0, -3.5}, 0.85};
	switch (d) {
	case AnimationState::ITEM_HANDHELD: return handheld;
	case AnimationState::ITEM_BLOCK: return block;
	case AnimationState::ITEM_BOW: return bow;
	case AnimationState::ITEM_HANDHELD_ROD: return rod;
	default: return generated;
	}
}

// Whether 1.8 has the item model, else the item is shown as in newer versions
bool has_display_18(AnimationState::ItemDisplay d)
{
	return d != AnimationState::ITEM_CROSSBOW && d != AnimationState::ITEM_TRIDENT &&
			d != AnimationState::ITEM_SPYGLASS;
}

// RenderItem.renderItemModelForEntity (1.8): from the hand to the item model
M4 item_display_18(AnimationState::ItemDisplay d)
{
	const ItemDisplayTransform &t = display_18(d);
	// preTransform: flat items are drawn twice as large
	double pre = d == AnimationState::ITEM_BLOCK ? 1.0 : 2.0;
	return M4::scale(pre, pre, pre) *
			M4::translate(t.trans[0] / 16, t.trans[1] / 16, t.trans[2] / 16) *
			M4::rotYDeg(t.rot[1]) * M4::rotXDeg(t.rot[0]) * M4::rotZDeg(t.rot[2]) *
			M4::scale(t.scale, t.scale, t.scale) *
			// RenderItem.renderItem
			M4::scale(0.5, 0.5, 0.5) * luanti_item(d);
}

// Item models' "thirdperson_righthand" and "thirdperson_lefthand" display
// (1.14; the left hand uses the right hand's when the model has none).
// A trident being charged is the trident_throwing model.
const ItemDisplayTransform &display_114(AnimationState::ItemDisplay d, bool left,
		bool throwing = false)
{
	static const ItemDisplayTransform generated{{0, 0, 0}, {0, 3, 1}, 0.55};
	static const ItemDisplayTransform block{{75, 45, 0}, {0, 2.5, 0}, 0.375};
	static const ItemDisplayTransform handheld[2] = {
		{{0, -90, 55}, {0, 4, 0.5}, 0.85}, {{0, 90, -55}, {0, 4, 0.5}, 0.85}};
	static const ItemDisplayTransform bow[2] = {
		{{-80, 260, -40}, {-1, -2, 2.5}, 0.9}, {{-80, -280, 40}, {-1, -2, 2.5}, 0.9}};
	static const ItemDisplayTransform rod[2] = {
		{{0, 90, 55}, {0, 4, 2.5}, 0.85}, {{0, -90, -55}, {0, 4, 2.5}, 0.85}};
	static const ItemDisplayTransform crossbow[2] = {
		{{-90, 0, -60}, {2, 0.1, -3}, 0.9}, {{-90, 0, 30}, {2, 0.1, -3}, 0.9}};
	static const ItemDisplayTransform trident[2] = {
		{{0, 60, 0}, {11, 17, -2}, 1}, {{0, 60, 0}, {3, 17, 12}, 1}};
	static const ItemDisplayTransform trident_throwing[2] = {
		{{0, 90, 180}, {8, -17, 9}, 1}, {{0, 90, 180}, {8, -17, -7}, 1}};
	static const ItemDisplayTransform spyglass{{0, 0, 0}, {0, -2, 0}, 1};
	switch (d) {
	case AnimationState::ITEM_HANDHELD: return handheld[left];
	case AnimationState::ITEM_BLOCK: return block;
	case AnimationState::ITEM_BOW: return bow[left];
	case AnimationState::ITEM_HANDHELD_ROD: return rod[left];
	case AnimationState::ITEM_CROSSBOW: return crossbow[left];
	case AnimationState::ITEM_TRIDENT: return throwing ? trident_throwing[left] : trident[left];
	case AnimationState::ITEM_SPYGLASS: return spyglass;
	default: return generated;
	}
}

// Where Luanti's flat sprites of items with 3D models in Minecraft sit in
// the item model's space (centered, in item widths)
M4 model_sprite(AnimationState::ItemDisplay d)
{
	switch (d) {
	case AnimationState::ITEM_TRIDENT:
		// TridentModel (prongs up, pixels -4 to 27) under the item's
		// transformation scale(1, -1, -1), centered on the item; the sprite is
		// the trident seen from the side, 5/16 x 2 item widths, centered
		return M4::translate(-0.5, -1.25, -0.5);
	case AnimationState::ITEM_SPYGLASS:
		// spyglass_in_hand: a tube along Y, 11 pixels long, through the
		// center, the eyepiece at +Y; the sprite is diagonal, eyepiece to the
		// bottom left, and turned about the tube to face sideways like the
		// tube's sides
		return M4::rotYDeg(90) * M4::rotZDeg(-135) * M4::scale(0.6, 0.6, 0.6);
	default:
		return M4::identity();
	}
}

// ItemTransform.apply (the left hand mirrored) and ItemRenderer.render (1.14)
M4 apply_item_transform(const ItemDisplayTransform &t, AnimationState::ItemDisplay d, bool left)
{
	// Quaternion(x, y, z) is Rx * Ry * Rz; the left hand negates y, z and x translation
	double m = left ? -1 : 1;
	return M4::translate(m * t.trans[0] / 16, t.trans[1] / 16, t.trans[2] / 16) *
			M4::rotXDeg(t.rot[0]) * M4::rotYDeg(m * t.rot[1]) * M4::rotZDeg(m * t.rot[2]) *
			M4::scale(t.scale, t.scale, t.scale) * model_sprite(d) * luanti_item(d);
}

M4 item_display_114(AnimationState::ItemDisplay d, bool left, bool throwing = false)
{
	return apply_item_transform(display_114(d, left, throwing), d, left);
}

} // namespace

const char *MinecraftPlayerAnimator::jointName(Joint j)
{
	static const char *names[JOINT_COUNT] = {
		"Head", "Body", "Arm_Right", "Arm_Left", "Leg_Right", "Leg_Left",
		"Armor_Arm_Right", "Armor_Arm_Left", "Cape", "Elytra_Left", "Elytra_Right",
		"Wield_Item", "Wield_Item_Left",
	};
	return names[j];
}

void MinecraftPlayerAnimator::setState(const AnimationState &state)
{
	m_state = state;
}

bool MinecraftPlayerAnimator::sneaking() const
{
	if (m_state.swimming || m_state.sleeping)
		return false;
	return m_state.sneaking || m_local_sneaking.value_or(false);
}

bool MinecraftPlayerAnimator::digging() const
{
	return m_local_digging.value_or(m_state.digging);
}

// EntityLivingBase.swingItem
void MinecraftPlayerAnimator::swing()
{
	int end = m_state.swing_duration;
	if (!m_swing_in_progress || m_swing_ticks >= end / 2 || m_swing_ticks < 0) {
		m_swing_ticks = -1;
		m_swing_in_progress = true;
	}
}

static v3f to_minecraft(v3f p)
{
	return v3f(p.X, p.Y, -p.Z);
}

void MinecraftPlayerAnimator::step(f32 dtime, const Input &input)
{
	m_input = input;
	if (!m_have_input) {
		m_have_input = true;
		m_pos = m_prev_pos = m_chasing = m_prev_chasing = to_minecraft(input.position);
		m_yaw = m_prev_yaw = m_head_yaw = m_prev_head_yaw =
				m_body_yaw = m_prev_body_yaw = 180.0f - input.look_yaw;
		m_pitch = m_prev_pitch = input.look_pitch * 180.0f / PI_F;
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

	// The local player's rotation follows the mouse every frame
	if (m_input.local) {
		m_yaw = continuous_degrees(m_yaw, 180.0f - m_input.look_yaw);
		m_pitch = m_input.look_pitch * 180.0f / PI_F;
	}

	// Elytra wings, approached every frame (ElytraModel.setupAnim, 1.14)
	f32 rx = PI_F / 12, rz = -PI_F / 12, ry = 0.0f;
	if (m_state.fall_flying) {
		f32 f = 1.0f;
		if (m_motion.Y < 0.0f) {
			v3f n = m_motion;
			n.normalize();
			f = 1.0f - std::pow(-n.Y, 1.5f);
		}
		rx = f * (PI_F / 9) + (1.0f - f) * rx;
		rz = f * (-PI_F / 2) + (1.0f - f) * rz;
	} else if (sneaking()) {
		rx = 2 * PI_F / 9;
		rz = -PI_F / 4;
		ry = 0.08726646f;
	}
	m_elytra_rot.X += (rx - m_elytra_rot.X) * 0.1f;
	m_elytra_rot.Y += (ry - m_elytra_rot.Y) * 0.1f;
	m_elytra_rot.Z += (rz - m_elytra_rot.Z) * 0.1f;
}

void MinecraftPlayerAnimator::tick()
{
	// Entity.onEntityUpdate: previous values
	m_prev_pos = m_pos;
	m_prev_body_yaw = m_body_yaw;
	m_prev_head_yaw = m_head_yaw;
	m_prev_yaw = m_yaw;
	m_prev_pitch = m_pitch;
	m_prev_swing_progress = m_swing_progress;
	m_prev_swim = m_swim;
	m_prev_chasing = m_chasing;
	m_prev_camera_yaw = m_camera_yaw;
	m_prev_walked = m_walked;

	m_pos = to_minecraft(m_input.position);
	m_yaw = continuous_degrees(m_yaw, 180.0f - m_input.look_yaw);
	m_pitch = m_input.look_pitch * 180.0f / PI_F;
	m_head_yaw = m_yaw; // EntityPlayer: rotationYawHead = rotationYaw
	m_motion = m_pos - m_prev_pos;

	// Minecraft.sendClickBlockToController: swing every tick while hitting
	if (digging())
		swing();

	// EntityLivingBase.updateArmSwingProgress
	int end = m_state.swing_duration;
	if (m_swing_in_progress) {
		m_swing_ticks++;
		if (m_swing_ticks >= end) {
			m_swing_ticks = 0;
			m_swing_in_progress = false;
		}
	} else {
		m_swing_ticks = 0;
	}
	m_swing_progress = (f32)m_swing_ticks / end;

	// Limb swing (EntityLivingBase.moveEntityWithHeading, EntityOtherPlayerMP.onUpdate)
	f32 dx = m_pos.X - m_prev_pos.X, dz = m_pos.Z - m_prev_pos.Z;
	m_prev_limb_swing_amount = m_limb_swing_amount;
	f32 f = std::min(std::sqrt(dx * dx + dz * dz) * 4.0f, 1.0f);
	m_limb_swing_amount += (f - m_limb_swing_amount) * 0.4f;
	m_limb_swing += m_limb_swing_amount;

	// Camera bob, used by the cape (EntityPlayer.onLivingUpdate; other
	// players have no motion on the client)
	f32 bob = 0.0f;
	if (m_input.local) {
		bob = std::min(std::sqrt(dx * dx + dz * dz), 0.1f);
		if (!m_input.on_ground || m_state.dead)
			bob = 0.0f;
		if (m_input.on_ground && !m_state.riding)
			m_walked += std::sqrt(dx * dx + dz * dz) * 0.6f;
	}
	m_camera_yaw += (bob - m_camera_yaw) * 0.4f;

	// Body rotation (EntityLivingBase.onUpdate, updateDistance)
	f32 target = m_body_yaw;
	if (dx * dx + dz * dz > 0.0025000002f)
		target = std::atan2(dz, dx) * 180.0f / PI_F - 90.0f;
	if (m_swing_progress > 0.0f)
		target = m_yaw;
	m_body_yaw += wrap_degrees(target - m_body_yaw) * 0.3f;
	f32 f3 = wrap_degrees(m_yaw - m_body_yaw);
	if (f3 < -75.0f)
		f3 = -75.0f;
	if (f3 >= 75.0f)
		f3 = 75.0f;
	m_body_yaw = m_yaw - f3;
	if (f3 * f3 > 2500.0f)
		m_body_yaw += f3 * 0.2f;
	m_prev_body_yaw = continuous_degrees(m_body_yaw, m_prev_body_yaw);
	m_prev_head_yaw = continuous_degrees(m_head_yaw, m_prev_head_yaw);

	// Cape (EntityPlayer.onUpdate)
	v3f d = m_pos - m_chasing;
	if (std::abs(d.X) > 10.0f)
		m_prev_chasing.X = m_chasing.X = m_pos.X;
	if (std::abs(d.Y) > 10.0f)
		m_prev_chasing.Y = m_chasing.Y = m_pos.Y;
	if (std::abs(d.Z) > 10.0f)
		m_prev_chasing.Z = m_chasing.Z = m_pos.Z;
	m_chasing += (m_pos - m_chasing) * 0.25f;

	// 1.14: swimming pose, gliding
	if (m_state.swimming)
		m_swim = std::min(1.0f, m_swim + 0.09f);
	else
		m_swim = std::max(0.0f, m_swim - 0.09f);
	m_fall_flying_ticks = m_state.fall_flying ? m_fall_flying_ticks + 1 : 0;

	// Dying (EntityLivingBase.onDeathUpdate)
	if (m_state.dead)
		m_death_time = std::min(m_death_time + 1, 20);
	else
		m_death_time = 0;

	// Item use (crossbow charging)
	AnimationState::ArmPose use = AnimationState::ARM_EMPTY;
	if (m_state.right_arm == AnimationState::ARM_CROSSBOW_CHARGE ||
			m_state.left_arm == AnimationState::ARM_CROSSBOW_CHARGE)
		use = AnimationState::ARM_CROSSBOW_CHARGE;
	m_use_ticks = (use != AnimationState::ARM_EMPTY && use == m_use_pose) ? m_use_ticks + 1 : 0;
	m_use_pose = use;

	m_ticks++;
}

std::array<core::Transform, MinecraftPlayerAnimator::JOINT_COUNT>
MinecraftPlayerAnimator::computeJoints() const
{
	using AS = AnimationState;
	const f32 p = m_partial;
	const bool sneak = sneaking();
	const bool slim = m_input.slim;

	// RendererLivingEntity.doRender
	f32 limb_amount = std::min(lerp(p, m_prev_limb_swing_amount, m_limb_swing_amount), 1.0f);
	f32 limb = m_limb_swing - m_limb_swing_amount * (1.0f - p);
	f32 body_yaw = interpolate_rotation(m_prev_body_yaw, m_body_yaw, p);
	f32 head_yaw = interpolate_rotation(m_prev_head_yaw, m_head_yaw, p);
	if (m_state.riding && m_input.mount_yaw) {
		f32 mount = 180.0f - *m_input.mount_yaw;
		f32 f5 = wrap_degrees(head_yaw - mount);
		if (f5 < -85.0f)
			f5 = -85.0f;
		if (f5 >= 85.0f)
			f5 = 85.0f;
		body_yaw = head_yaw - f5;
		if (f5 * f5 > 2500.0f)
			body_yaw += f5 * 0.2f;
	}
	f32 pitch = lerp(p, m_prev_pitch, m_pitch);
	// GuiInventory.drawEntityOnScreen: the player faces the cursor
	f32 inventory_tilt = 0.0f;
	if (m_input.inventory_cursor) {
		f32 mx = std::atan(m_input.inventory_cursor->X / 40.0f);
		f32 my = std::atan(m_input.inventory_cursor->Y / 40.0f);
		body_yaw = m_input.inventory_yaw + mx * 20.0f;
		head_yaw = m_input.inventory_yaw + mx * 40.0f;
		pitch = -my * 20.0f;
		inventory_tilt = -my * 20.0f;
	}
	f32 net_head_yaw = head_yaw - body_yaw;
	f32 age = m_ticks + p;
	f32 swing = m_swing_progress - m_prev_swing_progress;
	if (swing < 0.0f)
		swing += 1.0f;
	swing = m_prev_swing_progress + swing * p;
	f32 swim = lerp(p, m_prev_swim, m_swim);

	// ModelBiped/ModelPlayer constructors
	f32 arm_y = slim ? 2.5f : 2.0f;
	Part head, body, right_arm{-5, arm_y, 0}, left_arm{5, arm_y, 0},
			right_leg{-1.9f, 12, 0}, left_leg{1.9f, 12, 0};

	// setRotationAngles (1.8), with the additions of 1.14
	const bool flying = m_fall_flying_ticks > 4;
	head.yRot = net_head_yaw * PI_F / 180.0f;
	if (flying)
		head.xRot = -PI_F / 4;
	else if (swim > 0.0f)
		head.xRot = rotlerp_rad(pitch * PI_F / 180.0f,
				m_state.swimming ? -PI_F / 4 : pitch * PI_F / 180.0f, swim);
	else
		head.xRot = pitch * PI_F / 180.0f;

	f32 f6 = 1.0f;
	if (flying) {
		f6 = m_motion.getLengthSQ() / 0.2f;
		f6 = f6 * f6 * f6;
	}
	if (f6 < 1.0f)
		f6 = 1.0f;
	right_arm.xRot = std::cos(limb * 0.6662f + PI_F) * 2.0f * limb_amount * 0.5f / f6;
	left_arm.xRot = std::cos(limb * 0.6662f) * 2.0f * limb_amount * 0.5f / f6;
	right_leg.xRot = std::cos(limb * 0.6662f) * 1.4f * limb_amount / f6;
	left_leg.xRot = std::cos(limb * 0.6662f + PI_F) * 1.4f * limb_amount / f6;

	if (m_state.riding) {
		right_arm.xRot += -PI_F / 5;
		left_arm.xRot += -PI_F / 5;
		right_leg.xRot = -PI_F * 2.0f / 5.0f;
		left_leg.xRot = -PI_F * 2.0f / 5.0f;
		right_leg.yRot = PI_F / 10;
		left_leg.yRot = -PI_F / 10;
	}

	switch (m_state.left_arm) {
	case AS::ARM_BLOCK:
		left_arm.xRot = left_arm.xRot * 0.5f - 0.9424779f;
		left_arm.yRot = PI_F / 6;
		break;
	case AS::ARM_ITEM:
		left_arm.xRot = left_arm.xRot * 0.5f - PI_F / 10;
		break;
	default:
		break;
	}
	switch (m_state.right_arm) {
	case AS::ARM_ITEM:
	case AS::ARM_BOW: // 1.8: heldItemRight = 1 while aiming
		right_arm.xRot = right_arm.xRot * 0.5f - PI_F / 10;
		break;
	case AS::ARM_BLOCK: // 1.8: heldItemRight = 3
		right_arm.xRot = right_arm.xRot * 0.5f - PI_F / 10 * 3;
		right_arm.yRot = -PI_F / 6;
		break;
	case AS::ARM_THROW_SPEAR:
		right_arm.xRot = right_arm.xRot * 0.5f - PI_F;
		break;
	default:
		break;
	}
	if (m_state.left_arm == AS::ARM_THROW_SPEAR && m_state.right_arm != AS::ARM_BLOCK &&
			m_state.right_arm != AS::ARM_THROW_SPEAR && m_state.right_arm != AS::ARM_BOW) {
		left_arm.xRot = left_arm.xRot * 0.5f - PI_F;
		left_arm.yRot = 0.0f;
	}

	if (swing > 0.0f) {
		body.yRot = std::sin(std::sqrt(swing) * PI_F * 2.0f) * 0.2f;
		right_arm.z = std::sin(body.yRot) * 5.0f;
		right_arm.x = -std::cos(body.yRot) * 5.0f;
		left_arm.z = -std::sin(body.yRot) * 5.0f;
		left_arm.x = std::cos(body.yRot) * 5.0f;
		right_arm.yRot += body.yRot;
		left_arm.yRot += body.yRot;
		left_arm.xRot += body.yRot;
		f32 f7 = 1.0f - swing;
		f7 *= f7;
		f7 *= f7;
		f7 = 1.0f - f7;
		f32 f8 = std::sin(f7 * PI_F);
		f32 f9 = std::sin(swing * PI_F) * -(head.xRot - 0.7f) * 0.75f;
		right_arm.xRot = (f32)(right_arm.xRot - (f8 * 1.2 + f9));
		right_arm.yRot += body.yRot * 2.0f;
		right_arm.zRot += std::sin(swing * PI_F) * -0.4f;
	}

	if (sneak) {
		body.xRot = 0.5f;
		right_arm.xRot += 0.4f;
		left_arm.xRot += 0.4f;
		right_leg.z = 4.0f;
		left_leg.z = 4.0f;
		right_leg.y = 9.0f;
		left_leg.y = 9.0f;
		head.y = 1.0f;
	} else {
		right_leg.z = 0.1f;
		left_leg.z = 0.1f;
	}

	auto idle_bob = [&]() {
		right_arm.zRot += std::cos(age * 0.09f) * 0.05f + 0.05f;
		left_arm.zRot -= std::cos(age * 0.09f) * 0.05f + 0.05f;
		right_arm.xRot += std::sin(age * 0.067f) * 0.05f;
		left_arm.xRot -= std::sin(age * 0.067f) * 0.05f;
	};
	idle_bob();

	if (m_state.right_arm == AS::ARM_BOW) {
		// 1.8 aimedBow
		right_arm.zRot = 0.0f;
		left_arm.zRot = 0.0f;
		right_arm.yRot = -0.1f + head.yRot;
		left_arm.yRot = 0.1f + head.yRot + 0.4f;
		right_arm.xRot = -PI_F / 2 + head.xRot;
		left_arm.xRot = -PI_F / 2 + head.xRot;
		idle_bob();
	} else if (m_state.left_arm == AS::ARM_BOW && m_state.right_arm != AS::ARM_THROW_SPEAR &&
			m_state.right_arm != AS::ARM_BLOCK) {
		right_arm.yRot = -0.1f + head.yRot - 0.4f;
		left_arm.yRot = 0.1f + head.yRot;
		right_arm.xRot = -PI_F / 2 + head.xRot;
		left_arm.xRot = -PI_F / 2 + head.xRot;
	}

	// Crossbows (1.14)
	f32 charge = std::max(m_state.use_duration * 20.0f, 1.0f);
	f32 used = std::clamp((f32)m_use_ticks, 0.0f, charge);
	if (m_state.right_arm == AS::ARM_CROSSBOW_CHARGE) {
		right_arm.yRot = -0.8f;
		right_arm.xRot = -0.97079635f;
		left_arm.xRot = -0.97079635f;
		left_arm.yRot = lerp(used / charge, 0.4f, 0.85f);
		left_arm.xRot = lerp(used / charge, left_arm.xRot, -PI_F / 2);
	} else if (m_state.left_arm == AS::ARM_CROSSBOW_CHARGE) {
		left_arm.yRot = 0.8f;
		right_arm.xRot = -0.97079635f;
		left_arm.xRot = -0.97079635f;
		right_arm.yRot = lerp(used / charge, -0.4f, -0.85f);
		right_arm.xRot = lerp(used / charge, right_arm.xRot, -PI_F / 2);
	}
	if (m_state.right_arm == AS::ARM_CROSSBOW_HOLD && swing <= 0.0f) {
		right_arm.yRot = -0.3f + head.yRot;
		left_arm.yRot = 0.6f + head.yRot;
		right_arm.xRot = -PI_F / 2 + head.xRot + 0.1f;
		left_arm.xRot = -1.5f + head.xRot;
	} else if (m_state.left_arm == AS::ARM_CROSSBOW_HOLD) {
		right_arm.yRot = -0.6f + head.yRot;
		left_arm.yRot = 0.3f + head.yRot;
		right_arm.xRot = -1.5f + head.xRot;
		left_arm.xRot = -PI_F / 2 + head.xRot + 0.1f;
	}

	// Spyglass (1.17)
	auto spyglass_x = [&]() {
		return std::clamp(head.xRot - 1.9198622f - (sneak ? 0.2617994f : 0.0f), -2.4f, 3.3f);
	};
	if (m_state.right_arm == AS::ARM_SPYGLASS) {
		right_arm.xRot = spyglass_x();
		right_arm.yRot = head.yRot - 0.2617994f;
	}
	if (m_state.left_arm == AS::ARM_SPYGLASS) {
		left_arm.xRot = spyglass_x();
		left_arm.yRot = head.yRot + 0.2617994f;
	}

	// Swimming (1.14)
	if (swim > 0.0f) {
		f32 f13 = std::fmod(limb, 26.0f);
		f32 f14 = swing > 0.0f ? 0.0f : swim;
		if (f13 < 14.0f) {
			left_arm.xRot = rotlerp_rad(left_arm.xRot, 0.0f, swim);
			right_arm.xRot = lerp(f14, right_arm.xRot, 0.0f);
			left_arm.yRot = rotlerp_rad(left_arm.yRot, PI_F, swim);
			right_arm.yRot = lerp(f14, right_arm.yRot, PI_F);
			left_arm.zRot = rotlerp_rad(left_arm.zRot, PI_F + 1.8707964f *
					quadratic_arm_update(f13) / quadratic_arm_update(14.0f), swim);
			right_arm.zRot = lerp(f14, right_arm.zRot, PI_F - 1.8707964f *
					quadratic_arm_update(f13) / quadratic_arm_update(14.0f));
		} else if (f13 < 22.0f) {
			f32 f16 = (f13 - 14.0f) / 8.0f;
			left_arm.xRot = rotlerp_rad(left_arm.xRot, PI_F / 2 * f16, swim);
			right_arm.xRot = lerp(f14, right_arm.xRot, PI_F / 2 * f16);
			left_arm.yRot = rotlerp_rad(left_arm.yRot, PI_F, swim);
			right_arm.yRot = lerp(f14, right_arm.yRot, PI_F);
			left_arm.zRot = rotlerp_rad(left_arm.zRot, 5.012389f - 1.8707964f * f16, swim);
			right_arm.zRot = lerp(f14, right_arm.zRot, 1.2707963f + 1.8707964f * f16);
		} else if (f13 < 26.0f) {
			f32 f15 = (f13 - 22.0f) / 4.0f;
			left_arm.xRot = rotlerp_rad(left_arm.xRot, PI_F / 2 - PI_F / 2 * f15, swim);
			right_arm.xRot = lerp(f14, right_arm.xRot, PI_F / 2 - PI_F / 2 * f15);
			left_arm.yRot = rotlerp_rad(left_arm.yRot, PI_F, swim);
			right_arm.yRot = lerp(f14, right_arm.yRot, PI_F);
			left_arm.zRot = rotlerp_rad(left_arm.zRot, PI_F, swim);
			right_arm.zRot = lerp(f14, right_arm.zRot, PI_F);
		}
		left_leg.xRot = lerp(swim, left_leg.xRot, 0.3f * std::cos(limb * 0.33333334f + PI_F));
		right_leg.xRot = lerp(swim, right_leg.xRot, 0.3f * std::cos(limb * 0.33333334f));
	}

	// Entity rotations (RendererLivingEntity.rotateCorpse, RenderPlayer,
	// PlayerRenderer.setupRotations of 1.14), around the feet, Minecraft axes
	f32 pitch_now = m_pitch;
	M4 world = M4::identity();
	if (m_input.inventory_cursor) {
		// The whole player leans towards the cursor, around the axis
		// across the view
		world = M4::rotYDeg(-m_input.inventory_yaw) * M4::rotXDeg(inventory_tilt) *
				M4::rotYDeg(m_input.inventory_yaw);
	}
	if (sneak && !m_input.local)
		world = M4::translate(0, -0.125, 0);
	if (m_state.sleeping && !m_state.dead) {
		// Bed orientation: the direction from the foot to the head of the bed
		f32 a = m_state.sleep_yaw * PI_F / 180.0f;
		f32 bed = std::atan2(-std::cos(a), std::sin(a)) * 180.0f / PI_F;
		world = world * M4::rotYDeg(bed) * M4::rotZDeg(90) * M4::rotYDeg(270);
	} else {
		world = world * M4::rotYDeg(180.0f - body_yaw);
		if (m_death_time > 0) {
			f32 f = std::sqrt((m_death_time + p - 1.0f) / 20.0f * 1.6f);
			world = world * M4::rotZDeg(std::min(f, 1.0f) * 90.0f);
		} else if (m_state.spin_attack) {
			world = world * M4::rotXDeg(-90.0f - pitch_now) * M4::rotYDeg((m_ticks + p) * -75.0f);
		}
		if (m_state.fall_flying) {
			f32 t = m_fall_flying_ticks + p;
			f32 f5 = std::clamp(t * t / 100.0f, 0.0f, 1.0f);
			if (!m_state.spin_attack)
				world = world * M4::rotXDeg(f5 * (-90.0f - pitch_now));
			// Entity.getVectorForRotation
			f32 yr = -m_yaw * PI_F / 180.0f - PI_F, pr = -pitch_now * PI_F / 180.0f;
			v3f view(std::sin(yr) * -std::cos(pr), std::sin(pr), std::cos(yr) * -std::cos(pr));
			double d0 = m_motion.X * m_motion.X + m_motion.Z * m_motion.Z;
			double d1 = view.X * view.X + view.Z * view.Z;
			if (d0 > 0.0 && d1 > 0.0) {
				double d2 = (m_motion.X * view.X + m_motion.Z * view.Z) / (std::sqrt(d0) * std::sqrt(d1));
				double d3 = m_motion.X * view.Z - m_motion.Z * view.X;
				d2 = std::clamp(d2, -1.0, 1.0);
				world = world * M4::rotYDeg((f32)((d3 > 0 ? 1 : d3 < 0 ? -1 : 0) * std::acos(d2)) * 180.0f / PI_F);
			}
		} else if (swim > 0.0f) {
			f32 f6 = m_state.in_water ? -90.0f - pitch_now : -90.0f;
			world = world * M4::rotXDeg(lerp(swim, 0.0f, f6));
			if (m_state.swimming)
				world = world * M4::translate(0, -1, 0.3);
		}
	}
	world = world * M4::scale(-1, -1, 1) * M4::scale(0.9375, 0.9375, 0.9375) *
			M4::translate(0, -1.5078125, 0);

	// Minecraft object-relative axes to the model: the scene node is
	// rotated by the object yaw, Luanti's Z points north, 10 units per node,
	// and model vertices are relative to the joints' rest positions
	f32 object_yaw = 180.0f - m_input.object_yaw;
	M4 out = M4::scale(10, 10, -10) * M4::rotYDeg(object_yaw - 180.0f) * world;
	M4 in = M4::scale(-1 / 9.375, -1 / 9.375, -1 / 9.375);
	M4 model_sneak = sneak ? M4::translate(0, 0.2, 0) : M4::identity();

	std::array<core::Transform, JOINT_COUNT> joints;
	auto part = [&](Joint j, const Part &prt) {
		joints[j] = to_transform(out * model_sneak * prt.matrix() * in);
	};
	part(HEAD, head);
	part(BODY, body);
	part(ARM_RIGHT, right_arm);
	part(ARM_LEFT, left_arm);
	part(LEG_RIGHT, right_leg);
	part(LEG_LEFT, left_leg);
	// The armor model (ModelBiped) keeps its arms' rotation point height
	Part armor_right = right_arm, armor_left = left_arm;
	armor_right.y = armor_left.y = 2.0f;
	part(ARMOR_ARM_RIGHT, armor_right);
	part(ARMOR_ARM_LEFT, armor_left);

	// Cape (LayerCape, 1.8)
	{
		v3f pos = m_prev_pos + (m_pos - m_prev_pos) * p;
		v3f chase = m_prev_chasing + (m_chasing - m_prev_chasing) * p;
		double d0 = chase.X - pos.X, d1 = chase.Y - pos.Y, d2 = chase.Z - pos.Z;
		f32 f7 = m_prev_body_yaw + (m_body_yaw - m_prev_body_yaw) * p;
		double d3 = std::sin(f7 * PI_F / 180.0f);
		double d4 = -std::cos(f7 * PI_F / 180.0f);
		f32 f8 = std::clamp((f32)d1 * 10.0f, -6.0f, 32.0f);
		f32 f9 = (f32)(d0 * d3 + d2 * d4) * 100.0f;
		f32 f10 = (f32)(d0 * d4 - d2 * d3) * 100.0f;
		if (f9 < 0.0f)
			f9 = 0.0f;
		f32 f11 = lerp(p, m_prev_camera_yaw, m_camera_yaw);
		f8 += std::sin(lerp(p, m_prev_walked, m_walked) * 6.0f) * 32.0f * f11;
		if (sneak)
			f8 += 25.0f;
		Part cape{0, sneak ? 2.0f : 0.0f, 0};
		joints[CAPE] = to_transform(out * M4::translate(0, 0, 0.125) *
				M4::rotXDeg(6.0f + f9 / 2.0f + f8) * M4::rotZDeg(f10 / 2.0f) *
				M4::rotYDeg(-f10 / 2.0f) * M4::rotYDeg(180) * cape.matrix() * in);
	}

	// Elytra (ElytraLayer and ElytraModel, 1.14)
	{
		f32 y = (!m_state.fall_flying && sneak) ? 3.0f : 0.0f;
		Part left{5, y, 0, m_elytra_rot.X, m_elytra_rot.Y, m_elytra_rot.Z};
		Part right{-5, y, 0, m_elytra_rot.X, -m_elytra_rot.Y, -m_elytra_rot.Z};
		M4 layer = out * M4::translate(0, 0, 0.125);
		joints[ELYTRA_LEFT] = to_transform(layer * left.matrix() * in);
		joints[ELYTRA_RIGHT] = to_transform(layer * right.matrix() * in);
	}

	// Items in hand (ItemInHandLayer, 1.14)
	auto held_114 = [&](Part arm, bool left, AnimationState::ItemDisplay d,
			AnimationState::ArmPose pose) {
		if (pose == AnimationState::ARM_SPYGLASS && swing <= 0.0f) {
			// Held to the eye (PlayerItemInHandLayer.renderItemHeldToEye, 1.17):
			// the "head" display on the head, the pitch clamped
			static const ItemDisplayTransform on_head{{90, 0, 0}, {0, 0, -16}, 1.6};
			Part h = head;
			h.xRot = std::clamp(h.xRot, -PI_F / 6, PI_F / 2);
			// CustomHeadLayer.translateToHead
			M4 m = out * h.matrix() * M4::translate(0, -0.25, 0) * M4::rotYDeg(180) *
					M4::scale(0.625, 0.625, 0.625) * M4::rotXDeg(180) *
					M4::translate((left ? -2.5 : 2.5) / 16.0, -0.0625, 0);
			return to_transform(m * apply_item_transform(on_head, d, false));
		}
		if (slim)
			arm.x += left ? -0.5f : 0.5f; // PlayerModel.translateToHand
		M4 m = out * (sneak ? M4::translate(0, 0.2, 0) : M4::identity()) * arm.matrix() *
				M4::rotXDeg(-90) * M4::rotYDeg(180) *
				M4::translate((left ? -1 : 1) / 16.0, 0.125, -0.625);
		return to_transform(m * item_display_114(d, left,
				pose == AnimationState::ARM_THROW_SPEAR));
	};

	// Item in the right hand (LayerHeldItem, 1.8). Wield_Item holds the item
	// model's space: Luanti's wield item visual (visual_size 1) is attached to it.
	if (has_display_18(m_state.right_item) && m_state.right_arm != AnimationState::ARM_SPYGLASS) {
		Part arm = right_arm;
		if (slim)
			arm.x += 1.0f; // ModelPlayer.postRenderArm
		M4 m = out * arm.matrix() * M4::translate(-0.0625, 0.4375, 0.0625);
		if (sneak)
			m = m * M4::translate(0, 0.203125, 0);
		joints[WIELD_ITEM] = to_transform(m * item_display_18(m_state.right_item));
	} else {
		joints[WIELD_ITEM] = held_114(right_arm, false, m_state.right_item, m_state.right_arm);
	}

	// Item in the left hand (1.14)
	joints[WIELD_ITEM_LEFT] = held_114(left_arm, true, m_state.left_item, m_state.left_arm);
	return joints;
}

void MinecraftPlayerAnimator::apply(scene::AnimatedMeshSceneNode *node) const
{
	if (!node || !node->getMesh() || node->getMesh()->getMeshType() != scene::EAMT_SKINNED)
		return;
	auto joints = computeJoints();
	for (int j = 0; j < JOINT_COUNT; j++) {
		if (auto *bone = node->getJointNode(jointName((Joint)j)))
			bone->setTransform(joints[j]);
	}
}
