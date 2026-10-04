shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform, shadows_disabled, fog_disabled;

// Neighbouring and background galaxies as one quad each: the whole galaxy is
// an analytic function in the fragment shader (no textures, no geometry).
// INSTANCE_CUSTOM.z = type (0 spiral, 1 elliptical, 2 irregular) + 0.1 + 0.8 * cos(inclination).

#include "res://shaders/galaxy_sprite.gdshaderinc"

void fragment() {
	float typ = floor(v_shape);
	float cos_i = clamp((fract(v_shape) - 0.1) / 0.8, 0.08, 1.0);
	float h0 = sx_hash(vec2(v_seed, 1.7));
	float h1 = sx_hash(vec2(v_seed, 9.3));
	vec2 p = v_uv;
	vec3 col = v_col.rgb;
	float a;
	if (typ < 0.5) {
		p.y /= cos_i;
		float r = length(p);
		float arms = 2.0 + floor(h0 * 3.0);
		float wind = 2.5 + h1 * 4.0;
		float ang = atan(p.y, p.x);
		float s = 0.5 + 0.5 * cos(arms * (ang - wind * log(r + 0.04)));
		float disk = exp(-r * 4.2);
		float core = exp(-r * r * 70.0);
		float arm_mask = smoothstep(0.04, 0.22, r);
		a = disk * (0.3 + 1.1 * s * s * arm_mask) + core * 1.6;
		col = mix(col, vec3(1.0, 0.84, 0.62), clamp(core * 1.5 + (1.0 - arm_mask) * 0.4, 0.0, 1.0));
		a *= 1.0 - smoothstep(0.7, 1.0, r);
	} else if (typ < 1.5) {
		p.y /= max(cos_i, 0.35);
		float r = length(p);
		a = exp(-pow(r, 0.55) * 5.5) * 1.8;
		a *= 1.0 - smoothstep(0.75, 1.0, r);
	} else {
		p.y /= max(cos_i, 0.3);
		float r = length(p);
		vec2 q = p * 2.5 + sx_seed_offset(v_seed);
		float n = sx_vnoise(q) * 0.6 + sx_vnoise(q * 2.3) * 0.4;
		a = exp(-r * 3.0) * (0.35 + 0.65 * smoothstep(0.3, 0.85, n)) * 1.1;
		a *= 1.0 - smoothstep(0.6, 1.0, r);
	}
	ALBEDO = col * (a * v_col.a * v_fade);
	ALPHA = 1.0;
}
