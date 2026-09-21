class_name GalaxyLayer
extends Node3D
## Renders the galaxy: stars, nebula dust and markers for playable systems.
## Everything is a MultiMesh with a GPU billboard shader; after generation the
## CPU only updates a handful of uniforms per frame (anchor, scale, offset).
## Positions are in light years, anchored on the selected star so that the
## precision loss of float32 only affects distant stars (where it is invisible).

const BILLBOARD := preload("res://shaders/billboard_point.gdshader")

var galaxy: GalaxyGenerator.GalaxyData
var stars: MultiMeshInstance3D
var dust: MultiMeshInstance3D
var markers: MultiMeshInstance3D
var materials: Array[ShaderMaterial] = []
var _quad := QuadMesh.new()


func build(g: GalaxyGenerator.GalaxyData) -> void:
	galaxy = g
	for c in get_children():
		c.queue_free()
	materials.clear()
	_quad.size = Vector2.ONE

	var n := g.star_count
	var star_custom := PackedFloat32Array()
	star_custom.resize(n * 4)
	for i in n:
		star_custom[i * 4 + 1] = g.px_sizes[i]
	stars = _make_multimesh(g.positions, g.colors, star_custom, 1.0)
	stars.name = "Stars"

	var dn := g.dust_positions.size()
	var dust_custom := PackedFloat32Array()
	dust_custom.resize(dn * 4)
	for i in dn:
		dust_custom[i * 4] = g.dust_radii[i]
		dust_custom[i * 4 + 1] = 2.0
	dust = _make_multimesh(g.dust_positions, g.dust_colors, dust_custom, 1.0)
	dust.name = "Dust"

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
	markers = _make_multimesh(mpos, mcol, mcustom, 1.0)
	markers.name = "Markers"


func _make_multimesh(pos: PackedVector3Array, col: PackedColorArray, custom: PackedFloat32Array, px_scale: float) -> MultiMeshInstance3D:
	var n := pos.size()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _quad
	mm.instance_count = n
	var buf := PackedFloat32Array()
	buf.resize(n * 20)
	for i in n:
		var o := i * 20
		var p := pos[i]
		var c := col[i]
		buf[o] = 1.0
		buf[o + 3] = p.x
		buf[o + 5] = 1.0
		buf[o + 7] = p.y
		buf[o + 10] = 1.0
		buf[o + 11] = p.z
		buf[o + 12] = c.r
		buf[o + 13] = c.g
		buf[o + 14] = c.b
		buf[o + 15] = c.a
		buf[o + 16] = custom[i * 4]
		buf[o + 17] = custom[i * 4 + 1]
		buf[o + 18] = custom[i * 4 + 2]
		buf[o + 19] = custom[i * 4 + 3]
	mm.buffer = buf
	var mat := ShaderMaterial.new()
	mat.shader = BILLBOARD
	mat.set_shader_parameter("manual_transform", true)
	mat.set_shader_parameter("px_scale", px_scale)
	materials.append(mat)
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	mi.custom_aabb = AABB(Vector3(-1.0e7, -1.0e7, -1.0e7), Vector3(2.0e7, 2.0e7, 2.0e7))
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


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
	for m in materials:
		m.set_shader_parameter("anchor", anchor)
		m.set_shader_parameter("unit_scale", unit_scale)
		m.set_shader_parameter("offset", offset)
		m.set_shader_parameter("fade", star_fade)
	# Markers are only useful at galactic scale.
	markers.visible = vs.d > 1.0e16
	dust.visible = vs.d > 1.0e14
