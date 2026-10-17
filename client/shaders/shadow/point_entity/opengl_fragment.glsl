uniform sampler2D baseTexture;
// Light source position (scene coordinates) and 1 / the farthest distance
uniform vec3 pointShadowLightPos;
uniform float pointShadowInvFar;

VARYING_ vec3 vWorldPos;
CENTROID_ VARYING_ mediump vec2 varTexCoord;

void main()
{
	if (texture2D(baseTexture, varTexCoord).a < 0.5)
		discard;
	float dist = length(vWorldPos - pointShadowLightPos) * pointShadowInvFar;
	gl_FragColor = vec4(dist, 0.0, 0.0, 1.0);
}
