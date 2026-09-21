class_name Hud
extends CanvasLayer
## Minimal debug HUD: phase, scale, selection, FPS, quality, network, controls.

var info: Label
var hint: Label
var _acc := 0.0


func _ready() -> void:
	info = Label.new()
	info.position = Vector2(16, 12)
	info.add_theme_font_size_override("font_size", 16)
	info.add_theme_color_override("font_color", Color(0.85, 0.95, 1.0))
	info.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	info.add_theme_constant_override("shadow_offset_x", 1)
	info.add_theme_constant_override("shadow_offset_y", 1)
	add_child(info)

	hint = Label.new()
	hint.anchor_top = 1.0
	hint.anchor_bottom = 1.0
	hint.anchor_right = 1.0
	hint.offset_top = -74
	hint.offset_left = 16
	hint.offset_right = -16
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9, 0.9))
	hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	hint.add_theme_constant_override("shadow_offset_x", 1)
	hint.add_theme_constant_override("shadow_offset_y", 1)
	hint.text = "LPM: zaznacz gwiazdę / planetę   |   Scroll: zoom (Shift = szybciej, PgUp/PgDn ciągle)   |   Przeciągnij myszą: obrót\n" \
		+ "W/S/A/D: pływanie komórką (po dojściu do skali komórki)   |   F1/F2/F3: jakość LOW/MED/HIGH   |   F5: host LAN, F6: dołącz   |   F11: pełny ekran"
	add_child(hint)


static func fmt_distance(m: float) -> String:
	if m >= 9.4607e15 * 0.1:
		return "%.2f ly" % (m / 9.4607e15)
	if m >= 1.0e9:
		return "%.3f AU" % (m / 1.496e11) if m >= 1.496e10 else "%.0f tys. km" % (m / 1.0e6)
	if m >= 1000.0:
		return "%.1f km" % (m / 1000.0)
	if m >= 1.0:
		return "%.2f m" % m
	if m >= 1.0e-3:
		return "%.2f mm" % (m * 1000.0)
	return "%.0f µm" % (m * 1.0e6)


func update_info(vs: ScaleCamera.ViewState, universe: Universe, dt: float) -> void:
	_acc += dt
	if _acc < 0.1:
		return
	_acc = 0.0
	var lines := PackedStringArray()
	lines.append("[%s]   odległość kamery: %s   (1 jednostka = %s)" % [vs.phase, fmt_distance(vs.d), fmt_distance(vs.u)])
	lines.append("Galaktyka %s   |   Gwiazda: %s   |   Planeta: %s" % [universe.galaxy.name, universe.star_name(), universe.planet().name])
	if vs.frame >= Universe.Frame.P:
		var alt := vs.altitude
		if vs.underwater:
			lines.append("Głębokość: %s" % fmt_distance(-alt))
		else:
			lines.append("Wysokość: %s" % fmt_distance(alt))
	if vs.cell_mode:
		lines.append("Sterowanie komórką aktywne — W/S/A/D")
	lines.append("FPS: %d   |   GPU: %s   |   jakość: %s" % [Engine.get_frames_per_second(), GraphicsSettings.adapter_name(), GraphicsSettings.quality_name()])
	var net: String = NetManager.mode
	if NetManager.mode != "offline":
		net += " (%d peers)" % NetManager.peer_count()
	if NetManager.hosts.size() > 0:
		net += "   hosty LAN: %s" % ", ".join(NetManager.hosts.keys())
	lines.append("Sieć: %s   |   seed: %d" % [net, universe.galaxy.seed])
	info.text = "\n".join(lines)
