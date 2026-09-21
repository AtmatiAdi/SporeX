class_name PlanetLayer
extends Node3D
## The selected planet: displaced terrain sphere, sea sphere, cloud shell and
## atmosphere shell, all children of `body` which spins with the planet day.
## Authored in meters, anchored at the planet center.

const TERRAIN := preload("res://shaders/planet_terrain.gdshader")
const OCEAN := preload("res://shaders/planet_ocean.gdshader")
const CLOUDS := preload("res://shaders/clouds.gdshader")
const ATMO := preload("res://shaders/atmosphere.gdshader")

const CLOUD_RADIUS := 1.012
const ATMO_RADIUS := 1.035

var universe: Universe
var body: Node3D
var terrain: MeshInstance3D
var ocean: MeshInstance3D
var clouds: MeshInstance3D
var atmo: MeshInstance3D
var terrain_mat: ShaderMaterial
var ocean_mat: ShaderMaterial
var clouds_mat: ShaderMaterial
var atmo_mat: ShaderMaterial

var planet: SystemGenerator.PlanetData
var height: PlanetGenerator.HeightMapResult
var service := HeightMapService.new()
var _prev_tex: ImageTexture
var _blend := 1.0
var _height_tex: ImageTexture
var _cloud_noise: NoiseTexture2D


func _ready() -> void:
	service.map_ready.connect(_on_height_map)
	body = Node3D.new()
	body.name = "Body"
	add_child(body)
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = TERRAIN
	ocean_mat = ShaderMaterial.new()
	ocean_mat.shader = OCEAN
	clouds_mat = ShaderMaterial.new()
	clouds_mat.shader = CLOUDS
	atmo_mat = ShaderMaterial.new()
	atmo_mat.shader = ATMO

	terrain = _sphere(GraphicsSettings.planet_segments(), terrain_mat)
	terrain.name = "Terrain"
	ocean = _sphere(GraphicsSettings.planet_segments(), ocean_mat)
	ocean.name = "Ocean"
	clouds = _sphere(96, clouds_mat)
	clouds.name = "Clouds"
	atmo = _sphere(64, atmo_mat)
	atmo.name = "Atmo"

	_cloud_noise = NoiseTexture2D.new()
	_cloud_noise.width = 1024
	_cloud_noise.height = 512
	_cloud_noise.seamless = true
	_cloud_noise.seamless_blend_skirt = 0.2
	var cn := FastNoiseLite.new()
	cn.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	cn.fractal_octaves = 5
	cn.frequency = 0.006
	_cloud_noise.noise = cn
	clouds_mat.set_shader_parameter("cloud_tex", _cloud_noise)

	# Placeholder height map: flat ocean world until the worker thread reports.
	var img := Image.create(4, 2, false, Image.FORMAT_RF)
	img.fill(Color(0.3, 0.0, 0.0))
	_height_tex = ImageTexture.create_from_image(img)
	terrain_mat.set_shader_parameter("height_map", _height_tex)
	terrain_mat.set_shader_parameter("texel", Vector2(0.25, 0.5))
	terrain_mat.set_shader_parameter("height_map_prev", _height_tex)


func _sphere(segments: int, mat: Material) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = 1.0
	m.height = 2.0
	m.radial_segments = segments
	m.rings = maxi(8, segments / 2)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mi)
	return mi


func set_planet(u: Universe) -> void:
	universe = u
	var pd := u.planet()
	if planet != null and planet.seed == pd.seed:
		return
	planet = pd
	height = null
	var rng := Seeds.rng(Seeds.mix(pd.seed, 9))
	var hue := rng.randf()
	terrain_mat.set_shader_parameter("height_scale", pd.height_scale)
	terrain_mat.set_shader_parameter("sea_level", pd.sea_level)
	terrain_mat.set_shader_parameter("col_low", Color.from_hsv(fmod(0.25 + rng.randf_range(-0.12, 0.12), 1.0), 0.55, 0.42))
	terrain_mat.set_shader_parameter("col_high", Color.from_hsv(fmod(0.1 + rng.randf_range(-0.05, 0.1), 1.0), 0.35, 0.4))
	terrain_mat.set_shader_parameter("col_sand", Color.from_hsv(0.11 + rng.randf_range(-0.03, 0.03), 0.35, 0.78))
	terrain_mat.set_shader_parameter("ice_lat", rng.randf_range(0.8, 0.92))
	var sea := Color.from_hsv(fmod(0.58 + rng.randf_range(-0.08, 0.06), 1.0), 0.85, 0.45)
	ocean_mat.set_shader_parameter("color", sea)
	ocean_mat.set_shader_parameter("color_rim", sea.lightened(0.35))
	atmo_mat.set_shader_parameter("color", Color.from_hsv(fmod(0.6 + rng.randf_range(-0.06, 0.06), 1.0), 0.6, 1.0))
	clouds_mat.set_shader_parameter("coverage", rng.randf_range(0.45, 0.6))
	# Same cloud texture for every planet, different offset: no regeneration, no pop.
	clouds_mat.set_shader_parameter("uv_offset", Vector2(rng.randf(), rng.randf()))

	var r := pd.radius_m
	terrain.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * r), Vector3.ZERO)
	ocean.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * pd.r_sea()), Vector3.ZERO)
	clouds.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * r * CLOUD_RADIUS), Vector3.ZERO)
	atmo.transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * r * ATMO_RADIUS), Vector3.ZERO)

	# Use whatever the service already has (prefetched), then ask for the fine level.
	var cached := service.best(pd.seed)
	if cached:
		_apply_height_map(cached, true)
	else:
		var img := Image.create(4, 2, false, Image.FORMAT_RF)
		img.fill(Color(0.3, 0.0, 0.0))
		_set_height_texture(ImageTexture.create_from_image(img), Vector2(0.25, 0.5), true)
	service.request(pd.seed, true)




func _on_height_map(res: PlanetGenerator.HeightMapResult) -> void:
	if planet == null or res.seed != planet.seed:
		return
	_apply_height_map(res, false)


func _apply_height_map(res: PlanetGenerator.HeightMapResult, immediate: bool) -> void:
	height = res
	_set_height_texture(ImageTexture.create_from_image(res.image), Vector2(1.0 / res.size.x, 1.0 / res.size.y), immediate)


## Swap the terrain texture; unless immediate, the previous one stays as
## `height_map_prev` and the shader cross-fades over ~0.5 s (no pop).
func _set_height_texture(tex: ImageTexture, texel: Vector2, immediate: bool) -> void:
	if _height_tex and not immediate:
		_prev_tex = _height_tex
		terrain_mat.set_shader_parameter("height_map_prev", _prev_tex)
		_blend = 0.0
	else:
		_blend = 1.0
	_height_tex = tex
	terrain_mat.set_shader_parameter("height_map", _height_tex)
	terrain_mat.set_shader_parameter("texel", texel)
	terrain_mat.set_shader_parameter("hm_blend", _blend)


## Queue background generation for planets the player may pick next.
func prefetch(seeds: Array[int]) -> void:
	for s in seeds:
		service.request(s, false)


func _process(dt: float) -> void:
	if _blend < 1.0:
		_blend = minf(_blend + dt * 2.0, 1.0)
		terrain_mat.set_shader_parameter("hm_blend", _blend)


func _exit_tree() -> void:
	service.shutdown()


## True when the given body-frame direction is over water (or unknown yet).
func is_water(dir_body: Vector3) -> bool:
	if height == null:
		return true
	return height.sample_dir(dir_body) < planet.sea_level


## Nearest body-frame direction that is over water (spiral search on the map).
func find_water_dir(dir_body: Vector3) -> Vector3:
	if height == null or is_water(dir_body):
		return dir_body
	var w := height.size.x
	var h := height.size.y
	var u := atan2(dir_body.x, dir_body.z) / TAU + 0.5
	var v := 0.5 - asin(clampf(dir_body.y, -1.0, 1.0)) / PI
	var cx := posmod(int(floor(u * w)), w)
	var cy := clampi(int(floor(v * h)), 0, h - 1)
	for ring in range(1, maxi(w, h)):
		for dy in range(-ring, ring + 1):
			var y := cy + dy
			if y < 0 or y >= h:
				continue
			var edge := absi(dy) == ring
			var step := 1 if edge else ring * 2
			var dx := -ring
			while dx <= ring:
				var x := posmod(cx + dx, w)
				if height.data[y * w + x] < planet.sea_level - 0.01:
					return height.texel_dir(x, y)
				dx += step
	return dir_body


func update_view(vs: ScaleCamera.ViewState) -> void:
	var show := vs.d < 2.0e9 and (vs.frame != Universe.Frame.L or vs.altitude > 4000.0)
	visible = show
	if not show:
		return
	var inv_u := 1.0 / vs.u
	var origin := universe.pos_in(Universe.Frame.P, vs.frame).sub(vs.focus).mul(inv_u).to_v3()
	transform = Transform3D(Basis.IDENTITY.scaled(Vector3(inv_u, inv_u, inv_u)), origin)
	body.transform = Transform3D(universe.planet_rot(), Vector3.ZERO)
	atmo_mat.set_shader_parameter("sun_dir", vs.sun_dir)
	# Fade the cloud shell out as we descend through it; fog takes over.
	var alt := vs.altitude if vs.frame >= Universe.Frame.P else 1.0e9
	clouds_mat.set_shader_parameter("alpha_mul", 0.9 * clampf((alt - 8000.0) / 20000.0, 0.0, 1.0))
	clouds.visible = alt > 8000.0
