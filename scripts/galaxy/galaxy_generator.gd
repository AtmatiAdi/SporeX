class_name GalaxyGenerator
extends RefCounted
## Procedural spiral galaxy. Output is plain packed arrays so it can be pushed
## straight into a MultiMesh buffer without per-instance calls.
## Units: light years.

# Spectral classes: O B A F G K M
const CLASS_COLORS: Array[Color] = [
	Color(0.62, 0.72, 1.0), Color(0.72, 0.82, 1.0), Color(0.90, 0.93, 1.0),
	Color(1.0, 0.97, 0.90), Color(1.0, 0.92, 0.74), Color(1.0, 0.76, 0.50), Color(1.0, 0.55, 0.35)]
const CLASS_PX: Array[float] = [3.2, 2.8, 2.4, 2.0, 1.9, 1.7, 1.5]
const CLASS_BRIGHT: Array[float] = [1.0, 0.95, 0.85, 0.75, 0.7, 0.6, 0.5]
# Cumulative class weights for disk (young, arm-rich) and bulge (old, red) populations.
const DISK_CDF := [0.006, 0.03, 0.09, 0.2, 0.36, 0.62, 1.0]
const BULGE_CDF := [0.0, 0.002, 0.01, 0.05, 0.17, 0.5, 1.0]


class GalaxyData:
	var seed: int
	var name: String
	var radius_ly: float
	var arms: int
	var star_count: int
	var positions: PackedVector3Array   # ly, galaxy-centered
	var colors: PackedColorArray        # rgb + alpha = brightness
	var px_sizes: PackedFloat32Array    # on-screen point size (pixels)
	var classes: PackedInt32Array       # spectral class index
	var habitable: PackedInt32Array     # indices of playable star systems
	var dust_positions: PackedVector3Array
	var dust_colors: PackedColorArray
	var dust_radii: PackedFloat32Array  # ly


static func _pick_class(rng: RandomNumberGenerator, cdf: Array) -> int:
	var r := rng.randf()
	for i in cdf.size():
		if r <= cdf[i]:
			return i
	return cdf.size() - 1


static func generate(seed: int, star_count: int = 60000, dust_count: int = 3500, habitable_count: int = 8) -> GalaxyData:
	var g := GalaxyData.new()
	var rng := Seeds.rng(seed)
	g.seed = seed
	g.name = Seeds.make_name(Seeds.mix(seed, 777), 2, 3)
	g.arms = rng.randi_range(2, 5)
	g.radius_ly = rng.randf_range(32000.0, 60000.0)
	g.star_count = star_count

	var winding := rng.randf_range(2.2, 5.0)          # total twist over the radius (rad)
	var arm_spread := rng.randf_range(0.22, 0.45)     # angular scatter around an arm
	var bulge_frac := rng.randf_range(0.10, 0.22)
	var bulge_radius := g.radius_ly * rng.randf_range(0.08, 0.14)
	var thickness := g.radius_ly * rng.randf_range(0.008, 0.02)
	var disk_scale := g.radius_ly * rng.randf_range(0.28, 0.4)
	var arm_phase := rng.randf() * TAU

	g.positions.resize(star_count)
	g.colors.resize(star_count)
	g.px_sizes.resize(star_count)
	g.classes.resize(star_count)

	for i in star_count:
		var pos: Vector3
		var cls: int
		if rng.randf() < bulge_frac:
			var r := absf(rng.randfn(0.0, bulge_radius))
			var dir := Vector3(rng.randfn(), rng.randfn() * 0.55, rng.randfn()).normalized()
			pos = dir * r
			cls = _pick_class(rng, BULGE_CDF)
		else:
			var r := -disk_scale * log(1.0 - rng.randf())
			while r > g.radius_ly:
				r = -disk_scale * log(1.0 - rng.randf())
			var rn := r / g.radius_ly
			var arm := rng.randi_range(0, g.arms - 1)
			var scatter := rng.randfn(0.0, arm_spread * (0.35 + rn))
			var theta := arm_phase + arm * TAU / g.arms + rn * winding + scatter
			var y := rng.randfn(0.0, thickness * (1.2 - 0.7 * rn))
			pos = Vector3(cos(theta) * r, y, sin(theta) * r)
			# Stars sitting right on an arm are young -> bluer.
			var in_arm := absf(scatter) < arm_spread * 0.5
			cls = _pick_class(rng, DISK_CDF)
			if in_arm and rng.randf() < 0.35:
				cls = maxi(0, cls - 2)
		g.positions[i] = pos
		g.classes[i] = cls
		var c := CLASS_COLORS[cls]
		var bright := CLASS_BRIGHT[cls] * rng.randf_range(0.25, 0.6)
		if pos.length() < bulge_radius * 2.0:
			bright *= 0.45
		g.colors[i] = Color(c.r, c.g, c.b, bright)
		g.px_sizes[i] = CLASS_PX[cls] * rng.randf_range(0.8, 1.1)

	# Dust / nebula glow along the arms (large soft additive sprites).
	g.dust_positions.resize(dust_count)
	g.dust_colors.resize(dust_count)
	g.dust_radii.resize(dust_count)
	var tint_a := Color(0.45, 0.55, 1.0)
	var tint_b := Color(1.0, 0.6, 0.75)
	var tint_core := Color(1.0, 0.85, 0.6)
	for i in dust_count:
		var r := -disk_scale * 1.1 * log(1.0 - rng.randf())
		while r > g.radius_ly:
			r = -disk_scale * 1.1 * log(1.0 - rng.randf())
		var rn := r / g.radius_ly
		var arm := rng.randi_range(0, g.arms - 1)
		var theta := arm_phase + arm * TAU / g.arms + rn * winding + rng.randfn(0.0, arm_spread * 0.6)
		var y := rng.randfn(0.0, thickness * 0.8)
		g.dust_positions[i] = Vector3(cos(theta) * r, y, sin(theta) * r)
		var t := tint_a.lerp(tint_b, rng.randf())
		if rn < 0.18:
			t = t.lerp(tint_core, 0.8)
		var alpha := rng.randf_range(0.025, 0.06) * (1.0 - 0.4 * rn)
		g.dust_colors[i] = Color(t.r, t.g, t.b, alpha)
		g.dust_radii[i] = g.radius_ly * rng.randf_range(0.015, 0.035)

	# Playable systems: sun-like stars in the mid disk, not in the bulge.
	var tries := 0
	while g.habitable.size() < habitable_count and tries < 20000:
		tries += 1
		var idx := rng.randi_range(0, star_count - 1)
		var cls := g.classes[idx]
		if cls < 3 or cls > 5:
			continue
		var p := g.positions[idx]
		var rn := Vector2(p.x, p.z).length() / g.radius_ly
		if rn < 0.3 or rn > 0.8:
			continue
		if g.habitable.has(idx):
			continue
		g.habitable.append(idx)
	return g
