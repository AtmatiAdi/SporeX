class_name ScaleCamera
extends Node
## Scale-space camera: ONE continuous zoom parameter `d` (meters, double) from
## the whole galaxy (3e21 m) down to a single cell (2e-3 m). The camera always
## sits CAM_DIST scene units away from the focus point; the world is rescaled
## every frame so that `u = d / CAM_DIST` meters map to one scene unit.
##
## The focus point slides along the anchor chain as you zoom:
##   galaxy center -> star -> planet center -> landing point -> underwater cell
## Every hand-over is a smooth blend on log(d), so there are no cuts and no
## loading screens. Selecting a different star/planet adds a transient offset
## that decays, which reads as a fly-over instead of a jump.

signal clicked(screen_pos: Vector2)

const CAM_DIST := 10.0
const D_MAX := 3.0e21
const D_MIN := 2.0e-3
const D_GAL_HI := 3.0e20    # focus starts sliding galaxy center -> star
const D_GAL_LO := 3.0e19    # ... arrives at the star; star frame from here on
const D_SYS_HI := 1.0e12    # focus starts sliding star -> planet
const D_SYS_LO := 1.0e11
const D_FRAME_P := 1.0e9    # switch to the planet-centered frame
const SURF_HI_R := 3.0      # surface approach begins at 3 planet radii
const SURF_LO_R := 1.2      # ... and locks onto the landing point at 1.2 radii
const DIVE_HI := 30.0       # start diving below the sea surface (m)
const DIVE_LO := 3.0
const DIVE_DEPTH := 2.5     # cell depth below the surface (m)
const CELL_CTRL_D := 3.0e-2 # below this distance you control the cell
const ZOOM_STEP := 0.35     # ln units per wheel notch
const ZOOM_SMOOTH := 7.0
const ROT_SENS := 0.25      # degrees per pixel


class ViewState:
	var d := 1.0e21
	var u := 1.0e20
	var frame := Universe.Frame.G
	var focus := DVec3.zero()      # focus point relative to the frame origin (world axes)
	var cam_basis := Basis.IDENTITY
	var cam_dir := Vector3.BACK    # unit vector from focus to camera
	var l_basis := Basis.IDENTITY  # world basis of the landing frame (valid when locked)
	var up := Vector3.UP           # local "up" at the camera
	var altitude := 1.0e12         # camera height above sea level (m)
	var underwater := false
	var locked := false
	var cell_mode := false
	var b1 := 0.0
	var b2 := 0.0
	var b3 := 0.0
	var b4 := 0.0
	var sun_dir := Vector3.BACK    # unit vector from focus to the sun
	var phase := ""


var universe: Universe
var find_water: Callable            # (dir_body: Vector3) -> Vector3 nearest water direction
var state := ViewState.new()

var log_d := 0.0
var log_d_target := 0.0
var yaw := 35.0
var pitch := -30.0
var roll_extra := 0.0
var s_yaw := 0.0
var s_pitch_user := -90.0
var locked := false
var trans_offset := DVec3.zero()
var cell_pos := DVec3.zero()        # cell position in landing-frame local coords (m)
var cell_vel := DVec3.zero()

var _dragging := false
var _drag_moved := 0.0
var _key_zoom := 0.0
var input_enabled := true


func setup(u: Universe, water_lookup: Callable, start_d: float) -> void:
	universe = u
	find_water = water_lookup
	log_d = log(clampf(start_d, D_MIN, D_MAX))
	log_d_target = log_d


func set_distance(d: float, immediate: bool = true) -> void:
	log_d_target = log(clampf(d, D_MIN, D_MAX))
	if immediate:
		log_d = log_d_target


## 0 when d >= hi, 1 when d <= lo, smooth in log space in between.
static func blend(d: float, hi: float, lo: float) -> float:
	var t := (log(hi) - log(d)) / (log(hi) - log(lo))
	return smoothstep(0.0, 1.0, clampf(t, 0.0, 1.0))


func _space_basis() -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0)) * Basis(Vector3(0.0, 0.0, 1.0), roll_extra)


func _frame_for(d: float) -> int:
	if locked:
		return Universe.Frame.L
	if d < D_FRAME_P:
		return Universe.Frame.P
	if d < D_GAL_LO:
		return Universe.Frame.S
	return Universe.Frame.G


func _focus_local(frame: int, vs: ViewState, cam_dir: Vector3, l_basis: Basis) -> DVec3:
	match frame:
		Universe.Frame.G:
			return universe.star_pos_g().mul(vs.b1)
		Universe.Frame.S:
			return universe.planet_pos_s().mul(vs.b2)
		Universe.Frame.P:
			return DVec3.from_v3(cam_dir).mul(universe.r_sea() * vs.b3)
		_:
			return cell_pos.add(DVec3.new(0.0, -DIVE_DEPTH * vs.b4, 0.0)).xform(l_basis)


## Wrap a selection change so the camera flies to the new target instead of jumping.
func with_smooth_transition(apply: Callable) -> void:
	var vs := state
	var frame := vs.frame
	var old := universe.pos_in(frame, Universe.Frame.G).add(_focus_local(frame, vs, vs.cam_dir, vs.l_basis))
	apply.call()
	var new := universe.pos_in(frame, Universe.Frame.G).add(_focus_local(frame, vs, vs.cam_dir, vs.l_basis))
	trans_offset = trans_offset.add(old.sub(new))


func update(dt: float) -> ViewState:
	var vs := state
	if _key_zoom != 0.0:
		_zoom(_key_zoom * dt * 2.5)
	log_d += (log_d_target - log_d) * (1.0 - exp(-dt * ZOOM_SMOOTH))
	var d := exp(log_d)
	trans_offset = trans_offset.mul(exp(-dt * 4.0))
	# Never let the fly-over offset exceed a few view distances: zooming in pulls you to the target.
	var tl := trans_offset.length()
	if tl > 3.0 * d:
		trans_offset = trans_offset.mul(3.0 * d / tl)
	roll_extra *= exp(-dt * 2.5)

	var r_sea := universe.r_sea()
	var lock_d := r_sea * SURF_LO_R
	vs.d = d
	vs.u = d / CAM_DIST
	vs.b1 = blend(d, D_GAL_HI, D_GAL_LO)
	vs.b2 = blend(d, D_SYS_HI, D_SYS_LO)
	vs.b3 = blend(d, r_sea * SURF_HI_R, lock_d)
	vs.b4 = blend(d, DIVE_HI, DIVE_LO)

	if not locked and d <= lock_d:
		_lock(_space_basis(), r_sea)
	elif locked and d > lock_d:
		_unlock()

	var frame := _frame_for(d)
	var cam_basis: Basis
	var l_basis := Basis.IDENTITY
	if locked:
		l_basis = universe.l_basis_world()
		# Force the view straight down near the lock threshold so lock/unlock is seamless.
		var w := clampf((d - lock_d * 0.85) / (lock_d * 0.15), 0.0, 1.0)
		var pitch_eff := -90.0 + (s_pitch_user + 90.0) * (1.0 - w)
		cam_basis = l_basis * Basis.from_euler(Vector3(deg_to_rad(pitch_eff), deg_to_rad(s_yaw), 0.0))
	else:
		cam_basis = _space_basis()
	var cam_dir := cam_basis.z

	var focus := _focus_local(frame, vs, cam_dir, l_basis).add(trans_offset)

	var alt := 1.0e12
	var underwater := false
	var up := Vector3.UP
	if frame == Universe.Frame.P:
		var cp := focus.add(DVec3.from_v3(cam_dir).mul(d))
		alt = cp.length() - r_sea
		up = cp.normalized().to_v3()
	elif frame == Universe.Frame.L:
		var cp := focus.add(DVec3.from_v3(cam_dir).mul(d))
		up = l_basis.y
		alt = cp.dot(DVec3.from_v3(up))
		underwater = alt < 0.0

	vs.frame = frame
	vs.focus = focus
	vs.cam_basis = cam_basis
	vs.cam_dir = cam_dir
	vs.l_basis = l_basis
	vs.up = up
	vs.altitude = alt
	vs.underwater = underwater
	vs.locked = locked
	vs.cell_mode = locked and d < CELL_CTRL_D
	var sun_rel := universe.pos_in(Universe.Frame.S, frame).sub(focus)
	vs.sun_dir = sun_rel.normalized().to_v3() if sun_rel.length() > 0.0 else Vector3(0.3, 0.8, 0.5).normalized()
	vs.phase = _phase_name(vs)
	return vs


func _phase_name(vs: ViewState) -> String:
	match vs.frame:
		Universe.Frame.G:
			return "GALAKTYKA"
		Universe.Frame.S:
			return "GALAKTYKA" if vs.d > 1.0e16 else "UKŁAD GWIEZDNY"
		Universe.Frame.P:
			return "ORBITA"
		_:
			if vs.cell_mode:
				return "KOMÓRKA"
			if vs.underwater:
				return "OCEAN"
			if vs.altitude < 6000.0 and vs.altitude > 1500.0:
				return "CHMURY"
			return "ATMOSFERA"


func _lock(space_basis: Basis, r_sea: float) -> void:
	locked = true
	# Landing frame: up = direction from planet center to camera, x = camera right.
	var lw := Basis(space_basis.x, space_basis.z, -space_basis.y)
	var lb := universe.planet_rot().transposed() * lw
	var dir := lb.y
	var water_dir: Vector3 = find_water.call(dir) if find_water.is_valid() else dir
	if water_dir.distance_to(dir) > 1.0e-7:
		# Snap the landing point to water but keep the camera where it is; the
		# difference decays as a smooth pan.
		var spin := universe.spin_angle()
		var old_pt := DVec3.from_v3(dir).rotated_y(spin).mul(r_sea)
		var new_pt := DVec3.from_v3(water_dir).rotated_y(spin).mul(r_sea)
		trans_offset = trans_offset.add(old_pt.sub(new_pt))
		var x := (lb.x - water_dir * lb.x.dot(water_dir)).normalized()
		lb = Basis(x, water_dir, x.cross(water_dir))
	universe.lock_dir_body = lb.y
	universe.l_basis_body = lb
	s_yaw = 0.0
	s_pitch_user = -90.0
	cell_pos = DVec3.zero()
	cell_vel = DVec3.zero()


func _unlock() -> void:
	locked = false
	var actual := universe.l_basis_world() * Basis.from_euler(Vector3(deg_to_rad(-90.0), deg_to_rad(s_yaw), 0.0))
	var dir := actual.z
	pitch = rad_to_deg(-asin(clampf(dir.y, -1.0, 1.0)))
	yaw = rad_to_deg(atan2(dir.x, dir.z))
	var nominal := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0))
	roll_extra = atan2(actual.x.dot(nominal.y), actual.x.dot(nominal.x))
	pitch = clampf(pitch, -89.0, 89.0)


func _zoom(delta_ln: float) -> void:
	log_d_target = clampf(log_d_target + delta_ln * zoom_rate_mult(exp(log_d_target)), log(D_MIN), log(D_MAX))


func _process(_dt: float) -> void:
	if not input_enabled:
		return
	var z := 0.0
	if Input.is_key_pressed(KEY_MINUS) or Input.is_key_pressed(KEY_PAGEDOWN) or Input.is_key_pressed(KEY_KP_SUBTRACT):
		z += 1.0
	if Input.is_key_pressed(KEY_EQUAL) or Input.is_key_pressed(KEY_PAGEUP) or Input.is_key_pressed(KEY_KP_ADD):
		z -= 1.0
	_key_zoom = z


func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var mult := 3.0 if mb.shift_pressed else 1.0
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom(-ZOOM_STEP * mult)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom(ZOOM_STEP * mult)
		elif mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_dragging = true
				_drag_moved = 0.0
			else:
				_dragging = false
				if mb.button_index == MOUSE_BUTTON_LEFT and _drag_moved < 4.0:
					clicked.emit(mb.position)
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_drag_moved += mm.relative.length()
		if locked:
			s_yaw -= mm.relative.x * ROT_SENS
			s_pitch_user = clampf(s_pitch_user - mm.relative.y * ROT_SENS, -89.5, -12.0)
		else:
			yaw -= mm.relative.x * ROT_SENS
			pitch = clampf(pitch - mm.relative.y * ROT_SENS, -89.0, 89.0)


## Point the default orbit at the day side of the selected planet, so a plain
## scroll-in lands somewhere lit.
func face_day_side() -> void:
	var to_sun := universe.planet_pos_s().neg().normalized().to_v3()
	pitch = clampf(rad_to_deg(-asin(to_sun.y)) - 28.0, -80.0, 80.0)
	yaw = rad_to_deg(atan2(to_sun.x, to_sun.z)) + 30.0


## Zoom speed multiplier: the zoom is linear in log(d), which makes the "empty"
## stretches (flying from galactic scale to the star, and from the system to a
## planet that is still a dot) feel like a stall. Speed them up smoothly.
static func zoom_rate_mult(d: float) -> float:
	return 1.0 + 1.8 * _log_bump(d, 3.0e16, 1.0e13) + 1.0 * _log_bump(d, 6.0e10, 3.0e9)


## 1 inside [lo, hi] (log space), soft half-decade edges outside.
static func _log_bump(d: float, hi: float, lo: float) -> float:
	var x := log(d)
	var a := log(lo)
	var b := log(hi)
	return smoothstep(a - 1.15, a + 1.15, x) * (1.0 - smoothstep(b - 1.15, b + 1.15, x))
