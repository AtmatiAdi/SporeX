class_name PlanetGenerator
extends RefCounted
## Builds an equirectangular height map for a planet by sampling 3D noise on
## the unit sphere (no pole pinching). Runs on a worker thread in two passes
## (coarse, then fine) so the planet shows up immediately and refines itself —
## streaming instead of loading screens.

const COARSE := Vector2i(256, 128)
const FINE := Vector2i(1024, 512)


class HeightMapResult:
	var seed: int
	var size: Vector2i
	var data: PackedFloat32Array  # row-major, one float per texel
	var image: Image

	func sample_dir(dir: Vector3) -> float:
		var u := atan2(dir.x, dir.z) / TAU + 0.5
		var v := 0.5 - asin(clampf(dir.y, -1.0, 1.0)) / PI
		var x := posmod(int(floor(u * size.x)), size.x)
		var y := clampi(int(floor(v * size.y)), 0, size.y - 1)
		return data[y * size.x + x]

	func texel_dir(x: int, y: int) -> Vector3:
		var u := (x + 0.5) / float(size.x)
		var v := (y + 0.5) / float(size.y)
		var lon := (u - 0.5) * TAU
		var lat := (0.5 - v) * PI
		var cl := cos(lat)
		return Vector3(sin(lon) * cl, sin(lat), cos(lon) * cl)




static func make_noise(seed: int, freq: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = octaves
	n.fractal_lacunarity = 2.1
	n.fractal_gain = 0.5
	return n


static func build_height_map(seed: int, size: Vector2i) -> HeightMapResult:
	var continents := make_noise(Seeds.mix(seed, 1), 1.1, 4)
	var detail := make_noise(Seeds.mix(seed, 2), 3.5, 5)
	var ridges := make_noise(Seeds.mix(seed, 3), 2.2, 3)
	var res := HeightMapResult.new()
	res.seed = seed
	res.size = size
	res.data.resize(size.x * size.y)
	var w := size.x
	var h := size.y
	for y in h:
		var v := (y + 0.5) / float(h)
		var lat := (0.5 - v) * PI
		var cl := cos(lat)
		var sl := sin(lat)
		var row := y * w
		for x in w:
			var lon := ((x + 0.5) / float(w) - 0.5) * TAU
			var dx := sin(lon) * cl
			var dz := cos(lon) * cl
			var c := continents.get_noise_3d(dx, sl, dz)
			var d := detail.get_noise_3d(dx, sl, dz)
			var r := 1.0 - absf(ridges.get_noise_3d(dx, sl, dz))
			var height := 0.5 + 0.34 * c + 0.14 * d + 0.12 * (r - 0.6) * maxf(c, 0.0)
			res.data[row + x] = clampf(height, 0.0, 1.0)
	res.image = Image.create_from_data(w, h, false, Image.FORMAT_RF, res.data.to_byte_array())
	return res
