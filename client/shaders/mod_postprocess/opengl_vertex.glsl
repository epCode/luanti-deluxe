// Default vertex shader of post-processing passes set by mods
// (see `ObjectRef:set_shader` in lua_api.md): a full-screen quad.

CENTROID_ VARYING_ mediump vec2 varTexCoord;

void main(void)
{
	varTexCoord.st = inTexCoord0.st;
	gl_Position = inVertexPosition;
}
