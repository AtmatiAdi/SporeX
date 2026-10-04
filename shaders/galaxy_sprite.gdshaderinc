// Shared vertex stage for galaxy-scale sprites (nebulae, dust, novae, distant
// galaxies). Positions come from a MultiMesh in light years; the anchor /
// unit_scale / offset uniforms map them into the current scale-space frame.
//
// INSTANCE_CUSTOM: x = radius (ly), y = min size (px), z = shape, w = seed.
// For transients (z == 2, only when `transients` is on): x = period (s),
// y = peak size (px), w = phase offset in [0, 1).
//
// Sprites that would cover a large part of the screen fade out and collapse to
// a degenerate quad, so flying through a nebula costs no fill rate.

uniform vec3 anchor = vec3(0.0);
uniform float unit_scale = 1.0;
uniform vec3 offset = vec3(0.0);
uniform float clamp_radius = 150000.0;
uniform float fade = 1.0;
uniform float max_screen = 0.9;      // fraction of the viewport height
uniform bool transients = false;
uniform bool near_fade_all = false;   // dust: every sprite fades when the camera is inside it
uniform bool flatten_enabled = false; // z = shape + 0.45 * k: squash toward the disk plane by k
global uniform float sx_tan_half_fov;
global uniform float sx_viewport_height;

varying vec2 v_uv;
varying vec4 v_col;
varying float v_shape;
varying float v_seed;
varying float v_fade;
varying float v_t;

// Hash without sine (Dave Hoskins): stable for large inputs on every GPU.
float sx_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float sx_vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(sx_hash(i), sx_hash(i + vec2(1.0, 0.0)), u.x),
		mix(sx_hash(i + vec2(0.0, 1.0)), sx_hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

vec2 sx_seed_offset(float seed) {
	return vec2(fract(seed * 0.1234), fract(seed * 0.5678)) * 64.0;
}

void vertex() {
	vec3 center = (MODEL_MATRIX[3].xyz - anchor) * unit_scale + offset;
	vec3 rel = center - CAMERA_POSITION_WORLD;
	float d = length(rel);
	float shape = INSTANCE_CUSTOM.z;
	float flat_k = 0.0;
	if (flatten_enabled) {
		flat_k = fract(shape) / 0.45;
		shape = floor(shape);
	}
	float radius = INSTANCE_CUSTOM.x * unit_scale;
	float min_px = INSTANCE_CUSTOM.y;
	float glow = 1.0;
	v_t = 0.0;
	if (transients && shape > 1.5) {
		// Supernova: rise in ~1.5% of the period, then exponential decay.
		float t = fract(TIME / INSTANCE_CUSTOM.x + INSTANCE_CUSTOM.w);
		glow = smoothstep(0.0, 0.015, t) * exp(-max(t - 0.015, 0.0) * 9.0);
		v_t = t;
		radius = 0.0;
		min_px *= 0.3 + 0.7 * glow;
	}
	// Diffuse light (glow, shape 3) and dust dissolve once the camera is inside
	// them: up close the same light is resolved into individual stars.
	if (flatten_enabled && (near_fade_all || (shape > 2.5 && shape < 3.5)) && radius > 0.0) {
		glow *= smoothstep(1.2, 4.0, d / radius);
	}
	if (d > clamp_radius) {
		float k = clamp_radius / d;
		rel *= k;
		radius *= k;
		d = clamp_radius;
	}
	float upp = 2.0 * d * sx_tan_half_fov / sx_viewport_height;
	float half_size = max(radius, min_px * upp);
	float frac = half_size / (upp * sx_viewport_height);
	v_fade = fade * (1.0 - smoothstep(max_screen * 0.35, max_screen, frac)) * glow;

	float rot = INSTANCE_CUSTOM.w * 6.2831853;
	vec2 q = VERTEX.xy;
	q = vec2(q.x * cos(rot) - q.y * sin(rot), q.x * sin(rot) + q.y * cos(rot));
	vec3 vc = (VIEW_MATRIX * vec4(rel, 0.0)).xyz;
	vec3 quad = vec3(q * 2.0 * half_size, 0.0);
	if (flat_k > 0.0) {
		// Squash the part of the quad that sticks out of the galactic plane.
		// Disk normal of the galaxy this sprite belongs to: instance basis Y.
		vec3 n = normalize((VIEW_MATRIX * vec4(MODEL_MATRIX[1].xyz, 0.0)).xyz);
		quad -= n * dot(quad, n) * (0.85 * flat_k);
	}
	VERTEX = vc + quad;
	if (v_fade < 0.002) {
		VERTEX = vec3(0.0);   // degenerate: no fragments at all
	}
	NORMAL = vec3(0.0, 0.0, 1.0);
	v_uv = UV * 2.0 - 1.0;
	v_col = COLOR;
	v_shape = shape;
	v_seed = INSTANCE_CUSTOM.w;
}
