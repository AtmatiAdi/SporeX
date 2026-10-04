shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform, shadows_disabled;

// GPU billboard used for stars, nebula dust, the sun, selection markers and
// marine snow. Positions come from a MultiMesh; the whole galaxy (60k+ stars)
// is a single draw call and the CPU never touches it after generation.
//
// INSTANCE_CUSTOM: x = world radius (local units, 0 = point), y = min size in
// pixels, z = shape (0 soft dot, 1 ring, 2 glow, 3 star with diffraction
// spikes), w = unused.
// COLOR.a = brightness.

uniform bool manual_transform = false; // galaxy mode: apply anchor/scale/offset here (keeps node transform identity)
uniform vec3 anchor = vec3(0.0);       // local-unit position subtracted from every instance
uniform float unit_scale = 1.0;        // scene units per local unit
uniform vec3 offset = vec3(0.0);       // scene position of the anchor
uniform float clamp_radius = 150000.0; // far things are projected onto a sphere (keeps them inside the far plane)
uniform float fade = 1.0;              // 0 = invisible (daylight), 1 = full
uniform float px_scale = 1.0;
global uniform float sx_tan_half_fov;   // set from the camera each frame (main.gd)
global uniform float sx_viewport_height;
uniform bool wrap_enabled = false;     // marine snow: wrap around the origin
uniform float wrap_size = 1.0;
uniform vec3 drift = vec3(0.0);
// Amplification: meshes with K quads per instance (UV2.x = quad index) turn
// every star into K stars; children are scattered by a hash on the GPU, so
// K x more stars cost no memory and no CPU. Quad 0 is the parent.
uniform float sub_spread = 0.0;        // local units
uniform vec3 sub_normal = vec3(0.0, 1.0, 0.0);

uint sx_h(uint x) {
	x ^= x >> 16u;
	x *= 2146121005u;
	x ^= x >> 15u;
	x *= 2221713035u;
	x ^= x >> 16u;
	return x;
}

float sx_u(uint h) {
	return float(h >> 8u) * (1.0 / 16777216.0);
}

varying vec2 v_uv;
varying vec4 v_col;
varying float v_shape;

void vertex() {
	vec3 center;
	float sub_dim = 1.0;
	float scale;
	if (manual_transform) {
		vec3 origin = MODEL_MATRIX[3].xyz;
		if (UV2.x > 0.5) {
			uint h = sx_h(uint(INSTANCE_ID) * 7919u + uint(UV2.x));
			vec3 g = vec3(sx_u(h), sx_u(sx_h(h + 1u)), sx_u(sx_h(h + 2u))) * 2.0 - 1.0;
			g -= sub_normal * dot(g, sub_normal) * 0.75;   // stay in the disk
			origin += g * sub_spread;
			sub_dim = 0.2 + 0.5 * sx_u(sx_h(h + 3u));
		}
		center = (origin - anchor) * unit_scale + offset;
		scale = unit_scale;
	} else {
		center = MODEL_MATRIX[3].xyz;
		scale = length(MODEL_MATRIX[0].xyz);
	}
	if (wrap_enabled) {
		center += drift * TIME;
		center = mod(center + 0.5 * wrap_size, wrap_size) - 0.5 * wrap_size;
	}
	vec3 rel = center - CAMERA_POSITION_WORLD;
	float d = length(rel);
	float radius = INSTANCE_CUSTOM.x * scale;
	if (d > clamp_radius) {
		float k = clamp_radius / d;
		rel *= k;
		radius *= k;
		d = clamp_radius;
	}
	vec3 vc = (VIEW_MATRIX * vec4(rel, 0.0)).xyz;
	float units_per_px = 2.0 * d * sx_tan_half_fov / sx_viewport_height;
	float half_size = max(radius, INSTANCE_CUSTOM.y * px_scale * units_per_px);
	VERTEX = vc + vec3(VERTEX.xy * 2.0 * half_size, 0.0);
	NORMAL = vec3(0.0, 0.0, 1.0);
	v_uv = UV * 2.0 - 1.0;
	v_col = COLOR;
	if (sub_dim < 1.0) {
		// Children: dimmer and redder (most stars are dwarfs).
		v_col = vec4(mix(COLOR.rgb, vec3(1.0, 0.72, 0.5), 1.0 - sub_dim), COLOR.a * sub_dim);
	}
	v_shape = INSTANCE_CUSTOM.z;
}

void fragment() {
	float r = length(v_uv);
	float a;
	if (v_shape < 0.5) {
		a = pow(max(0.0, 1.0 - r), 2.0);
	} else if (v_shape < 1.5) {
		a = 1.0 - smoothstep(0.0, 0.14, abs(r - 0.78));
	} else if (v_shape > 2.5) {
		// Bright star: tight core + faint 4-point diffraction spikes.
		vec2 q = abs(v_uv);
		float core = pow(max(0.0, 1.0 - r * 2.2), 2.0);
		float spikes = max(0.0, 1.0 - q.x * 18.0) * pow(1.0 - q.y, 2.0) + max(0.0, 1.0 - q.y * 18.0) * pow(1.0 - q.x, 2.0);
		a = core + spikes * 0.35 + exp(-r * r * 9.0) * 0.12;
	} else {
		float core = exp(-r * r * 14.0);
		float halo = pow(max(0.0, 1.0 - r), 1.6) * 0.35;
		a = core + halo;
	}
	ALBEDO = v_col.rgb * (a * v_col.a * fade);
	ALPHA = 1.0;
}
