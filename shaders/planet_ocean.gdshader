shader_type spatial;
render_mode cull_back, depth_draw_opaque;

// Sea-level sphere. Opaque on purpose (no sorting, cheap on integrated GPUs).

uniform vec3 color : source_color = vec3(0.05, 0.22, 0.45);
uniform vec3 color_rim : source_color = vec3(0.25, 0.5, 0.8);
uniform float roughness = 0.32;

void fragment() {
	float fres = pow(clamp(1.0 - dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	ALBEDO = mix(color, color_rim, fres * 0.6);
	ROUGHNESS = roughness;
	SPECULAR = 0.7;
	METALLIC = 0.0;
}
