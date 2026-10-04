class_name GalaxyGenerator
extends RefCounted
## Procedural galaxy. The silhouette is composed from a random set of
## overlapping "patterns" (disk, spiral arms, bar, rings, spheroids, clumps,
## tidal streams, star clusters), so two galaxies never share a shape and the
## structures interleave instead of forming a clean textbook spiral.
##
## Star colours come from an age + mass model: each pattern carries an age
## range, the mass is drawn from an IMF truncated at the main-sequence turnoff
## of that age, and the colour is the blackbody colour of the resulting
## temperature. That is why arms are blue, the bulge is red, and old regions
## have red giants while young ones have blue supergiants.
##
## Output is plain packed arrays, ready to go into MultiMesh buffers.
## Units: light years, galaxy-centered, disk in the XZ plane.
##
## Determinism: every subsystem draws from its own sub-seed, so changing the
## star budget or the nebula detail (quality preset) never moves a playable
## system. LAN peers only exchange the galaxy seed.

enum Morph { GRAND, MULTI, BARRED, FLOCCULENT, RING, IRREGULAR, ELLIPTICAL, LENTICULAR }
const MORPH_NAMES: Array[String] = [
	"spiralna", "wieloramienna", "z poprzeczką", "kłaczkowata",
	"pierścieniowa", "nieregularna", "eliptyczna", "soczewkowata"]
const MORPH_CDF := [0.16, 0.36, 0.57, 0.69, 0.75, 0.85, 0.93, 1.0]

# Pattern kinds.
enum P { DISK, ARM, BAR, RING, SPHEROID, BLOB, STREAM, CLUSTER }

# Billboard shapes (must match shaders/nebula.gdshader).
const SH_PUFF := 0.0
const SH_RING := 1.0
const SH_NOVA := 2.0
const SH_GLOW := 3.0
# Added to a shape: squash the sprite toward the disk plane (1 FLAT = fully).
# Face-on it is a normal billboard, edge-on a thin sliver - disk glow and dust
# lanes then look right from every angle.
const FLAT := 0.45

# Light transmitted through a dust lane (reddened: blue is absorbed most).
const DUST_TINT := Color(0.32, 0.22, 0.16)

# Spectral class lower bounds in K (O B A F G K M) - kept for SystemGenerator.
const CLASS_TEMP := [30000.0, 10000.0, 7500.0, 6000.0, 5200.0, 3700.0]
const CLASS_LETTERS: Array[String] = ["O", "B", "A", "F", "G", "K", "M"]

const IMF_A := 11.873            # 0.16 ^ -1.35, the IMF inverse-CDF constant
const LUT_N := 96
const T_LO := 1800.0
const T_HI := 42000.0

# Emission line palettes: [dominant, accent]
const PALETTES: Array = [
	[Color(1.00, 0.20, 0.30), Color(0.30, 0.72, 1.00)],  # H II: hydrogen + O III
	[Color(0.32, 0.52, 1.00), Color(0.72, 0.84, 1.00)],  # reflection nebula
	[Color(0.25, 1.00, 0.72), Color(1.00, 0.50, 0.82)],  # supernova remnant
	[Color(1.00, 0.68, 0.32), Color(1.00, 0.36, 0.48)],  # dusty, near the core
	[Color(0.72, 0.34, 1.00), Color(0.34, 0.92, 1.00)],  # exotic
]

static var _lut: PackedColorArray = PackedColorArray()


## A sprite set ready for one MultiMesh (position + colour + 4 custom floats +
## the disk normal used to flatten the sprite, stored in the instance basis).
class Sprites:
	var pos := PackedVector3Array()
	var col := PackedColorArray()
	var cst := PackedFloat32Array()
	var nrm := PackedVector3Array()

	func add(p: Vector3, c: Color, c0: float, c1: float, c2: float, c3: float, n := Vector3.UP) -> void:
		pos.append(p)
		col.append(c)
		cst.append(c0)
		cst.append(c1)
		cst.append(c2)
		cst.append(c3)
		nrm.append(n)

	func size() -> int:
		return pos.size()

	func transform(xf: Transform3D) -> void:
		for i in pos.size():
			pos[i] = xf * pos[i]
			nrm[i] = (xf.basis * nrm[i]).normalized()

	func append_from(o: Sprites) -> void:
		pos.append_array(o.pos)
		col.append_array(o.col)
		cst.append_array(o.cst)
		nrm.append_array(o.nrm)


## One structural component of the galaxy. Several of these overlap.
class Pattern:
	var kind := 0
	var weight := 1.0        # share of the star budget
	var count := 0
	var age_lo := 1.0        # Gyr
	var age_hi := 8.0
	var gas := 0.0           # star formation -> seeds nebulae, dust and novae
	var center := Vector3.ZERO
	var r_in := 0.0          # fractions of the galaxy radius
	var r_out := 1.0
	var scale := 0.35
	var width := 0.03
	var thick := 0.012
	var phase := 0.0
	var winding := 3.0
	var flatten := 1.0
	var spurs := 0.0
	var tilt := Basis.IDENTITY
	var planar := true       # shares the disk-wide warp / shear
	var diffuse := true      # contributes to the unresolved-starlight glow
	var partner := false     # belongs to the second galaxy of a colliding pair
	var xform := Transform3D.IDENTITY   # local disk frame -> galaxy frame

	func normal() -> Vector3:
		return xform.basis.y.normalized()


## A neighbouring galaxy that is generated for real (in a worker thread).
class Neighbor:
	var seed := 0
	var pos := Vector3.ZERO   # ly, relative to our galaxy center


class GalaxyData:
	var seed: int
	var name: String
	var morph: int
	var morph_name: String
	var merger := false                 # colliding pair
	var radius_ly: float
	var arms: int
	var star_count: int
	var orient := Basis.IDENTITY        # disk plane of the galaxy in space
	var positions: PackedVector3Array   # ly, galaxy-centered
	var colors: PackedColorArray        # rgb + alpha = brightness
	var px_sizes: PackedFloat32Array    # on-screen point size (pixels)
	var classes: PackedInt32Array       # spectral class index (O..M)
	var temps: PackedFloat32Array       # K
	var ages: PackedFloat32Array        # Gyr
	var habitable: PackedInt32Array     # indices of playable star systems
	var nebula := Sprites.new()         # additive emission clouds
	var dust := Sprites.new()           # multiplicative dust lanes
	var novae := Sprites.new()          # time-driven transients
	var far := Sprites.new()            # background galaxy impostors and deep field
	var neighbors: Array[Neighbor] = [] # generated for real by generate_environment()
	# Core / active nucleus
	var core_color := Color(1.0, 0.85, 0.6)
	var core_radius := 300.0            # ly, accretion disk
	var core_tilt := Basis.IDENTITY     # disk plane of the black hole
	var quasar := 0.0                   # 0 = dormant, 1 = full quasar
	var jet_len := 0.0                  # ly

	var sys_seeds := {}                 # index -> system seed, for stars added at runtime
	var _by_sys_seed := {}

	func star_class_letter(i: int) -> String:
		return CLASS_LETTERS[classes[i]]

	## Seed of the star system around star i (same on every machine).
	func system_seed(i: int) -> int:
		return sys_seeds.get(i, Seeds.mix(seed, i))

	## Register a star from the local (virtual) field so it can be selected
	## like any other; returns its index. Re-adding the same star returns the
	## same index.
	func add_star(pos: Vector3, temp: float, age: float, sys_seed: int) -> int:
		if _by_sys_seed.has(sys_seed):
			return _by_sys_seed[sys_seed]
		var c := GalaxyGenerator.temp_color(temp)
		positions.append(pos)
		colors.append(Color(c.r, c.g, c.b, 0.5))
		px_sizes.append(1.6)
		classes.append(GalaxyGenerator.temp_class(temp))
		temps.append(temp)
		ages.append(age)
		var i := positions.size() - 1
		sys_seeds[i] = sys_seed
		_by_sys_seed[sys_seed] = i
		return i


## Everything around the galaxy that is generated in the background: real
## neighbour galaxies (stars + gas + dust) and giant nebulae.
class EnvData:
	var seed := 0
	var stars := Sprites.new()    # custom: 0, px, shape, 0
	var nebula := Sprites.new()
	var dust := Sprites.new()
	var neighbor_count := 0
	var star_total := 0


# --- instance state used while building --------------------------------------

var radius := 45000.0
var warp_noise: FastNoiseLite
var dens_noise: FastNoiseLite
var warp_amp := 0.0
var dens_floor := 0.3
var shear := 0.0
var shear_cos := 1.0
var shear_sin := 0.0
var bend := 0.0
var bend_m := 1.0
var bend_phase := 0.0


static func generate(seed: int, star_count: int = 60000, detail: float = 1.0) -> GalaxyData:
	return GalaxyGenerator.new()._build(seed, star_count, detail)


# --- colour ------------------------------------------------------------------

## Blackbody colour (Tanner Helland's approximation), slightly desaturated
## because stars read as white-ish tints, not as pure spectrum colours.
static func _blackbody(t: float) -> Color:
	var k := clampf(t, 1000.0, 40000.0) / 100.0
	var r := 1.0
	var g := 1.0
	var b := 1.0
	if k <= 66.0:
		g = (99.4708025861 * log(k) - 161.1195681661) / 255.0
	else:
		r = (329.698727446 * pow(k - 60.0, -0.1332047592)) / 255.0
		g = (288.1221695283 * pow(k - 60.0, -0.0755148492)) / 255.0
	if k < 66.0:
		b = 0.0 if k <= 19.0 else (138.5177312231 * log(k - 10.0) - 305.0447927307) / 255.0
	var c := Color(clampf(r, 0.0, 1.0), clampf(g, 0.0, 1.0), clampf(b, 0.0, 1.0))
	return c.lerp(Color.WHITE, 0.22)


static func temp_color(t: float) -> Color:
	if _lut.size() == 0:
		_lut.resize(LUT_N)
		for i in LUT_N:
			_lut[i] = _blackbody(T_LO * pow(T_HI / T_LO, float(i) / float(LUT_N - 1)))
	var f := log(clampf(t, T_LO, T_HI) / T_LO) / log(T_HI / T_LO) * float(LUT_N - 1)
	var i0 := int(f)
	if i0 >= LUT_N - 1:
		return _lut[LUT_N - 1]
	return _lut[i0].lerp(_lut[i0 + 1], f - float(i0))


static func temp_class(t: float) -> int:
	for i in CLASS_TEMP.size():
		if t >= CLASS_TEMP[i]:
			return i
	return CLASS_TEMP.size()


## Initial mass function (Salpeter), truncated at the turnoff mass of the age.
static func _imf(rng: RandomNumberGenerator, m_hi: float) -> float:
	var b := pow(maxf(m_hi, 0.2), -1.35)
	return pow(IMF_A + rng.randf() * (b - IMF_A), -0.7407407)


## Mass of a star that is leaving the main sequence right now.
static func _turnoff(age_gyr: float) -> float:
	return clampf(pow(10.0 / maxf(age_gyr, 0.012), 0.4), 0.3, 55.0)


# --- morphology --------------------------------------------------------------

static func _pick_morph(rng: RandomNumberGenerator) -> int:
	var r := rng.randf()
	for i in MORPH_CDF.size():
		if r <= MORPH_CDF[i]:
			return i
	return Morph.GRAND


func _pat(kind: int, weight: float, age_lo: float, age_hi: float, gas: float) -> Pattern:
	var p := Pattern.new()
	p.kind = kind
	p.weight = weight
	p.age_lo = age_lo
	p.age_hi = age_hi
	p.gas = gas
	return p


static func _random_basis(rng: RandomNumberGenerator, max_tilt: float) -> Basis:
	var b := Basis(Vector3.UP, rng.randf() * TAU)
	b = Basis(Vector3.RIGHT, rng.randf_range(-max_tilt, max_tilt)) * b
	return Basis(Vector3.UP, rng.randf() * TAU) * b


## Spiral arms: each arm gets its own pitch, strength, length and start angle,
## and can fork into a branch. Perfect symmetry is what makes procedural
## spirals look fake.
func _add_arms(pats: Array[Pattern], rng: RandomNumberGenerator, n: int, base_phase: float,
		winding: float, r_in: float, total_w: float, width: float, jitter: float) -> void:
	for a in n:
		var p := _pat(P.ARM, 0.0, 0.01, 3.0, 1.0)
		p.phase = base_phase + a * TAU / n + rng.randfn(0.0, jitter)
		p.winding = winding * rng.randf_range(0.8, 1.25)
		p.r_in = r_in * rng.randf_range(0.8, 1.2)
		p.r_out = rng.randf_range(0.7, 1.0)
		p.scale = rng.randf_range(0.28, 0.45)
		p.width = width * rng.randf_range(0.7, 1.4)
		p.thick = rng.randf_range(0.006, 0.012)
		p.spurs = rng.randf_range(0.04, 0.16)
		var strength := rng.randf_range(0.55, 1.3)
		p.weight = total_w / n * strength
		p.gas = strength
		pats.append(p)
		if rng.randf() < 0.45:
			# Branch splitting off the arm part way out.
			var b := _pat(P.ARM, p.weight * rng.randf_range(0.25, 0.5), 0.01, 2.0, 0.7)
			var t := rng.randf_range(0.35, 0.65)
			b.r_in = lerpf(p.r_in, p.r_out, t)
			b.r_out = minf(1.0, b.r_in + rng.randf_range(0.25, 0.5))
			b.phase = p.phase + p.winding * log(b.r_in / maxf(p.r_in, 0.01)) + rng.randf_range(0.15, 0.5)
			b.winding = p.winding * rng.randf_range(0.5, 0.9)
			b.scale = 0.5
			b.width = p.width * 0.7
			b.thick = p.thick
			b.spurs = p.spurs
			pats.append(b)


func _make_patterns(rng: RandomNumberGenerator, morph: int) -> Array[Pattern]:
	var pats: Array[Pattern] = []
	var phase := rng.randf() * TAU
	var winding := rng.randf_range(1.6, 3.4)   # rad per e-fold of radius (log spiral)
	var arms := 0

	# Every galaxy has a disk (possibly faint), a bulge and a stellar halo.
	var disk := _pat(P.DISK, 0.30, 0.5, 10.0, 0.25)
	disk.scale = rng.randf_range(0.25, 0.38)
	disk.thick = rng.randf_range(0.012, 0.025)
	pats.append(disk)
	var bulge := _pat(P.SPHEROID, 0.12, 6.0, 12.0, 0.0)
	bulge.scale = rng.randf_range(0.025, 0.05)
	bulge.r_out = 0.3
	bulge.flatten = rng.randf_range(0.5, 0.8)
	bulge.tilt = _random_basis(rng, 0.2)
	bulge.planar = false
	pats.append(bulge)
	var halo := _pat(P.SPHEROID, 0.03, 9.0, 13.0, 0.0)
	halo.scale = rng.randf_range(0.15, 0.3)
	halo.r_out = 1.3
	halo.flatten = rng.randf_range(0.6, 0.9)
	halo.planar = false
	halo.diffuse = false
	pats.append(halo)

	match morph:
		Morph.GRAND:
			arms = 2
			_add_arms(pats, rng, 2, phase, winding, rng.randf_range(0.05, 0.12), 0.45, 0.025, 0.15)
		Morph.MULTI:
			arms = rng.randi_range(3, 6)
			_add_arms(pats, rng, arms, phase, winding, rng.randf_range(0.06, 0.14), 0.42, 0.03, 0.5)
		Morph.BARRED:
			arms = 2 if rng.randf() < 0.7 else 4
			var bar := _pat(P.BAR, 0.12, 2.0, 10.0, 0.2)
			bar.r_out = rng.randf_range(0.14, 0.3)
			bar.width = bar.r_out * rng.randf_range(0.18, 0.3)
			bar.thick = 0.015
			bar.phase = phase
			pats.append(bar)
			_add_arms(pats, rng, arms, phase, winding * 0.8, bar.r_out, 0.38, 0.028, 0.12)
			if rng.randf() < 0.6:
				var ring := _pat(P.RING, 0.06, 0.2, 4.0, 0.6)
				ring.r_out = bar.r_out * rng.randf_range(0.95, 1.15)
				ring.width = 0.015
				ring.flatten = rng.randf_range(0.7, 0.95)
				ring.phase = phase
				pats.append(ring)
		Morph.FLOCCULENT:
			# Many short, weakly wound arm fragments on a clumpy disk.
			disk.weight = 0.4
			arms = rng.randi_range(9, 18)
			for i in arms:
				var p := _pat(P.ARM, 0.4 / arms, 0.01, 2.5, 0.8)
				p.phase = rng.randf() * TAU
				p.winding = winding * rng.randf_range(0.6, 1.5)
				p.r_in = rng.randf_range(0.08, 0.55)
				p.r_out = minf(1.0, p.r_in + rng.randf_range(0.15, 0.4))
				p.scale = 0.6
				p.width = rng.randf_range(0.015, 0.035)
				p.thick = 0.01
				p.spurs = 0.2
				pats.append(p)
		Morph.RING:
			# Collisional ring (Cartwheel-like): off-center ring plus weak spokes.
			disk.weight = 0.12
			var ring := _pat(P.RING, 0.4, 0.01, 1.5, 1.2)
			ring.r_out = rng.randf_range(0.55, 0.85)
			ring.width = rng.randf_range(0.03, 0.06)
			ring.flatten = rng.randf_range(0.75, 1.0)
			ring.center = Vector3(rng.randfn(0.0, 0.06), 0.0, rng.randfn(0.0, 0.06)) * radius
			ring.phase = phase
			pats.append(ring)
			var inner := _pat(P.RING, 0.1, 1.0, 6.0, 0.3)
			inner.r_out = ring.r_out * rng.randf_range(0.25, 0.4)
			inner.width = 0.02
			pats.append(inner)
			arms = rng.randi_range(4, 8)
			_add_arms(pats, rng, arms, phase, 0.25, 0.1, 0.12, 0.012, 0.6)
			for k in range(pats.size() - 1, 0, -1):
				if pats[k].kind != P.ARM:
					break
				pats[k].r_out = minf(pats[k].r_out, ring.r_out * 0.97)   # spokes end at the ring
		Morph.IRREGULAR:
			disk.weight = 0.25
			disk.thick = 0.04
			bulge.weight = 0.03
			for i in rng.randi_range(3, 6):
				var b := _pat(P.BLOB, rng.randf_range(0.06, 0.16), 0.01, 3.0, 1.0)
				b.center = Vector3(rng.randfn(0.0, 0.3), rng.randfn(0.0, 0.03), rng.randfn(0.0, 0.3)) * radius
				b.scale = rng.randf_range(0.06, 0.18)
				b.flatten = rng.randf_range(0.2, 0.5)
				b.tilt = _random_basis(rng, 0.4)
				pats.append(b)
			arms = rng.randi_range(0, 3)
			if arms > 0:
				_add_arms(pats, rng, arms, phase, winding * 1.4, 0.15, 0.18, 0.04, 1.2)
		Morph.ELLIPTICAL:
			# Old, gas-poor and smooth: the interest is in the halo and clusters.
			disk.weight = 0.04
			disk.gas = 0.0
			bulge.weight = 0.7
			bulge.scale = rng.randf_range(0.08, 0.14)
			bulge.r_out = 1.0
			bulge.flatten = rng.randf_range(0.45, 0.95)
			bulge.tilt = _random_basis(rng, 1.2)
			halo.weight = 0.12
		Morph.LENTICULAR:
			disk.weight = 0.45
			disk.gas = 0.05
			disk.age_lo = 3.0
			bulge.weight = 0.3
			bulge.scale *= 1.6
			var faint := _pat(P.RING, 0.05, 2.0, 8.0, 0.15)
			faint.r_out = rng.randf_range(0.4, 0.7)
			faint.width = 0.03
			pats.append(faint)

	# Interleaved extras: every galaxy gets a random mix of these on top of its
	# morphology, which is what breaks the textbook look.
	var gas_rich := morph != Morph.ELLIPTICAL and morph != Morph.LENTICULAR
	if gas_rich:
		for i in rng.randi_range(0, 2):
			var r := _pat(P.RING, rng.randf_range(0.02, 0.05), 0.05, 3.0, 0.5)
			r.r_out = rng.randf_range(0.3, 0.9)
			r.width = rng.randf_range(0.01, 0.03)
			r.flatten = rng.randf_range(0.8, 1.0)
			pats.append(r)
		for i in rng.randi_range(1, 4):
			# Giant star-forming complexes anywhere in the disk.
			var b := _pat(P.BLOB, rng.randf_range(0.01, 0.03), 0.005, 0.5, 1.5)
			var a := rng.randf() * TAU
			var rr := rng.randf_range(0.2, 0.8) * radius
			b.center = Vector3(cos(a) * rr, 0.0, sin(a) * rr)
			b.scale = rng.randf_range(0.02, 0.05)
			b.flatten = 0.3
			pats.append(b)
	if rng.randf() < 0.55:
		# Companion dwarf galaxy; sometimes with a short tidal tail of stripped stars.
		var comp := _pat(P.BLOB, rng.randf_range(0.015, 0.04), 0.5, 8.0, 0.4 if rng.randf() < 0.5 else 0.0)
		var a := rng.randf() * TAU
		var dist := rng.randf_range(1.05, 1.6) * radius
		comp.center = Vector3(cos(a) * dist, rng.randfn(0.0, 0.15) * radius, sin(a) * dist)
		comp.scale = rng.randf_range(0.03, 0.07)
		comp.flatten = rng.randf_range(0.4, 0.9)
		comp.tilt = _random_basis(rng, 1.5)
		comp.planar = false
		pats.append(comp)
		if rng.randf() < 0.45:
			var st := _pat(P.STREAM, rng.randf_range(0.004, 0.01), 1.0, 9.0, 0.0)
			st.phase = a - rng.randf_range(0.25, 0.6)
			st.winding = a - st.phase
			st.r_in = dist / radius * rng.randf_range(0.75, 0.9)
			st.r_out = dist / radius
			st.width = rng.randf_range(0.01, 0.02)
			st.tilt = Basis(Vector3(cos(a + PI * 0.5), 0.0, sin(a + PI * 0.5)), rng.randf_range(-0.3, 0.3))
			st.planar = false
			st.diffuse = false
			pats.append(st)

	# Star clusters: globulars in the halo (old), open clusters in the disk (young).
	for i in rng.randi_range(18, 45):
		var c := _pat(P.CLUSTER, 0.0015, 10.0, 13.0, 0.0)
		var dir := Vector3(rng.randfn(), rng.randfn() * 0.6, rng.randfn()).normalized()
		c.center = dir * radius * rng.randf_range(0.08, 0.7)
		c.scale = rng.randf_range(0.0006, 0.0014)
		c.planar = false
		pats.append(c)
	if gas_rich:
		for i in rng.randi_range(15, 40):
			var c := _pat(P.CLUSTER, 0.0008, 0.005, 0.3, 0.3)
			var a := rng.randf() * TAU
			var rr := rng.randf_range(0.15, 0.85) * radius
			c.center = Vector3(cos(a) * rr, rng.randfn(0.0, 0.004) * radius, sin(a) * rr)
			c.scale = rng.randf_range(0.0003, 0.0008)
			pats.append(c)

	var total := 0.0
	for p in pats:
		total += p.weight
	for p in pats:
		p.weight /= total
	_arms_count = arms
	return pats


var _arms_count := 0


# --- sampling ----------------------------------------------------------------

static func _rand_dir(rng: RandomNumberGenerator) -> Vector3:
	var v := Vector3(rng.randfn(), rng.randfn(), rng.randfn())
	return v.normalized() if v.length_squared() > 1.0e-12 else Vector3.UP


static func _exp_r(rng: RandomNumberGenerator, scale: float, lo: float, hi: float) -> float:
	for i in 4:
		var r := lo - scale * log(1.0 - rng.randf())
		if r <= hi:
			return r
	return rng.randf_range(lo, hi)


func _setup_shape(rng: RandomNumberGenerator, seed_val: int) -> void:
	warp_noise = FastNoiseLite.new()
	warp_noise.seed = Seeds.mix(seed_val, 31) & 0x7fffffff
	warp_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	warp_noise.fractal_octaves = 2
	warp_noise.frequency = rng.randf_range(1.5, 3.5) / radius
	warp_amp = radius * rng.randf_range(0.02, 0.08)

	dens_noise = FastNoiseLite.new()
	dens_noise.seed = Seeds.mix(seed_val, 47) & 0x7fffffff
	dens_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	dens_noise.fractal_octaves = 3
	dens_noise.frequency = rng.randf_range(6.0, 16.0) / radius
	dens_floor = rng.randf_range(0.12, 0.6)

	shear = rng.randf_range(0.0, 0.16)
	var sa := rng.randf() * TAU
	shear_cos = cos(sa)
	shear_sin = sin(sa)
	bend = rng.randf_range(0.0, 0.06) if rng.randf() < 0.7 else 0.0
	bend_m = 1.0 if rng.randf() < 0.7 else 2.0
	bend_phase = rng.randf() * TAU


## Raw position of one star of a pattern, before the disk-wide distortions.
func _sample(p: Pattern, rng: RandomNumberGenerator) -> Vector3:
	var R := radius
	match p.kind:
		P.DISK:
			var r := _exp_r(rng, p.scale * R, 0.0, p.r_out * R)
			var th := rng.randf() * TAU
			return Vector3(cos(th) * r, rng.randfn(0.0, p.thick * R * (1.3 - 0.8 * r / R)), sin(th) * r)
		P.ARM:
			var r := _exp_r(rng, p.scale * R, p.r_in * R, p.r_out * R)
			var th := p.phase + p.winding * log(r / maxf(p.r_in * R, 1.0))
			var radial := Vector3(cos(th), 0.0, sin(th))
			var tang := Vector3(-radial.z, 0.0, radial.x)
			var w := p.width * R * (0.45 + 0.9 * r / R)
			var off := rng.randfn(0.0, w)
			var along := 0.0
			if rng.randf() < p.spurs:
				# Feathers: short spurs leaving the arm at a consistent angle.
				var k := rng.randf_range(1.5, 5.0) * (1.0 if rng.randf() < 0.5 else -1.0)
				off += w * k
				along = w * k * 0.9
			return radial * (r + off) + tang * along + Vector3(0.0, rng.randfn(0.0, p.thick * R), 0.0)
		P.BAR:
			var t := rng.randf_range(-1.0, 1.0)
			var lx := t * p.r_out * R
			var lz := rng.randfn(0.0, p.width * R * (1.0 - 0.5 * t * t))
			var c := cos(p.phase)
			var s := sin(p.phase)
			return Vector3(lx * c - lz * s, rng.randfn(0.0, p.thick * R), lx * s + lz * c)
		P.RING:
			var th := rng.randf() * TAU
			var r := p.r_out * R + rng.randfn(0.0, p.width * R)
			var local := Vector3(cos(th) * r, rng.randfn(0.0, p.thick * R), sin(th) * r * p.flatten)
			return p.center + Basis(Vector3.UP, p.phase) * local
		P.SPHEROID:
			var u := rng.randf()
			var r := p.scale * R * u / maxf(1.0 - u, 0.01)
			for t in 6:
				if r <= p.r_out * R:
					break
				u = rng.randf()
				r = p.scale * R * u / maxf(1.0 - u, 0.01)
			if r > p.r_out * R:
				r = rng.randf() * p.r_out * R
			var v := _rand_dir(rng) * r
			v.y *= p.flatten
			return p.center + p.tilt * v
		P.BLOB:
			var v := Vector3(rng.randfn(), rng.randfn() * p.flatten, rng.randfn()) * p.scale * R
			return p.center + p.tilt * v
		P.STREAM:
			# t = 1 at the companion; denser there, thinning out toward the tip.
			var t := sqrt(rng.randf())
			var a := p.phase + t * p.winding
			var r := lerpf(p.r_in, p.r_out, t) * R
			var sig := p.width * R * (1.5 - t)
			var spine := p.tilt * Vector3(cos(a) * r, 0.0, sin(a) * r)
			return spine + Vector3(rng.randfn(), rng.randfn() * 0.6, rng.randfn()) * sig
		_:
			# CLUSTER: Plummer sphere.
			var u := maxf(rng.randf(), 0.002)
			var r := minf(p.scale * R / sqrt(pow(u, -0.6667) - 1.0 + 1.0e-4), p.scale * R * 8.0)
			return p.center + _rand_dir(rng) * r


## Disk-wide distortions shared by every planar pattern: oval shear, noise
## domain warp (bends arms and rings into organic shapes) and a vertical warp
## of the outer disk.
func _post(p: Vector3) -> Vector3:
	var u := p.x * shear_cos + p.z * shear_sin
	var v := -p.x * shear_sin + p.z * shear_cos
	u *= 1.0 + shear
	v /= 1.0 + shear
	var x := u * shear_cos - v * shear_sin
	var z := u * shear_sin + v * shear_cos
	x += warp_noise.get_noise_3d(x, p.y, z) * warp_amp
	z += warp_noise.get_noise_3d(z + 7919.0, p.y, x - 3571.0) * warp_amp
	var y := p.y
	if bend > 0.0:
		var rn := sqrt(x * x + z * z) / radius
		y += bend * radius * rn * rn * sin(atan2(z, x) * bend_m + bend_phase)
	return Vector3(x, y, z)


## Clumpy star formation: reject part of the samples in low-density noise.
func _dens_ok(p: Vector3, rng: RandomNumberGenerator) -> bool:
	var n := dens_noise.get_noise_3d(p.x, p.y * 3.0, p.z) * 0.5 + 0.5
	return rng.randf() < dens_floor + (1.0 - dens_floor) * smoothstep(0.3, 0.7, n)


func _place(p: Pattern, rng: RandomNumberGenerator, clumpy: bool) -> Vector3:
	var pos := _sample(p, rng)
	if clumpy:
		for t in 3:
			if _dens_ok(pos, rng):
				break
			pos = _sample(p, rng)
	return p.xform * (_post(pos) if p.planar else pos)


static func _cdf(pats: Array[Pattern], use_gas: bool) -> PackedFloat32Array:
	var cdf := PackedFloat32Array()
	var acc := 0.0
	for p in pats:
		var w := p.weight * p.gas if use_gas else p.weight
		if p.kind == P.CLUSTER:
			w = 0.0
		acc += w
		cdf.append(acc)
	if acc > 0.0:
		for i in cdf.size():
			cdf[i] /= acc
	return cdf


static func _pick(pats: Array[Pattern], cdf: PackedFloat32Array, rng: RandomNumberGenerator) -> Pattern:
	var i := cdf.bsearch(rng.randf())
	return pats[mini(i, pats.size() - 1)]


# --- build -------------------------------------------------------------------

func _build(seed_val: int, star_count: int, detail: float, full := true) -> GalaxyData:
	var g := GalaxyData.new()
	g.seed = seed_val
	g.name = Seeds.make_name(Seeds.mix(seed_val, 777), 2, 3)
	var rng := Seeds.rng(Seeds.mix(seed_val, 1))
	radius = rng.randf_range(30000.0, 66000.0)
	g.radius_ly = radius
	g.morph = _pick_morph(rng)
	g.morph_name = MORPH_NAMES[g.morph]
	_setup_shape(rng, seed_val)
	var pats := _make_patterns(rng, g.morph)
	g.arms = _arms_count
	if rng.randf() < MERGER_CHANCE and g.morph != Morph.ELLIPTICAL:
		_add_merger(pats, rng)
		g.merger = true
		g.morph_name = "zderzenie: %s + %s" % [g.morph_name, MORPH_NAMES[_partner_morph]]
	var hab := 8 if full else 0
	_gen_stars(g, pats, Seeds.rng(Seeds.mix(seed_val, 2)), star_count, hab)
	if full:
		_gen_habitable(g, pats, Seeds.rng(Seeds.mix(seed_val, 3)), hab)
		_gen_core(g, Seeds.rng(Seeds.mix(seed_val, 4)))
	_gen_nebulae(g, pats, Seeds.rng(Seeds.mix(seed_val, 5)), detail)
	_gen_dust(g, pats, Seeds.rng(Seeds.mix(seed_val, 6)), detail)
	if full:
		_gen_novae(g, pats, Seeds.rng(Seeds.mix(seed_val, 7)))
		_gen_far(g, Seeds.rng(Seeds.mix(seed_val, 8)), detail)
	_orient(g, Seeds.rng(Seeds.mix(seed_val, 9)))
	return g


## The galaxy is built in its own disk frame (XZ plane), then tilted as a
## whole: galaxies do not all lie flat in the sky.
func _orient(g: GalaxyData, rng: RandomNumberGenerator) -> void:
	var tilt := rng.randf_range(0.0, 1.3)
	var az := rng.randf() * TAU
	var axis := Vector3(cos(az), 0.0, sin(az))
	g.orient = Basis(axis, tilt) * Basis(Vector3.UP, rng.randf() * TAU)
	var xf := Transform3D(g.orient, Vector3.ZERO)
	for i in g.positions.size():
		g.positions[i] = g.orient * g.positions[i]
	g.nebula.transform(xf)
	g.dust.transform(xf)
	g.novae.transform(xf)
	g.core_tilt = g.orient * g.core_tilt


const MERGER_CHANCE := 0.04
var _partner_morph := 0


## Rare: two galaxies in collision. The partner is a full pattern set of its
## own (smaller, tilted, offset) and both throw out long tidal tails, like
## the Antennae or the Mice.
func _add_merger(pats: Array[Pattern], rng: RandomNumberGenerator) -> void:
	var main_arms := _arms_count
	_partner_morph = [Morph.GRAND, Morph.MULTI, Morph.BARRED, Morph.FLOCCULENT][rng.randi() % 4]
	var p2 := _make_patterns(rng, _partner_morph)
	_arms_count = main_arms
	var s := rng.randf_range(0.5, 0.85)
	var dir := _rand_dir(rng)
	dir.y *= 0.35
	dir = dir.normalized()
	var off := dir * radius * rng.randf_range(0.9, 1.4)
	var xf := Transform3D(_random_basis(rng, 1.4).scaled(Vector3(s, s, s)), off)
	for p in pats:
		p.weight *= 0.62
	for p in p2:
		p.weight *= 0.3
		p.partner = true
		p.xform = xf
	pats.append_array(p2)
	# Tidal tails: from each galaxy, swept away from the other one.
	for k in 2:
		var gxf := Transform3D.IDENTITY if k == 0 else xf
		var other := off if k == 0 else Vector3.ZERO
		var local := gxf.affine_inverse() * other
		var a := atan2(local.z, local.x) + PI
		var t := _pat(P.STREAM, 0.04, 0.01, 4.0, 0.5)
		# Stream t = 1 is its dense end: here the base at the galaxy, t = 0 the tip.
		t.winding = -rng.randf_range(1.2, 2.2)
		t.phase = a - rng.randf_range(0.2, 0.6) - t.winding
		t.r_in = rng.randf_range(1.6, 2.4)
		t.r_out = 0.6
		t.width = 0.03
		t.planar = false
		t.diffuse = false
		t.partner = k == 1
		t.xform = gxf
		pats.append(t)


func _set_star(g: GalaxyData, i: int, pos: Vector3, age: float, rng: RandomNumberGenerator) -> void:
	var temp: float
	var lum: float
	var roll := rng.randf()
	if roll < 0.015 and age > 0.3:
		# Red giant: a star of turnoff mass that has just left the main sequence.
		temp = rng.randf_range(3100.0, 4900.0)
		lum = rng.randf_range(60.0, 1500.0)
	elif roll < 0.03 and age > 1.0:
		# White dwarf left behind by a dead star.
		temp = rng.randf_range(7000.0, 25000.0)
		lum = 0.003
	else:
		var m := _imf(rng, _turnoff(age))
		temp = clampf(5780.0 * pow(m, 0.54), 2500.0, 44000.0)
		lum = pow(m, 3.3)
	var c := temp_color(temp)
	var bright := clampf(0.3 * pow(lum, 0.13), 0.06, 1.6) * rng.randf_range(0.8, 1.15)
	# Crowded core: dim individual stars so the bulge glows instead of clipping.
	bright *= clampf(pos.length() / (radius * 0.07), 0.45, 1.0)
	g.positions[i] = pos
	g.colors[i] = Color(c.r, c.g, c.b, bright)
	g.px_sizes[i] = clampf(1.15 + 0.22 * log(1.0 + lum), 1.1, 4.2)
	g.temps[i] = temp
	g.ages[i] = age
	g.classes[i] = temp_class(temp)


func _gen_stars(g: GalaxyData, pats: Array[Pattern], rng: RandomNumberGenerator, star_count: int, hab: int) -> void:
	var counts := PackedInt32Array()
	var total := 0
	for p in pats:
		var c := int(round(p.weight * star_count))
		counts.append(c)
		total += c
	var n := hab + total
	g.positions.resize(n)
	g.colors.resize(n)
	g.px_sizes.resize(n)
	g.classes.resize(n)
	g.temps.resize(n)
	g.ages.resize(n)
	var i := hab
	for k in pats.size():
		var p := pats[k]
		var clumpy := p.kind == P.DISK or p.kind == P.ARM or p.kind == P.RING
		var log_lo := log(p.age_lo)
		var log_span := log(p.age_hi) - log_lo
		for j in counts[k]:
			var pos := _place(p, rng, clumpy)
			# Log-uniform age: young regions get a real spread of ages.
			_set_star(g, i, pos, exp(log_lo + log_span * rng.randf()), rng)
			i += 1
	g.star_count = n


## Playable systems live in the first slots, so their indices (and therefore
## their system seeds) never depend on the star budget.
func _gen_habitable(g: GalaxyData, pats: Array[Pattern], rng: RandomNumberGenerator, count: int) -> void:
	var cands: Array[Pattern] = []
	for p in pats:
		if p.planar and not p.partner and (p.kind == P.ARM or p.kind == P.DISK or p.kind == P.RING):
			cands.append(p)
	var tries := 0
	var placed := 0
	while placed < count:
		tries += 1
		var p: Pattern = cands[rng.randi() % cands.size()]
		var pos := _place(p, rng, false)
		var rn := Vector2(pos.x, pos.z).length() / radius
		var relaxed := tries > 3000
		if not relaxed and (rn < 0.25 or rn > 0.85):
			continue
		var ok := true
		for k in placed:
			if g.positions[k].distance_to(pos) < radius * (0.02 if relaxed else 0.08):
				ok = false
				break
		if not ok:
			continue
		var m := rng.randf_range(0.8, 1.3)
		var temp := 5780.0 * pow(m, 0.54)
		var c := temp_color(temp)
		g.positions[placed] = pos
		g.colors[placed] = Color(c.r, c.g, c.b, 0.45)
		g.px_sizes[placed] = 1.8
		g.temps[placed] = temp
		g.ages[placed] = rng.randf_range(1.5, 7.0)
		g.classes[placed] = temp_class(temp)
		g.habitable.append(placed)
		placed += 1


func _gen_core(g: GalaxyData, rng: RandomNumberGenerator) -> void:
	var active := rng.randf() < 0.45
	g.quasar = rng.randf_range(0.55, 1.0) if active else rng.randf_range(0.08, 0.25)
	g.core_radius = radius * rng.randf_range(0.004, 0.008)
	g.jet_len = radius * rng.randf_range(0.15, 0.45) * g.quasar
	g.core_tilt = _random_basis(rng, 0.45)
	g.core_color = Color(1.0, 0.8, 0.55).lerp(Color(0.8, 0.88, 1.0), rng.randf() * g.quasar)


func _gen_nebulae(g: GalaxyData, pats: Array[Pattern], rng: RandomNumberGenerator, detail: float) -> void:
	var R := radius
	var mass_cdf := _cdf(pats, false)
	var gas_cdf := _cdf(pats, true)
	var has_gas := gas_cdf.size() > 0 and gas_cdf[gas_cdf.size() - 1] > 0.0

	# 1. Unresolved starlight: broad faint glow following the stellar mass.
	#    Old populations glow warm, young ones blue-white.
	for i in int(900 * detail):
		var p := _pick(pats, mass_cdf, rng)
		if not p.diffuse or p.kind == P.SPHEROID:
			continue
		var pos := _place(p, rng, false)
		var young := clampf(1.0 - log(p.age_hi) / log(10.0), 0.0, 1.0)
		var col := Color(1.0, 0.76, 0.5).lerp(Color(0.6, 0.72, 1.0), young)
		g.nebula.add(pos, Color(col, rng.randf_range(0.014, 0.03)), R * _s(p) * rng.randf_range(0.06, 0.13), 0.0, SH_GLOW + (FLAT if p.planar else 0.3 * FLAT), rng.randf() * 1000.0, p.normal())

	# Spheroids (bulge, elliptical body) glow as a few concentric layers: a
	# smooth profile instead of scattered blobs.
	for p in pats:
		if p.kind != P.SPHEROID or not p.diffuse:
			continue
		var k := 1.4
		while k < 24.0 and p.scale * k < p.r_out * 1.2:
			var a := clampf(p.weight * 0.9, 0.02, 0.2) / sqrt(k)
			g.nebula.add(p.xform * p.center, Color(Color(1.0, 0.8, 0.58), a), R * _s(p) * p.scale * k, 0.0, SH_GLOW + 0.3 * FLAT, rng.randf() * 1000.0, p.normal())
			k *= 1.7

	# 2. Core glow.
	for i in 5:
		var pos := _rand_dir(rng) * R * rng.randf_range(0.0, 0.02)
		pos.y *= 0.5
		g.nebula.add(pos, Color(g.core_color, rng.randf_range(0.05, 0.09)), R * rng.randf_range(0.05, 0.1), 0.0, SH_GLOW + 0.3 * FLAT, rng.randf() * 1000.0)

	if not has_gas:
		return
	# 3. Star-forming regions: random walks of puffs give filaments and knots.
	for r in int(round(rng.randf_range(22.0, 40.0) * detail)):
		var src := _pick(pats, gas_cdf, rng)
		var c := _place(src, rng, true)
		var roll := rng.randf()
		var pal: Array = PALETTES[0 if roll < 0.55 else (1 if roll < 0.75 else (4 if roll < 0.85 else 3))]
		if c.length() < R * 0.12:
			pal = PALETTES[3]
		var reg := R * rng.randf_range(0.01, 0.03)
		var n := int(rng.randf_range(18.0, 60.0) * detail) + 4
		var p := c
		for k in n:
			p += Vector3(rng.randfn(), rng.randfn() * 0.25, rng.randfn()) * reg * 0.35
			if p.distance_to(c) > reg * 2.5:
				p = c + (p - c) * 0.5
			var t := rng.randf()
			var col: Color = (pal[0] as Color).lerp(pal[1], t * t * t)
			var size := reg * rng.randf_range(0.25, 0.9) * (1.6 if k == 0 else 1.0)
			g.nebula.add(p, Color(col, rng.randf_range(0.05, 0.13)), size * _s(src), 1.2 if k == 0 else 0.0, SH_PUFF + 0.4 * FLAT, rng.randf() * 1000.0, src.normal())

	# 4. Supernova remnants and planetary nebulae: small glowing shells.
	for i in rng.randi_range(4, 9):
		var pos := _place(_pick(pats, gas_cdf, rng), rng, false)
		var pal: Array = PALETTES[2]
		g.nebula.add(pos, Color(pal[0] if rng.randf() < 0.6 else pal[1], rng.randf_range(0.25, 0.45)), R * rng.randf_range(0.002, 0.006), 0.0, SH_RING, rng.randf() * 1000.0)


## Dust lanes (subtractive): on the inner edge of every arm, around gas-rich
## rings, along the leading edges of a bar, plus patchy dust across the disk.
func _gen_dust(g: GalaxyData, pats: Array[Pattern], rng: RandomNumberGenerator, detail: float) -> void:
	var R := radius
	for p in pats:
		if p.kind == P.ARM:
			var n := int(90.0 * detail * clampf(p.gas, 0.3, 1.3) * (p.r_out - p.r_in))
			for i in n:
				var r := lerpf(p.r_in, p.r_out, pow(rng.randf(), 0.8)) * R
				var th := p.phase + p.winding * log(r / maxf(p.r_in * R, 1.0))
				var radial := Vector3(cos(th), 0.0, sin(th))
				var w := p.width * R * (0.45 + 0.9 * r / R)
				var pos := radial * (r - w * rng.randf_range(0.2, 1.3)) + Vector3(0.0, rng.randfn(0.0, p.thick * R * 0.5), 0.0)
				g.dust.add(p.xform * _post(pos), Color(DUST_TINT, rng.randf_range(0.2, 0.5)), _s(p) * w * rng.randf_range(0.6, 1.5), 0.0, SH_PUFF + FLAT, rng.randf() * 1000.0, p.normal())
		elif p.kind == P.RING and p.gas >= 0.3:
			for i in int(60.0 * detail * p.gas):
				var th := rng.randf() * TAU
				var r := (p.r_out - p.width * 0.8) * R
				var pos := p.center + Basis(Vector3.UP, p.phase) * Vector3(cos(th) * r, 0.0, sin(th) * r * p.flatten)
				g.dust.add(p.xform * _post(pos), Color(DUST_TINT, rng.randf_range(0.15, 0.4)), _s(p) * p.width * R * rng.randf_range(0.8, 1.8), 0.0, SH_PUFF + FLAT, rng.randf() * 1000.0, p.normal())
		elif p.kind == P.BAR:
			for i in int(40.0 * detail):
				var side := 1.0 if i % 2 == 0 else -1.0
				var t := rng.randf_range(-1.0, 1.0)
				var lx := t * p.r_out * R
				var lz := side * p.width * R * 0.8 + lx * 0.15 * side
				var c := cos(p.phase)
				var s := sin(p.phase)
				var pos := Vector3(lx * c - lz * s, 0.0, lx * s + lz * c)
				g.dust.add(p.xform * _post(pos), Color(DUST_TINT, rng.randf_range(0.25, 0.5)), _s(p) * p.width * R * rng.randf_range(0.3, 0.6), 0.0, SH_PUFF + FLAT, rng.randf() * 1000.0, p.normal())
		elif p.kind == P.DISK and p.gas > 0.1:
			for i in int(260.0 * detail * p.gas * 4.0):
				var pos := _place(p, rng, true)
				if (p.xform.affine_inverse() * pos).length() > R * 0.85:
					continue
				g.dust.add(pos, Color(DUST_TINT, rng.randf_range(0.08, 0.22)), R * _s(p) * rng.randf_range(0.008, 0.028), 0.0, SH_PUFF + FLAT, rng.randf() * 1000.0, p.normal())


## Supernovae: time-driven flares evaluated entirely in the shader.
## Custom data: x = period (s), y = peak size (px), w = phase offset.
func _gen_novae(g: GalaxyData, pats: Array[Pattern], rng: RandomNumberGenerator) -> void:
	var gas_cdf := _cdf(pats, true)
	var mass_cdf := _cdf(pats, false)
	var has_gas := gas_cdf.size() > 0 and gas_cdf[gas_cdf.size() - 1] > 0.0
	for i in rng.randi_range(10, 18):
		var core_collapse := has_gas and rng.randf() < 0.75
		var p := _pick(pats, gas_cdf if core_collapse else mass_cdf, rng)
		var col := Color(0.8, 0.88, 1.0) if core_collapse else Color(1.0, 0.95, 0.8)
		g.novae.add(_place(p, rng, false), Color(col, rng.randf_range(1.4, 2.4)), rng.randf_range(35.0, 140.0), rng.randf_range(16.0, 30.0), SH_NOVA, rng.randf())


## Neighbouring galaxies: the nearest are real (Neighbor), the rest analytic
## impostors in the shader, grouped
## into a few groups, plus a faint deep field of distant ones.
## Custom data: x = radius (ly), y = min px, z = type + 0.1 + 0.8 * cos(incl), w = seed.
func _gen_far(g: GalaxyData, rng: RandomNumberGenerator, detail: float) -> void:
	var groups: Array[Vector3] = []
	for i in rng.randi_range(4, 7):
		groups.append(_rand_dir(rng))
	# The nearest few are real galaxies, generated in the background (see
	# generate_environment); everything farther is an analytic impostor.
	for i in rng.randi_range(5, 9):
		var nb := Neighbor.new()
		var ndir := (groups[rng.randi() % groups.size()] + _rand_dir(rng) * rng.randf_range(0.1, 0.6)).normalized()
		nb.pos = ndir * 6.0e5 * pow(4.0, rng.randf())
		nb.seed = Seeds.mix(g.seed, 5000 + i)
		g.neighbors.append(nb)
	for i in rng.randi_range(40, 70):
		var dir := _rand_dir(rng)
		if rng.randf() < 0.6:
			dir = (groups[rng.randi() % groups.size()] + _rand_dir(rng) * rng.randf_range(0.05, 0.4)).normalized()
		var zf := rng.randf()
		var dist := 2.5e6 * pow(5.0, zf)
		var roll := rng.randf()
		var typ := 0 if roll < 0.55 else (1 if roll < 0.9 else 2)
		var size := rng.randf_range(1.2e4, 6.5e4) * (1.8 if typ == 1 and rng.randf() < 0.3 else 1.0)
		var col := Color(0.72, 0.8, 1.0)
		if typ == 1:
			col = Color(1.0, 0.8, 0.58)
		elif typ == 2:
			col = Color(0.65, 0.78, 1.0)
		col = col.lerp(Color(1.0, 0.62, 0.48), zf * 0.3)
		var cos_i := rng.randf_range(0.1, 1.0)
		g.far.add(dir * dist, Color(col, rng.randf_range(0.3, 0.7) * (1.0 - 0.45 * zf)), size, 1.6, float(typ) + 0.1 + 0.8 * cos_i, rng.randf() * 1000.0)
	for i in int(rng.randf_range(700.0, 1300.0) * detail):
		var dir := _rand_dir(rng)
		if rng.randf() < 0.35:
			dir = (groups[rng.randi() % groups.size()] + _rand_dir(rng) * 0.6).normalized()
		var dist := 1.2e7 * pow(5.0, rng.randf())
		var typ := 0 if rng.randf() < 0.6 else 1
		var col := Color(0.8, 0.82, 1.0).lerp(Color(1.0, 0.65, 0.5), rng.randf())
		g.far.add(dir * dist, Color(col, rng.randf_range(0.1, 0.3)), rng.randf_range(1.0e4, 4.0e4), rng.randf_range(1.0, 1.8), float(typ) + 0.1 + 0.8 * rng.randf_range(0.2, 1.0), rng.randf() * 1000.0)


## Linear scale of a pattern's frame (the partner of a merger is smaller).
static func _s(p: Pattern) -> float:
	return p.xform.basis.x.length()


# --- environment (worker thread) ---------------------------------------------

## Real neighbour galaxies + giant nebulae. Runs in a worker thread after the
## main galaxy is up; everything derives from the galaxy seed, only the
## budgets (star count, sprite density) follow the quality preset.
static func generate_environment(g_seed: int, neighbors: Array[Neighbor], detail: float) -> EnvData:
	var env := EnvData.new()
	env.seed = g_seed
	var budget := int(lerpf(1200.0, 3500.0, clampf(detail, 0.0, 1.0)))
	for nb in neighbors:
		var mg := GalaxyGenerator.new()._build(nb.seed, budget, 0.22 * detail, false)
		var xf := Transform3D(Basis.IDENTITY, nb.pos)
		for i in mg.positions.size():
			var c := mg.colors[i]
			env.stars.add(xf * mg.positions[i], Color(c.r, c.g, c.b, c.a * 0.8), 0.0, minf(mg.px_sizes[i], 2.0), 0.0, 0.0)
		mg.nebula.transform(xf)
		mg.dust.transform(xf)
		env.nebula.append_from(mg.nebula)
		env.dust.append_from(mg.dust)
		env.star_total += mg.positions.size()
	env.neighbor_count = neighbors.size()
	_gen_mega_nebulae(env, Seeds.rng(Seeds.mix(g_seed, 10)), detail)
	return env


## Giant nebula complexes far outside the galaxy: sheets of noisy gas grown by
## a random walk, a wide faint halo, dark knots and a sprinkle of young stars.
static func _gen_mega_nebulae(env: EnvData, rng: RandomNumberGenerator, detail: float) -> void:
	for m in rng.randi_range(2, 5):
		var c := _rand_dir(rng) * rng.randf_range(3.5e5, 1.2e6)
		var size := rng.randf_range(3.0e4, 1.1e5)
		var b := _random_basis(rng, PI)
		var nrm := b.y
		var pal: Array = PALETTES[rng.randi() % PALETTES.size()]
		env.nebula.add(c, Color(pal[0] as Color, 0.035), size * 1.3, 0.0, SH_GLOW + 0.5 * FLAT, rng.randf() * 1000.0, nrm)
		var p := c
		for k in int(rng.randf_range(70.0, 160.0) * detail) + 12:
			p += b * Vector3(rng.randfn(), rng.randfn() * 0.2, rng.randfn()) * size * 0.12
			if p.distance_to(c) > size:
				p = c + (p - c) * 0.4
			var t := rng.randf()
			var col: Color = (pal[0] as Color).lerp(pal[1], t * t)
			env.nebula.add(p, Color(col, rng.randf_range(0.03, 0.07)), size * rng.randf_range(0.12, 0.35), 0.0, SH_PUFF + 0.6 * FLAT, rng.randf() * 1000.0, nrm)
			if rng.randf() < 0.3:
				var dp := p + b * Vector3(rng.randfn(), 0.0, rng.randfn()) * size * 0.1
				env.dust.add(dp, Color(DUST_TINT, rng.randf_range(0.15, 0.35)), size * rng.randf_range(0.08, 0.2), 0.0, SH_PUFF + 0.6 * FLAT, rng.randf() * 1000.0, nrm)
		for k in int(40.0 * detail) + 10:
			var sp := c + b * Vector3(rng.randfn(), rng.randfn() * 0.2, rng.randfn()) * size * 0.4
			var sc := temp_color(rng.randf_range(9000.0, 30000.0))
			env.stars.add(sp, Color(sc.r, sc.g, sc.b, rng.randf_range(0.4, 1.0)), 0.0, rng.randf_range(1.3, 2.6), 0.0, 0.0)
