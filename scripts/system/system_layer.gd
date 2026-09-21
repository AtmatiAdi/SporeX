class_name SystemLayer
extends Node3D
## Star system view: the sun (GPU glow billboard), orbit rings, low-poly planet
## spheres and pickable ring markers. Authored in meters, anchored at the star.

const BILLBOARD := preload("res://shaders/billboard_point.gdshader")
const ORBIT_SEGMENTS := 160

var universe: Universe
var sun: MultiMeshInstance3D
var sun_mat: ShaderMaterial
var markers: MultiMeshInstance3D
var marker_mat: ShaderMaterial
var orbits: Array[MeshInstance3D] = []
var spheres: Array[MeshInstance3D] = []
var _quad := QuadMesh.new()
var _sphere := SphereMesh.new()


func _ready() -> void:
	_quad.size = Vector2.ONE
	_sphere.radius = 1.0
	_sphere.height = 2.0
	_sphere.radial_segments = 24
	_sphere.rings = 12


func build(u: Universe) -> void:
	universe = u
	for c in get_children():
		c.queue_free()
	orbits.clear()
	spheres.clear()
	var s := u.system

	# Sun
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _quad
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D.IDENTITY)
	var sc := s.star_color
	mm.set_instance_color(0, Color(sc.r, sc.g, sc.b, 1.6))
	mm.set_instance_custom_data(0, Color(s.star_radius_m * 1.6, 9.0, 2.0, 0.0))
	sun_mat = ShaderMaterial.new()
	sun_mat.shader = BILLBOARD
	sun = MultiMeshInstance3D.new()
	sun.multimesh = mm
	sun.material_override = sun_mat
	sun.custom_aabb = AABB(Vector3(-1.0e13, -1.0e13, -1.0e13), Vector3(2.0e13, 2.0e13, 2.0e13))
	sun.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sun)

	# Planet markers (rings) — transforms updated every frame with the orbits.
	var mmk := MultiMesh.new()
	mmk.transform_format = MultiMesh.TRANSFORM_3D
	mmk.use_colors = true
	mmk.use_custom_data = true
	mmk.mesh = _quad
	mmk.instance_count = s.planets.size()
	for i in s.planets.size():
		var p := s.planets[i]
		mmk.set_instance_custom_data(i, Color(0.0, 12.0, 1.0, 0.0))
		mmk.set_instance_color(i, Color(p.color.r, p.color.g, p.color.b, 0.8))
	marker_mat = ShaderMaterial.new()
	marker_mat.shader = BILLBOARD
	markers = MultiMeshInstance3D.new()
	markers.multimesh = mmk
	markers.material_override = marker_mat
	markers.custom_aabb = AABB(Vector3(-1.0e13, -1.0e13, -1.0e13), Vector3(2.0e13, 2.0e13, 2.0e13))
	markers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(markers)

	# Orbit rings + planet spheres
	var line_mat := StandardMaterial3D.new()
	line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_mat.albedo_color = Color(0.5, 0.6, 0.8, 0.25)
	line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for i in s.planets.size():
		var p := s.planets[i]
		var im := ImmediateMesh.new()
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for k in ORBIT_SEGMENTS + 1:
			var th := TAU * k / ORBIT_SEGMENTS
			im.surface_add_vertex(Vector3(cos(th) * p.orbit_m, sin(th) * sin(p.incl) * p.orbit_m, sin(th) * cos(p.incl) * p.orbit_m))
		im.surface_end()
		var mi := MeshInstance3D.new()
		mi.mesh = im
		mi.material_override = line_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		orbits.append(mi)

		var sp := MeshInstance3D.new()
		sp.mesh = _sphere
		var mat := StandardMaterial3D.new()
		mat.albedo_color = p.color
		mat.roughness = 0.8
		sp.material_override = mat
		sp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(sp)
		spheres.append(sp)


func planet_scene_pos(index: int, vs: ScaleCamera.ViewState) -> Vector3:
	var p := universe.pos_in(Universe.Frame.S, vs.frame).add(universe.planet_pos_s(index)).sub(vs.focus)
	return p.mul(1.0 / vs.u).to_v3()


func update_view(vs: ScaleCamera.ViewState, planet_layer_visible: bool) -> void:
	visible = vs.d < 1.0e15
	if not visible:
		return
	var inv_u := 1.0 / vs.u
	var origin := universe.pos_in(Universe.Frame.S, vs.frame).sub(vs.focus).mul(inv_u).to_v3()
	transform = Transform3D(Basis.IDENTITY.scaled(Vector3(inv_u, inv_u, inv_u)), origin)

	var show_markers := vs.d > 3.0e8
	markers.visible = show_markers
	var mmk := markers.multimesh
	for i in universe.system.planets.size():
		var p := universe.system.planets[i]
		var pos := universe.planet_pos_s(i).to_v3()
		if show_markers:
			mmk.set_instance_transform(i, Transform3D(Basis.IDENTITY, pos))
			var c := p.color
			var sel := i == universe.selected_planet
			mmk.set_instance_color(i, Color(1.0, 1.0, 1.0, 1.0) if sel else Color(c.r, c.g, c.b, 0.7))
		var sp := spheres[i]
		sp.visible = not (planet_layer_visible and i == universe.selected_planet)
		sp.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * p.radius_m), pos)
	for o in orbits:
		o.visible = vs.d > 1.0e9
