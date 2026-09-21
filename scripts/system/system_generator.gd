class_name SystemGenerator
extends RefCounted
## Procedural star system derived from a star seed. Units: meters, seconds.
## Distances are compressed compared to reality (like Spore) so that a system
## is readable on screen while planets still have believable sizes.

enum PlanetType { ROCKY, OCEAN, DESERT, ICE, GAS }

const TYPE_COLORS: Array[Color] = [
	Color(0.55, 0.45, 0.4), Color(0.25, 0.5, 0.9), Color(0.85, 0.7, 0.4),
	Color(0.8, 0.9, 1.0), Color(0.85, 0.75, 0.55)]


class PlanetData:
	var seed: int
	var index: int
	var name: String
	var type: int
	var radius_m: float
	var orbit_m: float
	var period_s: float
	var phase: float
	var incl: float
	var day_s: float
	var sea_level: float     # height threshold (0..1) below which there is water
	var height_scale: float  # terrain relief as fraction of the radius
	var color: Color
	var habitable: bool

	func r_sea() -> float:
		return radius_m * (1.0 + (sea_level - 0.5) * height_scale)


class SystemData:
	var seed: int
	var name: String
	var star_color: Color
	var star_class: int
	var star_radius_m: float
	var planets: Array[PlanetData] = []
	var habitable_index: int = -1


static func generate(seed: int, star_color: Color, star_class: int) -> SystemData:
	var s := SystemData.new()
	var rng := Seeds.rng(seed)
	s.seed = seed
	s.name = Seeds.make_name(Seeds.mix(seed, 1))
	s.star_color = star_color
	s.star_class = star_class
	s.star_radius_m = 7e8 * (2.6 - star_class * 0.3) * rng.randf_range(0.8, 1.2)

	var n := rng.randi_range(3, 8)
	s.habitable_index = rng.randi_range(1, mini(3, n - 1))
	var orbit := 3.5e9 * rng.randf_range(0.8, 1.3)
	for i in n:
		var p := PlanetData.new()
		p.seed = Seeds.mix(seed, i + 100)
		p.index = i
		p.name = "%s %s" % [s.name, ["I", "II", "III", "IV", "V", "VI", "VII", "VIII"][i]]
		p.orbit_m = orbit
		orbit *= rng.randf_range(1.5, 1.9)
		p.period_s = 900.0 * pow(p.orbit_m / 3.5e9, 1.5)
		p.phase = rng.randf() * TAU
		p.incl = rng.randfn(0.0, 0.03)
		p.day_s = rng.randf_range(240.0, 900.0)
		p.habitable = (i == s.habitable_index)
		if p.habitable:
			p.type = PlanetType.OCEAN
			p.radius_m = rng.randf_range(5.0e6, 8.0e6)
			p.sea_level = rng.randf_range(0.53, 0.6)
			p.height_scale = rng.randf_range(0.012, 0.02)
		elif i >= 3 and rng.randf() < 0.6:
			p.type = PlanetType.GAS
			p.radius_m = rng.randf_range(2.5e7, 6.0e7)
			p.sea_level = 0.0
			p.height_scale = 0.002
		else:
			p.type = [PlanetType.ROCKY, PlanetType.DESERT, PlanetType.ICE][rng.randi_range(0, 2)]
			if i == 0:
				p.type = PlanetType.ROCKY
			p.radius_m = rng.randf_range(2.0e6, 9.0e6)
			p.sea_level = 0.0 if p.type != PlanetType.ICE else 0.45
			p.height_scale = rng.randf_range(0.01, 0.025)
		var base := TYPE_COLORS[p.type]
		p.color = Color.from_hsv(fmod(base.h + rng.randf_range(-0.05, 0.05), 1.0), base.s * rng.randf_range(0.8, 1.1), base.v)
		s.planets.append(p)
	return s
