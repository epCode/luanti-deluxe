// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2021 x2048, Dmitry Kostenko <codeforsmile@gmail.com>

#pragma once
#include "SColor.h"
#include "irr_v3d.h"
#include "light.h"


/**
 * Parameters for automatic exposure compensation
 *
 * Automatic exposure compensation uses the following equation:
 *
 * wanted_exposure = 2^exposure_correction / clamp(observed_luminance, 2^luminance_min, 2^luminance_max)
 *
 */
struct AutoExposure
{
	/// @brief Minimum boundary for computed luminance
	float luminance_min;
	/// @brief Maximum boundary for computed luminance
	float luminance_max;
	/// @brief Luminance bias. Higher values make the scene darker, can be negative.
	float exposure_correction;
	/// @brief Speed of transition from dark to bright scenes
	float speed_dark_bright;
	/// @brief Speed of transition from bright to dark scenes
	float speed_bright_dark;
	/// @brief Power value for center-weighted metering. Value of 1.0 measures entire screen uniformly
	float center_weight_power;

	constexpr AutoExposure()
		: luminance_min(-3.f),
		luminance_max(-3.f),
		exposure_correction(0.0f),
		speed_dark_bright(1000.f),
		speed_bright_dark(1000.f),
		center_weight_power(1.f)
	{}
};

/**
 * Parameters of the lightmap lighting model.
 *
 * The lightmap model reproduces Minecraft (Java Edition 26.x) world lighting:
 * every vertex carries a sky light and a block light level, and a per-frame
 * lightmap turns that pair into a color, depending on the time of day, the
 * weather and the dimension. The defaults are those of the overworld.
 * See doc/lua_api.md, `set_lighting`.
 */
struct LightmapLighting
{
	/// Render the world with the lightmap model.
	/// Defaults to on for games with separate sky light (see light.h).
	bool enabled = g_separate_sky_light;
	/// Light at sky and block light level 0 (visual/ambient_light_color)
	video::SColor ambient_color {255, 10, 10, 10};
	/// Color of sky light (visual/sky_light_color), before the day cycle
	video::SColor sky_light_color {255, 255, 255, 255};
	/// Strength of sky light (visual/sky_light_factor), before the day cycle
	float sky_light_factor = 1.0f;
	/// Tint of dim block light (visual/block_light_tint)
	video::SColor block_light_tint {255, 255, 216, 140};
	/// Color night vision brightens dark places to (visual/night_vision_color)
	video::SColor night_vision_color {255, 153, 153, 153};
	/// Apply the overworld day cycle to sky light color and factor
	bool day_cycle = true;
	/// Face shading without strong top/bottom contrast (cardinal_light nether)
	bool constant_shade = false;
	/// Weather strength in [0, 1]; the client fades towards these values
	float rain = 0.0f;
	float thunder = 0.0f;
	/// Night vision strength in [0, 1]
	float night_vision = 0.0f;
	/// Darkness effect strength in [0, 1]
	float darkness = 0.0f;
	/// Darkening of the world (boss fog) in [0, 1]
	float darken_world = 0.0f;
	/// Seconds the sky stays fully lit, e.g. after a lightning strike
	float sky_flash = 0.0f;
	/// Environmental fog distances in nodes (visual/fog_start_distance and
	/// visual/fog_end_distance); render distance fog comes on top
	float fog_start = 0.0f;
	float fog_end = 1024.0f;
	/// Below this height (in nodes) the sky's lower half is dark
	/// (LevelData.getHorizonHeight)
	float horizon_height = 0.0f;
	/// Fog color with the camera in water (visual/water_fog_color)
	video::SColor water_fog_color {255, 5, 5, 51};
};

/** Describes ambient light settings for a player
 */
struct Lighting
{
	AutoExposure exposure;
	float shadow_intensity {0.0f};
	float saturation {1.0f};
	float volumetric_light_strength {0.0f};
	video::SColor shadow_tint {255, 0, 0, 0};
	float bloom_intensity {0.05f};
	float bloom_strength_factor {1.0f};
	float bloom_radius {1.0f};
	/**
	 * Absolute motion blur strength, or negative to leave it to the player.
	 *
	 * A non-negative value overrides the player's own motion blur settings
	 * outright: it may exceed their configured strength, and it switches the
	 * effect on even for a player who has it disabled. Negative means unset,
	 * in which case the player's own settings apply.
	 */
	float motion_blur_strength {-1.0f};
	v3f shadow_direction;
	LightmapLighting lightmap;
};

/**
 * Resolve the motion blur strength to actually render with.
 *
 * A server-provided strength wins outright; the player's settings are only
 * consulted when the server has left it unset.
 */
inline float resolveMotionBlurStrength(const Lighting &lighting,
		bool player_enabled, float player_strength)
{
	if (lighting.motion_blur_strength >= 0.0f)
		return lighting.motion_blur_strength;
	return player_enabled ? player_strength : 0.0f;
}
