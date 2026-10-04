shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled, skip_vertex_transform, shadows_disabled, fog_disabled;

// Galactic nucleus: part 0 = accretion disk (flat quad in the black hole's
// plane, with the shadow, photon ring, swirl and Doppler beaming), part 1 =
// the pair of relativistic jets (a quad that rotates around the jet axis to
// face the camera). Premultiplied alpha: ALBEDO adds light, ALPHA occludes,
// so the shadow can actually darken the glowing core behind it.

uniform int part = 0;
uniform vec3 anchor = vec3(0.0);
uniform float unit_scale = 1.0;
uniform vec3 offset = vec3(0.0);
uniform float clamp_radius = 150000.0;
uniform float fade = 1.0;
uniform vec3 core_pos = vec3(0.0);      // ly
uniform vec3 axis = vec3(0.0, 1.0, 0.0);
uniform vec3 disk_x = vec3(1.0, 0.0, 0.0);
uniform vec3 disk_z = vec3(0.0, 0.0, 1.0);
uniform float radius_ly = 300.0;
uniform float jet_len_ly = 10000.0;
uniform float strength = 0.5;
uniform vec3 color : source_color = vec3(1.0, 0.8, 0.55);
global uniform float sx_tan_half_fov;
global uniform float sx_viewport_height;

varying vec2 v_uv;
varying float v_fade;

void vertex() {
	vec3 rel = (core_pos - anchor) * unit_scale + offset - CAMERA_POSITION_WORLD;
	float d = length(rel);
	float k = 1.0;
	if (d > clamp_radius) {
		k = clamp_radius / d;
		rel *= k;
		d = clamp_radius;
	}
	float s = unit_scale * k;
	float upp = 2.0 * d * sx_tan_half_fov / sx_viewport_height;
	vec3 wp;
	if (part == 0) {
		float r = max(radius_ly * s, 5.0 * upp);
		wp = rel + (disk_x * VERTEX.x + disk_z * VERTEX.y) * 2.0 * r;
		// Fade out once the disk fills the screen (we are "inside" the core).
		v_fade = fade * (1.0 - smoothstep(0.3, 0.9, r / (upp * sx_viewport_height)));
	} else {
		vec3 side = cross(axis, normalize(-rel));
		side = length(side) > 1.0e-4 ? normalize(side) : disk_x;
		float w = max(jet_len_ly * 0.025 * s, 1.5 * upp);
		wp = rel + axis * VERTEX.y * 2.0 * jet_len_ly * s + side * VERTEX.x * 2.0 * w;
		v_fade = fade;
	}
	VERTEX = (VIEW_MATRIX * vec4(wp, 0.0)).xyz;
	NORMAL = vec3(0.0, 0.0, 1.0);
	v_uv = UV * 2.0 - 1.0;
}

void fragment() {
	vec2 p = v_uv;
	vec3 emit;
	float occ = 0.0;
	if (part == 0) {
		float r = length(p);
		float ang = atan(p.y, p.x);
		float shadow = 1.0 - smoothstep(0.15, 0.2, r);
		float ring = exp(-pow((r - 0.22) * 38.0, 2.0)) * 1.6;
		float disk = smoothstep(0.2, 0.3, r) * pow(max(0.0, 1.0 - r), 1.5);
		float swirl = 0.65 + 0.35 * sin(ang * 3.0 - log(r + 0.01) * 9.0 + TIME * 1.2);
		float beam = 0.55 + 0.45 * sin(ang + 0.6);
		vec3 hot = vec3(0.85, 0.9, 1.0);
		vec3 c = mix(hot, color * vec3(1.0, 0.7, 0.45), smoothstep(0.25, 0.8, r));
		emit = c * (disk * swirl * beam * 1.4 + ring);
		occ = shadow * 0.92;
		emit *= strength;
	} else {
		float along = abs(p.y);
		float core = exp(-p.x * p.x * 18.0 / (0.25 + along * 1.5));
		float knots = 0.65 + 0.35 * sin(along * 38.0 - TIME * 1.6);
		float fall = pow(max(0.0, 1.0 - along), 1.4) * smoothstep(0.0, 0.04, along);
		emit = vec3(0.55, 0.68, 1.0) * core * fall * knots * strength * 0.9;
	}
	ALBEDO = emit * v_fade;
	ALPHA = occ * v_fade;
}
