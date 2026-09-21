class_name SurfaceLayer
extends Node3D
## Local sea surface around the landing point. Takes over from the planet
## sphere below ~40 km (where float precision on a 6000 km sphere would start
## to jitter) and stays valid down to the cell. Authored in meters, anchored at
## the landing point with the landing basis (y = local up).

const OCEAN := preload("res://shaders/ocean_surface.gdshader")
const PLANE_SIZE := 240000.0  # 240 km

var universe: Universe
var plane: MeshInstance3D
var mat: ShaderMaterial


func _ready() -> void:
	var pm := PlaneMesh.new()
	pm.size = Vector2(PLANE_SIZE, PLANE_SIZE)
	pm.subdivide_depth = 24
	pm.subdivide_width = 24
	mat = ShaderMaterial.new()
	mat.shader = OCEAN
	# Runtime-generated wave normal map (no assets on disk).
	var wn := NoiseTexture2D.new()
	wn.width = 512
	wn.height = 512
	wn.seamless = true
	wn.as_normal_map = true
	wn.bump_strength = 6.0
	wn.generate_mipmaps = true
	var wnoise := FastNoiseLite.new()
	wnoise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	wnoise.frequency = 0.02
	wnoise.fractal_octaves = 4
	wn.noise = wnoise
	mat.set_shader_parameter("wave_normal", wn)
	plane = MeshInstance3D.new()
	plane.mesh = pm
	plane.material_override = mat
	plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	plane.custom_aabb = AABB(Vector3(-PLANE_SIZE, -1000.0, -PLANE_SIZE), Vector3(PLANE_SIZE * 2.0, 2000.0, PLANE_SIZE * 2.0))
	add_child(plane)


func set_universe(u: Universe) -> void:
	universe = u


func set_colors(deep: Color, shallow: Color) -> void:
	mat.set_shader_parameter("color_deep", deep)
	mat.set_shader_parameter("color_shallow", shallow)


func update_view(vs: ScaleCamera.ViewState) -> void:
	var show := vs.locked and vs.altitude < 60000.0
	visible = show
	if not show:
		return
	var inv_u := 1.0 / vs.u
	var origin := universe.pos_in(Universe.Frame.L, vs.frame).sub(vs.focus).mul(inv_u).to_v3()
	transform = Transform3D(vs.l_basis.scaled(Vector3(inv_u, inv_u, inv_u)), origin)
	mat.set_shader_parameter("meters_per_unit", vs.u)
	# Cross-fade with the planet sphere between 40 km and 20 km.
	mat.set_shader_parameter("alpha", 0.92 * clampf((40000.0 - vs.altitude) / 20000.0, 0.0, 1.0))
