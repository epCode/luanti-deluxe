// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>

#include "camera.h"
#include "client/lightmap.h"
#include "client.h"
#include "clientmap.h"     // MapDrawControl
#include "localplayer.h"
#include "player.h"
#include <cmath>
#include "client/renderingengine.h"
#include "client/content_cao.h"
#include "settings.h"
#include "wieldmesh.h"
#include "noise.h"         // easeCurve
#include "mtevent.h"
#include "nodedef.h"
#include "util/numeric.h"
#include "constants.h"
#include "fontengine.h"
#include "script/scripting_client.h"
#include "gettext.h"
#include "voxelalgorithms.h"

#include <ICameraSceneNode.h>
#include <IGUIFont.h>
#include <ISceneNode.h>
#include <IVideoDriver.h>
#include <SViewFrustum.h>

static constexpr f32 CAMERA_OFFSET_STEP = 200;

#define WIELDMESH_OFFSET_X 55.0f
#define WIELDMESH_OFFSET_Y -35.0f
#define WIELDMESH_AMPLITUDE_X 7.0f
#define WIELDMESH_AMPLITUDE_Y 10.0f

static const char *setting_names[] = {
	"view_bobbing_amount", "fov", "arm_inertia",
	"show_nametag_backgrounds",
};

Camera::Camera(MapDrawControl &draw_control, Client *client, RenderingEngine *rendering_engine):
	m_draw_control(draw_control),
	m_client(client),
	m_camera_mode(CAMERA_MODE_FIRST),
	m_player_light_color(0xFFFFFFFF)
{
	auto smgr = rendering_engine->get_scene_manager();
	// note: making the camera node a child of the player node
	// would lead to unexpected behavior, so we don't do that.
	m_playernode = smgr->addEmptySceneNode(smgr->getRootSceneNode());
	m_headnode = smgr->addEmptySceneNode(m_playernode);
	m_cameranode = smgr->addCameraSceneNode(smgr->getRootSceneNode());
	m_cameranode->bindTargetAndRotation(true);

	// This needs to be in its own scene manager. It is drawn after
	// all other 3D scene nodes and before the GUI.
	m_wieldmgr = smgr->createNewSceneManager();
	m_wieldmgr->addCameraSceneNode();
	for (HandItem &hand : m_hands) {
		hand.node = new WieldMeshSceneNode(m_wieldmgr, -1);
		hand.node->setItem(ItemStack(), m_client);
		hand.node->drop(); // m_wieldmgr grabbed it
	}

	m_nametags.clear();

	readSettings();
	for (auto name : setting_names)
		g_settings->registerChangedCallback(name, settingChangedCallback, this);
}

void Camera::settingChangedCallback(const std::string &name, void *data)
{
	static_cast<Camera *>(data)->readSettings();
}

void Camera::readSettings()
{
	/* TODO: Local caching of settings is not optimal and should at some stage
	 *       be updated to use a global settings object for getting thse values
	 *       (as opposed to the this local caching). This can be addressed in
	 *       a later release.
	 */
	m_cache_view_bobbing_amount = g_settings->getFloat("view_bobbing_amount", 0.0f, 7.9f);
	// 45 degrees is the lowest FOV that doesn't cause the server to treat this
	// as a zoom FOV and load world beyond the set server limits.
	m_cache_fov                 = g_settings->getFloat("fov", 45.0f, 160.0f);
	m_arm_inertia               = g_settings->getBool("arm_inertia");
	m_show_nametag_backgrounds  = g_settings->getBool("show_nametag_backgrounds");
}

Camera::~Camera()
{
	g_settings->deregisterAllChangedCallbacks(this);
	m_wieldmgr->drop();
}

v3f Camera::getHeadPosition() const
{
	return m_headnode->getAbsolutePosition();
}

void Camera::notifyFovChange()
{
	LocalPlayer *player = m_client->getEnv().getLocalPlayer();
	assert(player);

	PlayerFovSpec spec = player->getFov();

	// Remember old FOV in case a transition is wanted
	f32 m_old_fov_degrees = m_fov_transition_active
		? m_curr_fov_degrees // FOV is overridden with transition
		: m_server_sent_fov
			? m_target_fov_degrees // FOV is overridden without transition
			: m_cache_fov; // FOV is not overridden

	m_server_sent_fov = spec.fov > 0.0f;
	m_target_fov_degrees = m_server_sent_fov
		? spec.is_multiplier
			? m_cache_fov * spec.fov // apply multiplier to client-set FOV
			: spec.fov // absolute override
		: m_cache_fov; // reset to client-set FOV

	m_fov_transition_active = spec.transition_time > 0.0f;
	if (m_fov_transition_active) {
		m_transition_time = spec.transition_time;
		m_fov_diff = m_target_fov_degrees - m_old_fov_degrees;
	}
}

// Returns the fractional part of x
inline f32 my_modf(f32 x)
{
	float dummy;
	return std::modf(x, &dummy);
}

// Minecraft's client tick (the hand animation runs on it)
constexpr f32 HAND_TICK = 0.05f;
// Use duration of items that are used until released (bows)
constexpr s32 USE_DURATION_UNTIL_STOPPED = 72000;

void Camera::step(f32 dtime)
{
	m_hand_tick_timer += dtime;
	// Don't fast-forward through a long stall
	if (m_hand_tick_timer > 10 * HAND_TICK)
		m_hand_tick_timer = HAND_TICK;
	while (m_hand_tick_timer >= HAND_TICK) {
		m_hand_tick_timer -= HAND_TICK;
		tickHand();
	}

	if (m_view_bobbing_state != 0)
	{
		//f32 offset = dtime * m_view_bobbing_speed * 0.035;
		f32 offset = dtime * m_view_bobbing_speed * 0.030;
		if (m_view_bobbing_state == 2) {
			// Animation is getting turned off
			if (m_view_bobbing_anim < 0.25) {
				m_view_bobbing_anim -= offset;
			} else if (m_view_bobbing_anim > 0.75) {
				m_view_bobbing_anim += offset;
			} else if (m_view_bobbing_anim < 0.5) {
				m_view_bobbing_anim += offset;
				if (m_view_bobbing_anim > 0.5)
					m_view_bobbing_anim = 0.5;
			} else {
				m_view_bobbing_anim -= offset;
				if (m_view_bobbing_anim < 0.5)
					m_view_bobbing_anim = 0.5;
			}

			if (m_view_bobbing_anim <= 0 || m_view_bobbing_anim >= 1 ||
					fabs(m_view_bobbing_anim - 0.5) < 0.01) {
				m_view_bobbing_anim = 0;
				m_view_bobbing_state = 0;
			}
		}
		else {
			float was = m_view_bobbing_anim;
			m_view_bobbing_anim = my_modf(m_view_bobbing_anim + offset);
			bool step = (was == 0 ||
					(was < 0.5f && m_view_bobbing_anim >= 0.5f) ||
					(was > 0.5f && m_view_bobbing_anim <= 0.5f));
			if(step) {
				m_client->getEventManager()->put(new SimpleTriggerEvent(MtEvent::VIEW_BOBBING_STEP));
			}
		}
	}
}

// Whether switching between two items keeps the item up. Count, wear and
// metadata changes don't lower it (the shown item is replaced at once).
static bool same_wield_item(const ItemStack &a, bool a_is_hand, const ItemStack &b, bool b_is_hand)
{
	return a.name == b.name && a_is_hand == b_is_hand;
}

void Camera::tickHand()
{
	// Player.tick()
	m_attack_strength_ticks = std::min(m_attack_strength_ticks + 1, 1000);

	// LivingEntity.SwingState.tick()
	m_attack_anim_old = m_attack_anim;
	if (m_swinging) {
		if (m_swing_duration > 0)
			m_attack_anim = std::min((f32)m_swing_ticks / m_swing_duration, 1.0f);
		if (m_swing_ticks++ > m_swing_duration) {
			m_swinging = false;
			m_attack_anim = 0.0f;
		}
	} else {
		m_attack_anim = 0.0f;
	}

	// LivingEntity.updatingUsingItem()
	if (isUsingItem() && --m_use_remaining <= 0)
		stopItemUse();

	// FirstPersonHandsAndItems.tick(): a new item waits until the shown one is
	// lowered, then rises (in the main hand with the attack cooldown)
	const f32 attack_ticks = std::max(m_attack_interval / HAND_TICK, 1.0f);
	const f32 strength = std::min((m_attack_strength_ticks + 1) / attack_ticks, 1.0f);
	for (int i = 0; i < 2; i++) {
		HandItem &hand = m_hands[i];
		hand.height_old = hand.height;
		if (same_wield_item(hand.shown, hand.shown_is_hand, hand.next, hand.next_is_hand) ?
				hand.shown.metadata != hand.next.metadata :
				!m_client->idef()->get(hand.next.name).hand_animation_on_swap)
			updateWieldedTool(i);
		const bool same = same_wield_item(hand.shown, hand.shown_is_hand,
				hand.next, hand.next_is_hand);
		const f32 raised = i == 0 ? strength * strength * strength : 1.0f;
		hand.height += rangelim((same ? raised : 0.0f) - hand.height, -0.4f, 0.4f);
		if (!same && hand.height < 0.1f)
			updateWieldedTool(i);
	}
}

bool Camera::swingHand(const SwingAnimation &animation, bool offhand)
{
	// LivingEntity.getModifiedSwingDuration()
	const s32 duration = std::round(animation.duration / HAND_TICK) +
			std::round(m_hand_params.swing_duration_offset / HAND_TICK);
	const bool same = m_swinging && m_swing_type == animation.type &&
			m_swing_duration == duration && m_swing_offhand == offhand;

	// LivingEntity.SwingState.startIfAble(): not in the first half of a swing.
	// A restart that is already waiting for the next tick changes nothing.
	if (m_swinging && m_swing_ticks > 0 && m_swing_ticks <= m_swing_duration / 2)
		return false;
	if (same && m_swing_ticks == 0)
		return false;

	if (!same) {
		m_attack_anim_old = 0.0f;
		m_attack_anim = 0.0f;
	}
	m_swinging = true;
	m_swing_offhand = offhand;
	m_swing_type = animation.type;
	m_swing_duration = duration;
	m_swing_ticks = 0;
	return true;
}

void Camera::startItemUse(const ItemUse &use)
{
	m_item_use = use;
	m_use_duration = use.duration > 0.0f ?
			std::max<s32>(std::round(use.duration / HAND_TICK), 1) :
			USE_DURATION_UNTIL_STOPPED;
	// As if started during the last tick (Minecraft starts using an item
	// during a tick, then counts that tick)
	m_use_remaining = m_use_duration - 1;
	if (m_use_remaining <= 0)
		stopItemUse();
}

/*
	The first-person hand and item poses are ported from Minecraft's
	FirstPersonHandsAndItemsRenderer and SpearAnimations (Java Edition 26.3).
	They are built in Minecraft's view space (right-handed, -Z forward, units of
	blocks) relative to the resting pose, then mapped into the wield scene
	(left-handed, +Z forward) around the wield item's resting position.
*/

namespace {

// Wield scene units per Minecraft block, matching the hand's distance from the camera
constexpr f32 MC_TO_WIELD = 65.0f / 0.72f;

// Minecraft's PoseStack: each transform applies in the frame of the previous ones
struct PoseStack
{
	core::matrix4 m;

	void mul(const core::matrix4 &other) { m = m * other; }
	void translate(f32 x, f32 y, f32 z)
	{
		core::matrix4 t;
		t.setTranslation(v3f(x, y, z));
		mul(t);
	}
	// Right-handed rotations as with Minecraft's Axis.XP/YP/ZP
	void rotateX(f32 degrees) { rotate(v3f(degrees, 0, 0)); }
	void rotateY(f32 degrees) { rotate(v3f(0, degrees, 0)); }
	void rotateZ(f32 degrees) { rotate(v3f(0, 0, degrees)); }
	void rotate(v3f degrees)
	{
		core::matrix4 r;
		r.setRotationDegrees(degrees);
		mul(r);
	}
};

f32 progress(f32 time, f32 start, f32 end)
{
	return rangelim((time - start) / (end - start), 0.0f, 1.0f);
}

f32 ease_in_out_sine(f32 x)
{
	return -(std::cos(M_PI * x) - 1.0f) / 2.0f;
}

f32 ease_out_back(f32 x)
{
	const f32 y = x - 1.0f;
	return 1.0f + 2.70158f * y * y * y + 1.70158f * y * y;
}

f32 ease_in_out_expo(f32 x)
{
	if (x < 0.5f)
		return x == 0.0f ? 0.0f : std::pow(2.0f, 20.0f * x - 10.0f) / 2.0f;
	return x == 1.0f ? 1.0f : (2.0f - std::pow(2.0f, -20.0f * x + 10.0f)) / 2.0f;
}

// `invert` is 1 for the right arm and -1 for the left arm, as in Minecraft

void apply_item_arm_transform(PoseStack &ps, f32 invert, f32 inverse_arm_height)
{
	ps.translate(invert * 0.56f, -0.52f + inverse_arm_height * -0.6f, -0.72f);
}

void apply_item_arm_attack_transform(PoseStack &ps, f32 invert, f32 attack)
{
	const f32 y_swing_rotation = std::sin(attack * attack * M_PI);
	ps.rotateY(invert * (45.0f + y_swing_rotation * -20.0f));
	const f32 xz_swing_rotation = std::sin(std::sqrt(attack) * M_PI);
	ps.rotateZ(invert * xz_swing_rotation * -20.0f);
	ps.rotateX(xz_swing_rotation * -80.0f);
	ps.rotateY(invert * -45.0f);
}

void swing_arm(PoseStack &ps, f32 invert, f32 attack)
{
	const f32 sqrt_attack = std::sqrt(attack);
	ps.translate(invert * -0.4f * std::sin(sqrt_attack * M_PI),
			0.2f * std::sin(sqrt_attack * 2.0f * M_PI),
			-0.2f * std::sin(attack * M_PI));
	apply_item_arm_attack_transform(ps, invert, attack);
}

// SpearAnimations.firstPersonAttack()
void stab_arm(PoseStack &ps, f32 invert, f32 attack)
{
	const f32 starting = ease_in_out_sine(progress(attack, 0.0f, 0.05f));
	const f32 middle = ease_out_back(progress(attack, 0.05f, 0.2f));
	const f32 ending = ease_in_out_expo(progress(attack, 0.4f, 1.0f));
	ps.translate(invert * 0.1f * (starting - middle), -0.075f * (starting - ending),
			0.65f * (starting - middle));
	ps.rotateX(-70.0f * (starting - ending));
	ps.translate(0.0f, 0.0f, -0.25f * (ending - middle));
}

// Bow, crossbow and trident: shake once mostly drawn
void apply_charge_shake(PoseStack &ps, f32 time_held, f32 power)
{
	if (power > 0.1f) {
		const f32 shake = std::sin((time_held - 0.1f) * 1.3f) * (power - 0.1f);
		ps.translate(0.0f, shake * 0.004f, 0.0f);
	}
}

// Mirror a pose of the right hand to the left hand
core::matrix4 mirror_x(const core::matrix4 &m)
{
	core::matrix4 mirror;
	mirror.setScale(v3f(-1.0f, 1.0f, 1.0f));
	return mirror * m * mirror;
}

} // namespace

void Camera::updateWieldPose(bool offhand, f32 bob_x, f32 bob_y)
{
	HandItem &hand = m_hands[offhand];
	const f32 invert = offhand ? -1.0f : 1.0f;
	// The wield item rests at the same place on the screen as before,
	// mirrored for the other hand; arm inertia moves both alike
	const v3f rest_position(offhand ?
			m_wieldmesh_offset.X - 2.0f * WIELDMESH_OFFSET_X : m_wieldmesh_offset.X,
			m_wieldmesh_offset.Y, 65);
	core::matrix4 rest_rotation;
	rest_rotation.setRotationDegrees(v3f(-100, 120, -100));
	if (offhand)
		rest_rotation = mirror_x(rest_rotation);

	const f32 partial_tick = m_hand_tick_timer / HAND_TICK;
	// LivingEntity.SwingState.getAnimation(), only for the hand that swings
	f32 attack = 0.0f;
	if (m_swing_offhand == offhand) {
		attack = m_attack_anim >= m_attack_anim_old ?
				m_attack_anim_old + (m_attack_anim - m_attack_anim_old) * partial_tick :
				m_attack_anim_old + (m_attack_anim + 1.0f - m_attack_anim_old) * partial_tick;
	}
	const bool swinging = m_swinging && m_swing_offhand == offhand;
	const ItemDefinition &def = m_client->idef()->get(hand.shown.name);
	const f32 swap_scale = def.swap_animation_scale;
	const f32 inverse_arm_height = swap_scale * (1.0f - (hand.height_old +
			(hand.height - hand.height_old) * partial_tick));

	const bool using_item = isUsingItem() && m_use_remaining > 0;
	const ItemUseAnimation use_anim = m_item_use.animation;
	// FirstPersonHandsAndItems.evaluateWhichHandsToRender(): a drawn bow or
	// crossbow takes both hands, a spyglass hides both, a charged crossbow
	// in the main hand hides the other hand
	auto charged_crossbow = [&] (const HandItem &h) {
		return m_client->idef()->get(h.shown.name).hold_animation ==
				ItemHoldAnimation::CHARGED_CROSSBOW;
	};
	const bool two_handed_use = use_anim == ItemUseAnimation::BOW ||
			use_anim == ItemUseAnimation::CROSSBOW;
	bool visible = !(using_item && use_anim == ItemUseAnimation::SPYGLASS) &&
			!(using_item && m_item_use.offhand != offhand && two_handed_use);
	if (offhand && !using_item && charged_crossbow(m_hands[0]))
		visible = false;
	if (offhand && using_item && !m_item_use.offhand && !two_handed_use &&
			charged_crossbow(m_hands[1]))
		visible = false;

	PoseStack pose, rest;
	v3f rest_origin(invert * 0.56f, -0.52f, -0.72f);
	if (hand.shown.empty() && offhand) {
		// Nothing in the other hand
		visible = false;
	} else if (hand.shown_is_hand) {
		// renderPlayerArm()
		const f32 sqrt_attack = std::sqrt(attack);
		pose.translate(invert * (-0.3f * std::sin(sqrt_attack * M_PI) + 0.64f),
				0.4f * std::sin(sqrt_attack * 2.0f * M_PI) - 0.6f + inverse_arm_height * -0.6f,
				-0.4f * std::sin(attack * M_PI) - 0.72f);
		pose.rotateY(invert * 45.0f);
		pose.rotateY(invert * std::sin(sqrt_attack * M_PI) * 70.0f);
		pose.rotateZ(invert * std::sin(attack * attack * M_PI) * -20.0f);

		rest_origin = v3f(invert * 0.64f, -0.6f, -0.72f);
		rest.translate(rest_origin.X, rest_origin.Y, rest_origin.Z);
		rest.rotateY(invert * 45.0f);
	} else if (using_item && m_item_use.offhand == offhand) {
		// submitArmWithItem() while using the item
		const f32 remaining = m_use_remaining - partial_tick + 1.0f;
		const f32 time_held = m_use_duration - remaining;
		auto charge_ticks = [&] (f32 default_ticks) {
			return m_item_use.charge_time >= 0.0f ?
					std::max(m_item_use.charge_time / HAND_TICK, 0.001f) : default_ticks;
		};

		if (use_anim != ItemUseAnimation::EAT && use_anim != ItemUseAnimation::DRINK)
			apply_item_arm_transform(pose, invert, inverse_arm_height);

		switch (use_anim) {
		case ItemUseAnimation::EAT:
		case ItemUseAnimation::DRINK: {
			// applyEatTransform()
			const f32 scaled = remaining / m_use_duration;
			if (scaled < 0.8f)
				pose.translate(0.0f, std::abs(std::cos(remaining / 4.0f * M_PI) * 0.1f), 0.0f);
			const f32 jiggle = 1.0f - std::pow(scaled, 27.0f);
			pose.translate(jiggle * 0.6f * invert, jiggle * -0.5f, 0.0f);
			pose.rotateY(invert * jiggle * 90.0f);
			pose.rotateX(jiggle * 10.0f);
			pose.rotateZ(invert * jiggle * 30.0f);
			apply_item_arm_transform(pose, invert, inverse_arm_height);
			break;
		}
		case ItemUseAnimation::BLOCK:
			pose.translate(invert * -0.14142136f, 0.08f, 0.14142136f);
			pose.rotateX(-102.25f);
			pose.rotateY(invert * 13.365f);
			pose.rotateZ(invert * 78.05f);
			break;
		case ItemUseAnimation::BOW: {
			pose.translate(invert * -0.2785682f, 0.18344387f, 0.15731531f);
			pose.rotateX(-13.935f);
			pose.rotateY(invert * 35.3f);
			pose.rotateZ(invert * -9.785f);
			f32 power = time_held / charge_ticks(20.0f);
			power = std::min((power * power + power * 2.0f) / 3.0f, 1.0f);
			apply_charge_shake(pose, time_held, power);
			pose.translate(0.0f, 0.0f, power * 0.04f);
			pose.rotateY(invert * -45.0f);
			break;
		}
		case ItemUseAnimation::TRIDENT: {
			pose.translate(invert * -0.5f, 0.7f, 0.1f);
			pose.rotateX(-55.0f);
			pose.rotateY(invert * 35.3f);
			pose.rotateZ(invert * -9.785f);
			const f32 power = std::min(time_held / charge_ticks(10.0f), 1.0f);
			apply_charge_shake(pose, time_held, power);
			pose.translate(0.0f, 0.0f, power * 0.2f);
			pose.rotateY(invert * -45.0f);
			break;
		}
		case ItemUseAnimation::CROSSBOW: {
			pose.translate(invert * -0.4785682f, -0.094387f, 0.05731531f);
			pose.rotateX(-11.935f);
			pose.rotateY(invert * 65.3f);
			pose.rotateZ(invert * -9.785f);
			const f32 power = std::min(time_held / charge_ticks(25.0f), 1.0f);
			apply_charge_shake(pose, time_held, power);
			pose.translate(0.0f, 0.0f, power * 0.04f);
			pose.rotateY(invert * -45.0f);
			break;
		}
		case ItemUseAnimation::BRUSH: {
			// applyBrushTransform()
			const f32 delta = std::fmod((f32)m_use_remaining, 10.0f) - partial_tick + 1.0f;
			const f32 scaled = 1.0f - delta / 10.0f;
			const f32 swipe = -15.0f + 75.0f * std::cos(scaled * 2.0f * M_PI);
			if (offhand) {
				pose.translate(0.1f, 0.83f, 0.35f);
				pose.rotateX(-80.0f);
				pose.rotateY(-90.0f);
				pose.rotateX(swipe);
				pose.translate(-0.3f, 0.22f, 0.35f);
			} else {
				pose.translate(-0.25f, 0.22f, 0.35f);
				pose.rotateX(-80.0f);
				pose.rotateY(90.0f);
				pose.rotateX(swipe);
			}
			break;
		}
		case ItemUseAnimation::BUNDLE:
			swing_arm(pose, invert, attack);
			break;
		case ItemUseAnimation::SHIELD:
			// The change from the shield model's first-person display to its
			// blocking display (models/item/shield(_blocking).json)
			pose.translate(invert * -15.0f / 16, 3.25f / 16, -11.0f / 16);
			pose.rotateZ(invert * 10.0f);
			pose.translate(invert * 10.0f / 16, -1.75f / 16, 10.0f / 16);
			break;
		default:
			break;
		}

		rest.translate(rest_origin.X, rest_origin.Y, rest_origin.Z);
	} else {
		// submitArmWithItem() with the item's swing animation
		apply_item_arm_transform(pose, invert, inverse_arm_height);
		if (swinging) {
			switch (m_swing_type) {
			case SwingAnimationType::WHACK:
				swing_arm(pose, invert, attack);
				break;
			case SwingAnimationType::STAB:
				stab_arm(pose, invert, attack);
				break;
			default:
				break;
			}
		}
		// A charged crossbow is held up, ready to shoot
		if (!offhand && attack < 0.001f && charged_crossbow(hand)) {
			pose.translate(invert * -0.641864f, 0.0f, 0.0f);
			pose.rotateY(invert * 10.0f);
		}

		rest.translate(rest_origin.X, rest_origin.Y, rest_origin.Z);
	}

	// ItemTransform.apply(): flat items are drawn around their center, which
	// generated item models move away from the arm (block models do not).
	// Turning about it rather than about the arm keeps animated items where
	// Minecraft has them.
	const bool block_model = def.type == ITEM_NODE &&
			def.inventory_image.name.empty() && def.wield_image.name.empty();
	if (!hand.shown_is_hand && !block_model) {
		const v3f display_offset(invert * 1.13f / 16, 3.2f / 16, 1.13f / 16);
		pose.translate(display_offset.X, display_offset.Y, display_offset.Z);
		rest.translate(display_offset.X, display_offset.Y, display_offset.Z);
		rest_origin += display_offset;
	}

	// The item's own first-person display rotation (negated Y and Z for the
	// left hand), relative to that of generated items, which the wield item
	// rests in
	if (!hand.shown_is_hand) {
		v3f item_rot = offhand ?
				def.first_person_rotation_offhand : def.first_person_rotation;
		v3f rest_rot = ITEM_FIRST_PERSON_ROTATION;
		if (offhand) {
			item_rot = v3f(item_rot.X, -item_rot.Y, -item_rot.Z);
			rest_rot = v3f(rest_rot.X, -rest_rot.Y, -rest_rot.Z);
		}
		if (item_rot != rest_rot) {
			pose.rotateX(item_rot.X);
			pose.rotateY(item_rot.Y);
			pose.rotateZ(item_rot.Z);
			pose.rotateZ(-rest_rot.Z);
			pose.rotateY(-rest_rot.Y);
			pose.rotateX(-rest_rot.X);
		}
	}

	hand.node->setVisible(visible);
	if (!visible)
		return;

	// The change from the resting pose, in Minecraft's view space
	core::matrix4 rest_inverse;
	rest.m.getInverse(rest_inverse);
	const core::matrix4 delta = pose.m * rest_inverse;

	// Map Minecraft's view space into the wield scene, taking the resting
	// position of the Minecraft item to the resting position of the wield item
	core::matrix4 to_wield, to_wield_inverse;
	{
		core::matrix4 t1, s, t2;
		t1.setTranslation(rest_position);
		s.setScale(v3f(MC_TO_WIELD, MC_TO_WIELD, -MC_TO_WIELD));
		t2.setTranslation(-rest_origin);
		to_wield = t1 * s * t2;
		to_wield.getInverse(to_wield_inverse);
	}
	core::matrix4 wield_delta = to_wield * delta * to_wield_inverse;

	v3f position = rest_position;
	wield_delta.transformVect(position);
	wield_delta.setTranslation(v3f(0.0f));

	hand.node->setPosition(position + v3f(bob_x, bob_y, 0.0f));
	hand.node->setRotation((wield_delta * rest_rotation).getRotationDegrees());
}

static inline v2f dir(const v2f &pos_dist)
{
	f32 x = pos_dist.X - WIELDMESH_OFFSET_X;
	f32 y = pos_dist.Y - WIELDMESH_OFFSET_Y;

	f32 x_abs = std::fabs(x);
	f32 y_abs = std::fabs(y);

	if (x_abs >= y_abs) {
		y *= (1.0f / x_abs);
		x /= x_abs;
	}

	if (y_abs >= x_abs) {
		x *= (1.0f / y_abs);
		y /= y_abs;
	}

	return v2f(std::fabs(x), std::fabs(y));
}

void Camera::addArmInertia(f32 player_yaw)
{
	m_cam_vel.X = std::fabs(rangelim(m_last_cam_pos.X - player_yaw,
		-100.0f, 100.0f) / 0.016f) * 0.01f;
	m_cam_vel.Y = std::fabs((m_last_cam_pos.Y - m_camera_direction.Y) / 0.016f);
	f32 gap_X = std::fabs(WIELDMESH_OFFSET_X - m_wieldmesh_offset.X);
	f32 gap_Y = std::fabs(WIELDMESH_OFFSET_Y - m_wieldmesh_offset.Y);

	if (m_cam_vel.X > 1.0f || m_cam_vel.Y > 1.0f) {
		/*
		    The arm moves relative to the camera speed,
		    with an acceleration factor.
		*/

		if (m_cam_vel.X > 1.0f) {
			if (m_cam_vel.X > m_cam_vel_old.X)
				m_cam_vel_old.X = m_cam_vel.X;

			f32 acc_X = 0.12f * (m_cam_vel.X - (gap_X * 0.1f));
			m_wieldmesh_offset.X += m_last_cam_pos.X < player_yaw ? acc_X : -acc_X;

			if (m_last_cam_pos.X != player_yaw)
				m_last_cam_pos.X = player_yaw;

			m_wieldmesh_offset.X = rangelim(m_wieldmesh_offset.X,
				WIELDMESH_OFFSET_X - (WIELDMESH_AMPLITUDE_X * 0.5f),
				WIELDMESH_OFFSET_X + (WIELDMESH_AMPLITUDE_X * 0.5f));
		}

		if (m_cam_vel.Y > 1.0f) {
			if (m_cam_vel.Y > m_cam_vel_old.Y)
				m_cam_vel_old.Y = m_cam_vel.Y;

			f32 acc_Y = 0.12f * (m_cam_vel.Y - (gap_Y * 0.1f));
			m_wieldmesh_offset.Y +=
				m_last_cam_pos.Y > m_camera_direction.Y ? acc_Y : -acc_Y;

			if (m_last_cam_pos.Y != m_camera_direction.Y)
				m_last_cam_pos.Y = m_camera_direction.Y;

			m_wieldmesh_offset.Y = rangelim(m_wieldmesh_offset.Y,
				WIELDMESH_OFFSET_Y - (WIELDMESH_AMPLITUDE_Y * 0.5f),
				WIELDMESH_OFFSET_Y + (WIELDMESH_AMPLITUDE_Y * 0.5f));
		}

		m_arm_dir = dir(m_wieldmesh_offset);
	} else {
		/*
		    Now the arm gets back to its default position when the camera stops,
		    following a vector, with a smooth deceleration factor.
		*/

		f32 dec_X = 0.35f * (std::min(15.0f, m_cam_vel_old.X) * (1.0f +
			(1.0f - m_arm_dir.X))) * (gap_X / 20.0f);

		f32 dec_Y = 0.25f * (std::min(15.0f, m_cam_vel_old.Y) * (1.0f +
			(1.0f - m_arm_dir.Y))) * (gap_Y / 15.0f);

		if (gap_X < 0.1f)
			m_cam_vel_old.X = 0.0f;

		m_wieldmesh_offset.X -=
			m_wieldmesh_offset.X > WIELDMESH_OFFSET_X ? dec_X : -dec_X;

		if (gap_Y < 0.1f)
			m_cam_vel_old.Y = 0.0f;

		m_wieldmesh_offset.Y -=
			m_wieldmesh_offset.Y > WIELDMESH_OFFSET_Y ? dec_Y : -dec_Y;
	}
}

void Camera::updateOffset()
{
	v3f cp = m_camera_position / BS;

	// Update offset if too far away from the center of the map
	m_camera_offset = v3s16(
		floorf(cp.X / CAMERA_OFFSET_STEP) * CAMERA_OFFSET_STEP,
		floorf(cp.Y / CAMERA_OFFSET_STEP) * CAMERA_OFFSET_STEP,
		floorf(cp.Z / CAMERA_OFFSET_STEP) * CAMERA_OFFSET_STEP
	);

	// No need to update m_cameranode as that will be done before the next render.
}

void Camera::update(LocalPlayer* player, f32 frametime, f32 full_punch_interval)
{
	m_attack_interval = full_punch_interval;

	// Get player position
	// Smooth the movement when walking up stairs
	v3f old_player_position = m_playernode->getPosition();
	v3f player_position = player->getPosition();

	f32 yaw = player->getYaw();
	f32 pitch = player->getPitch();

	// This is worse than `LocalPlayer::getPosition()` but
	// mods expect the player head to be at the parent's position
	// plus eye height.
	if (player->getParent())
		player_position = player->getParent()->getPosition();

	// Smooth the camera movement after the player instantly moves upward due to stepheight.
	// The smoothing usually continues until the camera position reaches the player position.
	float player_stepheight = player->getCAO() ? player->getCAO()->getStepHeight() : HUGE_VALF;
	float upward_movement = player_position.Y - old_player_position.Y;
	if (upward_movement < 0.01f || upward_movement > player_stepheight) {
		m_stepheight_smooth_active = false;
	} else if (player->touching_ground) {
		m_stepheight_smooth_active = true;
	}
	if (m_stepheight_smooth_active) {
		f32 oldy = old_player_position.Y;
		f32 newy = player_position.Y;
		f32 t = std::exp(-23 * frametime);
		player_position.Y = oldy * t + newy * (1-t);
	}

	// Set player node transformation
	m_playernode->setPosition(player_position);
	m_playernode->setRotation(v3f(0, -1 * yaw, 0));
	m_playernode->updateAbsolutePosition();

	// Get camera tilt timer (hurt animation)
	float cameratilt = fabs(fabs(player->hurt_tilt_timer-0.75)-0.75);

	// Calculate and translate the head SceneNode offsets
	{
		v3f eye_offset = player->getEyeOffset();
		if (player->physics_override.new_sneak && !std::isnan(m_eye_height_smooth)) {
			// Minecraft halves the distance to the target eye height every tick (1/20 s)
			const f32 t = std::exp2(-20.0f * frametime);
			m_eye_height_smooth = eye_offset.Y + (m_eye_height_smooth - eye_offset.Y) * t;
			eye_offset.Y = m_eye_height_smooth;
		} else {
			m_eye_height_smooth = eye_offset.Y;
		}
		switch(m_camera_mode) {
		case CAMERA_MODE_ANY:
		case CameraMode_END:
			assert(false);
			break;
		case CAMERA_MODE_FIRST:
			eye_offset += player->eye_offset_first;
			break;
		case CAMERA_MODE_THIRD:
			eye_offset += player->eye_offset_third;
			break;
		case CAMERA_MODE_THIRD_FRONT:
			eye_offset.X += player->eye_offset_third_front.X;
			eye_offset.Y += player->eye_offset_third_front.Y;
			eye_offset.Z -= player->eye_offset_third_front.Z;
			break;
		}

		// Set head node transformation
		eye_offset.Y += cameratilt * -player->hurt_tilt_strength;
		m_headnode->setPosition(eye_offset);
		m_headnode->setRotation(v3f(pitch, 0,
			cameratilt * player->hurt_tilt_strength));
		m_headnode->updateAbsolutePosition();
	}


	// Compute relative camera position and target
	v3f rel_cam_pos = v3f(0,0,0);
	v3f rel_cam_target = v3f(0,0,1);
	v3f rel_cam_up = v3f(0,1,0);

	if (m_cache_view_bobbing_amount != 0.0f && m_view_bobbing_anim != 0.0f &&
		m_camera_mode < CAMERA_MODE_THIRD) {
		f32 bobfrac = my_modf(m_view_bobbing_anim * 2);
		f32 bobdir = (m_view_bobbing_anim < 0.5) ? 1.0 : -1.0;

		f32 bobknob = 1.2;
		f32 bobtmp = std::sin(std::pow(bobfrac, bobknob) * M_PI);

		v3f bobvec = v3f(
			0.3 * bobdir * std::sin(bobfrac * M_PI),
			-0.28 * bobtmp * bobtmp,
			0.);

		rel_cam_pos += bobvec * m_cache_view_bobbing_amount;
		rel_cam_target += bobvec * m_cache_view_bobbing_amount;
		rel_cam_up.rotateXYBy(-0.03 * bobdir * bobtmp * M_PI * m_cache_view_bobbing_amount);
	}

	// Compute absolute camera position and target
	m_headnode->getAbsoluteTransformation().transformVect(m_camera_position, rel_cam_pos);
	m_camera_direction = m_headnode->getAbsoluteTransformation()
			.rotateAndScaleVect(rel_cam_target - rel_cam_pos);

	v3f abs_cam_up = m_headnode->getAbsoluteTransformation()
			.rotateAndScaleVect(rel_cam_up);

	// Reposition the camera for third person view
	if (m_camera_mode > CAMERA_MODE_FIRST)
	{
		v3f my_cp = m_camera_position;

		if (m_camera_mode == CAMERA_MODE_THIRD_FRONT)
			m_camera_direction *= -1;

		my_cp.Y += 2;

		// Calculate new position
		bool abort = false;
		for (int i = BS; i <= BS * 2.75; i++) {
			my_cp.X = m_camera_position.X + m_camera_direction.X * -i;
			my_cp.Z = m_camera_position.Z + m_camera_direction.Z * -i;
			if (i > 12)
				my_cp.Y = m_camera_position.Y + (m_camera_direction.Y * -i);

			// Prevent camera positioned inside nodes
			const NodeDefManager *nodemgr = m_client->ndef();
			MapNode n = m_client->getEnv().getClientMap()
				.getNode(floatToInt(my_cp, BS));

			const ContentFeatures& features = nodemgr->get(n);
			if (features.walkable) {
				my_cp.X += m_camera_direction.X*-1*-BS/2;
				my_cp.Z += m_camera_direction.Z*-1*-BS/2;
				my_cp.Y += m_camera_direction.Y*-1*-BS/2;
				abort = true;
				break;
			}
		}

		// If node blocks camera position don't move y to height
		if (abort && my_cp.Y > player_position.Y+BS*2)
			my_cp.Y = player_position.Y+BS*2;

		// update the camera position in third-person mode to render blocks behind player
		// and correctly apply liquid post FX.
		m_camera_position = my_cp;
	}

	// Set camera node transformation
	m_cameranode->setPosition(m_camera_position - intToFloat(m_camera_offset, BS));
	m_cameranode->setUpVector(abs_cam_up);
	m_cameranode->updateAbsolutePosition();
	// *100 helps in large map coordinates
	m_cameranode->setTarget(m_camera_position - intToFloat(m_camera_offset, BS)
		+ 100 * m_camera_direction);

	/*
	 * Apply server-sent FOV, instantaneous or smooth transition.
	 * If not, check for zoom and set to zoom FOV.
	 * Otherwise, default to m_cache_fov.
	 */
	if (m_fov_transition_active) {
		// Smooth FOV transition
		// Dynamically calculate FOV delta based on frametimes
		f32 delta = (frametime / m_transition_time) * m_fov_diff;
		m_curr_fov_degrees += delta;

		// Mark transition as complete if target FOV has been reached
		if ((m_fov_diff > 0.0f && m_curr_fov_degrees >= m_target_fov_degrees) ||
				(m_fov_diff < 0.0f && m_curr_fov_degrees <= m_target_fov_degrees)) {
			m_fov_transition_active = false;
			m_curr_fov_degrees = m_target_fov_degrees;
		}
	} else if (m_server_sent_fov) {
		// Instantaneous FOV change
		m_curr_fov_degrees = m_target_fov_degrees;
	} else if (player->getPlayerControl().zoom && player->getZoomFOV() > 0.001f) {
		// Player requests zoom, apply zoom FOV
		m_curr_fov_degrees = player->getZoomFOV();
	} else {
		// Set to client's selected FOV
		m_curr_fov_degrees = m_cache_fov;
	}
	m_curr_fov_degrees = rangelim(m_curr_fov_degrees, 1.0f, 160.0f);

	// FOV and aspect ratio
	const v2u32 &window_size = RenderingEngine::getWindowSize();
	m_aspect = (f32) window_size.X / (f32) window_size.Y;
	m_fov_y = m_curr_fov_degrees * M_PI / 180.0;
	// Increase vertical FOV on lower aspect ratios (<16:10)
	m_fov_y *= core::clamp(sqrt(16./10. / m_aspect), 1.0, 1.4);
	m_fov_x = 2 * atan(m_aspect * tan(0.5 * m_fov_y));
	m_cameranode->setAspectRatio(m_aspect);
	m_cameranode->setFOV(m_fov_y);

	// Make new matrices and frustum
	m_cameranode->updateMatrices();

	if (m_arm_inertia)
		addArmInertia(yaw);

	// Position the items in both hands
	f32 bobfrac = my_modf(m_view_bobbing_anim);
	const f32 bob_x = -std::sin(bobfrac * M_PI * 2.0) * 3.0;
	const f32 bob_y = std::sin(my_modf(bobfrac * 2.0) * M_PI) * 3.0;
	updateWieldPose(false, bob_x, bob_y);
	updateWieldPose(true, bob_x, bob_y);

	m_player_light_color = m_client->getLightmapState().isEnabled() ?
			player->lightmap_light : player->light_color;
	for (HandItem &hand : m_hands)
		hand.node->setLightColorAndAnimation(m_player_light_color,
				m_client->getAnimationTime());

	// Set render distance
	updateViewingRange();

	// If the player is walking, swimming, or climbing,
	// view bobbing is enabled and free_move is off,
	// start (or continue) the view bobbing animation.
	const v3f &speed = player->getSpeed();
	const bool movement_XZ = std::hypot(speed.X, speed.Z) > BS;
	const bool movement_Y = std::abs(speed.Y) > BS;

	const bool walking = movement_XZ && player->touching_ground;
	const bool swimming = (movement_XZ || player->swimming_vertical) && player->in_liquid;
	const bool climbing = movement_Y && player->is_climbing;
	const bool flying = g_settings->getBool("free_move")
		&& m_client->checkLocalPrivilege("fly");
	if ((walking || swimming || climbing) && !flying) {
		// Start animation
		m_view_bobbing_state = 1;
		m_view_bobbing_speed = MYMIN(speed.getLength(), 70);
	} else if (m_view_bobbing_state == 1) {
		// Stop animation
		m_view_bobbing_state = 2;
		m_view_bobbing_speed = 60;
	}
}

void Camera::updateViewingRange()
{
	f32 viewing_range = g_settings->getFloat("viewing_range");

	m_cameranode->setNearValue(0.1f * BS);

	m_draw_control.wanted_range = std::fmin(adjustDist(viewing_range, getFovMax()), 6000);
	if (m_draw_control.range_all) {
		m_cameranode->setFarValue(100000.0);
		return;
	}
	m_cameranode->setFarValue(std::fmax(2000, m_draw_control.wanted_range) * BS);
}

void Camera::wield(const ItemStack &item, bool animate, bool is_hand)
{
	HandItem &hand = m_hands[0];
	if (same_wield_item(item, is_hand, hand.next, hand.next_is_hand) &&
			item.metadata == hand.next.metadata)
		return;

	// Switching to another kind of item restarts the attack cooldown
	if (animate && item.name != hand.next.name)
		resetAttackStrength();

	hand.next = item;
	hand.next_is_hand = is_hand;
	// Otherwise the item is replaced once it is lowered (see tickHand())
	if (!animate)
		updateWieldedTool(false);
}

void Camera::wieldOffhand(const ItemStack &item, bool animate)
{
	HandItem &hand = m_hands[1];
	if (same_wield_item(item, false, hand.next, false) &&
			item.metadata == hand.next.metadata)
		return;

	hand.next = item;
	if (!animate)
		updateWieldedTool(true);
}

void Camera::drawWieldedTool(core::matrix4* translation)
{
	// Clear Z buffer so that the wielded tool stays in front of world geometry
	m_wieldmgr->getVideoDriver()->clearBuffers(video::ECBF_DEPTH);

	// Draw the wielded node (in a separate scene manager)
	scene::ICameraSceneNode* cam = m_wieldmgr->getActiveCamera();
	cam->setAspectRatio(m_cameranode->getAspectRatio());
	cam->setFOV(72.0*M_PI/180.0);
	cam->setNearValue(10);
	cam->setFarValue(1000);
	if (translation != NULL)
	{
		core::matrix4 startMatrix = cam->getAbsoluteTransformation();
		core::vector3df focusPoint = (cam->getTarget()
				- cam->getAbsolutePosition()).setLength(1)
				+ cam->getAbsolutePosition();

		core::vector3df camera_pos =
				(startMatrix * *translation).getTranslation();
		cam->setPosition(camera_pos);
		cam->updateAbsolutePosition();
		cam->setTarget(focusPoint);
	}
	m_wieldmgr->drawAll();
}

void Camera::toggleCameraMode()
{
	if (m_camera_mode == CAMERA_MODE_FIRST)
		m_camera_mode = CAMERA_MODE_THIRD;
	else if (m_camera_mode == CAMERA_MODE_THIRD)
		m_camera_mode = CAMERA_MODE_THIRD_FRONT;
	else
		m_camera_mode = CAMERA_MODE_FIRST;
}

// Whether nodes drawn as (mostly) opaque cubes are in the way between two points
static bool is_view_blocked(Client *client, v3f from, v3f to)
{
	const NodeDefManager *ndef = client->ndef();
	Map &map = client->getEnv().getMap();
	voxalgo::VoxelLineIterator iterator(from / BS, (to - from) / BS);
	do {
		bool is_valid;
		MapNode n = map.getNode(iterator.m_current_node_pos, &is_valid);
		if (is_valid) {
			switch (ndef->get(n).drawtype) {
			case NDT_NORMAL:
			case NDT_LIQUID:
			case NDT_GLASSLIKE:
			case NDT_GLASSLIKE_FRAMED:
			case NDT_GLASSLIKE_FRAMED_OPTIONAL:
			case NDT_ALLFACES:
			case NDT_ALLFACES_OPTIONAL:
				return true;
			default:
				break;
			}
		}
		iterator.next();
	} while (iterator.m_current_index <= iterator.m_last_index);
	return false;
}

void Camera::drawNametags()
{
	core::matrix4 trans = m_cameranode->getProjectionMatrix();
	trans *= m_cameranode->getViewMatrix();

	// This isn't the actual size, just a placeholder so we can easily apply
	// the user's font size preference...
	const u32 default_font_size = 16;
	// ...by multiplying this in.
	const f32 font_size_mult = g_fontengine->getFontSize(FM_Unspecified) / (float)default_font_size;

	// Minimum distance until z-scaled nametags actually become smaller
	const f32 minimum_d = 3.0f * BS;
	// Smoothing constant: larger = slower size falloff with distance
	const f32 smoothing_k = 4.0f * BS;

	video::IVideoDriver *driver = RenderingEngine::get_video_driver();
	v2u32 screensize = driver->getScreenSize();

	const v3f camera_offset = intToFloat(m_camera_offset, BS);

	// Note: hidden nametags (e.g. GenericCAO) are removed from the array
	for (const Nametag *nametag : m_nametags) {
		v3f pos = nametag->parent_node->getAbsolutePosition() + nametag->pos * BS;

		if (nametag->range > 0.0f || !nametag->see_through) {
			const v3f world_pos = pos + camera_offset;
			if (nametag->range > 0.0f &&
					world_pos.getDistanceFrom(m_camera_position) > nametag->range * BS)
				continue;
			if (!nametag->see_through &&
					is_view_blocked(m_client, m_camera_position, world_pos))
				continue;
		}
		f32 transformed_pos[4] = { pos.X, pos.Y, pos.Z, 1.0f };
		trans.multiplyWith1x4Matrix(transformed_pos);
		if (transformed_pos[3] <= 0) // negative Z means behind camera
			continue;
		f32 zDiv = transformed_pos[3] == 0.0f ? 1.0f : (1.0f / transformed_pos[3]);

		u32 font_size = 0;
		if (nametag->scale_z) {
			// Higher default since nametag should be reasonably visible
			// even at distance.
			u32 base_size = nametag->textsize.value_or(default_font_size * 3.2f);
			f32 adjusted_d = std::max(transformed_pos[3] - minimum_d, 0.0f);
			// Normalized for base_size * BS
			f32 scale = (smoothing_k / (adjusted_d + smoothing_k)) / BS;
			font_size = myround(font_size_mult *
				rangelim(base_size * BS * scale, 0, base_size));
		} else {
			font_size = myround(font_size_mult * nametag->textsize.value_or(default_font_size));
		}
		if (font_size <= 1)
			continue;
		// TODO: This is quite primitive. It would be better to let the GPU handle
		// scaling (draw to RTT first?).
		{
			// Because the current approach puts a high load on the font engine
			// we quantize the font size and set an arbitrary maximum...
			font_size = MYMIN(font_size, 256);
			if (font_size > 128)
				font_size &= ~(1|2|4);
			else if (font_size > 64)
				font_size &= ~(1|2);
			else if (font_size > 32)
				font_size &= ~1;
		}
		auto *font = g_fontengine->getFont(font_size);
		assert(font);

		const auto wtext = utf8_to_wide(nametag->text);
		// Measure dimensions with escapes removed
		core::dimension2du textsize = font->getDimension(unescape_translate(wtext).c_str());
		v2s32 screen_pos;
		screen_pos.X = screensize.X *
			(0.5f + transformed_pos[0] * zDiv * 0.5f) - textsize.Width / 2;
		screen_pos.Y = screensize.Y *
			(0.5f - transformed_pos[1] * zDiv * 0.5f) - textsize.Height / 2;
		core::rect<s32> size(0, 0, textsize.Width, textsize.Height);

		auto bgcolor = nametag->getBgColor(m_show_nametag_backgrounds);
		if (bgcolor.getAlpha() != 0) {
			core::rect<s32> bg_size(-2, 0, textsize.Width + 2, textsize.Height);
			driver->draw2DRectangle(bgcolor, bg_size + screen_pos);
		}

		// but draw text with escapes
		font->draw(translate_string(wtext).c_str(),
			size + screen_pos, nametag->textcolor);
	}
}

Nametag *Camera::addNametag(const Nametag &params)
{
	assert(params.parent_node);
	auto *nametag = new Nametag(params);
	m_nametags.push_back(nametag);
	return nametag;
}

void Camera::removeNametag(Nametag *nametag)
{
	auto it = std::find(m_nametags.begin(), m_nametags.end(), nametag);
	assert(it != m_nametags.end());
	m_nametags.erase(it);
	delete nametag;
}

std::array<core::plane3d<f32>, 4> Camera::getFrustumCullPlanes() const
{
	using scene::SViewFrustum;
	const auto &frustum_planes = m_cameranode->getViewFrustum()->planes;
	return {
		frustum_planes[SViewFrustum::VF_LEFT_PLANE],
		frustum_planes[SViewFrustum::VF_RIGHT_PLANE],
		frustum_planes[SViewFrustum::VF_BOTTOM_PLANE],
		frustum_planes[SViewFrustum::VF_TOP_PLANE],
	};
}

void Camera::updateWieldedTool(bool offhand)
{
	HandItem &hand = m_hands[offhand];
	hand.shown = hand.next;
	hand.shown_is_hand = hand.next_is_hand;
	hand.node->setItem(hand.next, m_client);
	hand.node->setLightColorAndAnimation(m_player_light_color, m_client->getAnimationTime());
}
