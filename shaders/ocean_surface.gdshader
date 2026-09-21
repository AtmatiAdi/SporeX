shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_always;

// Local sea surface used from ~40 km altitude down to the cell. The plane is
// authored in meters. Waves come from two scrolling layers of a noise normal
// map (generated at runtime, no assets) and fade with distance so the surface
// stays calm and alias-free when seen from high up.

uniform vec3 color_deep : source_color = vec3(0.02, 0.12, 0.25);
uniform vec3 color_shallow : source_color = vec3(0.10, 0.35, 0.45);
uniform sampler2D wave_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float meters_per_unit = 1.0;
uniform float alpha = 0.92;
uniform float wave_strength = 0.6;

varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	vec2 p = v_local.xz;
	float t = TIME;
	float dist_m = length(VERTEX) * meters_per_unit;
	float fade = wave_strength / (1.0 + dist_m / 120.0);
	vec3 n1 = texture(wave_normal, p * 0.045 + vec2(t * 0.010, t * 0.007)).xyz * 2.0 - 1.0;
	vec3 n2 = texture(wave_normal, p * 0.21 + vec2(-t * 0.018, t * 0.012)).xyz * 2.0 - 1.0;
	vec3 n3 = texture(wave_normal, p * 1.3 + vec2(t * 0.05, -t * 0.04)).xyz * 2.0 - 1.0;
	vec2 g = (n1.xy * 1.0 + n2.xy * 0.6 + n3.xy * 0.25) * fade;
	vec3 n_local = normalize(vec3(g.x, 1.0, g.y));
	vec3 n = normalize((VIEW_MATRIX * vec4(mat3(MODEL_MATRIX) * n_local, 0.0)).xyz);
	if (!FRONT_FACING) {
		n = -n;
	}
	NORMAL = n;
	float fres = pow(clamp(1.0 - dot(n, VIEW), 0.0, 1.0), 4.0);
	ALBEDO = mix(color_deep, color_shallow, fres * 0.6);
	ROUGHNESS = 0.25;
	SPECULAR = 0.5;
	METALLIC = 0.0;
	ALPHA = alpha;
}
