// Pixelated sun shadows and point light shadows, shared by the nodes and
// object fragment shaders (included after their uniforms and varyings).
// The C++ side of point light shadows is src/client/shadows/pointlightshadows.cpp

#if __VERSION__ >= 130
#ifdef PIXEL_SHADOWS
#define USE_PIXEL_SHADOWS 1
#endif
#ifdef ENABLE_POINT_SHADOWS
#define USE_POINT_SHADOWS 1
#endif
#endif

// Moves a surface position to the center of the texture pixel it shows, so
// that shadows computed from it are uniform over each texture pixel.
// pos and uv must both vary linearly over the primitive, which holds for any
// flat textured triangle. Call this before any discard.
vec3 snapToTexel(vec3 pos, vec2 uv, vec2 tex_size)
{
#ifdef USE_PIXEL_SHADOWS
	vec2 texel = uv * tex_size;
	vec2 duv = (floor(texel) + 0.5 - texel) / tex_size;
	vec2 uv_dx = dFdx(uv);
	vec2 uv_dy = dFdy(uv);
	float det = uv_dx.x * uv_dy.y - uv_dx.y * uv_dy.x;
	if (abs(det) < 1e-20)
		return pos;
	// The screen space step that moves uv by duv...
	vec2 s = vec2(duv.x * uv_dy.y - duv.y * uv_dy.x,
			uv_dx.x * duv.y - uv_dx.y * duv.x) / det;
	// ...moves the position this much
	vec3 offset = dFdx(pos) * s.x + dFdy(pos) * s.y;
	// Derivatives fall apart at grazing angles, half a node is plenty
	float len = length(offset);
	if (len > 5.0)
		offset *= 5.0 / len;
	// Texel centers lie on a 1/32 node grid. Round away the float noise of
	// the derivatives so all pixels of a texel get the very same position
	// (scene coordinates are in tenths of nodes).
	return floor((pos + offset) * 409.6 + 0.5) / 409.6;
#else
	return pos;
#endif
}

#ifdef ENABLE_DYNAMIC_SHADOWS
uniform float zPerspectiveBias;

// Same as in the vertex shaders
vec4 shadowRelativePosition(vec4 position)
{
	vec2 l = position.xy - CameraPos.xy;
	vec2 s = l / abs(l);
	s = (1.0 - s * CameraPos.xy);
	l /= s;
	return vec4(l, s);
}

float shadowPerspectiveFactor(vec4 relative_position)
{
	return length(relative_position.xy) * xyPerspectiveBias0 + xyPerspectiveBias1;
}

vec4 shadowPerspectiveDistortion(vec4 position)
{
	vec4 l = shadowRelativePosition(position);
	l.xy /= shadowPerspectiveFactor(l);
	position.xy = l.xy * l.zw + CameraPos.xy;
	position.z *= zPerspectiveBias;
	return position;
}

// Shadow map position ([0, 1]^3) of a scene position, computed per pixel so
// that it can be snapped to texture pixels. The offset and bias scales are
// those of the vertex shader of the including shader.
vec3 getPixelShadowPosition(vec3 pos, vec3 normal, float offset_scale,
		float normal_bias_scale)
{
	float p_factor = shadowPerspectiveFactor(
			shadowRelativePosition(m_ShadowViewProj * vec4(pos, 1.0)));
	float normal_offset = 0.0;
	float z_bias;
	vec3 n = vec3(0.0);
	if (length(normal) > 0.0) {
		n = normalize(normal);
		float cos_light = max(1e-5, dot(n, -v_LightDirection));
		float sin_light = sqrt(1.0 - cos_light * cos_light);
		normal_offset = offset_scale * p_factor * p_factor * sin_light *
				min(f_shadowfar, 500.0) / xyPerspectiveBias1 / f_textureresolution;
		z_bias = normal_bias_scale * sin_light / cos_light;
	} else {
		float cos_light = clamp(dot(v_LightDirection,
				normalize(vec3(v_LightDirection.x, 0.0, v_LightDirection.z))), 1e-2, 1.0);
		float sin_light = sqrt(1.0 - cos_light * cos_light);
		z_bias = 3.6e3 * sin_light / cos_light;
	}
	z_bias *= p_factor * p_factor / f_textureresolution / f_shadowfar;

	vec3 shadow_pos = shadowPerspectiveDistortion(
			m_ShadowViewProj * vec4(pos + normal_offset * n, 1.0)).xyz;
	shadow_pos.z -= z_bias;
	return shadow_pos * 0.5 + 0.5;
}
#endif

#ifdef USE_POINT_SHADOWS
#define pointShadowVolume texture2
uniform highp sampler2DArray pointShadowVolume;
// Volume corner in scene coordinates
uniform vec3 pointShadowOrigin;
// Volume origin node modulo the volume size (toroidal addressing)
uniform vec3 pointShadowWrap;
// 0 = off
uniform float pointShadowStrength;

#define PS_SIZE POINT_SHADOW_SIZE
#define PS_CELLS (POINT_SHADOW_SIZE / POINT_SHADOW_CELL)
#define PS_TEX_WIDTH (2 * POINT_SHADOW_SIZE)

// RGBA8 texel (stored as A8R8G8B8) back to its 32 bits
uint psDecode(vec4 t)
{
	uvec4 b = uvec4(t * 255.0 + 0.5);
	return b.b | (b.g << 8u) | (b.r << 16u) | (b.a << 24u);
}

// Sub-voxel occupancy of a node of the volume, 64 bits
uvec2 psMask(ivec3 c)
{
	ivec3 w = (c + ivec3(pointShadowWrap)) & (PS_SIZE - 1);
	return uvec2(
		psDecode(texelFetch(pointShadowVolume, ivec3(2 * w.x, w.z, w.y), 0)),
		psDecode(texelFetch(pointShadowVolume, ivec3(2 * w.x + 1, w.z, w.y), 0)));
}

bool psBit(uvec2 mask, ivec3 s)
{
	int i = s.x + 4 * s.y + 16 * s.z;
	uint word = i < 32 ? mask.x : mask.y;
	return ((word >> uint(i & 31)) & 1u) != 0u;
}

// Whether the segment a -> b (node local, [0, 1]^3) crosses a filled
// sub-voxel. The first one can be skipped: thin geometry that only partly
// fills it would shadow itself.
bool psSegmentBlocked(uvec2 mask, vec3 a, vec3 b, bool skip_first)
{
	vec3 p = a * 4.0;
	vec3 d = b * 4.0 - p;
	ivec3 s = clamp(ivec3(floor(p)), ivec3(0), ivec3(3));
	ivec3 dir = ivec3(sign(d));
	vec3 t_delta = 1.0 / max(abs(d), vec3(1e-6));
	vec3 t_max = mix(p - vec3(s), vec3(s) + 1.0 - p, step(0.0, d)) * t_delta;
	for (int i = 0; i < 12; i++) {
		if ((i > 0 || !skip_first) && psBit(mask, s))
			return true;
		if (min(t_max.x, min(t_max.y, t_max.z)) >= 1.0)
			return false;
		if (t_max.x <= t_max.y && t_max.x <= t_max.z) {
			s.x += dir.x;
			t_max.x += t_delta.x;
		} else if (t_max.y <= t_max.z) {
			s.y += dir.y;
			t_max.y += t_delta.y;
		} else {
			s.z += dir.z;
			t_max.z += t_delta.z;
		}
		if (any(lessThan(s, ivec3(0))) || any(greaterThan(s, ivec3(3))))
			return false;
	}
	return false;
}

// 1 if nothing blocks the way from p (volume coordinates, nodes) to the
// center of the light source node, else 0
float psTrace(vec3 p, ivec3 light)
{
	// Aim slightly off the node center: texel centers and node centers are
	// on the same grid, so rays would hit block edges exactly, where float
	// noise decides between lit and shadowed.
	vec3 d = vec3(light) + vec3(0.5013, 0.5007, 0.5011) - p;
	ivec3 c = ivec3(floor(p));
	ivec3 dir = ivec3(sign(d));
	vec3 t_delta = 1.0 / max(abs(d), vec3(1e-6));
	vec3 t_max = mix(p - vec3(c), vec3(c) + 1.0 - p, step(0.0, d)) * t_delta;
	float t0 = 0.0;
	// A light reaches 15 nodes (Manhattan distance) at most
	for (int i = 0; i < 24; i++) {
		if (c == light)
			return 1.0;
		if (any(lessThan(c, ivec3(0))) || any(greaterThanEqual(c, ivec3(PS_SIZE))))
			return 1.0;
		float t1 = min(min(t_max.x, t_max.y), min(t_max.z, 1.0));
		uvec2 mask = psMask(c);
		if (mask.x != 0u || mask.y != 0u) {
			if (i > 0 && mask.x == 0xFFFFFFFFu && mask.y == 0xFFFFFFFFu)
				return 0.0;
			vec3 a = p + d * t0 - vec3(c);
			vec3 b = p + d * t1 - vec3(c);
			if (psSegmentBlocked(mask, a, b, i == 0))
				return 0.0;
		}
		if (t1 >= 1.0)
			return 1.0;
		if (t_max.x <= t_max.y && t_max.x <= t_max.z) {
			c.x += dir.x;
			t_max.x += t_delta.x;
		} else if (t_max.y <= t_max.z) {
			c.y += dir.y;
			t_max.y += t_delta.y;
		} else {
			c.z += dir.z;
			t_max.z += t_delta.z;
		}
		t0 = t1;
	}
	return 1.0;
}

// How much of the block light at a surface point its light sources reach
// directly, from 0 (all blocked) to 1.
// pos: scene coordinates, normal: surface normal or zero
float getPointShadow(vec3 pos, vec3 normal)
{
	vec3 n = length(normal) > 0.0 ? normalize(normal) : vec3(0.0);
	// Volume coordinates, starting just above the surface
	vec3 p = (pos - pointShadowOrigin) * 0.1 + n * 0.02;
	// Fade out towards the border of the volume, beyond it lights and
	// occluders are unknown
	vec3 border = min(p, vec3(float(PS_SIZE)) - p);
	float fade = clamp((min(border.x, min(border.y, border.z)) - 2.0) / 8.0, 0.0, 1.0);
	if (fade <= 0.0)
		return 1.0;

	ivec3 cell = ivec3(p) / POINT_SHADOW_CELL;
	int base = ((cell.y * PS_CELLS + cell.z) * PS_CELLS + cell.x) * POINT_SHADOW_CELL_LIGHTS;
	float total = 0.0;
	float lit = 0.0;
	for (int i = 0; i < POINT_SHADOW_CELL_LIGHTS; i++) {
		int e = base + i;
		uint v = psDecode(texelFetch(pointShadowVolume, ivec3(e % PS_TEX_WIDTH,
				(e / PS_TEX_WIDTH) % PS_SIZE, PS_SIZE + e / (PS_TEX_WIDTH * PS_SIZE)), 0));
		float level = float(v >> 24u);
		if (level == 0.0)
			break;
		ivec3 light = ivec3(int(v & 255u), int((v >> 8u) & 255u), int((v >> 16u) & 255u));
		vec3 d = vec3(light) + 0.5 - p;
		// Light left at this point, as the engine spreads it
		float w = level - (abs(d.x) + abs(d.y) + abs(d.z));
		if (w <= 0.0)
			continue;
		w *= w;
		total += w;
		float dist2 = dot(d, d);
		if (dist2 < 0.36) {
			// Inside the light source node (e.g. the torch itself)
			lit += w;
			continue;
		}
		float facing = 1.0;
		if (n != vec3(0.0))
			facing = clamp(dot(n, d) * inversesqrt(dist2) * 3.0 + 0.5, 0.0, 1.0);
		if (facing > 0.0)
			lit += w * facing * psTrace(p, light);
	}
	return total > 0.0 ? mix(1.0, lit / total, fade) : 1.0;
}
#endif
