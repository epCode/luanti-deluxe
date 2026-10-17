// Luanti
// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2013 celeron55, Perttu Ahola <celeron55@gmail.com>

#include "light.h"
#include <algorithm>
#include <cmath>
#include "util/numeric.h"
#include "settings.h"

bool g_separate_sky_light = false;

#if CHECK_CLIENT_BUILD()

static u16 light_LUT[LIGHT_SUN + 1];

// The const ref to light_LUT is what is actually used in the code
const u16 *light_decode_table = light_LUT;

// Steepness of the brightness curve above LIGHT_SUN_LEVEL
static constexpr float OVERBRIGHT_STEEPNESS = 0.05f;

namespace {

struct LightCurve {
	float a, b, c; // Lighting curve polynomial coefficients
	float boost, center, sigma; // Lighting curve parametric boost
	float gamma; // Lighting curve gamma correction

	float get(float x) const;
};

}

float LightCurve::get(float x) const
{
	if (x >= 1.0f)
		return 1.0f;
	x = std::fmax(x, 0.0f);
	float brightness = ((a * x + b) * x + c) * x;
	brightness += boost *
		std::exp(-0.5f * sqr((x - center) / sigma));
	if (brightness <= 0.0f) // May happen if parameters are extreme
		return 0.0f;
	if (brightness >= 1.0f)
		return 1.0f;
	return powf(brightness, 1.0f / gamma);
}

void set_light_curve(float gamma)
{
	LightCurve params;
	// bounding gradients
	const float alpha = rangelim(g_settings->getFloat("lighting_alpha"), 0.0f, 3.0f);
	const float beta  = rangelim(g_settings->getFloat("lighting_beta"), 0.0f, 3.0f);
	// polynomial coefficients
	params.a = alpha + beta - 2.0f;
	params.b = 3.0f - 2.0f * alpha - beta;
	params.c = alpha;
	// parametric boost
	params.boost = rangelim(g_settings->getFloat("lighting_boost"), 0.0f, 0.4f);
	params.center = rangelim(g_settings->getFloat("lighting_boost_center"), 0.0f, 1.0f);
	params.sigma = rangelim(g_settings->getFloat("lighting_boost_spread"), 0.0f, 0.4f);
	// gamma correction
	params.gamma = rangelim(gamma, 0.33f, 3.0f);

	// Boundary values should be fixed
	light_LUT[0] = 0;
	light_LUT[LIGHT_SUN_LEVEL] = 255;

	for (size_t i = 1; i < LIGHT_SUN_LEVEL; i++) {
		float brightness = params.get((float)i / LIGHT_SUN_LEVEL);
		// Strictly speaking, rangelim is not necessary here - if the implementation
		// is conforming. But we don't want problems in any case.
		light_LUT[i] = rangelim((s32)(255.0f * brightness), 0, 255);

		// Ensure light brightens with each level
		if (light_LUT[i] <= light_LUT[i - 1]) {
			light_LUT[i] = std::min<u16>(254, light_LUT[i - 1]) + 1;
		}
	}

	// Extended levels: from the brightness of LIGHT_SUN_LEVEL up to twice
	// the brightness of LIGHT_MAX at LIGHT_LIMIT, with diminishing steps
	const float hdr_max = std::max(2.0f * light_LUT[LIGHT_MAX], 256.0f);
	for (size_t i = LIGHT_SUN_LEVEL + 1; i <= LIGHT_LIMIT; i++) {
		float v = 255.0f + (hdr_max - 255.0f) * light_overbright_shape(i);
		// Steps may be below 1 with extreme settings: don't force them
		light_LUT[i] = rangelim(core::round32(v), light_LUT[i - 1],
				LIGHT_HDR_MAX);
	}
	// Direct sunlight looks like it always did
	light_LUT[LIGHT_SUN] = 255;
}

float light_overbright_shape(float level)
{
	if (level <= LIGHT_SUN_LEVEL)
		return 0.0f;
	if (level >= LIGHT_LIMIT)
		return 1.0f;
	const float k = OVERBRIGHT_STEEPNESS;
	return (1.0f - std::exp(-k * (level - LIGHT_SUN_LEVEL))) /
		(1.0f - std::exp(-k * (LIGHT_LIMIT - LIGHT_SUN_LEVEL)));
}

float decode_light_f(float light_f)
{
	light_f = std::fmax(light_f, 0.0f);
	float in;
	float fr = std::modf(light_f * LIGHT_SUN_LEVEL, &in); // fraction
	const u32 light_i = in; // integer
	if (light_i >= LIGHT_SUN_LEVEL)
		return light_LUT[LIGHT_SUN_LEVEL] / 255.0f;
	// interpolate from two samples
	u16 l0 = light_LUT[light_i], l1 = light_LUT[light_i+1];
	return (l0 * (1.0f - fr) + l1 * fr) / 255.0f;
}

#endif
