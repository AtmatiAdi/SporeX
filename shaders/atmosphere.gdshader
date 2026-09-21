shader_type spatial;
render_mode unshaded, blend_add, cull_front, depth_draw_never, shadows_disabled;

// Cheap rim-scattering shell drawn on the far hemisphere (cull_front).
// Works both from orbit (halo) and from inside the shell (sky haze).

uniform vec3 color : source_color = vec3(0.35, 0.55, 1.0);
uniform vec3 sun_dir = vec3(0.0, 0.0, 1.0);
uniform float intensity = 1.0;
uniform float falloff = 3.0;

varying vec3 v_wn;
varying vec3 v_wp;

void vertex() {
	v_wn = normalize(mat3(MODEL_MATRIX) * VERTEX);
	v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 vdir = normalize(CAMERA_POSITION_WORLD - v_wp);
	// Renormalize + clamp: pow() with a negative base is NaN and would explode in the glow pass.
	float rim = clamp(1.0 - abs(dot(normalize(v_wn), vdir)), 0.0, 1.0);
	float day = clamp(dot(v_wn, sun_dir) * 0.6 + 0.5, 0.0, 1.0);
	ALBEDO = color * pow(rim, falloff) * day * intensity;
	ALPHA = 1.0;
}
