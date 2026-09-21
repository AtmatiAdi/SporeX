shader_type spatial;
render_mode cull_back, blend_mix, depth_draw_always;

// Player cell membrane: soft wobble in the vertex stage, fresnel glow.

uniform vec3 color : source_color = vec3(0.45, 0.9, 0.6);
uniform vec3 glow : source_color = vec3(0.6, 1.0, 0.8);
uniform float wobble = 0.06;
uniform float speed = 1.0;

void vertex() {
	vec3 n = normalize(VERTEX);
	float t = TIME * speed;
	float w = sin(n.x * 5.0 + t * 2.0) * sin(n.y * 4.0 - t * 1.7) * sin(n.z * 6.0 + t * 1.3);
	VERTEX += n * w * wobble;
}

void fragment() {
	float fres = pow(clamp(1.0 - dot(NORMAL, VIEW), 0.0, 1.0), 2.5);
	ALBEDO = color;
	ALPHA = 0.5 + 0.5 * fres;
	EMISSION = glow * fres * 0.7;
	ROUGHNESS = 0.3;
	SPECULAR = 0.6;
}
