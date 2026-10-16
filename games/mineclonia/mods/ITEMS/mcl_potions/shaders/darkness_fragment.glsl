// The fog of Minecraft's Darkness effect (DarknessFogEnvironment and
// FogRenderer, Java Edition 26.3) as a post-processing pass. The pulsing
// darkening of the light is done by the engine's lightmap (`darkness`).
//
// The environmental fog ends at mix(render distance, 15, blend) blocks and
// starts at 3/4 of that; the sky and the clouds end there too. The fog
// color is darkened by (1 - blend)^2.
uniform sampler2D texture0;
uniform sampler2D texture1;
uniform mat4 mInvViewProj;
uniform vec3 cameraPosition;
uniform vec3 cameraOffset;
// environmental fog start/end, render distance fog start/end (nodes)
uniform vec4 lightmapFog;
uniform lowp vec4 fogColor;
// MobEffectInstance.getBlendFactor
uniform float darknessBlend;

CENTROID_ VARYING_ mediump vec2 varTexCoord;

// fog.glsl linear_fog_value
float linear_fog_value(float dist, float fog_start, float fog_end)
{
	if (dist <= fog_start)
		return 0.0;
	if (dist >= fog_end)
		return 1.0;
	return (dist - fog_start) / (fog_end - fog_start);
}

void main(void)
{
	vec2 uv = varTexCoord.st;
	vec4 color = texture2D(texture0, uv);
	if (darknessBlend <= 0.0) {
		gl_FragColor = color;
		return;
	}
	float depth = texture2D(texture1, uv).r;
	float dist;
	if (depth >= 1.0) {
		// Sky
		dist = 1.0e9;
	} else {
		vec4 world = mInvViewProj * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
		world.xyz /= world.w;
		// BS units relative to the camera offset -> nodes from the eye
		dist = length(world.xyz - (cameraPosition - cameraOffset)) / 10.0;
	}
	float render_distance = lightmapFog.w > 0.0 ? lightmapFog.w : 192.0;
	float fog_end = mix(render_distance, 15.0, darknessBlend);
	float fog = linear_fog_value(dist, fog_end * 0.75, fog_end);
	float brightness = (1.0 - darknessBlend) * (1.0 - darknessBlend);
	gl_FragColor = vec4(mix(color.rgb, fogColor.rgb * brightness, fog), color.a);
}
