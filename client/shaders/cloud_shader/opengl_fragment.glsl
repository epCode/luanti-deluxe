uniform lowp vec4 fogColor;
uniform float fogDistance;
uniform float fogShadingParameter;
VARYING_ highp vec3 eyeVec;

VARYING_ lowp vec4 varColor;

// Lightmap (Minecraft-style) lighting, see client/lightmap.cpp
uniform float lightmapEnabled;

void main(void)
{
	vec4 col = varColor;
	if (lightmapEnabled > 0.5) {
		// Minecraft clouds.fsh: fade out towards the cloud range (2048)
		col.a *= 1.0 - clamp(length(eyeVec) / (2048.0 * 10.0), 0.0, 1.0);
		gl_FragColor = col;
		return;
	}

	float clarity = clamp(fogShadingParameter
		- fogShadingParameter * length(eyeVec) / fogDistance, 0.0, 1.0);
	col.rgb = mix(fogColor.rgb, col.rgb, clarity);

	gl_FragColor = col;
}
