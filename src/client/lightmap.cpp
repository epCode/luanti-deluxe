// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later

#include "lightmap.h"
#include "client.h"
#include "client/localplayer.h"
#include "client/shader.h"
#include "settings.h"
#include "constants.h"
#include <IVideoDriver.h>
#include <IMaterialRendererServices.h>
#include "util/numeric.h"
#include <cmath>

/*
	Day cycle of the Minecraft overworld (data/minecraft/timeline/day.json,
	Java Edition 26.3), in day time ticks: 0 is sunrise, 6000 noon.
*/

static v3f rgb(u32 c)
{
	return v3f((c >> 16 & 0xFF) / 255.0f, (c >> 8 & 0xFF) / 255.0f, (c & 0xFF) / 255.0f);
}

static const LightmapTrack s_sky_light_factor = {
	{{730, v3f(1.0f)}, {11270, v3f(1.0f)}, {13140, v3f(0.24f)}, {22860, v3f(0.24f)}},
};

static const LightmapTrack s_sky_light_color = {
	{{730, rgb(0xffffff)}, {11270, rgb(0xffffff)}, {13140, rgb(0x7a7aff)}, {22860, rgb(0x7a7aff)}},
	LightmapTrack::Easing::Linear, {0.0f, 0.0f, 1.0f, 1.0f}, true
};

static const LightmapTrack s_sky_color = {
	{{133, rgb(0xffffff)}, {11867, rgb(0xffffff)}, {13670, rgb(0x000000)}, {22330, rgb(0x000000)}},
};

static const LightmapTrack s_fog_color = {
	{{133, rgb(0xffffff)}, {11867, rgb(0xffffff)}, {13670, rgb(0x0f0f16)}, {22330, rgb(0x0f0f16)}},
};

static const LightmapTrack s_cloud_color = {
	{{133, rgb(0xffffff)}, {11867, rgb(0xffffff)}, {13670, rgb(0x191926)}, {22330, rgb(0x191926)}},
};

static const LightmapTrack s_star_brightness = {
	{{92, v3f(0.037f)}, {627, v3f(0.0f)}, {11373, v3f(0.0f)}, {11732, v3f(0.016f)},
	{11959, v3f(0.044f)}, {12399, v3f(0.143f)}, {12729, v3f(0.258f)}, {13228, v3f(0.5f)},
	{22772, v3f(0.5f)}, {23032, v3f(0.364f)}, {23356, v3f(0.225f)}, {23758, v3f(0.101f)}},
};

// Sunrise/sunset fan color, ARGB; split into RGB and alpha tracks
static const u32 s_sunrise_keys[][2] = {
	{71, 0x5fefa333}, {310, 0x29f5ba33}, {565, 0x06fbd433}, {730, 0x00ffe533},
	{11270, 0x00ffe533}, {11397, 0x04fcd833}, {11522, 0x0ff9cb33}, {11690, 0x29f5ba33},
	{11929, 0x5fefa333}, {12243, 0xb1e78733}, {12358, 0xcce47e33}, {12512, 0xe9e07233},
	{12613, 0xf6dd6b33}, {12732, 0xfeda6333}, {12841, 0xfed75c33}, {13035, 0xecd25133},
	{13252, 0xc1cc4733}, {13775, 0x36be3733}, {13888, 0x1fbb3533}, {14039, 0x09b73333},
	{14192, 0x00b33333}, {21807, 0x00b23333}, {21961, 0x09b73333}, {22112, 0x1fbb3533},
	{22225, 0x36be3733}, {22748, 0xc1cc4733}, {22965, 0xecd25133}, {23159, 0xfed75c33},
	{23272, 0xfeda6333}, {23488, 0xe9e07233}, {23642, 0xcce47e33}, {23757, 0xb1e78733},
};

static LightmapTrack make_sunrise_track(bool alpha)
{
	LightmapTrack t;
	for (const auto &k : s_sunrise_keys)
		t.keys.push_back({(int)k[0], alpha ? v3f((k[1] >> 24) / 255.0f) : rgb(k[1])});
	return t;
}
static const LightmapTrack s_sunrise_rgb = make_sunrise_track(false);
static const LightmapTrack s_sunrise_alpha = make_sunrise_track(true);

// sun_angle: keyframes 6000:360, 6000:0, i.e. one eased turn per day
// starting at noon
static const f32 s_sun_angle_bezier[4] = {0.362f, 0.241f, 0.638f, 0.759f};

// Timelines.NIGHT_SKY_LIGHT_COLOR, used by the weather layers
static const u32 NIGHT_SKY_LIGHT_COLOR = 0x7a7aff;

static f32 cubic_bezier(const f32 c[4], f32 x)
{
	// Solve for the curve parameter at x, then evaluate y
	auto bez = [] (f32 p1, f32 p2, f32 t) {
		f32 u = 1.0f - t;
		return 3.0f * u * u * t * p1 + 3.0f * u * t * t * p2 + t * t * t;
	};
	f32 lo = 0.0f, hi = 1.0f, t = x;
	for (int i = 0; i < 32; i++) {
		t = 0.5f * (lo + hi);
		if (bez(c[0], c[2], t) < x)
			lo = t;
		else
			hi = t;
	}
	return bez(c[1], c[3], t);
}

v3f LightmapTrack::sample(f32 tick) const
{
	constexpr f32 period = 24000.0f;
	if (keys.empty())
		return v3f();
	if (keys.size() == 1)
		return keys[0].value;
	tick = std::fmod(tick, period);
	if (tick < 0.0f)
		tick += period;

	// Segments, including the ones wrapping around the period
	const Key *from = &keys.back(), *to = &keys.front();
	f32 from_tick = keys.back().tick - period, to_tick = keys.front().tick;
	if (tick >= keys.front().tick) {
		from_tick = keys.back().tick;
		to_tick = keys.front().tick + period;
		for (size_t i = 0; i + 1 < keys.size(); i++) {
			if (tick < keys[i + 1].tick) {
				from = &keys[i];
				to = &keys[i + 1];
				from_tick = from->tick;
				to_tick = to->tick;
				break;
			}
		}
	}

	if (tick <= from_tick)
		return from->value;
	if (tick >= to_tick)
		return to->value;
	f32 t = (tick - from_tick) / (to_tick - from_tick);
	if (easing == Easing::CubicBezier)
		t = cubic_bezier(bezier, t);
	return from->value + (to->value - from->value) * t;
}

LightmapState::LightmapState() :
	m_random(std::random_device{}())
{
}

f32 LightmapState::randomFloat()
{
	return std::uniform_real_distribution<f32>(0.0f, 1.0f)(m_random);
}

v3f LightmapState::daySkyLightColor(f32 day_time)
{
	return s_sky_light_color.sample(day_time);
}

f32 LightmapState::daySkyLightFactor(f32 day_time)
{
	return s_sky_light_factor.sample(day_time).X;
}

// One client tick (20 per second)
void LightmapState::tick(const LightmapLighting &params)
{
	// LightmapRenderStateExtractor.tick
	m_flicker += (randomFloat() - randomFloat()) * randomFloat() * randomFloat() * 0.1f;
	m_flicker *= 0.9f;

	// Level.tick: weather fades by 0.01 per tick
	auto approach = [] (f32 &v, f32 target) {
		if (v < target)
			v = std::min(v + 0.01f, target);
		else if (v > target)
			v = std::max(v - 0.01f, target);
	};
	approach(m_rain, params.rain);
	approach(m_thunder, params.thunder);

	if (m_sky_flash > 0.0f)
		m_sky_flash -= 0.05f;

	// LocalPlayer.aiStep
	if (m_fluid == CameraFluid::Water)
		m_water_vision_time = std::min(m_water_vision_time + 1, 600);
	else
		m_water_vision_time = std::max(m_water_vision_time - 10, 0);

	m_tick_count++;
}

// LocalPlayer.getWaterVision
f32 LightmapState::waterVision() const
{
	if (m_fluid != CameraFluid::Water)
		return 0.0f;
	if (m_water_vision_time >= 600)
		return 1.0f;
	f32 t = m_water_vision_time;
	f32 a = rangelim(t / 100.0f, 0.0f, 1.0f);
	f32 b = t < 100.0f ? 0.0f : rangelim((t - 100.0f) / 500.0f, 0.0f, 1.0f);
	return a * 0.6f + b * 0.39999998f;
}

void LightmapState::step(f32 dtime, LightmapLighting &params, f32 time_of_day,
		u8 eye_sky_light, CameraFluid eye_fluid)
{
	m_enabled = params.enabled;
	m_fluid = eye_fluid;
	m_water_fog_color = rgb(params.water_fog_color.color);

	// A sky flash is an event: start it once
	if (params.sky_flash > 0.0f) {
		m_sky_flash = std::max(m_sky_flash, params.sky_flash);
		params.sky_flash = 0.0f;
	}

	m_tick_timer += dtime;
	// Don't catch up on long pauses
	m_tick_timer = std::min(m_tick_timer, 1.0f);
	while (m_tick_timer >= 0.05f) {
		m_tick_timer -= 0.05f;
		tick(params);
	}
	const f32 partial_tick = m_tick_timer / 0.05f;

	// Luanti time 0.25 (6:00) is Minecraft's sunrise, day time 0
	m_day_time = std::fmod(time_of_day * 24000.0f + 18000.0f, 24000.0f);

	LightmapUniforms &u = m_uniforms;

	// Sky light: dimension value, day cycle, then weather (WeatherAttributes)
	f32 sky_factor = params.sky_light_factor;
	v3f sky_color = rgb(params.sky_light_color.color);
	if (params.day_cycle) {
		sky_factor *= daySkyLightFactor(m_day_time);
		sky_color *= daySkyLightColor(m_day_time);
	}
	const f32 thunder_level = m_thunder * m_rain;
	const f32 rain_level = m_rain - thunder_level;
	const v3f night_color = rgb(NIGHT_SKY_LIGHT_COLOR);
	auto weather = [&] (f32 level, f32 alpha) {
		if (level <= 0.0f)
			return;
		// Colors carry their alpha as 8 bits (ARGB.color(float, int))
		f32 color_alpha = std::floor(alpha * 255.0f) / 255.0f;
		f32 f = sky_factor + (0.24f - sky_factor) * alpha;
		sky_factor += (f - sky_factor) * level;
		v3f c = sky_color + (night_color - sky_color) * color_alpha;
		sky_color += (c - sky_color) * level;
	};
	weather(rain_level, 0.3125f);
	weather(thunder_level, 0.52734375f);
	// Lightning
	if (m_sky_flash > 0.0f)
		sky_factor = 1.0f;

	u.sky_factor = sky_factor;
	u.sky_light_color = sky_color;
	u.block_factor = m_flicker + 1.4f;
	u.ambient_color = rgb(params.ambient_color.color);
	u.block_light_tint = rgb(params.block_light_tint.color);
	u.night_vision_color = rgb(params.night_vision_color.color);
	u.night_vision = params.night_vision;
	u.darken_world = params.darken_world;

	// AtmosphericFogEnvironment: rain pulls the environmental fog in where
	// the sky is visible
	f32 rain_fog = m_rain * rangelim((eye_sky_light - 8.0f) / 7.0f, 0.0f, 1.0f);
	m_rain_fog += (rain_fog - m_rain_fog) * std::min(1.0f, dtime * 20.0f * 0.2f);
	u.fog_start = params.fog_start - 160.0f * m_rain_fog;
	u.fog_end = std::max(std::min(96.0f, params.fog_end), params.fog_end - 256.0f * m_rain_fog);
	if (m_fluid == CameraFluid::Water) {
		// WaterFogEnvironment
		u.fog_start = -8.0f;
		u.fog_end = 96.0f * std::max(0.25f, waterVision());
	} else if (m_fluid == CameraFluid::Lava) {
		// LavaFogEnvironment
		u.fog_start = 0.25f;
		u.fog_end = 1.0f;
	}

	// Darkness effect: pulsing darkening, and it cancels the brightness option
	const f32 darkness = params.darkness;
	f32 pulse = std::cos((m_tick_count - partial_tick) * (f32)M_PI * 0.025f);
	u.darkness = std::max(0.0f, pulse * 0.45f * darkness);
	f32 brightness_option = rangelim(g_settings->getFloat("lightmap_brightness"), 0.0f, 1.0f);
	u.brightness = std::max(0.0f, brightness_option - darkness);

}

static f32 lightmap_curve(f32 level)
{
	return level / (4.0f - 3.0f * level);
}

// core/lightmap.fsh (Java Edition 26.3), one texel
video::SColorf LightmapState::texel(int block, int sky) const
{
	const LightmapUniforms &u = m_uniforms;
	f32 block_level = block / 15.0f;
	f32 sky_level = sky / 15.0f;
	f32 block_brightness = lightmap_curve(block_level) * u.block_factor;
	f32 sky_brightness = lightmap_curve(sky_level) * u.sky_factor;

	v3f nv = u.night_vision_color * u.night_vision;
	v3f c(std::max(u.ambient_color.X, nv.X), std::max(u.ambient_color.Y, nv.Y),
			std::max(u.ambient_color.Z, nv.Z));
	c += u.sky_light_color * sky_brightness;
	f32 parabola = (2.0f * block_level - 1.0f) * (2.0f * block_level - 1.0f);
	v3f block_color = u.block_light_tint + (v3f(1.0f) - u.block_light_tint) * (0.9f * parabola);
	c += block_color * block_brightness;
	c += (c * v3f(0.7f, 0.6f, 0.6f) - c) * u.darken_world;
	c -= v3f(u.darkness);
	c.X = rangelim(c.X, 0.0f, 1.0f);
	c.Y = rangelim(c.Y, 0.0f, 1.0f);
	c.Z = rangelim(c.Z, 0.0f, 1.0f);

	f32 max_c = std::max(std::max(c.X, c.Y), c.Z);
	if (max_c > 0.0f) {
		f32 inv = 1.0f - max_c;
		f32 scaled = 1.0f - inv * inv * inv * inv;
		v3f not_gamma = c * (scaled / max_c);
		c += (not_gamma - c) * u.brightness;
	}
	// Stored in an RGBA8 texture
	auto q = [] (f32 v) { return std::round(v * 255.0f) / 255.0f; };
	return video::SColorf(q(c.X), q(c.Y), q(c.Z), 1.0f);
}

video::SColorf LightmapState::sample(f32 block, f32 sky) const
{
	block = rangelim(block, 0.0f, 15.0f);
	sky = rangelim(sky, 0.0f, 15.0f);
	int b0 = (int)block, s0 = (int)sky;
	int b1 = std::min(b0 + 1, 15), s1 = std::min(s0 + 1, 15);
	f32 fb = block - b0, fs = sky - s0;
	auto lerp = [] (const video::SColorf &a, const video::SColorf &b, f32 t) {
		return video::SColorf(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
				a.b + (b.b - a.b) * t, 1.0f);
	};
	return lerp(lerp(texel(b0, s0), texel(b1, s0), fb),
			lerp(texel(b0, s1), texel(b1, s1), fb), fs);
}

static v3f lerp3(f32 t, v3f a, v3f b)
{
	return a + (b - a) * t;
}

static v3f greyscale(v3f c)
{
	return v3f(c.X * 0.3f + c.Y * 0.59f + c.Z * 0.11f);
}

static v3f clamp01(v3f c)
{
	return v3f(rangelim(c.X, 0.0f, 1.0f), rangelim(c.Y, 0.0f, 1.0f), rangelim(c.Z, 0.0f, 1.0f));
}

LightmapSky LightmapState::computeSky(v3f base_sky, v3f base_fog, v3f forward,
		f32 render_distance, bool below_horizon) const
{
	LightmapSky s;
	const f32 t = m_day_time;
	const f32 thunder = m_thunder * m_rain;
	const f32 rain = m_rain - thunder; // weather layer levels

	// Celestial angles (sun_angle runs over one day, starting at noon; the
	// track starts at tick 6000)
	f32 day_fraction = std::fmod(t - 6000.0f + 24000.0f, 24000.0f) / 24000.0f;
	f32 sun_deg = 360.0f * cubic_bezier(s_sun_angle_bezier, day_fraction);
	s.sun_angle = sun_deg * (f32)M_PI / 180.0f;
	s.star_angle = s.sun_angle;
	s.moon_angle = s.sun_angle + (f32)M_PI;

	// visual/sky_color: biome color, day cycle, weather (blend_to_gray), lightning
	v3f sky = base_sky * s_sky_color.sample(t);
	auto blend_to_gray = [] (v3f c, f32 brightness, f32 factor) {
		return lerp3(factor, c, clamp01(greyscale(c) * brightness));
	};
	if (rain > 0.0f)
		sky = lerp3(rain, sky, blend_to_gray(sky, 0.6f, 0.75f));
	if (thunder > 0.0f)
		sky = lerp3(thunder, sky, blend_to_gray(sky, 0.24f, 0.94f));
	if (m_sky_flash > 0.0f)
		sky = lerp3(0.22f, sky, v3f(204, 204, 255) / 255.0f);
	s.sky_color = sky;

	// visual/sunrise_sunset_color
	v3f sunrise = s_sunrise_rgb.sample(t);
	f32 sunrise_a = s_sunrise_alpha.sample(t).X;
	if (rain > 0.0f)
		sunrise = lerp3(rain, sunrise, sunrise * v3f(0.5f, 0.5f, 0.6f));
	if (thunder > 0.0f)
		sunrise = lerp3(thunder, sunrise, sunrise * v3f(0.25f, 0.25f, 0.3f));
	s.sunrise = video::SColorf(sunrise.X, sunrise.Y, sunrise.Z, sunrise_a);

	// visual/star_brightness, set to 0 by weather
	f32 stars = s_star_brightness.sample(t).X;
	stars *= (1.0f - rain) * (1.0f - thunder);
	s.star_brightness = stars;
	s.rain_brightness = 1.0f - m_rain;

	// visual/fog_color, then AtmosphericFogEnvironment.getBaseColor
	v3f fog = base_fog * s_fog_color.sample(t);
	if (rain > 0.0f)
		fog = lerp3(rain, fog, fog * v3f(0.5f, 0.5f, 0.6f));
	if (thunder > 0.0f)
		fog = lerp3(thunder, fog, fog * v3f(0.25f, 0.25f, 0.3f));
	const f32 rd_chunks = render_distance / 16.0f;
	if (rd_chunks >= 4.0f) {
		// Looking towards the sun side of the sky tints the fog
		f32 sun_x = std::sin(s.sun_angle) > 0.0f ? -1.0f : 1.0f;
		f32 looking = forward.X * sun_x;
		if (looking > 0.0f && sunrise_a > 0.0f)
			fog = lerp3(looking * sunrise_a, fog, sunrise);
	}
	v3f sky_weather = sky;
	if (m_rain > 0.0f)
		sky_weather = clamp01(sky_weather * v3f(1.0f - m_rain * 0.5f,
				1.0f - m_rain * 0.5f, 1.0f - m_rain * 0.4f));
	if (thunder > 0.0f)
		sky_weather = clamp01(sky_weather * (1.0f - thunder * 0.5f));
	f32 sky_fog_end = std::min(512.0f / 16.0f, rd_chunks);
	f32 mix = 0.25f + 0.75f * rangelim(sky_fog_end / 32.0f, 0.0f, 1.0f);
	mix = 1.0f - std::pow(mix, 0.25f);
	fog = lerp3(mix, fog, sky_weather);

	const LightmapUniforms &u = m_uniforms;
	s.sky_end = std::min(render_distance, 512.0f);
	f32 brighten = u.night_vision;
	if (m_fluid == CameraFluid::Water) {
		fog = m_water_fog_color;
		brighten = waterVision();
		s.sky_end = u.fog_end;
	} else if (m_fluid == CameraFluid::Lava) {
		fog = v3f(153, 26, 0) / 255.0f;
		brighten = 0.0f;
		s.sky_end = u.fog_end;
	}

	// FogRenderer.computeFogColor: boss darkening, then water vision or
	// night vision brightening
	fog = lerp3(u.darken_world, fog, fog * v3f(0.7f, 0.6f, 0.6f));
	if (brighten > 0.0f && fog.X != 0.0f && fog.Y != 0.0f && fog.Z != 0.0f) {
		f32 scale = 1.0f / std::max(fog.X, std::max(fog.Y, fog.Z));
		fog = lerp3(brighten, fog, fog * scale);
	}
	s.fog_color = fog;

	// visual/cloud_color: day cycle and weather (blend_to_gray)
	v3f cloud = s_cloud_color.sample(t);
	if (rain > 0.0f)
		cloud = lerp3(rain, cloud, blend_to_gray(cloud, 0.24f, 0.5f));
	if (thunder > 0.0f)
		cloud = lerp3(thunder, cloud, blend_to_gray(cloud, 0.095f, 0.94f));
	s.cloud_color = cloud;

	// Not under water (SkyRenderer.shouldRenderDarkDisc)
	s.dark_disc = below_horizon && m_fluid != CameraFluid::Water;
	return s;
}

/*
	Shader uniforms
*/

class LightmapUniformSetter : public IShaderUniformSetter
{
	Client *m_client;
	CachedVertexShaderSetting<float> m_enabled{"lightmapEnabled"};
	CachedVertexShaderSetting<float, 4> m_params{"lightmapParams"};
	CachedVertexShaderSetting<float, 4> m_params2{"lightmapParams2"};
	CachedVertexShaderSetting<float, 3> m_sky_color{"lightmapSkyLightColor"};
	CachedVertexShaderSetting<float, 3> m_ambient_color{"lightmapAmbientColor"};
	CachedVertexShaderSetting<float, 3> m_block_tint{"lightmapBlockLightTint"};
	CachedVertexShaderSetting<float, 3> m_night_vision_color{"lightmapNightVisionColor"};
	CachedPixelShaderSetting<float> m_enabled_pixel{"lightmapEnabled"};
	CachedPixelShaderSetting<float, 4> m_fog{"lightmapFog"};

public:
	LightmapUniformSetter(Client *client) : m_client(client) {}

	void onSetUniforms(video::IMaterialRendererServices *services) override
	{
		const LightmapState &state = m_client->getLightmapState();
		const LightmapUniforms &u = state.getUniforms();
		float enabled = state.isEnabled() ? 1.0f : 0.0f;
		m_enabled.set(&enabled, services);
		m_enabled_pixel.set(&enabled, services);
		float params[4] = {u.sky_factor, u.block_factor, u.night_vision, u.darkness};
		m_params.set(params, services);
		float params2[4] = {u.darken_world, u.brightness,
				m_client->getLightmapConstantShade() ? 1.0f : 0.0f, 0.0f};
		m_params2.set(params2, services);
		m_sky_color.set(u.sky_light_color, services);
		m_ambient_color.set(u.ambient_color, services);
		m_block_tint.set(u.block_light_tint, services);
		m_night_vision_color.set(u.night_vision_color, services);

		// FogRenderer.setupFog: render distance fog over the last tenth of
		// the view range (4..64 nodes), plus the environmental fog
		video::SColor fog_color;
		video::E_FOG_TYPE fog_type;
		f32 fog_start, fog_end, fog_density;
		bool pixel_fog, range_fog;
		services->getVideoDriver()->getFog(fog_color, fog_type, fog_start,
				fog_end, fog_density, pixel_fog, range_fog);
		f32 rd = fog_end / BS;
		float fog[4] = {u.fog_start, u.fog_end,
				rd - rangelim(rd / 10.0f, 4.0f, 64.0f), rd};
		m_fog.set(fog, services);
	}
};

class LightmapUniformSetterFactory : public IShaderUniformSetterFactory
{
	Client *m_client;
public:
	LightmapUniformSetterFactory(Client *client) : m_client(client) {}

	IShaderUniformSetter *create(const std::string &name) override
	{
		if (str_starts_with(name, "shadow/"))
			return nullptr;
		return new LightmapUniformSetter(m_client);
	}
};

IShaderUniformSetterFactory *createLightmapUniformSetterFactory(Client *client)
{
	return new LightmapUniformSetterFactory(client);
}
