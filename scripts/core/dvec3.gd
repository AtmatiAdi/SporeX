class_name DVec3
extends RefCounted
## Double-precision 3D vector.
## GDScript `float` is a 64-bit double, while Vector3 is 32-bit. Everything that
## spans the galaxy -> cell scale range (about 25 orders of magnitude) is computed
## with DVec3 and only converted to Vector3 at the very end, relative to the camera
## focus, so the renderer never sees large float values.

var x: float
var y: float
var z: float


func _init(px: float = 0.0, py: float = 0.0, pz: float = 0.0) -> void:
	x = px
	y = py
	z = pz


static func zero() -> DVec3:
	return DVec3.new()


static func from_v3(v: Vector3) -> DVec3:
	return DVec3.new(v.x, v.y, v.z)


func to_v3() -> Vector3:
	return Vector3(x, y, z)


func dup() -> DVec3:
	return DVec3.new(x, y, z)


func add(o: DVec3) -> DVec3:
	return DVec3.new(x + o.x, y + o.y, z + o.z)


func sub(o: DVec3) -> DVec3:
	return DVec3.new(x - o.x, y - o.y, z - o.z)


func mul(s: float) -> DVec3:
	return DVec3.new(x * s, y * s, z * s)


func neg() -> DVec3:
	return DVec3.new(-x, -y, -z)


func dot(o: DVec3) -> float:
	return x * o.x + y * o.y + z * o.z


func length() -> float:
	return sqrt(x * x + y * y + z * z)


func normalized() -> DVec3:
	var l := length()
	if l <= 0.0:
		return DVec3.new()
	return DVec3.new(x / l, y / l, z / l)


func lerp_to(o: DVec3, t: float) -> DVec3:
	return DVec3.new(x + (o.x - x) * t, y + (o.y - y) * t, z + (o.z - z) * t)


## Apply a (float) rotation basis: result = b.x * x + b.y * y + b.z * z.
func xform(b: Basis) -> DVec3:
	return DVec3.new(
		b.x.x * x + b.y.x * y + b.z.x * z,
		b.x.y * x + b.y.y * y + b.z.y * z,
		b.x.z * x + b.y.z * y + b.z.z * z)


## Rotate around the Y axis using double precision trig.
func rotated_y(angle: float) -> DVec3:
	var c := cos(angle)
	var s := sin(angle)
	return DVec3.new(x * c + z * s, y, -x * s + z * c)


func _to_string() -> String:
	return "DVec3(%g, %g, %g)" % [x, y, z]
