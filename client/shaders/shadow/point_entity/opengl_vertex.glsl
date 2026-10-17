// Entity shadow maps of point lights: distance of each entity pixel from the
// light source, see PointLightShadows::renderEntityShadowMaps()

#ifdef USE_SKINNING
layout (std140) uniform JointMatrices {
	mat4 joints[MAX_JOINTS];
};
#endif

uniform highp mat4 mWorld;

VARYING_ vec3 vWorldPos;
CENTROID_ VARYING_ mediump vec2 varTexCoord;

void main()
{
#ifdef USE_SKINNING
	uvec4 jids = inVertexJointIDs;
	vec4 skinPos = inVertexPosition;
	if (inVertexWeights != vec4(0.0)) {
		mat4 mSkin =
				inVertexWeights.x * joints[jids.x] +
				inVertexWeights.y * joints[jids.y] +
				inVertexWeights.z * joints[jids.z] +
				inVertexWeights.w * joints[jids.w];
		skinPos = vec4((mSkin * vec4(inVertexPosition.xyz, 1.0)).xyz, 1.0);
	}
#else
	vec4 skinPos = inVertexPosition;
#endif
	vWorldPos = (mWorld * skinPos).xyz;
	gl_Position = mWorldViewProj * skinPos;
	varTexCoord = (mTexture * vec4(inTexCoord0.xy, 1.0, 1.0)).st;
}
