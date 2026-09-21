shader_type spatial;
render_mode cull_disabled, depth_draw_never, blend_mix;

uniform sampler2D cloud_tex : filter_linear, repeat_enable;
uniform float coverage = 0.5;
uniform float alpha_mul = 0.9;
uniform float speed = 0.0015;
uniform vec2 uv_offset = vec2(0.0);

varying vec3 v_n;

vec2 sphere_uv(vec3 n) {
	return vec2(atan(n.x, n.z) / TAU + 0.5, 0.5 - asin(clamp(n.y, -1.0, 1.0)) / PI);
}

void vertex() {
	v_n = normalize(VERTEX);
}

void fragment() {
	vec2 uv = sphere_uv(normalize(v_n)) + uv_offset + vec2(TIME * speed, 0.0);
	float c = texture(cloud_tex, uv).r;
	float c2 = texture(cloud_tex, uv * 3.0 + vec2(0.3, 0.1)).r;
	float a = smoothstep(coverage, coverage + 0.3, c * 0.75 + c2 * 0.25) * alpha_mul;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	ALBEDO = vec3(1.0);
	ALPHA = a;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
