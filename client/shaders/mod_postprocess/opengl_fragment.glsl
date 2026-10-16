// Used for post-processing passes set by mods whose own fragment shader
// failed to compile: passes the image through unchanged.

#define rendered texture0

uniform sampler2D rendered;

CENTROID_ VARYING_ mediump vec2 varTexCoord;

void main(void)
{
	gl_FragColor = texture2D(rendered, varTexCoord.st);
}
