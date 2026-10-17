// --- inserted by Luanti Shader Studio: lets generated code re-run this pass ---
vec2 ss_uv;
vec4 ss_fragColor;
bool ss_override;
vec4 ss_override_color;
vec4 ss_fetch(sampler2D s, vec2 p)
{
	if (ss_override)
		return ss_override_color;
	return texture2D(s, p);
}
// --- end of insertion ---
#define rendered texture0
#define bloom texture1

#ifdef GL_ES
// Dithering requires sufficient floating-point precision
#ifndef GL_FRAGMENT_PRECISION_HIGH
#undef ENABLE_DITHERING
#endif
#endif

struct ExposureParams {
	float compensationFactor;
};

uniform sampler2D rendered;
uniform sampler2D bloom;

uniform vec2 texelSize0;

uniform ExposureParams exposureParams;
uniform lowp float bloomIntensity;
uniform lowp float saturation;

CENTROID_ VARYING_ mediump vec2 varTexCoord;

#ifdef ENABLE_AUTO_EXPOSURE
VARYING_ float exposure; // linear exposure factor, see vertex shader
#endif

#ifdef ENABLE_BLOOM

vec4 applyBloom(vec4 color, vec2 uv)
{
	vec3 light = texture2D(bloom, uv).rgb;
#ifdef ENABLE_BLOOM_DEBUG
	if (uv.x > 0.5 && uv.y < 0.5)
		return vec4(light, color.a);
	if (uv.x < 0.5)
		return color;
#endif
	color.rgb = mix(color.rgb, light, bloomIntensity);
	return color;
}

#endif

#if ENABLE_TONE_MAPPING

/* Hable's UC2 Tone mapping parameters
	A = 0.22;
	B = 0.30;
	C = 0.10;
	D = 0.20;
	E = 0.01;
	F = 0.30;
	W = 11.2;
	equation used:  ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F
*/

// highp for GLES, see <https://github.com/luanti-org/luanti/pull/14688>
highp vec3 uncharted2Tonemap(highp vec3 x)
{
	return ((x * (0.22 * x + 0.03) + 0.002) / (x * (0.22 * x + 0.3) + 0.06)) - 0.03333;
}

vec4 applyToneMapping(vec4 color)
{
	color = vec4(pow(color.rgb, vec3(2.2)), color.a);
	const float gamma = 1.6;
	const float exposureBias = 5.5;
	color.rgb = uncharted2Tonemap(exposureBias * color.rgb);
	// Precalculated white_scale from
	//vec3 whiteScale = 1.0 / uncharted2Tonemap(vec3(W));
	vec3 whiteScale = vec3(1.036015346);
	color.rgb *= whiteScale;
	return vec4(pow(color.rgb, vec3(1.0 / gamma)), color.a);
}
#endif

vec3 applySaturation(vec3 color, float factor)
{
	// Calculate the perceived luminosity from the RGB color.
	// See also: https://www.w3.org/WAI/GL/wiki/Relative_luminance
	float brightness = dot(color, vec3(0.2125, 0.7154, 0.0721));
	return mix(vec3(brightness), color, factor);
}

#ifdef ENABLE_DITHERING
// From http://alex.vlachos.com/graphics/Alex_Vlachos_Advanced_VR_Rendering_GDC2015.pdf
// and https://www.shadertoy.com/view/MslGR8 (5th one starting from the bottom)
// NOTE: `frag_coord` is in pixels (i.e. not normalized UV).
vec3 screen_space_dither(highp vec2 frag_coord) {
	// Iestyn's RGB dither (7 asm instructions) from Portal 2 X360, slightly modified for VR.
	highp vec3 dither = vec3(dot(vec2(171.0, 231.0), frag_coord));
	dither.rgb = fract(dither.rgb / vec3(103.0, 71.0, 97.0));

	// Subtract 0.5 to avoid slightly brightening the whole viewport.
	return (dither.rgb - 0.5) / 255.0;
}
#endif

void ss_stock_main(void)
{
	vec2 uv = ss_uv.st;
#ifdef ENABLE_SSAA
	vec4 color = vec4(0.);
	for (float dx = 1.; dx < SSAA_SCALE; dx += 2.)
	for (float dy = 1.; dy < SSAA_SCALE; dy += 2.)
		color += ss_fetch(rendered, uv + texelSize0 * vec2(dx, dy)).rgba;
	color /= SSAA_SCALE * SSAA_SCALE / 4.;
#else
	vec4 color = ss_fetch(rendered, uv).rgba;
#endif

	// translate to linear colorspace (approximate)
	color.rgb = pow(color.rgb, vec3(2.2));

#ifdef ENABLE_BLOOM_DEBUG
	if (uv.x > 0.5 || uv.y > 0.5)
#endif
	{
		color.rgb *= exposureParams.compensationFactor;
#ifdef ENABLE_AUTO_EXPOSURE
		color.rgb *= exposure;
#endif
	}

#ifdef ENABLE_BLOOM
	color = applyBloom(color, uv);
#endif


	color.rgb = clamp(color.rgb, vec3(0.), vec3(1.));

	// return to sRGB colorspace (approximate)
	color.rgb = pow(color.rgb, vec3(1.0 / 2.2));

#ifdef ENABLE_BLOOM_DEBUG
	if (uv.x > 0.5 || uv.y > 0.5)
#endif
	{
#if ENABLE_TONE_MAPPING
		color = applyToneMapping(color);
#endif

		color.rgb = applySaturation(color.rgb, saturation);
	}

#ifdef ENABLE_DITHERING
	// Apply dithering just before quantisation
	color.rgb += screen_space_dither(gl_FragCoord.xy);
#endif

	ss_fragColor = vec4(color.rgb, 1.0); // force full alpha to avoid holes in the image.
}

// ======================================================================
// Luanti Shader Studio — generated code (post-processing)
// Everything above this line is Luanti's own shader, with main()
// renamed to ss_stock_main().
// ======================================================================

// engine uniforms
uniform float animationTimer;
uniform vec3 dayLight;

float ss_t;    // seconds (animationTimer * 100), wraps every 1000 s
float ss_day;  // 0 = night .. 1 = full day
// phase in cycles for a frequency, rounded so that it loops seamlessly
// when Luanti's timer wraps after 1000 s
float ss_cycle(float hz) { return ss_t * floor(hz * 1000.0 + 0.5) * 0.001; }

// effect parameters
vec2 ss_px;      // size of one screen pixel in uv units
vec2 ss_res;     // screen resolution in pixels
float ss_aspect; // width / height
float e5_intensity;
float e5_radius;
float e5_softness;
float e5_roundness;
vec3 e5_color;
vec2 e5_center;
float e5_mix;

// scene access
vec3 ss_scene(vec2 p)
{
	return texture2D(rendered, p).rgb;
}
// Luanti's complete final pass for coordinate uv
vec4 ss_sample(vec2 uv)
{
	ss_override = false;
	ss_uv = uv;
	ss_stock_main();
	return ss_fragColor;
}
// Luanti's final pass (exposure, bloom, tone mapping…) applied to a
// colour in scene space instead of the scene at uv
vec4 ss_finish(vec3 c, vec2 uv)
{
	ss_override = true;
	ss_override_color = vec4(c, 1.0);
	ss_uv = uv;
	ss_stock_main();
	ss_override = false;
	return ss_fragColor;
}
vec3 ss_src0(vec2 p) { return ss_scene(p); }


void main(void)
{
	ss_t = animationTimer * 100.0;
	ss_day = clamp((dayLight.r + 0.04 - 0.175) / 0.825, 0.0, 1.0);
	ss_px = texelSize0;
	ss_res = 1.0 / max(texelSize0, vec2(1e-6));
	ss_aspect = ss_res.x / ss_res.y;
	e5_intensity = 0.6555;
	e5_radius = 0.18;
	e5_softness = 1.0098;
	e5_roundness = 1.0;
	e5_color = vec3(0.0, 0.0, 0.0);
	e5_center = vec2(0.5, 0.5);
	e5_mix = 1.0;
	vec2 ss_uv0 = varTexCoord.st;
	vec2 uv = ss_uv0;
	vec4 col = ss_sample(uv);
	// @fx 5 color : Vignette
	{
		vec4 ss_in = col;
		vec2 d = (ss_uv0 - e5_center) * 2.0;
		d.x *= mix(1.0, ss_aspect, e5_roundness);
		float r = length(d) / mix(1.41421, length(vec2(ss_aspect, 1.0)), e5_roundness);
		float v = smoothstep(e5_radius, e5_radius + e5_softness, r);
		col.rgb = mix(col.rgb, e5_color, min(v * e5_intensity, 1.0));
		col = mix(ss_in, col, e5_mix);
	}
	gl_FragColor = vec4(col.rgb, 1.0);
}
