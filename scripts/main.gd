extends Node3D
## Entry point. Builds the universe from one seed, wires the scale-space camera
## to the render layers and drives lighting/fog from the current view state.
##
## Debug / test harness (args after `--`):
##   --seed=123      galaxy seed
##   --d=1e9         start camera distance in meters
##   --shot=out.png  save a screenshot after --frames frames and quit
##   --frames=60

const STAR_COUNT := 60000
const DEFAULT_SEED := 20260920

var universe := Universe.new()
var cam := ScaleCamera.new()
var camera3d := Camera3D.new()
var env := Environment.new()
var world_env := WorldEnvironment.new()
var sun_light := DirectionalLight3D.new()
var galaxy_layer := GalaxyLayer.new()
var system_layer := SystemLayer.new()
var planet_layer := PlanetLayer.new()
var surface_layer := SurfaceLayer.new()
var cell_layer := CellLayer.new()
var hud := Hud.new()

var _args := {}
var _shot_frames := -1
var _warmup := 3   # frames during which every layer is drawn once so pipelines compile up front


func _ready() -> void:
	_parse_args()
	var seed: int = int(_args.get("seed", DEFAULT_SEED))
	NetManager.galaxy_seed = seed
	NetManager.galaxy_seed_received.connect(_rebuild_universe)

	# Scene graph
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.6, 0.8)
	env.ambient_light_energy = 0.06
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = false
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	world_env.environment = env
	add_child(world_env)

	sun_light.light_energy = 1.3
	sun_light.shadow_enabled = false
	add_child(sun_light)

	camera3d.near = 0.05
	camera3d.far = 2.0e5
	camera3d.fov = 60.0
	camera3d.current = true
	add_child(camera3d)

	galaxy_layer.name = "Galaxy"
	system_layer.name = "System"
	planet_layer.name = "Planet"
	surface_layer.name = "Surface"
	cell_layer.name = "Cell"
	add_child(galaxy_layer)
	add_child(system_layer)
	add_child(planet_layer)
	add_child(surface_layer)
	add_child(cell_layer)
	add_child(cam)
	add_child(hud)

	if _args.has("quality"):
		GraphicsSettings.quality = int(_args["quality"])
	GraphicsSettings.apply(GraphicsSettings.quality, env, get_viewport())
	if _args.has("bench"):
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)

	_rebuild_universe(seed)
	universe.time = float(_args.get("time", 0.0))
	cam.setup(universe, planet_layer.find_water_dir, float(_args.get("d", 1.2e21)))
	cam.clicked.connect(_on_click)
	if not _args.has("yaw"):
		cam.face_day_side()
	else:
		cam.yaw = float(_args["yaw"])
		cam.pitch = float(_args.get("pitch", -30.0))
	if _args.has("shot"):
		_shot_frames = int(_args.get("frames", 60))
		var vs0 := cam.update(0.0)
		pass


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1]


func _rebuild_universe(seed: int) -> void:
	universe.build(seed, STAR_COUNT)
	galaxy_layer.build(universe.galaxy)
	system_layer.build(universe)
	planet_layer.set_planet(universe)
	surface_layer.set_universe(universe)
	cell_layer.setup(universe, cam)
	_apply_planet_colors()
	_prefetch_playable_planets()


## Background-generate terrain for every playable planet so switching targets
## never shows a placeholder (8 x ~0.4 s on the worker thread, done long before
## the player can scroll there).
func _prefetch_playable_planets() -> void:
	var seeds: Array[int] = []
	for idx in universe.galaxy.habitable:
		if idx == universe.selected_star:
			continue
		var c := universe.galaxy.colors[idx]
		var sys := SystemGenerator.generate(Seeds.mix(universe.galaxy.seed, idx), Color(c.r, c.g, c.b), universe.galaxy.classes[idx])
		seeds.append(sys.planets[sys.habitable_index].seed)
	planet_layer.prefetch(seeds)


func _apply_planet_colors() -> void:
	var sea: Color = planet_layer.ocean_mat.get_shader_parameter("color")
	surface_layer.set_colors(sea.darkened(0.3), sea.lightened(0.25))


func _process(dt: float) -> void:
	universe.time += dt
	if _args.has("select") and _shot_frames == int(_args.get("frames", 60)) - 30:
		var idx: int = universe.galaxy.habitable[int(_args["select"])]
		cam.with_smooth_transition(func(): universe.select_star(idx))
		system_layer.build(universe)
		planet_layer.set_planet(universe)
		_apply_planet_colors()
		print("selected star ", idx, " at frame ", _bench_frames)
	if _args.has("autozoom"):
		cam._zoom(-float(_args["autozoom"]) * dt)
	var vs := cam.update(dt)
	cell_layer.update_control(dt, vs)
	if vs.cell_mode:
		# Re-evaluate the focus with the moved cell so the camera tracks it this frame.
		vs = cam.update(0.0)

	var atmo := _atmosphere_factor(vs)
	var day := _daylight(vs)
	var star_fade := 1.0 - atmo * day * 0.97
	if vs.underwater:
		star_fade = 0.0
	galaxy_layer.update_view(vs, universe, star_fade)
	planet_layer.update_view(vs)
	system_layer.update_view(vs, planet_layer.visible)
	surface_layer.update_view(vs)
	cell_layer.update_view(vs)

	if _warmup > 0:
		_warmup -= 1
		_force_all_visible()
	camera3d.transform = Transform3D(vs.cam_basis, vs.cam_basis.z * ScaleCamera.CAM_DIST)
	RenderingServer.global_shader_parameter_set("sx_tan_half_fov", tan(deg_to_rad(camera3d.fov * 0.5)))
	RenderingServer.global_shader_parameter_set("sx_viewport_height", float(get_viewport().get_visible_rect().size.y))
	_update_light(vs)
	_update_environment(vs, atmo, day)
	hud.update_info(vs, universe, dt)
	if _args.has("bench"):
		_bench_frame(dt, vs)
	if _args.has("hide"):
		for n in String(_args["hide"]).split(","):
			var node := get_node_or_null(n)
			if node:
				node.visible = false

	if _shot_frames >= 0:
		_shot_frames -= 1
		if _shot_frames == 0:
			_take_shot()
		elif _args.has("series") and _shot_frames % int(_args.get("every", 10)) == 0:
			get_viewport().get_texture().get_image().save_png(String(_args["shot"]).replace(".png", "_%03d.png" % _shot_frames))


func _atmosphere_factor(vs: ScaleCamera.ViewState) -> float:
	if vs.frame < Universe.Frame.P:
		return 0.0
	return exp(-maxf(vs.altitude, 0.0) / 9000.0)


func _daylight(vs: ScaleCamera.ViewState) -> float:
	return smoothstep(-0.12, 0.3, vs.up.dot(vs.sun_dir))


func _update_light(vs: ScaleCamera.ViewState) -> void:
	var dir := vs.sun_dir
	if vs.underwater:
		dir = (vs.up + dir * 0.4).normalized()
	var up_ref := Vector3.UP if absf(dir.y) < 0.95 else Vector3.RIGHT
	sun_light.transform = Transform3D(Basis.looking_at(-dir, up_ref), Vector3.ZERO)
	sun_light.light_energy = 0.7 if vs.underwater else 1.3
	sun_light.light_color = Color(0.5, 0.85, 0.9) if vs.underwater else Color(1.0, 0.97, 0.9)


func _update_environment(vs: ScaleCamera.ViewState, atmo: float, day: float) -> void:
	var sky_col := Color(0.42, 0.62, 0.98)
	var horizon_col := Color(0.75, 0.85, 1.0)
	if vs.underwater:
		var depth_t := clampf(-vs.altitude / 40.0, 0.0, 1.0)
		var water := Color(0.02, 0.22, 0.34).lerp(Color(0.0, 0.05, 0.12), depth_t)
		env.background_color = water
		env.fog_enabled = true
		env.fog_light_color = water.lightened(0.15)
		env.fog_light_energy = 1.0
		env.fog_density = maxf(0.16 * vs.u, 0.035)
		env.ambient_light_color = Color(0.3, 0.7, 0.8)
		env.ambient_light_energy = 0.55
		return

	var cloud := 0.0
	if vs.locked:
			cloud = smoothstep(2200.0, 2900.0, vs.altitude) * smoothstep(4200.0, 3500.0, vs.altitude)
	var sky_amount := atmo * day
	var bg := Color.BLACK.lerp(sky_col, sky_amount)
	bg = bg.lerp(Color(0.92, 0.94, 0.98), cloud * day)
	env.background_color = bg
	var haze := atmo * day * (1.0 / 45000.0) * vs.u + cloud * (1.0 / 500.0) * vs.u
	env.fog_enabled = haze > 1.0e-5
	env.fog_light_color = horizon_col.lerp(Color(0.95, 0.95, 1.0), cloud)
	env.fog_light_energy = maxf(day, 0.08)
	env.fog_density = haze
	env.ambient_light_color = Color(0.5, 0.6, 0.8).lerp(sky_col, sky_amount)
	env.ambient_light_energy = lerpf(0.06, 0.45, sky_amount) + 0.25 * (1.0 - day) * atmo


func _on_click(pos: Vector2) -> void:
	var vs := cam.state
	var best := -1
	var best_d := 22.0
	if vs.d > 1.0e16:
		for i in universe.galaxy.habitable.size():
			var idx: int = universe.galaxy.habitable[i]
			var sp := galaxy_layer.star_scene_pos(idx, universe, vs)
			var dist := _screen_dist(sp, pos)
			if dist < best_d:
				best_d = dist
				best = idx
		if best >= 0 and best != universe.selected_star:
			cam.with_smooth_transition(func(): universe.select_star(best))
			system_layer.build(universe)
			planet_layer.set_planet(universe)
			_apply_planet_colors()
	elif vs.d < 1.0e13 and not vs.locked:
		for i in universe.system.planets.size():
			var sp := system_layer.planet_scene_pos(i, vs)
			var dist := _screen_dist(sp, pos)
			if dist < best_d:
				best_d = dist
				best = i
		if best >= 0 and best != universe.selected_planet:
			cam.with_smooth_transition(func(): universe.select_planet(best))
			planet_layer.set_planet(universe)
			_apply_planet_colors()


func _screen_dist(scene_pos: Vector3, click: Vector2) -> float:
	if camera3d.is_position_behind(scene_pos):
		return 1.0e9
	return camera3d.unproject_position(scene_pos).distance_to(click)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F1:
				GraphicsSettings.apply(GraphicsSettings.Quality.LOW, env, get_viewport())
			KEY_F2:
				GraphicsSettings.apply(GraphicsSettings.Quality.MEDIUM, env, get_viewport())
			KEY_F3:
				GraphicsSettings.apply(GraphicsSettings.Quality.HIGH, env, get_viewport())
			KEY_F5:
				NetManager.host()
			KEY_F6:
				NetManager.join_first_host()
			KEY_F11:
				var w := get_window()
				w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
			KEY_ESCAPE:
				get_tree().quit()


func _take_shot() -> void:
	var img := get_viewport().get_texture().get_image()
	var path: String = _args["shot"]
	img.save_png(path)
	print("screenshot saved: ", path)
	get_tree().quit()




var _bench_hist := {}
var _bench_frames := 0


## Prints every slow frame with the current scale, then a histogram at exit.
func _bench_frame(dt: float, vs: ScaleCamera.ViewState) -> void:
	_bench_frames += 1
	var ms := dt * 1000.0
	var bucket := "<16" if ms < 16.7 else ("<33" if ms < 33.4 else ("<100" if ms < 100.0 else ">=100"))
	_bench_hist[bucket] = _bench_hist.get(bucket, 0) + 1
	var gpu_ms := RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid())
	var cpu_ms := RenderingServer.viewport_get_measured_render_time_cpu(get_viewport().get_viewport_rid())
	if _args.has("gpulog") and _bench_frames % 30 == 0:
		print("GPU %.1f ms cpu %.1f frame=%d d=%s" % [gpu_ms, cpu_ms, _bench_frames, Hud.fmt_distance(vs.d)])
	if ms > 25.0 or gpu_ms > 12.0:
		print("SLOW %6.1f ms (render cpu %.1f gpu %.1f)  frame=%d  d=%s  phase=%s  alt=%s  planet_hm=%s" % [ms, cpu_ms, gpu_ms, _bench_frames, Hud.fmt_distance(vs.d), vs.phase, Hud.fmt_distance(vs.altitude), "yes" if planet_layer.height else "no"])
	if _shot_frames == 1:
		print("BENCH histogram: ", _bench_hist)


## Pipeline warm-up: draw everything on the first frames (at whatever scale) so
## that no material compiles its pipeline later, mid-zoom.
func _force_all_visible() -> void:
	for layer in [system_layer, planet_layer, surface_layer, cell_layer]:
		layer.visible = true
	planet_layer.clouds.visible = true
	system_layer.markers.visible = true
	for o in system_layer.orbits:
		o.visible = true
	cell_layer.snow.visible = true
	galaxy_layer.dust.visible = true
	galaxy_layer.markers.visible = true
