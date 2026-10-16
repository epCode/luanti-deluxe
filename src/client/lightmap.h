// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once

#include "irrlichttypes.h"
#include "irr_v3d.h"
#include "lighting.h"
#include <SColor.h>
#include <random>
#include <vector>

class Client;
class IShaderUniformSetterFactory;

/*
	Lightmap lighting (see LightmapLighting in lighting.h).

	This reproduces the per-frame state of Minecraft's (Java Edition 26.x)
	lightmap: a 16x16 table indexed by block and sky light level. The shaders
	evaluate the same table from the uniforms below; LightmapState also
	evaluates it on the CPU for things lit without shaders.
*/

/// One keyframe track of a Minecraft timeline, sampled over a 24000 tick day
struct LightmapTrack
{
	enum class Easing { Linear, CubicBezier };

	struct Key {
		int tick;
		v3f value;
	};

	std::vector<Key> keys;
	Easing easing = Easing::Linear;
	// cubic_bezier control points (x1, y1, x2, y2)
	f32 bezier[4] = {0.0f, 0.0f, 1.0f, 1.0f};
	bool color = false; // values are 8-bit colors, lerped per channel like ARGB.srgbLerp

	v3f sample(f32 tick) const;
};

struct LightmapUniforms
{
	f32 sky_factor = 1.0f;
	f32 block_factor = 1.5f;
	f32 night_vision = 0.0f;
	f32 darkness = 0.0f;
	f32 darken_world = 0.0f;
	f32 brightness = 0.5f;
	v3f sky_light_color{1.0f, 1.0f, 1.0f};
	v3f ambient_color;
	v3f block_light_tint;
	v3f night_vision_color;
	// Environmental fog in nodes, including rain
	f32 fog_start = 0.0f;
	f32 fog_end = 1024.0f;
};

/// Sky of the lightmap model for one frame (Minecraft SkyRenderer state)
struct LightmapSky
{
	v3f sky_color;          // sky disc color
	v3f fog_color;          // fog and clear color
	f32 sun_angle = 0.0f;   // radians, 0 at noon
	f32 moon_angle = 0.0f;
	f32 star_angle = 0.0f;
	f32 star_brightness = 0.0f;
	f32 rain_brightness = 1.0f; // sun and moon opacity
	video::SColorf sunrise; // sunrise/sunset fan color, alpha = strength
	v3f cloud_color;        // multiplier for the cloud color
	f32 sky_end = 512.0f;   // sky fog distance in nodes
	bool dark_disc = false; // camera below the horizon: draw the dark disc
};

class LightmapState
{
public:
	/// Fluid at the camera, for its fog (FogType)
	enum class CameraFluid { None, Water, Lava };

	LightmapState();

	/// Advances the state by dtime seconds.
	/// \param time_of_day Luanti time of day, 0..1 (0.5 is noon)
	/// Consumes the one-shot params.sky_flash.
	/// \param eye_sky_light sky light level at the camera, for rain fog
	void step(f32 dtime, LightmapLighting &params, f32 time_of_day,
			u8 eye_sky_light, CameraFluid eye_fluid = CameraFluid::None);

	const LightmapUniforms &getUniforms() const { return m_uniforms; }

	/// Whether the lightmap model is active for the local player
	bool isEnabled() const { return m_enabled; }

	/// Lightmap color for whole light levels (one lightmap texel), 0..1
	video::SColorf texel(int block, int sky) const;

	/// Lightmap color for fractional levels, interpolated like the terrain
	/// shader's linear lightmap sampling
	video::SColorf sample(f32 block, f32 sky) const;

	/// Weather levels after fading, 0..1
	f32 getRainLevel() const { return m_rain; }
	f32 getThunderLevel() const { return m_thunder * m_rain; }

	/// Minecraft day time in ticks (0 = sunrise, 6000 = noon)
	f32 getDayTime() const { return m_day_time; }

	/// Sky light color and factor of the day cycle, without weather
	static v3f daySkyLightColor(f32 day_time);
	static f32 daySkyLightFactor(f32 day_time);

	/**
	 * Sky and fog colors and celestial positions (SkyRenderer,
	 * FogRenderer and AtmosphericFogEnvironment).
	 * \param base_sky sky color of the biome/dimension (visual/sky_color)
	 * \param base_fog fog color of the biome/dimension (visual/fog_color)
	 * \param forward camera direction
	 * \param render_distance view range in nodes
	 * \param below_horizon camera is below the horizon height
	 */
	LightmapSky computeSky(v3f base_sky, v3f base_fog, v3f forward,
			f32 render_distance, bool below_horizon) const;

private:
	void tick(const LightmapLighting &params);

	bool m_enabled = false;
	LightmapUniforms m_uniforms;

	f32 m_tick_timer = 0.0f;
	u32 m_tick_count = 0;
	f32 m_flicker = 0.0f;
	f32 m_rain = 0.0f;
	f32 m_thunder = 0.0f;
	f32 m_sky_flash = 0.0f;
	f32 m_rain_fog = 0.0f;
	CameraFluid m_fluid = CameraFluid::None;
	int m_water_vision_time = 0; // ticks
	v3f m_water_fog_color;
	f32 waterVision() const;
	f32 m_day_time = 6000.0f;
	f32 m_brightness_setting = 0.5f;
	std::mt19937 m_random;

	f32 randomFloat();
};

/// Material color for objects lit with the lightmap: whole block and sky
/// light levels in red and green, see object_shader
inline video::SColor lightmap_object_light(u8 block, u8 sky)
{
	return video::SColor(255, std::min<u8>(block, 15) * 17, std::min<u8>(sky, 15) * 17, 0);
}

/// Creates the shader uniform setter factory for the lightmap uniforms
IShaderUniformSetterFactory *createLightmapUniformSetterFactory(Client *client);
