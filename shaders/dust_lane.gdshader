shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, cull_disabled, skip_vertex_transform, shadows_disabled, fog_disabled;

// Dark dust lanes. Multiplicative: COLOR.rgb is the light transmitted through
// thick dust (blue absorbed most, so starlight behind it reddens, like real
// interstellar extinction), COLOR.a the opacity. Multiplying dims bright and
// faint stars alike instead of clipping faint ones to black. Drawn after stars
// and nebulae (render_priority).

#include "res://shaders/galaxy_sprite.gdshaderinc"

void fragment() {
	float r = length(v_uv);
	vec2 p = v_uv * 1.6 + sx_seed_offset(v_seed);
	float n = sx_vnoise(p) * 0.6 + sx_vnoise(p * 2.6 + 3.3) * 0.4;
	float body = pow(max(0.0, 1.0 - r), 1.3);
	float a = body * smoothstep(0.3, 0.8, n + body * 0.3);
	ALBEDO = mix(vec3(1.0), v_col.rgb, clamp(a * v_col.a * v_fade, 0.0, 1.0));
	ALPHA = 1.0;
}
