class_name Hud
extends CanvasLayer
## Minimal debug HUD: phase, scale, selection, FPS, quality, network, controls.

var info: Label
var hint: Label
var _acc := 0.0
var extra := ""   # extra info line set by main (e.g. star counts)
var peer_labels := []   # [{p: Vector2 (screen), text, color}] - names next to other players
signal join_requested(ip: String)
var _join_panel: PanelContainer
var _join_edit: LineEdit
var _labels: Control


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
		+ "W/S/A/D: pływanie komórką   |   F1/F2/F3: jakość LOW/MED/HIGH   |   F5: host LAN, F6: dołącz (IP), F7: leć do gracza   |   F9: nowa galaktyka   |   F11: pełny ekran"
	add_child(hint)
	_build_overlays()


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
	var g := universe.galaxy
	var si := universe.selected_star
	lines.append("Galaktyka %s (%s, promień %d tys. ly)   |   Gwiazda: %s, klasa %s, %d K, wiek %.1f mld lat   |   Planeta: %s" % [
		g.name, g.morph_name, roundi(g.radius_ly / 1000.0), universe.star_name(), g.star_class_letter(si),
		roundi(g.temps[si]), g.ages[si], universe.planet().name])
	if vs.frame >= Universe.Frame.P:
		var alt := vs.altitude
		if vs.underwater:
			lines.append("Głębokość: %s" % fmt_distance(-alt))
		else:
			lines.append("Wysokość: %s" % fmt_distance(alt))
	if extra != "":
		lines.append(extra)
	if vs.cell_mode:
		lines.append("Sterowanie komórką aktywne — W/S/A/D")
	lines.append("FPS: %d   |   GPU: %s   |   jakość: %s" % [Engine.get_frames_per_second(), GraphicsSettings.adapter_name(), GraphicsSettings.quality_name()])
	var net: String = NetManager.mode
	if NetManager.mode != "offline":
		net += " (%d graczy)" % (NetManager.peer_count() + 1)
	if NetManager.hosts.size() > 0 and NetManager.mode == "offline":
		net += "   hosty w LAN: %s (F6)" % ", ".join(NetManager.hosts.keys())
	lines.append("Sieć: %s   |   ja: %s   |   seed: %d%s" % [net, NetManager.player_name, universe.galaxy.seed, _version_text()])
	for id in NetManager.peers:
		var p: Dictionary = NetManager.peers[id]
		var where := "%s, %s" % [str(p.get("star_name", "?")), fmt_distance(float(p.get("d", 0.0)))]
		if int(p.get("seed", 0)) != universe.galaxy.seed:
			where = "w innej galaktyce"
		lines.append("   • %s – %s (%s)" % [str(p.get("name", "?")), where, str(p.get("phase", ""))])
	info.text = "\n".join(lines)


func _build_overlays() -> void:
	_labels = Control.new()
	_labels.set_anchors_preset(Control.PRESET_FULL_RECT)
	_labels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_labels.draw.connect(_draw_labels)
	add_child(_labels)

	_join_panel = PanelContainer.new()
	_join_panel.set_anchors_preset(Control.PRESET_CENTER)
	_join_panel.custom_minimum_size = Vector2(420, 0)
	_join_panel.position = Vector2(-210, -60)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = "Dołącz do gry w LAN – adres IP hosta:"
	box.add_child(title)
	_join_edit = LineEdit.new()
	_join_edit.placeholder_text = "np. 192.168.1.20"
	_join_edit.text_submitted.connect(_on_join_submitted)
	box.add_child(_join_edit)
	var help := Label.new()
	help.text = "Enter – połącz   |   Esc – anuluj\nHost: F5 na drugim komputerze (port UDP 27015)"
	help.add_theme_font_size_override("font_size", 12)
	help.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9))
	box.add_child(help)
	_join_panel.add_child(box)
	_join_panel.hide()
	add_child(_join_panel)


func show_join(default_ip: String) -> void:
	_join_panel.show()
	_join_edit.text = default_ip
	_join_edit.grab_focus()
	_join_edit.select_all()


func is_typing() -> bool:
	return _join_panel != null and _join_panel.visible


func _on_join_submitted(text: String) -> void:
	_join_panel.hide()
	var ip := text.strip_edges()
	if ip != "":
		join_requested.emit(ip)


func _input(event: InputEvent) -> void:
	if is_typing() and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_join_panel.hide()
		get_viewport().set_input_as_handled()


func set_peer_labels(labels: Array) -> void:
	peer_labels = labels
	_labels.queue_redraw()


func _draw_labels() -> void:
	var font := ThemeDB.fallback_font
	for e in peer_labels:
		var p: Vector2 = e["p"] + Vector2(16, -12)
		_labels.draw_string(font, p + Vector2(1, 1), e["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0, 0, 0, 0.8))
		_labels.draw_string(font, p, e["text"], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, e["color"])


func _version_text() -> String:
	var s := "   |   v" + Updater.version
	if Updater.available:
		s += "   |   dostępna wersja %s – F12 aktualizuj" % Updater.latest
	if Updater.status != "":
		s += " (" + Updater.status + ")"
	return s
