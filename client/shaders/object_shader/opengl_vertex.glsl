uniform mat4 mWorld;
uniform vec3 dayLight;
uniform float animationTimer;
uniform lowp vec4 materialColor;

VARYING_ vec3 vNormal;
VARYING_ vec3 worldPosition;
VARYING_ lowp vec4 varColor;
CENTROID_ VARYING_ mediump vec2 varTexCoord;
#ifdef USE_ARRAY_TEXTURE
flat VARYING_ uint varTexLayer;
#endif

#ifdef ENABLE_DYNAMIC_SHADOWS
	// shadow uniforms
	uniform vec3 v_LightDirection;
	uniform float f_textureresolution;
	uniform mat4 m_ShadowViewProj;
	uniform float f_shadowfar;
	uniform float f_shadow_strength;
	uniform float f_timeofday;
	uniform vec4 CameraPos;

	VARYING_ float cosLight;
	VARYING_ float adj_shadow_strength;
	VARYING_ float f_normal_length;
	VARYING_ vec3 shadow_position;
	VARYING_ float perspective_factor;
#endif

VARYING_ highp vec3 eyeVec;
VARYING_ float nightRatio;
// Color of the light emitted by the light sources.
const vec3 artificialLight = vec3(1.04, 1.04, 1.04);
VARYING_ float vIDiff;

#if defined(ENABLE_DYNAMIC_SHADOWS) || defined(ENABLE_POINT_SHADOWS)
// Sky and block light parts of varColor (lightmap lighting)
VARYING_ mediump vec3 varSkyLight;
VARYING_ mediump vec3 varBlockLight;
#endif

#ifdef USE_SKINNING
layout (std140) uniform JointMatrices {
	mat4 joints[MAX_JOINTS];
};
#endif

#ifdef ENABLE_DYNAMIC_SHADOWS

uniform float xyPerspectiveBias0;
uniform float xyPerspectiveBias1;
uniform float zPerspectiveBias;

vec4 getRelativePosition(in vec4 position)
{
	vec2 l = position.xy - CameraPos.xy;
	vec2 s = l / abs(l);
	s = (1.0 - s * CameraPos.xy);
	l /= s;
	return vec4(l, s);
}

float getPerspectiveFactor(in vec4 relativePosition)
{
	float pDistance = length(relativePosition.xy);
	float pFactor = pDistance * xyPerspectiveBias0 + xyPerspectiveBias1;
	return pFactor;
}

vec4 applyPerspectiveDistortion(in vec4 position)
{
	vec4 l = getRelativePosition(position);
	float pFactor = getPerspectiveFactor(l);
	l.xy /= pFactor;
	position.xy = l.xy * l.zw + CameraPos.xy;
	position.z *= zPerspectiveBias;
	return position;
}

#if __VERSION__ >= 130
#define mtsmoothstep smoothstep
#else
float mtsmoothstep(in float edge0, in float edge1, in float x)
{
	float t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}
#endif

#endif


float directional_ambient(vec3 normal)
{
	vec3 v = normal * normal;

	if (normal.y < 0.0)
		return dot(v, vec3(0.670820, 0.447213, 0.836660));

	return dot(v, vec3(0.670820, 1.000000, 0.836660));
}

void main(void)
{
#ifdef USE_SKINNING
	uvec4 jids = inVertexJointIDs;
	vec4 skinPos = inVertexPosition;
	vec3 skinNormal = inVertexNormal;
	// Alternatively: Introduce neutral bone at index 0 with identity matrix?
	if (inVertexWeights != vec4(0.0)) {
		// Note that this deals correctly with a disabled vertex attribute.
		mat4 mSkin =
				inVertexWeights.x * joints[jids.x] +
				inVertexWeights.y * joints[jids.y] +
				inVertexWeights.z * joints[jids.z] +
				inVertexWeights.w * joints[jids.w];
		skinPos = vec4((mSkin * vec4(inVertexPosition.xyz, 1.0)).xyz, 1.0);
		skinNormal = (mSkin * vec4(inVertexNormal, 0.0)).xyz;
	}
#else
	vec4 skinPos = inVertexPosition;
	vec3 skinNormal = inVertexNormal;
#endif

#ifdef USE_ARRAY_TEXTURE
	varTexLayer = inVertexAux;
#endif
	varTexCoord = (mTexture * vec4(inTexCoord0.xy, 1.0, 1.0)).st;

	gl_Position = mWorldViewProj * skinPos;

	vNormal = (mWorld * vec4(skinNormal, 0.0)).xyz;
	worldPosition = (mWorld * skinPos).xyz;
	eyeVec = -(mWorldView * skinPos).xyz;

#if (MATERIAL_TYPE == TILE_MATERIAL_PLAIN) || (MATERIAL_TYPE == TILE_MATERIAL_PLAIN_ALPHA)
	vIDiff = 1.0;
#else
	// This is intentional comparison with zero without any margin.
	// If normal is not equal to zero exactly, then we assume it's a valid, just not normalized vector
	vIDiff = length(vNormal) == 0.0
		? 1.0
		: directional_ambient(normalize(vNormal));
#endif

	vec4 color = inVertexColor;

	if (lightmapEnabled > 0.5) {
		// Lightmap lighting (Minecraft entity.vsh): materialColor holds the
		// block and sky light at the eye, see lightmap_object_light()
		vec2 light = floor(materialColor.rg * 15.0 + 0.5);
		// Emissive layers (blue 1) don't use the lightmap and have the
		// alpha of the material color (Minecraft's EMISSIVE entity shader
		// with translucent blending). Otherwise blue holds the block light
		// above level 15 (extended light levels).
		bool emissive = materialColor.b > 0.5;
		float overbright = emissive ? 1.0 :
			lightmapOverbright(15.0 + floor(materialColor.b * 255.0 + 0.5));
		vec3 light_color = lightmapSample(light) * overbright;
		if (emissive)
			light_color = vec3(1.0);
#if defined(ENABLE_DYNAMIC_SHADOWS) || defined(ENABLE_POINT_SHADOWS)
		// What the sky and the block light add, for shadows to take away
		varSkyLight = color.rgb * (light_color - lightmapSample(vec2(light.x, 0.0)) * overbright);
		varBlockLight = color.rgb * (light_color - lightmapSample(vec2(0.0, light.y)));
		if (emissive) {
			varSkyLight = vec3(0.0);
			varBlockLight = vec3(0.0);
		}
#endif
		color.rgb *= light_color;
		color.a = emissive ? materialColor.a : 1.0;
		nightRatio = 0.0;
		varColor = clamp(color, 0.0, max(1.0, overbright));
#if (MATERIAL_TYPE != TILE_MATERIAL_PLAIN) && (MATERIAL_TYPE != TILE_MATERIAL_PLAIN_ALPHA)
		// minecraft_mix_light: two directional lights (Lighting.java), with
		// Minecraft's -Z north turned into Luanti's +Z north
		if (length(vNormal) > 0.0) {
			vec3 n = normalize(vNormal);
			vec3 light0 = normalize(vec3(0.2, 1.0, 0.7));
			vec3 light1 = lightmapParams2.z > 0.5 ?
				normalize(vec3(-0.2, -1.0, -0.7)) : normalize(vec3(-0.2, 1.0, -0.7));
			vIDiff = min(1.0, (max(0.0, dot(light0, n)) + max(0.0, dot(light1, n))) * 0.6 + 0.4);
		}
#endif
	} else {
#if defined(ENABLE_DYNAMIC_SHADOWS) || defined(ENABLE_POINT_SHADOWS)
	varSkyLight = vec3(0.0);
	varBlockLight = vec3(0.0);
#endif
	color *= materialColor;

	// Light brighter than the classic maximum (extended light levels)
	// may go up to twice the usual brightness, see the node shader
	vec3 max_color = max(vec3(1.0), color.rgb * 2.0);
	// The alpha gives the ratio of sunlight in the incoming light.
	nightRatio = 1.0 - color.a;
	color.rgb = color.rgb * (color.a * dayLight.rgb +
		nightRatio * artificialLight.rgb) * 2.0;
	color.a = 1.0;

	// Emphase blue a bit in darker places
	// See C++ implementation in mapblock_mesh.cpp final_color_blend()
	float brightness = (color.r + color.g + color.b) / 3.0;
	color.b += max(0.0, 0.021 - abs(0.2 * brightness - 0.021) +
		0.07 * brightness);

	varColor = vec4(clamp(color.rgb, vec3(0.0), max_color), clamp(color.a, 0.0, 1.0));
	}


#ifdef ENABLE_DYNAMIC_SHADOWS
	if (f_shadow_strength > 0.0) {
		vec3 nNormal = normalize(vNormal);
		f_normal_length = length(vNormal);

		/* normalOffsetScale is in world coordinates (1/10th of a meter)
		   z_bias is in light space coordinates */
		float normalOffsetScale, z_bias;
		float pFactor = getPerspectiveFactor(getRelativePosition(m_ShadowViewProj * mWorld * inVertexPosition));
		if (f_normal_length > 0.0) {
			nNormal = normalize(vNormal);
			cosLight = max(1e-5, dot(nNormal, -v_LightDirection));
			float sinLight = pow(1.0 - pow(cosLight, 2.0), 0.5);
			normalOffsetScale = 0.1 * pFactor * pFactor * sinLight * min(f_shadowfar, 500.0) /
					xyPerspectiveBias1 / f_textureresolution;
			z_bias = 1e3 * sinLight / cosLight * (0.5 + f_textureresolution / 1024.0);
		}
		else {
			nNormal = vec3(0.0);
			cosLight = clamp(dot(v_LightDirection, normalize(vec3(v_LightDirection.x, 0.0, v_LightDirection.z))), 1e-2, 1.0);
			float sinLight = pow(1.0 - pow(cosLight, 2.0), 0.5);
			normalOffsetScale = 0.0;
			z_bias = 3.6e3 * sinLight / cosLight;
		}
		z_bias *= pFactor * pFactor / f_textureresolution / f_shadowfar;

		shadow_position = applyPerspectiveDistortion(m_ShadowViewProj * mWorld * (inVertexPosition + vec4(normalOffsetScale * nNormal, 0.0))).xyz;
		shadow_position.z -= z_bias;
		perspective_factor = pFactor;

		if (f_timeofday < 0.2) {
			adj_shadow_strength = f_shadow_strength * 0.5 *
				(1.0 - mtsmoothstep(0.18, 0.2, f_timeofday));
		} else if (f_timeofday >= 0.8) {
			adj_shadow_strength = f_shadow_strength * 0.5 *
				mtsmoothstep(0.8, 0.83, f_timeofday);
		} else {
			adj_shadow_strength = f_shadow_strength *
				mtsmoothstep(0.20, 0.25, f_timeofday) *
				(1.0 - mtsmoothstep(0.7, 0.8, f_timeofday));
		}
	}
#endif
}
