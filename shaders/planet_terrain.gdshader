shader_type spatial;
render_mode cull_back, depth_draw_opaque;

// Planet terrain: a unit sphere displaced by an equirectangular height map that
// is generated procedurally from the planet seed. Normals are reconstructed
// from the height map in the fragment shader, so the mesh can stay coarse.

uniform sampler2D height_map : filter_linear, repeat_enable;
uniform vec2 texel = vec2(0.0009765625, 0.001953125);
// Previous map + blend factor: new detail levels cross-fade in instead of popping.
uniform sampler2D height_map_prev : filter_linear, repeat_enable;
uniform float hm_blend = 1.0;
uniform float height_scale = 0.016; // relief as a fraction of the radius, over h in [0,1]
uniform float sea_level = 0.55;
uniform float normal_strength = 6.0;
uniform float ice_lat = 0.86;       // |sin(latitude)| above which ice caps start
uniform vec3 col_deep : source_color = vec3(0.02, 0.06, 0.14);
uniform vec3 col_shallow : source_color = vec3(0.08, 0.28, 0.32);
uniform vec3 col_sand : source_color = vec3(0.76, 0.70, 0.50);
uniform vec3 col_low : source_color = vec3(0.20, 0.42, 0.16);
uniform vec3 col_high : source_color = vec3(0.36, 0.34, 0.22);
uniform vec3 col_rock : source_color = vec3(0.42, 0.40, 0.38);
uniform vec3 col_snow : source_color = vec3(0.95, 0.96, 1.0);

varying vec3 v_n;
varying float v_h;

float hsample(vec2 uv) {
	float a = texture(height_map, uv).r;
	if (hm_blend >= 1.0) {
		return a;
	}
	return mix(texture(height_map_prev, uv).r, a, hm_blend);
}

vec2 sphere_uv(vec3 n) {
	return vec2(atan(n.x, n.z) / TAU + 0.5, 0.5 - asin(clamp(n.y, -1.0, 1.0)) / PI);
}

void vertex() {
	vec3 n = normalize(VERTEX);
	float h = hsample(sphere_uv(n));
	// Seabed is pushed down a little so it never pokes through the sea sphere.
	float hv = h < sea_level ? min(h, sea_level - 0.06) : h;
	VERTEX = n * (1.0 + (hv - 0.5) * height_scale);
	NORMAL = n;
	v_n = n;
	v_h = h;
}

void fragment() {
	vec3 n = normalize(v_n);
	vec2 uv = sphere_uv(n);
	float h = hsample(uv);
	float hl = hsample(uv - vec2(texel.x, 0.0));
	float hr = hsample(uv + vec2(texel.x, 0.0));
	float hup = hsample(uv - vec2(0.0, texel.y)); // north
	float hdn = hsample(uv + vec2(0.0, texel.y)); // south
	float cos_lat = max(sqrt(max(0.0, 1.0 - n.y * n.y)), 0.05);
	vec3 t = normalize(cross(vec3(0.0, 1.0, 0.0), n));
	vec3 b = cross(n, t);
	float dhu = (hr - hl) / (2.0 * texel.x * TAU * cos_lat);
	float dhb = (hup - hdn) / (2.0 * texel.y * PI);
	vec3 pn = normalize(n - (t * dhu + b * dhb) * height_scale * normal_strength);
	NORMAL = normalize((VIEW_MATRIX * vec4(mat3(MODEL_MATRIX) * pn, 0.0)).xyz);

	vec3 col;
	if (h < sea_level) {
		col = mix(col_deep, col_shallow, smoothstep(sea_level - 0.12, sea_level, h));
	} else {
		float land = (h - sea_level) / max(1.0 - sea_level, 0.001);
		col = col_sand;
		col = mix(col, col_low, smoothstep(0.02, 0.10, land));
		col = mix(col, col_high, smoothstep(0.25, 0.45, land));
		col = mix(col, col_rock, smoothstep(0.45, 0.65, land));
		col = mix(col, col_snow, smoothstep(0.70, 0.85, land));
	}
	float polar = smoothstep(ice_lat, ice_lat + 0.06, abs(n.y));
	col = mix(col, col_snow, polar * (h >= sea_level ? 1.0 : 0.6));
	ALBEDO = col;
	ROUGHNESS = 0.92;
	SPECULAR = 0.15;
}
