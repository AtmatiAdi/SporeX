class_name Universe
extends RefCounted
## Holds the generated universe plus the "anchor chain" that gives every layer a
## double-precision origin:
##   G (galaxy center) -> S (selected star) -> P (selected planet center) -> L (landing point on the sea)
## All frames share the same axis orientation; only L additionally carries a
## rotation basis (up = local vertical) that spins with the planet.

enum Frame { G, S, P, L }

const LY := 9.4607e15

var galaxy: GalaxyGenerator.GalaxyData
var system: SystemGenerator.SystemData
var selected_star := -1
var selected_planet := -1
var time := 0.0

# Landing point, in the planet body frame (before spin).
var lock_dir_body := Vector3.UP
var l_basis_body := Basis.IDENTITY


func build(seed: int, star_count: int, detail: float = 1.0) -> void:
	var t0 := Time.get_ticks_msec()
	galaxy = GalaxyGenerator.generate(seed, star_count, detail)
	print("galaxy %d (%s, %d stars, %d nebula, %d dust, %d far): %d ms" % [seed, galaxy.morph_name, galaxy.star_count,
		galaxy.nebula.size(), galaxy.dust.size(), galaxy.far.size(), Time.get_ticks_msec() - t0])
	selected_star = -1
	select_star(galaxy.habitable[0])


func select_star(index: int) -> void:
	if index == selected_star:
		return
	selected_star = index
	var c := galaxy.colors[index]
	system = SystemGenerator.generate(galaxy.system_seed(index), Color(c.r, c.g, c.b), galaxy.classes[index])
	selected_planet = system.habitable_index


func select_planet(index: int) -> void:
	selected_planet = clampi(index, 0, system.planets.size() - 1)


func planet() -> SystemGenerator.PlanetData:
	return system.planets[selected_planet]


func star_name() -> String:
	return system.name


func r_sea() -> float:
	return planet().r_sea()


# --- chain offsets (double precision) ---------------------------------------

func star_pos_g() -> DVec3:
	var p := galaxy.positions[selected_star]
	return DVec3.new(p.x * LY, p.y * LY, p.z * LY)


func planet_pos_s(index: int = -1, at_time: float = -1.0) -> DVec3:
	var pd: SystemGenerator.PlanetData = system.planets[index if index >= 0 else selected_planet]
	var t := time if at_time < 0.0 else at_time
	var th := pd.phase + t * TAU / pd.period_s
	var ci := cos(pd.incl)
	var si := sin(pd.incl)
	return DVec3.new(cos(th) * pd.orbit_m, sin(th) * si * pd.orbit_m, sin(th) * ci * pd.orbit_m)


func spin_angle() -> float:
	return fmod(time * TAU / planet().day_s, TAU)


func planet_rot() -> Basis:
	return Basis(Vector3.UP, spin_angle())


func lock_pos_p() -> DVec3:
	return DVec3.from_v3(lock_dir_body).rotated_y(spin_angle()).mul(r_sea())


func l_basis_world() -> Basis:
	return planet_rot() * l_basis_body


## Offset of frame k's origin expressed in frame k-1.
func chain_offset(k: int) -> DVec3:
	match k:
		Frame.S: return star_pos_g()
		Frame.P: return planet_pos_s()
		Frame.L: return lock_pos_p()
	return DVec3.zero()


## Position of frame a's origin expressed in frame b.
func pos_in(a: int, b: int) -> DVec3:
	var acc := DVec3.zero()
	if a > b:
		for k in range(b + 1, a + 1):
			acc = acc.add(chain_offset(k))
	elif a < b:
		for k in range(a + 1, b + 1):
			acc = acc.sub(chain_offset(k))
	return acc
