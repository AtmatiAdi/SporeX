class_name GalaxyLayer
extends Node3D
## Renders the galaxy and its surroundings. Every sprite set is one MultiMesh
## (one draw call) with a GPU billboard shader; after generation the CPU only
## updates a handful of uniforms per frame (anchor, scale, offset, fade).
## Positions are in light years, anchored on the selected star so that the
## precision loss of float32 only affects distant objects (where it is invisible).
##
## Each instance's basis carries the disk normal of the galaxy it belongs to
## (column 1), used by the shaders to flatten glow and dust sprites - so a
## tilted galaxy, the partner of a collision and every neighbour galaxy all
## flatten along their own plane.
##
## The surroundings (real neighbour galaxies + giant nebulae) are generated in
## a worker thread after the main galaxy is up and fade in when ready.
##
## Draw order (render_priority, all transparent):
##   Far (-3) -> Stars (0) -> Nebula / Novae (1) -> Dust (2, multiplicative) -> Core (3) -> Markers (4)

const BILLBOARD := preload("res://shaders/billboard_point.gdshader")
const NEBULA := preload("res://shaders/nebula.gdshader")
const DUST := preload("res://shaders/dust_lane.gdshader")
const FAR := preload("res://shaders/far_galaxy.gdshader")
const QUASAR := preload("res://shaders/quasar.gdshader")
const BIG_AABB := AABB(Vector3(-1.0e7, -1.0e7, -1.0e7), Vector3(2.0e7, 2.0e7, 2.0e7))

var galaxy: GalaxyGenerator.GalaxyData
var stars: MultiMeshInstance3D
var nebula: MultiMeshInstance3D
var dust: MultiMeshInstance3D
var novae: MultiMeshInstance3D
var far: MultiMeshInstance3D
var markers: MultiMeshInstance3D
var peer_markers: MultiMeshInstance3D   # other players (LAN), rings at their camera position
const MAX_PEERS := 16
var core: Node3D
var env_nodes: Array[MultiMeshInstance3D] = []
var env_info := ""
var materials: Array[ShaderMaterial] = []
var _dim_floor := {}   # material -> brightness kept inside a star system
var _env_mats := {}    # materials of the surroundings (fade in when ready)
var _env_fade := 0.0
var _env_thread: Thread
var _quad := QuadMesh.new()
var star_mult := 1   # benchmark: every star drawn as this many (GPU amplification)


func build(g: GalaxyGenerator.GalaxyData, detail: float = 1.0) -> void:
	_join_env_thread()
	galaxy = g
	for c in get_children():
		remove_child(c)
		c.queue_free()
	materials.clear()
	_dim_floor.clear()
	_env_mats.clear()
	env_nodes.clear()
	env_info = ""
	_env_fade = 0.0
	_quad.size = Vector2.ONE

	var n := g.star_count
	var star_custom := PackedFloat32Array()
	star_custom.resize(n * 4)
	for i in n:
		var px := g.px_sizes[i]
		if px > 3.0:
			# Brightest stars get diffraction spikes on a larger quad.
			star_custom[i * 4 + 1] = px * 2.6
			star_custom[i * 4 + 2] = 3.0
		else:
			star_custom[i * 4 + 1] = px
	var star_mat := _billboard_mat()
	stars = _add_mm("Stars", pack(g.positions, g.colors, star_custom), g.star_count, star_mat, 0,
			quad_batch(star_mult) if star_mult > 1 else null)
	if star_mult > 1:
		star_mat.set_shader_parameter("sub_spread", g.radius_ly * 0.012)
		star_mat.set_shader_parameter("sub_normal", g.orient.y)

	far = _add_sprites("Far", g.far, _sprite_mat(FAR, 0.9), -3)
	nebula = _add_sprites("Nebula", g.nebula, _sprite_mat(NEBULA, 0.8), 1)
	var nova_mat := _sprite_mat(NEBULA, 0.8)
	nova_mat.set_shader_parameter("transients", true)
	novae = _add_sprites("Novae", g.novae, nova_mat, 1)
	var dust_mat := _sprite_mat(DUST, 0.8)
	dust_mat.set_shader_parameter("near_fade_all", true)
	dust = _add_sprites("Dust", g.dust, dust_mat, 2)

	var hn := g.habitable.size()
	var mpos := PackedVector3Array()
	var mcol := PackedColorArray()
	var mcustom := PackedFloat32Array()
	mpos.resize(hn)
	mcol.resize(hn)
	mcustom.resize(hn * 4)
	for i in hn:
		mpos[i] = g.positions[g.habitable[i]]
		mcol[i] = Color(0.6, 1.0, 0.7, 0.9)
		mcustom[i * 4 + 1] = 13.0
		mcustom[i * 4 + 2] = 1.0
	markers = _add_mm("Markers", pack(mpos, mcol, mcustom), hn, _billboard_mat(), 4)
	var ppos := PackedVector3Array()
	var pcol := PackedColorArray()
	var pcst := PackedFloat32Array()
	ppos.resize(MAX_PEERS)
	pcol.resize(MAX_PEERS)
	pcst.resize(MAX_PEERS * 4)
	peer_markers = _add_mm("Peers", pack(ppos, pcol, pcst), MAX_PEERS, _billboard_mat(), 5)
	peer_markers.multimesh.visible_instance_count = 0
	_dim_floor[nebula.material_override] = 0.45
	_dim_floor[novae.material_override] = 0.6
	_dim_floor[dust.material_override] = 0.35

	_build_core(g)

	_env_thread = Thread.new()
	_env_thread.start(_env_job.bind(g.seed, g.neighbors, detail))


# --- buffers -------------------------------------------------------------------

## MultiMesh buffer (20 floats per instance). Static and allocation-only, so it
## can run on the worker thread. The basis is identity with Y = disk normal.
static func pack(pos: PackedVector3Array, col: PackedColorArray, custom: PackedFloat32Array,
		nrm: PackedVector3Array = PackedVector3Array()) -> PackedFloat32Array:
	var n := pos.size()
	var has_n := nrm.size() == n
	var buf := PackedFloat32Array()
	buf.resize(n * 20)
	for i in n:
		var o := i * 20
		var p := pos[i]
		var c := col[i]
		var y := Vector3.UP
		if has_n:
			y = nrm[i]
		var x := Vector3.RIGHT
		if y != Vector3.UP:
			x = y.cross(Vector3.FORWARD if absf(y.z) < 0.9 else Vector3.RIGHT).normalized()
		var z := x.cross(y)
		buf[o] = x.x
		buf[o + 1] = y.x
		buf[o + 2] = z.x
		buf[o + 3] = p.x
		buf[o + 4] = x.y
		buf[o + 5] = y.y
		buf[o + 6] = z.y
		buf[o + 7] = p.y
		buf[o + 8] = x.z
		buf[o + 9] = y.z
		buf[o + 10] = z.z
		buf[o + 11] = p.z
		buf[o + 12] = c.r
		buf[o + 13] = c.g
		buf[o + 14] = c.b
		buf[o + 15] = c.a
		buf[o + 16] = custom[i * 4]
		buf[o + 17] = custom[i * 4 + 1]
		buf[o + 18] = custom[i * 4 + 2]
		buf[o + 19] = custom[i * 4 + 3]
	return buf


func _add_sprites(node_name: String, s: GalaxyGenerator.Sprites, mat: ShaderMaterial, priority: int) -> MultiMeshInstance3D:
	return _add_mm(node_name, pack(s.pos, s.col, s.cst, s.nrm), s.size(), mat, priority)


func _add_mm(node_name: String, buf: PackedFloat32Array, n: int, mat: ShaderMaterial, priority: int,
		mesh: Mesh = null) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh if mesh else _quad
	mm.instance_count = n
	if n > 0:
		mm.buffer = buf
	mat.render_priority = priority
	materials.append(mat)
	var mi := MultiMeshInstance3D.new()
	mi.name = node_name
	mi.multimesh = mm
	mi.material_override = mat
	mi.custom_aabb = BIG_AABB
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _billboard_mat() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = BILLBOARD
	mat.set_shader_parameter("manual_transform", true)
	return mat


func _sprite_mat(shader: Shader, max_screen: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("max_screen", max_screen)
	mat.set_shader_parameter("flatten_enabled", shader != FAR)
	return mat


# --- surroundings (worker thread) ---------------------------------------------

func _env_job(g_seed: int, neighbors: Array[GalaxyGenerator.Neighbor], detail: float) -> void:
	var t0 := Time.get_ticks_msec()
	var env := GalaxyGenerator.generate_environment(g_seed, neighbors, detail)
	var stars_cst := env.stars.cst
	var bufs := [
		pack(env.stars.pos, env.stars.col, stars_cst),
		pack(env.nebula.pos, env.nebula.col, env.nebula.cst, env.nebula.nrm),
		pack(env.dust.pos, env.dust.col, env.dust.cst, env.dust.nrm),
	]
	var counts := [env.stars.size(), env.nebula.size(), env.dust.size()]
	var info := "%d sąsiadów, %d gwiazd, %d mgławic" % [env.neighbor_count, env.star_total, env.nebula.size()]
	print("environment %d: %s, %d ms (worker)" % [g_seed, info, Time.get_ticks_msec() - t0])
	_env_ready.call_deferred(g_seed, bufs, counts, info)


func _env_ready(g_seed: int, bufs: Array, counts: Array, info: String) -> void:
	_join_env_thread()
	if galaxy == null or g_seed != galaxy.seed:
		return   # a newer galaxy replaced this one meanwhile
	env_info = info
	var s := _add_mm("EnvStars", bufs[0], counts[0], _billboard_mat(), 0)
	var nb := _add_mm("EnvNebula", bufs[1], counts[1], _sprite_mat(NEBULA, 0.8), 1)
	var dust_mat := _sprite_mat(DUST, 0.8)
	dust_mat.set_shader_parameter("near_fade_all", true)
	var du := _add_mm("EnvDust", bufs[2], counts[2], dust_mat, 2)
	env_nodes = [s, nb, du]
	_dim_floor[nb.material_override] = 0.45
	_dim_floor[du.material_override] = 0.35
	for n in env_nodes:
		_env_mats[n.material_override] = true


func _join_env_thread() -> void:
	if _env_thread and _env_thread.is_started():
		_env_thread.wait_to_finish()
	_env_thread = null


func _process(dt: float) -> void:
	if not env_nodes.is_empty() and _env_fade < 1.0:
		_env_fade = minf(_env_fade + dt * 0.7, 1.0)


func _exit_tree() -> void:
	_join_env_thread()


## Supermassive black hole: accretion disk + (for active nuclei) two jets.
func _build_core(g: GalaxyGenerator.GalaxyData) -> void:
	core = Node3D.new()
	core.name = "Core"
	add_child(core)
	var parts := [0, 1] if g.quasar > 0.3 else [0]
	for part in parts:
		var mat := ShaderMaterial.new()
		mat.shader = QUASAR
		mat.render_priority = 3
		mat.set_shader_parameter("part", part)
		mat.set_shader_parameter("axis", g.core_tilt.y)
		mat.set_shader_parameter("disk_x", g.core_tilt.x)
		mat.set_shader_parameter("disk_z", g.core_tilt.z)
		mat.set_shader_parameter("radius_ly", g.core_radius)
		mat.set_shader_parameter("jet_len_ly", g.jet_len)
		mat.set_shader_parameter("strength", g.quasar)
		mat.set_shader_parameter("color", g.core_color)
		materials.append(mat)
		_dim_floor[mat] = 0.5
		var mi := MeshInstance3D.new()
		mi.name = "Disk" if part == 0 else "Jets"
		mi.mesh = _quad
		mi.material_override = mat
		mi.custom_aabb = BIG_AABB
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		core.add_child(mi)


## Scene-space position of a star, for picking (double precision until the end).
func star_scene_pos(index: int, universe: Universe, vs: ScaleCamera.ViewState) -> Vector3:
	var p := galaxy.positions[index]
	var a := galaxy.positions[universe.selected_star]
	var rel := DVec3.new((p.x - a.x) * Universe.LY, (p.y - a.y) * Universe.LY, (p.z - a.z) * Universe.LY)
	var anchor_scene := universe.pos_in(Universe.Frame.S, vs.frame).sub(vs.focus)
	return rel.add(anchor_scene).mul(1.0 / vs.u).to_v3()


func update_view(vs: ScaleCamera.ViewState, universe: Universe, star_fade: float) -> void:
	var anchor := galaxy.positions[universe.selected_star]
	var offset := universe.pos_in(Universe.Frame.S, vs.frame).sub(vs.focus).mul(1.0 / vs.u).to_v3()
	var unit_scale := Universe.LY / vs.u
	# Entering a star system: gas, dust and the core dim smoothly to a floor
	# instead of switching off, so the galaxy stays in the sky at every scale.
	var sys := ScaleCamera.blend(vs.d, 3.0e17, 3.0e14)
	var ui := 1.0 - ScaleCamera.blend(vs.d, 4.0e16, 1.0e16)
	for m in materials:
		var dim := lerpf(1.0, _dim_floor.get(m, 1.0), sys)
		if m == markers.material_override:
			dim = ui
		elif _env_mats.has(m):
			dim *= _env_fade
		m.set_shader_parameter("anchor", anchor)
		m.set_shader_parameter("unit_scale", unit_scale)
		m.set_shader_parameter("offset", offset)
		m.set_shader_parameter("fade", star_fade * dim)
	# Nothing is hidden by scale any more; skip draw calls only when fully faded.
	var on := star_fade > 0.001
	for n in [stars, far, nebula, novae, dust, core]:
		n.visible = on
	for n in env_nodes:
		n.visible = on
	markers.visible = ui > 0.001


## A mesh of n unit quads (UV2.x = quad index) for GPU-side star generation:
## the vertex shader turns quad i of an instance into star i.
static func quad_batch(n: int) -> ArrayMesh:
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var idx := PackedInt32Array()
	v.resize(n * 4)
	uv.resize(n * 4)
	uv2.resize(n * 4)
	idx.resize(n * 6)
	var corners := [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)]
	for q in n:
		for k in 4:
			var c: Vector2 = corners[k]
			v[q * 4 + k] = Vector3(c.x, c.y, 0.0)
			uv[q * 4 + k] = Vector2(c.x + 0.5, 0.5 - c.y)
			uv2[q * 4 + k] = Vector2(float(q), 0.0)
		var b := q * 4
		var o := q * 6
		idx[o] = b
		idx[o + 1] = b + 1
		idx[o + 2] = b + 2
		idx[o + 3] = b
		idx[o + 4] = b + 2
		idx[o + 5] = b + 3
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	m.custom_aabb = AABB(Vector3(-1.0e7, -1.0e7, -1.0e7), Vector3(2.0e7, 2.0e7, 2.0e7))
	return m


## Other players: [{pos (ly, galaxy frame), color}] - a ring where their camera is.
func set_peers(list: Array) -> void:
	if peer_markers == null:
		return
	var mm := peer_markers.multimesh
	var n := mini(list.size(), MAX_PEERS)
	for i in n:
		var e: Dictionary = list[i]
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, e["pos"]))
		mm.set_instance_color(i, e["color"])
		mm.set_instance_custom_data(i, Color(0.0, 22.0, 1.0, 0.0))
	mm.visible_instance_count = n
