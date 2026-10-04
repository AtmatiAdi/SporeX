shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform, shadows_disabled, fog_disabled;

// Real-density star field around the camera. Nothing is stored per star: an
// instance is (cell origin, first star index, star count, cell seed, cell age)
// and quad i of the batch mesh (UV2.x) becomes star (first + i) of that cell.
// Position, mass, age, temperature and luminosity come from an integer hash,
// identical to LocalStars.star() in GDScript (used for picking).
// Apparent brightness follows the real inverse-square law, so faint distant
// dwarfs cull themselves (degenerate quads) and only a natural sky remains.

uniform float unit_scale = 1.0;        // scene units per ly
uniform vec3 offset = vec3(0.0);       // scene position of the anchor star
uniform vec3 cam_rel = vec3(0.0);      // camera position relative to the anchor, ly
uniform float cell_size = 40.0;        // ly
uniform float radius = 160.0;          // ly: stars fade out toward the edge of the block
uniform float clamp_radius = 150000.0;
uniform float fade = 1.0;
uniform float bright_k = 1.0;
global uniform float sx_tan_half_fov;
global uniform float sx_viewport_height;

varying vec2 v_uv;
varying vec4 v_col;

uint lh(uint x) {
	x ^= x >> 16u;
	x *= 2146121005u;
	x ^= x >> 15u;
	x *= 2221713035u;
	x ^= x >> 16u;
	return x;
}

float lu(uint h) {
	return float(h >> 8u) * (1.0 / 16777216.0);
}

vec3 blackbody(float t) {
	float k = clamp(t, 1000.0, 40000.0) / 100.0;
	vec3 c = vec3(1.0);
	if (k <= 66.0) {
		c.g = (99.4708025861 * log(k) - 161.1195681661) / 255.0;
	} else {
		c.r = 329.698727446 * pow(k - 60.0, -0.1332047592) / 255.0;
		c.g = 288.1221695283 * pow(k - 60.0, -0.0755148492) / 255.0;
	}
	if (k < 66.0) {
		c.b = k <= 19.0 ? 0.0 : (138.5177312231 * log(k - 10.0) - 305.0447927307) / 255.0;
	}
	return mix(clamp(c, 0.0, 1.0), vec3(1.0), 0.22);
}

void vertex() {
	uint q = uint(UV2.x + 0.5);
	bool alive = float(q) < INSTANCE_CUSTOM.y;
	uint i = uint(INSTANCE_CUSTOM.x + 0.5) + q;
	uint seed = uint(INSTANCE_CUSTOM.z + 0.5);
	uint h0 = lh(seed ^ lh(i + 1u));
	vec3 p = MODEL_MATRIX[3].xyz + vec3(lu(lh(h0 + 1u)), lu(lh(h0 + 2u)), lu(lh(h0 + 3u))) * cell_size;

	// Population split (see LocalStars): indices [0, nb) are the bright part of
	// the IMF (m > 1 plus giants), the rest are dwarfs; w >= 100 marks dwarfs.
	bool dwarfs = INSTANCE_CUSTOM.w >= 100.0;
	float cell_age = mod(INSTANCE_CUSTOM.w, 100.0);
	float m_to = clamp(pow(10.0 / max(cell_age, 0.012), 0.4), 0.3, 55.0);
	float b = pow(max(m_to, 0.2), -1.35);
	float u1 = clamp((11.873 - 1.0) / (11.873 - b), 0.0, 1.0);
	float fb = clamp(1.0 - u1 + 0.015, 0.015, 1.0);
	float age = cell_age * exp((lu(lh(h0 + 4u)) - 0.5) * 1.6);
	float roll = lu(lh(h0 + 5u));
	float um = lu(lh(h0 + 6u));
	float temp;
	float lum;
	float m = 0.0;
	if (!dwarfs && roll < 0.015 / fb) {
		temp = mix(3100.0, 4900.0, um);
		lum = mix(60.0, 1500.0, lu(lh(h0 + 7u)));
	} else if (dwarfs && roll < 0.015 / max(1.0 - fb, 0.015) && cell_age > 1.0) {
		temp = mix(7000.0, 25000.0, um);
		lum = 0.003;
	} else {
		float uu = dwarfs ? um * u1 : u1 + um * (1.0 - u1);
		m = pow(11.873 + uu * (b - 11.873), -0.7407407);
		temp = clamp(5780.0 * pow(m, 0.54), 2500.0, 44000.0);
		lum = pow(m, 3.3);
	}

	vec3 d_ly = p - cam_rel;
	float dist = length(d_ly);
	float flux = lum / max(dist * dist, 1.0e-6);
	float bright = 0.3 * pow(flux / 0.01, 0.3) * bright_k;
	bright *= 1.0 - smoothstep(radius * 0.7, radius, dist);
	alive = alive && dist > 0.02 && bright > 0.055 && fade > 0.001;
	bright = min(bright, 2.5);

	vec3 center = p * unit_scale + offset;
	vec3 rel = center - CAMERA_POSITION_WORLD;
	float d = length(rel);
	if (d > clamp_radius) {
		rel *= clamp_radius / d;
		d = clamp_radius;
	}
	float upp = 2.0 * d * sx_tan_half_fov / sx_viewport_height;
	float half_size = clamp(1.0 + 1.1 * bright, 1.0, 4.0) * upp;
	vec3 vc = (VIEW_MATRIX * vec4(rel, 0.0)).xyz;
	VERTEX = alive ? vc + vec3(VERTEX.xy * 2.0 * half_size, 0.0) : vec3(0.0);
	NORMAL = vec3(0.0, 0.0, 1.0);
	v_uv = UV * 2.0 - 1.0;
	v_col = vec4(blackbody(temp), bright * fade);
}

void fragment() {
	float r = length(v_uv);
	float a = pow(max(0.0, 1.0 - r), 2.0);
	ALBEDO = v_col.rgb * (a * v_col.a);
	ALPHA = 1.0;
}
