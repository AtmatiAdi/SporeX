shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform, shadows_disabled, fog_disabled;

// Emission nebulae, unresolved starlight glow, shells (supernova remnants,
// planetary nebulae) and supernova flares. Shape 0 = noisy puff, 1 = shell,
// 2 = flare (see galaxy_sprite.gdshaderinc for the time curve).

#include "res://shaders/galaxy_sprite.gdshaderinc"

void fragment() {
	float r = length(v_uv);
	float a = 0.0;
	vec2 o = sx_seed_offset(v_seed);
	if (v_shape < 0.5) {
		vec2 p = v_uv * 1.8 + o;
		float n = sx_vnoise(p) * 0.55 + sx_vnoise(p * 2.3 + 4.1) * 0.3 + sx_vnoise(p * 5.1 - 2.7) * 0.15;
		float body = pow(max(0.0, 1.0 - r), 1.6);
		a = body * smoothstep(0.2, 0.85, n + body * 0.35);
	} else if (v_shape < 1.5) {
		vec2 p = v_uv * 3.0 + o;
		float n = sx_vnoise(p) * 0.6 + sx_vnoise(p * 2.7) * 0.4;
		float rim = exp(-pow((r - 0.7) * 7.0, 2.0));
		a = rim * (0.35 + 0.9 * n) + 0.12 * max(0.0, 1.0 - r);
	} else if (v_shape > 2.5) {
		// Smooth glow (unresolved starlight, core): no noise, cheapest shape.
		a = pow(max(0.0, 1.0 - r), 2.2);
	} else {
		float core = exp(-r * r * 22.0) * 1.6 + pow(max(0.0, 1.0 - r), 3.0) * 0.35;
		vec2 q = abs(v_uv);
		float spikes = max(0.0, 1.0 - q.x * 16.0) * (1.0 - q.y) + max(0.0, 1.0 - q.y * 16.0) * (1.0 - q.x);
		// Expanding shock shell after the peak.
		float shell_r = 0.2 + v_t * 5.0;
		float shell = exp(-pow((r - shell_r) * 9.0, 2.0)) * 0.4;
		a = core + spikes * 0.45 + shell;
	}
	ALBEDO = v_col.rgb * (a * v_col.a * v_fade);
	ALPHA = 1.0;
}
