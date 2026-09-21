class_name CellLayer
extends Node3D
## The player's cell and the water around it (marine snow). Authored in meters,
## anchored at the landing point with the landing basis, like SurfaceLayer.
## Movement happens on the plane parallel to the sea surface (Spore-style).

const CELL_SHADER := preload("res://shaders/cell.gdshader")
const BILLBOARD := preload("res://shaders/billboard_point.gdshader")

const CELL_RADIUS := 2.0e-4     # 0.2 mm
const MAX_SPEED := 1.4e-3       # m/s (~7 radii per second)
const ACCEL := 6.0e-3
const DRAG := 3.0
const SNOW_COUNT := 700
const SNOW_BOX_UNITS := 30.0    # scene units: the snow is a scale-independent screen-space effect

var universe: Universe
var camera: ScaleCamera
var cell_root: Node3D
var membrane: MeshInstance3D
var nucleus: MeshInstance3D
var snow: MultiMeshInstance3D
var snow_mat: ShaderMaterial
var _facing := Vector3(0.0, 0.0, -1.0)


func _ready() -> void:
	cell_root = Node3D.new()
	add_child(cell_root)

	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 40
	sm.rings = 20
	var mat := ShaderMaterial.new()
	mat.shader = CELL_SHADER
	membrane = MeshInstance3D.new()
	membrane.mesh = sm
	membrane.material_override = mat
	membrane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cell_root.add_child(membrane)

	var nm := SphereMesh.new()
	nm.radius = 0.38
	nm.height = 0.76
	nm.radial_segments = 24
	nm.rings = 12
	var nmat := StandardMaterial3D.new()
	nmat.albedo_color = Color(0.25, 0.5, 0.35)
	nmat.roughness = 0.6
	nucleus = MeshInstance3D.new()
	nucleus.mesh = nm
	nucleus.material_override = nmat
	nucleus.position = Vector3(0.0, 0.0, -0.25)
	nucleus.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cell_root.add_child(nucleus)

	_build_snow()


func _build_snow() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2.ONE
	mm.mesh = q
	mm.instance_count = SNOW_COUNT
	for i in SNOW_COUNT:
		var p := Vector3(rng.randf() - 0.5, rng.randf() - 0.5, rng.randf() - 0.5) * SNOW_BOX_UNITS
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, p))
		var b := rng.randf_range(0.15, 0.45)
		mm.set_instance_color(i, Color(0.8, 0.95, 0.9, b))
		mm.set_instance_custom_data(i, Color(0.0, rng.randf_range(1.0, 2.2), 0.0, 0.0))
	snow_mat = ShaderMaterial.new()
	snow_mat.shader = BILLBOARD
	snow_mat.set_shader_parameter("wrap_enabled", true)
	snow_mat.set_shader_parameter("manual_transform", true)
	snow_mat.set_shader_parameter("wrap_size", SNOW_BOX_UNITS)
	snow_mat.set_shader_parameter("drift", Vector3(0.12, -0.25, 0.08))
	snow = MultiMeshInstance3D.new()
	snow.top_level = true  # scene-space, not affected by the layer scale
	snow.multimesh = mm
	snow.material_override = snow_mat
	snow.custom_aabb = AABB(Vector3(-40.0, -40.0, -40.0), Vector3(80.0, 80.0, 80.0))
	snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(snow)


func setup(u: Universe, cam: ScaleCamera) -> void:
	universe = u
	camera = cam


## Reads WASD and integrates the cell position (in landing-frame local meters).
func update_control(dt: float, vs: ScaleCamera.ViewState) -> void:
	if not vs.cell_mode:
		camera.cell_vel = DVec3.zero()
		return
	var local_cam := vs.l_basis.transposed() * vs.cam_basis
	var fwd := Vector3(-local_cam.z.x, 0.0, -local_cam.z.z) + Vector3(local_cam.y.x, 0.0, local_cam.y.z)
	fwd = fwd.normalized() if fwd.length() > 1.0e-4 else Vector3(0.0, 0.0, -1.0)
	var right := Vector3(fwd.z, 0.0, -fwd.x)
	var input := Vector3.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		input += fwd
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		input -= fwd
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		input += right
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		input -= right
	var sprint := 2.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0
	var vel := camera.cell_vel.to_v3()
	if input.length() > 0.0:
		vel += input.normalized() * ACCEL * sprint * dt
	vel *= exp(-DRAG * dt)
	var spd := vel.length()
	if spd > MAX_SPEED * sprint:
		vel = vel / spd * MAX_SPEED * sprint
	camera.cell_vel = DVec3.from_v3(vel)
	camera.cell_pos = camera.cell_pos.add(camera.cell_vel.mul(dt))
	if spd > 1.0e-5:
		_facing = _facing.slerp(vel.normalized(), clampf(dt * 6.0, 0.0, 1.0))


func update_view(vs: ScaleCamera.ViewState) -> void:
	var show := vs.locked and vs.d < 60.0
	visible = show
	if not show:
		return
	var inv_u := 1.0 / vs.u
	var origin := universe.pos_in(Universe.Frame.L, vs.frame).sub(vs.focus).mul(inv_u).to_v3()
	transform = Transform3D(vs.l_basis.scaled(Vector3(inv_u, inv_u, inv_u)), origin)
	# The cell sits exactly at the focus: cell_pos + dive offset.
	var local_pos := camera.cell_pos.add(DVec3.new(0.0, -ScaleCamera.DIVE_DEPTH * vs.b4, 0.0)).to_v3()
	var look := Basis.looking_at(_facing, Vector3.UP) if _facing.length() > 0.5 else Basis.IDENTITY
	cell_root.transform = Transform3D(look.scaled(Vector3.ONE * CELL_RADIUS), local_pos)
	snow.visible = vs.underwater
	# Scroll the snow with the focus so it streams past when the cell swims.
	snow_mat.set_shader_parameter("offset", vs.focus.mul(-inv_u).to_v3())
