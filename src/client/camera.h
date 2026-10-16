// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2010-2013 celeron55, Perttu Ahola <celeron55@gmail.com>

#pragma once

#include <cmath>
#include "irrlichttypes.h"
#include "inventory.h" // ItemStack
#include "itemdef.h" // SwingAnimation
#include "hand_animation.h"
#include "util/basic_macros.h"
#include "util/numeric.h"
#include <plane3d.h>
#include <array>
#include <vector>
#include <optional>

class LocalPlayer;
struct MapDrawControl;
class Client;
class RenderingEngine;
class WieldMeshSceneNode;

enum CameraMode : int;

namespace scene {
	class ICameraSceneNode;
	class ISceneManager;
	class ISceneNode;
};

struct Nametag
{
	scene::ISceneNode *parent_node = nullptr;
	std::string text;
	video::SColor textcolor;
	std::optional<video::SColor> bgcolor;
	std::optional<u32> textsize;
	v3f pos; // offset from parent node
	bool scale_z;
	bool see_through = true; // shown when nodes are in the way
	f32 range = 0.0f; // maximum distance in nodes, 0 = unlimited

	video::SColor getBgColor(bool use_fallback) const
	{
		if (bgcolor.has_value())
			return bgcolor.value();
		else if (!use_fallback)
			return video::SColor(0, 0, 0, 0);
		else if (textcolor.getBrightness() > 186)
			// Dark background for light text
			return video::SColor(50, 50, 50, 50);
		else
			// Light background for dark text
			return video::SColor(50, 255, 255, 255);
	}
};

/*
	Client camera class, manages the player and camera scene nodes, the viewing distance
	and performs view bobbing etc. It also displays the wielded tool in front of the
	first-person camera.
*/
class Camera
{
public:
	Camera(MapDrawControl &draw_control, Client *client, RenderingEngine *rendering_engine);
	~Camera();

	static void settingChangedCallback(const std::string &name, void *data);
	void readSettings();

	// Get camera scene node.
	// It has the eye transformation, pitch and view bobbing applied.
	inline scene::ICameraSceneNode* getCameraNode() const
	{
		return m_cameranode;
	}

	// Get the camera position (in absolute scene coordinates).
	// This has view bobbing applied.
	inline v3f getPosition() const
	{
		return m_camera_position;
	}

	// Returns the absolute position of the head SceneNode in the world
	v3f getHeadPosition() const;

	// Get the camera direction (in absolute camera coordinates).
	// This has view bobbing applied.
	inline v3f getDirection() const
	{
		return m_camera_direction;
	}

	// Get the camera offset
	inline v3s16 getOffset() const
	{
		return m_camera_offset;
	}

	// Horizontal field of view
	inline f32 getFovX() const
	{
		return m_fov_x;
	}

	// Vertical field of view
	inline f32 getFovY() const
	{
		return m_fov_y;
	}

	// Get maximum of getFovX() and getFovY()
	inline f32 getFovMax() const
	{
		return MYMAX(m_fov_x, m_fov_y);
	}

	// Returns a lambda that when called with an object's position and bounding-sphere
	// radius (both in BS space) returns true if, and only if the object should be
	// frustum-culled.
	auto getFrustumCuller() const
	{
		return [planes = getFrustumCullPlanes(),
				camera_offset = intToFloat(m_camera_offset, BS)
				](v3f position, f32 radius) {
			v3f pos_camspace = position - camera_offset;
			for (auto &plane : planes) {
				if (plane.getDistanceTo(pos_camspace) > radius)
					return true;
			}
			return false;
		};
	}

	// Notify about new server-sent FOV and initialize smooth FOV transition
	void notifyFovChange();

	// Step the camera: updates the viewing range and view bobbing.
	void step(f32 dtime);

	// Update the camera from the local player's position.
	// full_punch_interval is the attack cooldown of the wielded item in seconds.
	void update(LocalPlayer* player, f32 frametime, f32 full_punch_interval);

	// Adjust the camera offset when needed
	void updateOffset();

	// Update render distance
	void updateViewingRange();

	// Swing a hand like Minecraft's LivingEntity.swing(). A swing that is
	// in its first half is not restarted. Returns whether a swing started.
	bool swingHand(const SwingAnimation &animation, bool offhand = false);

	// The wielded item was used up (e.g. a node was placed): snap it down so
	// that it rises again (Minecraft's FirstPersonHandsAndItems.itemUsed())
	void itemUsed(bool offhand = false) { m_hands[offhand].height = 0.0f; }

	// Restart the attack cooldown that the wielded item rises with
	void resetAttackStrength() { m_attack_strength_ticks = 0; }

	void setHandAnimationParams(const HandAnimationParams &params) { m_hand_params = params; }
	const HandAnimationParams &getHandAnimationParams() const { return m_hand_params; }

	// Show the wielded item being used (eaten, drawn, ...)
	void startItemUse(const ItemUse &use);
	void stopItemUse() { m_item_use = ItemUse(); }
	bool isUsingItem() const { return m_item_use.animation != ItemUseAnimation::NONE; }

	// Replace the wielded item mesh
	// is_hand: the item is the hand (no item selected)
	void wield(const ItemStack &item, bool animate = true, bool is_hand = false);

	// Replace the item shown in the other hand
	void wieldOffhand(const ItemStack &item, bool animate = true);

	// Draw the wielded tool.
	// This has to happen *after* the main scene is drawn.
	// Warning: This clears the Z buffer.
	void drawWieldedTool(core::matrix4* translation=NULL);

	// Toggle the current camera mode
	void toggleCameraMode();

	// Set the current camera mode
	inline void setCameraMode(CameraMode mode)
	{
		m_camera_mode = mode;
	}

	//read the current camera mode
	inline CameraMode getCameraMode() const
	{
		return m_camera_mode;
	}

	Nametag *addNametag(const Nametag &params);

	void removeNametag(Nametag *nametag);

	void drawNametags();

	inline void addArmInertia(f32 player_yaw);

private:
	// Use getFrustumCuller().
	// This helper just exists to decrease the header's number of includes.
	std::array<core::plane3d<f32>, 4> getFrustumCullPlanes() const;

	// Nodes
	scene::ISceneNode *m_playernode = nullptr;
	scene::ISceneNode *m_headnode = nullptr;
	scene::ICameraSceneNode *m_cameranode = nullptr;

	scene::ISceneManager *m_wieldmgr = nullptr;

	// draw control
	MapDrawControl& m_draw_control;

	Client *m_client;

	// Default Client FOV (as defined by the "fov" setting)
	f32 m_cache_fov;

	// Absolute camera position
	v3f m_camera_position;
	// Absolute camera direction
	v3f m_camera_direction;
	// Camera offset
	v3s16 m_camera_offset;

	bool m_stepheight_smooth_active = false;
	// Eye height as currently shown by the camera, eased towards the player's eye height
	f32 m_eye_height_smooth = NAN;

	// Server-sent FOV variables
	bool m_server_sent_fov = false;
	f32 m_curr_fov_degrees, m_target_fov_degrees;

	// FOV transition variables
	bool m_fov_transition_active = false;
	f32 m_fov_diff, m_transition_time;

	v2f m_wieldmesh_offset = v2f(55.0f, -35.0f);
	v2f m_arm_dir;
	v2f m_cam_vel;
	v2f m_cam_vel_old;
	v2f m_last_cam_pos;

	// Field of view and aspect ratio stuff
	f32 m_aspect = 1.0f;
	f32 m_fov_x = 1.0f;
	f32 m_fov_y = 1.0f;

	// View bobbing animation frame (0 <= m_view_bobbing_anim < 1)
	f32 m_view_bobbing_anim = 0.0f;
	// If 0, view bobbing is off (e.g. player is standing).
	// If 1, view bobbing is on (player is walking).
	// If 2, view bobbing is getting switched off.
	s32 m_view_bobbing_state = 0;
	// Speed of view bobbing animation
	f32 m_view_bobbing_speed = 0.0f;

	// Hand animation, stepped in Minecraft's 20 Hz client ticks and
	// interpolated between them. m_hand_tick_timer is the time into the tick.
	void tickHand();
	// Position and rotation of the item in a hand in the wield scene
	void updateWieldPose(bool offhand, f32 bob_x, f32 bob_y);
	// Show the item that waits to be shown in a hand
	void updateWieldedTool(bool offhand);
	f32 m_hand_tick_timer = 0.0f;
	HandAnimationParams m_hand_params;
	// The current swing (Minecraft's LivingEntity.SwingState)
	bool m_swinging = false;
	bool m_swing_offhand = false;
	SwingAnimationType m_swing_type = SwingAnimationType::WHACK;
	s32 m_swing_duration = 0; // ticks
	s32 m_swing_ticks = 0;
	// Swing progress (0 <= m_attack_anim <= 1) at the current and previous tick
	f32 m_attack_anim = 0.0f;
	f32 m_attack_anim_old = 0.0f;
	// Item use, animation NONE = not using
	ItemUse m_item_use;
	s32 m_use_duration = 0; // ticks
	s32 m_use_remaining = 0; // ticks
	// Ticks since the last attack, the main hand item rises with the cooldown cubed
	s32 m_attack_strength_ticks = 0;
	f32 m_attack_interval = 0.25f;

	// The items in the main hand and the other hand
	struct HandItem
	{
		WieldMeshSceneNode *node = nullptr;
		// How far the item is raised (1 = fully up) at the current and previous tick
		f32 height = 0.0f;
		f32 height_old = 0.0f;
		// Item to show once the shown one is lowered
		ItemStack next;
		bool next_is_hand = false;
		ItemStack shown;
		bool shown_is_hand = false;
	};
	HandItem m_hands[2];

	CameraMode m_camera_mode;

	f32 m_cache_view_bobbing_amount;
	bool m_arm_inertia;

	std::vector<Nametag*> m_nametags;
	bool m_show_nametag_backgrounds;

	// Last known light color of the player
	video::SColor m_player_light_color;
};
