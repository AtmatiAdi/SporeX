class_name LocalStars
extends Node3D
## Real-density star field around the camera ("virtual galaxy").
##
## The 60k stars of the galaxy layer are representatives: each stands for
## millions of real stars. Their distribution is binned into a coarse density
## grid, scaled to a realistic total (~10^11 stars), and space is cut into
## CELL-sized cubes. Every cube has a deterministic star count and seed; the
## block of cubes around the camera is drawn by the GPU (local_stars.gdshader)
## from nothing but (origin, first index, count, seed, age) per 256-star batch.
## The CPU touches the instance buffer only when the camera crosses a cell.
##
## Every one of those stars has a stable identity (cell + index) and can be
## clicked: it becomes a star system of its own, with the same seed on every
## machine.

const SHADER := preload("res://shaders/local_stars.gdshader")
const BATCH := 256
const CELL := 40.0                            # ly
const REAL_PER_R2 := 1.5e11 / (50000.0 * 50000.0)   # a 50k-ly galaxy has ~1.5e11 stars
const M32 := 0xffffffff
const DWARF_CELLS := 1                     # dwarfs only in the 3x3x3 cells around the camera
const PICK_MIN := 0.055                    # = shader cull threshold: everything drawn is clickable

var galaxy: GalaxyGenerator.GalaxyData
var real_total := 0.0     # stars the galaxy "really" has
var generated := 0        # stars that exist in the block around the camera
var drawn := 0            # stars sent to the GPU (bright everywhere, dwarfs only nearby)
var rebuild_ms := 0.0
var fade := 0.0
var _grid := {}           # Vector3i -> Vector2(count, age sum) of representative stars
var _coarse := 1000.0
var _w := 1.0             # real stars per representative star
var _half := 4
var _cap := 4096
var _cell := Vector3i(1 << 30, 0, 0)
var _anchor_idx := -1
var _mi: MultiMeshInstance3D
var _mat: ShaderMaterial
var _mesh: ArrayMesh


func setup(g: GalaxyGenerator.GalaxyData, quality: int) -> void:
	galaxy = g
	_grid.clear()
	_coarse = g.radius_ly / 40.0
	for i in g.star_count:
		var key := Vector3i((g.positions[i] / _coarse).floor())
		var v: Vector2 = _grid.get(key, Vector2.ZERO)
		_grid[key] = v + Vector2(1.0, g.ages[i])
	real_total = REAL_PER_R2 * g.radius_ly * g.radius_ly * (1.4 if g.merger else 1.0)
	_w = real_total / float(g.star_count)
	_half = [4, 5, 6][clampi(quality, 0, 2)]
	_cap = 8192
	if _mesh == null:
		_mesh = GalaxyLayer.quad_batch(BATCH)
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
		_mi = MultiMeshInstance3D.new()
		_mi.name = "LocalStars"
		_mi.material_override = _mat
		_mi.custom_aabb = GalaxyLayer.BIG_AABB
		_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mi)
	_mat.set_shader_parameter("cell_size", CELL)
	_mat.set_shader_parameter("radius", CELL * (float(_half) + 0.5))
	_cell = Vector3i(1 << 30, 0, 0)
	_anchor_idx = -1


# --- deterministic hash (must match local_stars.gdshader) --------------------

static func _mul32(a: int, b: int) -> int:
	return (a * (b & 0xffff) + (((a * (b >> 16)) & 0xffff) << 16)) & M32


static func h32(x: int) -> int:
	x &= M32
	x ^= x >> 16
	x = _mul32(x, 0x7feb352d)
	x ^= x >> 15
	x = _mul32(x, 0x846ca68b)
	x ^= x >> 16
	return x


static func u01(h: int) -> float:
	return float(h >> 8) / 16777216.0


func cell_seed(key: Vector3i) -> int:
	var s := h32(key.x & M32)
	s = h32(s ^ (key.y & M32))
	s = h32(s ^ (key.z & M32))
	s = h32(s ^ (galaxy.seed & M32))
	return s & 0xffffff


## Stars per ly^3 and mean age (Gyr) at a point, trilinear over the coarse grid.
func density(p: Vector3) -> Vector2:
	var q := p / _coarse - Vector3(0.5, 0.5, 0.5)
	var b := Vector3i(q.floor())
	var f := q - Vector3(b)
	var cnt := 0.0
	var age := 0.0
	for dx in 2:
		for dy in 2:
			for dz in 2:
				var wgt := (f.x if dx == 1 else 1.0 - f.x) * (f.y if dy == 1 else 1.0 - f.y) * (f.z if dz == 1 else 1.0 - f.z)
				var v: Vector2 = _grid.get(b + Vector3i(dx, dy, dz), Vector2.ZERO)
				cnt += v.x * wgt
				age += v.y * wgt
	var mean_age := age / cnt if cnt > 1.0e-6 else 6.0
	return Vector2(cnt * _w / (_coarse * _coarse * _coarse), mean_age)


## Deterministic star count of a cell (Poisson-free rounding by the cell hash).
func cell_count(key: Vector3i, seed: int, dens: float) -> int:
	var nf := dens * CELL * CELL * CELL
	var n := int(nf)
	if u01(h32(seed ^ 0x5bd1e995)) < nf - float(n):
		n += 1
	return mini(n, _cap)


## Population split of a cell with a given age: u1 = IMF quantile of 1 solar
## mass (below it: dwarfs), fb = fraction of "bright" stars (m > 1 + giants).
## Bright stars are indices [0, nb), dwarfs [nb, n). Far cells only draw the
## bright ones - dwarfs are invisible beyond a few dozen ly anyway.
static func split(cell_age: float) -> Vector2:
	var m_to := clampf(pow(10.0 / maxf(cell_age, 0.012), 0.4), 0.3, 55.0)
	var b := pow(maxf(m_to, 0.2), -1.35)
	var u1 := clampf((11.873 - 1.0) / (11.873 - b), 0.0, 1.0)
	return Vector2(u1, clampf(1.0 - u1 + 0.015, 0.015, 1.0))


## One star, exactly as the shader builds it. Returns p (ly, from the cell
## origin), temp, lum, age.
static func star(seed: int, i: int, cell_age: float, dwarf: bool) -> Dictionary:
	var h0 := h32(seed ^ h32(i + 1))
	var p := Vector3(u01(h32(h0 + 1)), u01(h32(h0 + 2)), u01(h32(h0 + 3))) * CELL
	var sp := split(cell_age)
	var u1 := sp.x
	var fb := sp.y
	var m_to := clampf(pow(10.0 / maxf(cell_age, 0.012), 0.4), 0.3, 55.0)
	var b := pow(maxf(m_to, 0.2), -1.35)
	var age := cell_age * exp((u01(h32(h0 + 4)) - 0.5) * 1.6)
	var roll := u01(h32(h0 + 5))
	var um := u01(h32(h0 + 6))
	var temp: float
	var lum: float
	if not dwarf and roll < 0.015 / fb:
		temp = lerpf(3100.0, 4900.0, um)
		lum = lerpf(60.0, 1500.0, u01(h32(h0 + 7)))
	elif dwarf and roll < 0.015 / maxf(1.0 - fb, 0.015) and cell_age > 1.0:
		temp = lerpf(7000.0, 25000.0, um)
		lum = 0.003
	else:
		var uu := um * u1 if dwarf else u1 + um * (1.0 - u1)
		var m := pow(11.873 + uu * (b - 11.873), -0.7407407)
		temp = clampf(5780.0 * pow(m, 0.54), 2500.0, 44000.0)
		lum = pow(m, 3.3)
	return {"p": p, "temp": temp, "lum": lum, "age": age}


static func brightness(lum: float, dist: float) -> float:
	return 0.3 * pow(lum / maxf(dist * dist, 1.0e-6) / 0.01, 0.3)


# --- per frame ----------------------------------------------------------------

## cam_rel: camera position relative to the anchor star, ly (from doubles).
func update_view(cam_rel: Vector3, anchor_idx: int, unit_scale: float, offset: Vector3, star_fade: float, d: float) -> void:
	if galaxy == null:
		return
	# Resolved local stars only matter from inside the galaxy: full below
	# ~3e19 m (3000 ly), gone above 1e20 m.
	fade = star_fade * (1.0 - smoothstep(19.5, 20.0, log(d) / log(10.0)))
	var anchor_world := galaxy.positions[anchor_idx]
	var c := Vector3i(((anchor_world + cam_rel) / CELL).floor())
	if c != _cell or anchor_idx != _anchor_idx:
		var t0 := Time.get_ticks_usec()
		_rebuild(c, anchor_world)
		rebuild_ms = (Time.get_ticks_usec() - t0) / 1000.0
		_cell = c
		_anchor_idx = anchor_idx
	_mat.set_shader_parameter("unit_scale", unit_scale)
	_mat.set_shader_parameter("offset", offset)
	_mat.set_shader_parameter("cam_rel", cam_rel)
	_mat.set_shader_parameter("fade", fade)
	_mi.visible = fade > 0.001 and drawn > 0


func _emit(buf: PackedFloat32Array, rel: Vector3, from: int, to: int, seed: int, w: float) -> int:
	var inst := 0
	var start := from
	while start < to:
		var cnt := mini(BATCH, to - start)
		buf.append_array(PackedFloat32Array([1.0, 0.0, 0.0, rel.x, 0.0, 1.0, 0.0, rel.y, 0.0, 0.0, 1.0, rel.z,
			float(start), float(cnt), float(seed), w]))
		start += BATCH
		inst += 1
	return inst


func _rebuild(c: Vector3i, anchor_world: Vector3) -> void:
	var buf := PackedFloat32Array()
	var total := 0
	var inst := 0
	var draw := 0
	for x in range(-_half, _half + 1):
		for y in range(-_half, _half + 1):
			for z in range(-_half, _half + 1):
				var key := c + Vector3i(x, y, z)
				var origin := Vector3(key) * CELL
				var dens := density(origin + Vector3.ONE * (CELL * 0.5))
				var seed := cell_seed(key)
				var n := cell_count(key, seed, dens.x)
				total += n
				if n == 0:
					continue
				var nb := mini(int(ceil(n * split(dens.y).y)), n)
				var rel := origin - anchor_world
				inst += _emit(buf, rel, 0, nb, seed, dens.y)
				draw += nb
				if maxi(absi(x), maxi(absi(y), absi(z))) <= DWARF_CELLS:
					inst += _emit(buf, rel, nb, n, seed, dens.y + 100.0)
					draw += n - nb
	generated = total
	drawn = draw
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _mesh
	mm.instance_count = inst
	if inst > 0:
		mm.buffer = buf
	_mi.multimesh = mm


## Stars bright enough to be seen close to a view ray, for picking.
## Returns [{rel (ly from anchor), temp, lum, age, sys_seed}]. Cheap: cells
## away from the ray are skipped, and a star's full physics is evaluated only
## if its position (3 hashes) falls inside the pick cone.
func pickable(cam_rel: Vector3, anchor_idx: int, ray: Vector3, cone := 0.03) -> Array:
	var out := []
	if galaxy == null or fade < 0.05:
		return out
	var anchor_world := galaxy.positions[anchor_idx]
	var c := Vector3i(((anchor_world + cam_rel) / CELL).floor())
	var cos_cone := cos(cone)
	var cell_r := CELL * 0.8660254
	for x in range(-_half, _half + 1):
		for y in range(-_half, _half + 1):
			for z in range(-_half, _half + 1):
				var key := c + Vector3i(x, y, z)
				var origin := Vector3(key) * CELL
				var to_cell := origin - anchor_world + Vector3.ONE * (CELL * 0.5) - cam_rel
				var along := to_cell.dot(ray)
				if along < -cell_r:
					continue
				if (to_cell - ray * along).length() > cell_r + maxf(along, 0.0) * tan(cone):
					continue
				var dens := density(origin + Vector3.ONE * (CELL * 0.5))
				var seed := cell_seed(key)
				var n := cell_count(key, seed, dens.x)
				var nb := mini(int(ceil(n * split(dens.y).y)), n)
				var last := n if maxi(absi(x), maxi(absi(y), absi(z))) <= DWARF_CELLS else nb
				for i in last:
					var rel := origin - anchor_world + star_pos(seed, i)
					var v := rel - cam_rel
					var dist := v.length()
					if dist < 0.02 or v.dot(ray) < dist * cos_cone:
						continue
					var s := star(seed, i, dens.y, i >= nb)
					if brightness(s["lum"], dist) < PICK_MIN:
						continue
					s["rel"] = rel
					s["sys_seed"] = Seeds.mix(Seeds.mix(galaxy.seed, seed), i)
					out.append(s)
	return out


static func star_pos(seed: int, i: int) -> Vector3:
	var h0 := h32(seed ^ h32(i + 1))
	return Vector3(u01(h32(h0 + 1)), u01(h32(h0 + 2)), u01(h32(h0 + 3))) * CELL
