@tool
extends EditorPlugin
# =====================================================================
#  TERRAIN TOOLS
#   Faz 1A: dokunmatik heightmap sculpt + kaydet + undo
#   Faz 1B: doku boyama (SINIRSIZ zemin, indeksli splat) + kaydet + undo
#   Faz 1C: delik (hole) maskesi + kaydet + undo
#   Faz 1D: Terrain3D benzeri UX -> 3B gorunum kenarinda buyuk dokunmatik
#           arac cubugu + alt bar + EKRANDA FIRCA HALKASI + giris duzeltme
#  Godot editoru (telefon dahil) icinde calisir. Mevcut CDLOD/runtime
#  kodu DEGISMEZ; veri TerrainChunkManager.edit_* API'si uzerinden
#  duzenlenir (yalniz editor-only).
# =====================================================================

const MIN_BTN := Vector2(118, 46)        # parmak-dostu minimum
const RING_COL := Color(1.0, 0.85, 0.15, 0.95)
const RING_BG := Color(0.0, 0.0, 0.0, 0.55)

var _toolbar: VBoxContainer              # 3B sol kenar
var _bottombar: PanelContainer           # 3B alt
var _active := false
var _tool := 0          # 0 Heykel  1 Boya  2 Delik
var _mode := 0          # sculpt: 0 raise 1 lower 2 smooth 3 flatten
var _layer := 0         # boya: secili zemin indeksi
var _hole_open := true  # delik: true=ac  false=kapat
var _radius_m := 40.0
var _strength := 0.06
var _opacity := 0.5
var _status: Label
var _layer_opt: OptionButton
var _mode_row: Control
var _hole_row: Control
var _layer_row: Control
var _strength_row: Control
var _opacity_row: Control
var _open_btn: Button
var _tool_btns: Array[Button] = []

var _mgr: Node = null
var _stroking := false
var _stroke_seen := {}
var _flatten_target := 0.0
var _stroke_idx := PackedInt32Array()
var _stroke_val := PackedFloat32Array()
var _p_key := PackedInt32Array()
var _p_ip := PackedInt32Array()
var _p_wp := PackedInt32Array()
var _o_key := PackedInt32Array()
var _o_val := PackedFloat32Array()
var _undo: Array = []
const UNDO_MAX := 8

# firca halkasi (overlay)
var _cam: Camera3D = null
var _brush_world := Vector3.ZERO
var _brush_valid := false


func _enter_tree() -> void:
	_build_toolbar()
	_build_bottombar()
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, _toolbar)
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_BOTTOM, _bottombar)
	_sync_tool_ui()
	_refresh_status()


func _exit_tree() -> void:
	if _toolbar:
		remove_control_from_container(
			EditorPlugin.CONTAINER_SPATIAL_EDITOR_SIDE_LEFT, _toolbar)
		_toolbar.free()
	if _bottombar:
		remove_control_from_container(
			EditorPlugin.CONTAINER_SPATIAL_EDITOR_BOTTOM, _bottombar)
		_bottombar.free()


# === UI: SOL ARAC CUBUGU (Terrain3D deseni) =========================
func _big(b: Button) -> Button:
	b.custom_minimum_size = MIN_BTN
	b.add_theme_font_size_override("font_size", 18)
	b.focus_mode = Control.FOCUS_NONE
	return b


func _build_toolbar() -> void:
	_toolbar = VBoxContainer.new()
	_toolbar.name = "TerrainTools"
	_toolbar.add_theme_constant_override("separation", 6)

	var t := Label.new()
	t.text = "ARAZI"
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toolbar.add_child(t)

	var en := _big(Button.new())
	en.text = "● AKTIF"
	en.toggle_mode = true
	en.toggled.connect(_on_active_toggled)
	_toolbar.add_child(en)

	_toolbar.add_child(HSeparator.new())

	var names := ["⛰ Heykel", "🖌 Boya", "⌬ Delik"]
	for i in names.size():
		var b := _big(Button.new())
		b.text = names[i]
		b.toggle_mode = true
		b.pressed.connect(_on_tool_btn.bind(i))
		_tool_btns.append(b)
		_toolbar.add_child(b)
	_tool_btns[0].button_pressed = true

	_toolbar.add_child(HSeparator.new())

	var u := _big(Button.new())
	u.text = "↶ GERI AL"
	u.pressed.connect(_on_undo)
	_toolbar.add_child(u)

	_open_btn = _big(Button.new())
	_open_btn.text = "SAHNEYI AC"
	_open_btn.pressed.connect(_on_open_scene)
	_toolbar.add_child(_open_btn)


# === UI: ALT BAR (baglama duyarli) ==================================
func _slider_row(lbl: String, lo: float, hi: float, val: float,
		cb: Callable) -> Control:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = lbl
	l.custom_minimum_size.x = 96
	h.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = (hi - lo) / 200.0
	s.value = val
	s.custom_minimum_size = Vector2(220, 40)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(s)
	var vl := Label.new()
	vl.custom_minimum_size.x = 60
	vl.text = "%.3f" % val
	s.value_changed.connect(func(v): vl.text = "%.3f" % v; cb.call(v))
	h.add_child(vl)
	return h


func _opt_row(lbl: String, items: Array, cb: Callable) -> Control:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = lbl
	l.custom_minimum_size.x = 96
	h.add_child(l)
	var o := OptionButton.new()
	for s in items:
		o.add_item(s)
	o.custom_minimum_size = Vector2(170, 42)
	o.item_selected.connect(cb)
	h.add_child(o)
	h.set_meta("opt", o)
	return h


func _build_bottombar() -> void:
	_bottombar = PanelContainer.new()
	_bottombar.name = "TerrainBar"
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_bottombar.add_child(row)

	row.add_child(_slider_row("Yaricap (m)", 2.0, 400.0, _radius_m,
		func(v): _radius_m = v; update_overlays()))

	_strength_row = _slider_row("Heykel guc", 0.005, 0.4, _strength,
		func(v): _strength = v)
	row.add_child(_strength_row)

	_opacity_row = _slider_row("Boya yogun.", 0.02, 1.0, _opacity,
		func(v): _opacity = v)
	row.add_child(_opacity_row)

	_mode_row = _opt_row("Heykel modu",
		["Yukselt", "Alcalt", "Yumusat", "Duzlestir"],
		func(i): _mode = i)
	row.add_child(_mode_row)

	_layer_row = _opt_row("Zemin", ["(zemin yok)"], func(i): _layer = i)
	_layer_opt = _layer_row.get_meta("opt")
	row.add_child(_layer_row)
	var lref := _big(Button.new())
	lref.text = "Zemin↻"
	lref.custom_minimum_size = Vector2(78, 42)
	lref.pressed.connect(_reload_layers)
	row.add_child(lref)

	_hole_row = _opt_row("Delik",
		["Delik ac", "Delik kapat"],
		func(i): _hole_open = (i == 0); update_overlays())
	row.add_child(_hole_row)

	row.add_child(VSeparator.new())

	var sv := _big(Button.new())
	sv.text = "ARAZIYI\nKAYDET"
	sv.pressed.connect(_on_save)
	row.add_child(sv)
	var sp := _big(Button.new())
	sp.text = "BOYAYI\nKAYDET"
	sp.pressed.connect(_on_save_splat)
	row.add_child(sp)
	var sh := _big(Button.new())
	sh.text = "DELIGI\nKAYDET"
	sh.pressed.connect(_on_save_hole)
	row.add_child(sh)

	row.add_child(VSeparator.new())
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status.custom_minimum_size.x = 260
	row.add_child(_status)


# === ARAC / DURUM ===================================================
func _on_active_toggled(v: bool) -> void:
	_active = v
	if _active:
		if _find_mgr():
			# Otomatik sec -> spatial editor girisi/overlay bize forward eder
			var sel := get_editor_interface().get_selection()
			sel.clear()
			sel.add_node(_mgr)
		else:
			_active = false
			for b in _toolbar.get_children():
				if b is Button and b.toggle_mode and b.text == "● AKTIF":
					b.set_pressed_no_signal(false)
	_brush_valid = false
	update_overlays()
	_refresh_status()


func _on_tool_btn(i: int) -> void:
	_tool = i
	for k in _tool_btns.size():
		_tool_btns[k].set_pressed_no_signal(k == i)
	if _tool == 1:
		_reload_layers()
	_sync_tool_ui()
	update_overlays()
	_refresh_status()


func _sync_tool_ui() -> void:
	if _strength_row == null:
		return
	_strength_row.visible = _tool == 0
	_mode_row.visible = _tool == 0
	_opacity_row.visible = _tool == 1
	_layer_row.visible = _tool == 1
	_hole_row.visible = _tool == 2


func _reload_layers() -> void:
	if _layer_opt == null or not _find_mgr():
		return
	if not _mgr.has_method("edit_layer_count"):
		return
	_layer_opt.clear()
	var n: int = _mgr.edit_layer_count()
	if n <= 0:
		_layer_opt.add_item("(zemin yok - Inspector'a doku ekle)")
	else:
		for i in n:
			_layer_opt.add_item("%d - %s" % [i, _mgr.edit_layer_name(i)])
	_layer = clampi(_layer, 0, maxi(n - 1, 0))
	if _layer < _layer_opt.item_count:
		_layer_opt.select(_layer)
	_refresh_status()


func _refresh_status() -> void:
	if _status == null:
		return
	var has := _find_mgr()
	var m := "VAR" if has else "YOK"
	var tl := "Heykel"
	if _tool == 1:
		tl = "Boya z%d" % _layer
	elif _tool == 2:
		tl = "Delik " + ("ac" if _hole_open else "kapat")
	var hint := ""
	if not has:
		hint = "\nSahneyi ac: scenes/main.tscn + 3B sekmesi"
	elif not _active:
		hint = "\n'● AKTIF'i ac, sonra 3B'ye dokun"
	_status.text = "Durum: %s | %s | Manager: %s | Undo: %d%s" % [
		("AKTIF" if _active else "kapali"), tl, m, _undo.size(), hint]
	if _open_btn:
		_open_btn.visible = not has


func _on_open_scene() -> void:
	var p := str(ProjectSettings.get_setting(
		"application/run/main_scene", "res://scenes/main.tscn"))
	get_editor_interface().open_scene_from_path(p)


func _find_mgr() -> bool:
	if _mgr != null and is_instance_valid(_mgr):
		return true
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return false
	_mgr = _scan(root)
	return _mgr != null


func _scan(n: Node) -> Node:
	if n.has_method("edit_apply_dab"):
		return n
	for c in n.get_children():
		var r := _scan(c)
		if r != null:
			return r
	return null


# === FIRCA HALKASI (overlay) =======================================
func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if not _active or not _brush_valid or _cam == null:
		return
	if _cam.is_position_behind(_brush_world):
		return
	var c := _cam.unproject_position(_brush_world)
	var e := _cam.unproject_position(
		_brush_world + _cam.global_transform.basis.x * _radius_m)
	var px: float = clampf(c.distance_to(e), 4.0, 4000.0)
	overlay.draw_arc(c, px, 0.0, TAU, 64, RING_BG, 5.0, true)
	overlay.draw_arc(c, px, 0.0, TAU, 64, RING_COL, 2.0, true)
	overlay.draw_circle(c, 3.0, RING_COL)


# === GIRIS ==========================================================
func _handles(object) -> bool:
	return _active and object != null \
		and object.has_method("edit_apply_dab")


func _forward_3d_gui_input(cam: Camera3D, event: InputEvent) -> int:
	_cam = cam
	if not _active or not _find_mgr() or not _mgr.edit_ensure():
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	var pos := Vector2.ZERO
	var phase := -1   # -1 hover  0 press  1 move  2 release
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
		phase = 0 if event.pressed else 2
	elif event is InputEventMouseMotion:
		pos = event.position
		phase = 1 if (event.button_mask & MOUSE_BUTTON_MASK_LEFT) else -1
	elif event is InputEventScreenTouch:
		pos = event.position
		phase = 0 if event.pressed else 2
	elif event is InputEventScreenDrag:
		pos = event.position
		phase = 1
	else:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	var origin := cam.project_ray_origin(pos)
	var dir := cam.project_ray_normal(pos)
	var hit: Dictionary = _mgr.edit_raycast(origin, dir)
	_brush_valid = hit.get("hit", false)
	if _brush_valid:
		_brush_world = hit["pos"]
	update_overlays()

	if not _brush_valid:
		return EditorPlugin.AFTER_GUI_INPUT_STOP if _stroking \
			else EditorPlugin.AFTER_GUI_INPUT_PASS
	if phase == -1:
		return EditorPlugin.AFTER_GUI_INPUT_PASS   # sadece halka takip
	# araca gore hazirlik (ensure)
	if _tool == 1 and not _mgr.edit_splat_ensure():
		if _status:
			_status.text = "Boya icin Inspector'a 'layer_albedo' dokulari ekle."
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if _tool == 2 and not _mgr.edit_hole_ensure():
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	var wp: Vector3 = _brush_world
	if phase == 0:
		_begin_stroke(wp)
		_dab(wp)
	elif phase == 1 and _stroking:
		_dab(wp)
	elif phase == 2 and _stroking:
		_end_stroke()
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _begin_stroke(wp: Vector3) -> void:
	_stroking = true
	_stroke_seen = {}
	if _tool == 0:
		_stroke_idx = PackedInt32Array()
		_stroke_val = PackedFloat32Array()
		var tc: Vector2 = _mgr.edit_world_to_texel(wp.x, wp.z)
		_flatten_target = _mgr.edit_sample_raw(int(tc.x), int(tc.y))
	elif _tool == 1:
		_p_key = PackedInt32Array()
		_p_ip = PackedInt32Array()
		_p_wp = PackedInt32Array()
	else:
		_o_key = PackedInt32Array()
		_o_val = PackedFloat32Array()


func _dab(wp: Vector3) -> void:
	if _tool == 0:
		_dab_sculpt(wp)
	elif _tool == 1:
		_dab_paint(wp)
	else:
		_dab_hole(wp)


func _dab_sculpt(wp: Vector3) -> void:
	var hr: int = _mgr.edit_hr()
	var texel_m: float = float(_mgr.world_size) / float(hr - 1)
	var r_tex := _radius_m / texel_m
	var tc: Vector2 = _mgr.edit_world_to_texel(wp.x, wp.z)
	var ri := int(ceil(r_tex)) + 1
	var x0 := clampi(int(tc.x) - ri, 0, hr - 1)
	var y0 := clampi(int(tc.y) - ri, 0, hr - 1)
	var x1 := clampi(int(tc.x) + ri, 0, hr - 1)
	var y1 := clampi(int(tc.y) + ri, 0, hr - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var key := y * hr + x
			if not _stroke_seen.has(key):
				_stroke_seen[key] = true
				_stroke_idx.append(key)
				_stroke_val.append(_mgr.edit_sample_raw(x, y))
	_mgr.edit_apply_dab(tc.x, tc.y, r_tex, _strength, _mode, _flatten_target)
	_mgr.edit_refresh_gpu()


func _dab_paint(wp: Vector3) -> void:
	var s: int = _mgr.edit_splat_size()
	if s <= 0:
		return
	var px_m: float = float(_mgr.world_size) / float(s - 1)
	var r_px := _radius_m / px_m
	var pc: Vector2 = _mgr.edit_splat_world_to_px(wp.x, wp.z)
	var ri := int(ceil(r_px)) + 1
	var x0 := clampi(int(pc.x) - ri, 0, s - 1)
	var y0 := clampi(int(pc.y) - ri, 0, s - 1)
	var x1 := clampi(int(pc.x) + ri, 0, s - 1)
	var y1 := clampi(int(pc.y) + ri, 0, s - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var key := y * s + x
			if not _stroke_seen.has(key):
				_stroke_seen[key] = true
				var pk: Vector2i = _mgr.edit_splat_pack(x, y)
				_p_key.append(key)
				_p_ip.append(pk.x)
				_p_wp.append(pk.y)
	_mgr.edit_apply_dab_splat(pc.x, pc.y, r_px, _opacity, _layer)
	_mgr.edit_splat_refresh_gpu()


func _dab_hole(wp: Vector3) -> void:
	var s: int = _mgr.edit_hole_size()
	if s <= 0:
		return
	var px_m: float = float(_mgr.world_size) / float(s - 1)
	var r_px := _radius_m / px_m
	var pc: Vector2 = _mgr.edit_hole_world_to_px(wp.x, wp.z)
	var ri := int(ceil(r_px)) + 1
	var x0 := clampi(int(pc.x) - ri, 0, s - 1)
	var y0 := clampi(int(pc.y) - ri, 0, s - 1)
	var x1 := clampi(int(pc.x) + ri, 0, s - 1)
	var y1 := clampi(int(pc.y) + ri, 0, s - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var key := y * s + x
			if not _stroke_seen.has(key):
				_stroke_seen[key] = true
				_o_key.append(key)
				_o_val.append(_mgr.edit_hole_get(x, y))
	_mgr.edit_apply_dab_hole(pc.x, pc.y, r_px, _hole_open)
	_mgr.edit_hole_refresh_gpu()


func _end_stroke() -> void:
	_stroking = false
	if _tool == 0:
		if _stroke_idx.size() > 0:
			_undo.append({"kind": "h", "idx": _stroke_idx, "val": _stroke_val})
	elif _tool == 1:
		if _p_key.size() > 0:
			_undo.append({"kind": "s", "key": _p_key,
				"ip": _p_ip, "wp": _p_wp})
	else:
		if _o_key.size() > 0:
			_undo.append({"kind": "o", "key": _o_key, "val": _o_val})
	if _undo.size() > UNDO_MAX:
		_undo.pop_front()
	_refresh_status()


func _on_undo() -> void:
	if _undo.is_empty() or not _find_mgr():
		return
	var s: Dictionary = _undo.pop_back()
	if s["kind"] == "h":
		_mgr.edit_scatter(s["idx"], s["val"])
		_mgr.edit_refresh_gpu()
	elif s["kind"] == "o":
		_mgr.edit_hole_scatter(s["key"], s["val"])
		_mgr.edit_hole_refresh_gpu()
	else:
		var sz: int = _mgr.edit_splat_size()
		var k: PackedInt32Array = s["key"]
		var ip: PackedInt32Array = s["ip"]
		var wp: PackedInt32Array = s["wp"]
		for i in k.size():
			var key := k[i]
			@warning_ignore("integer_division")
			var y := key / sz
			var x := key % sz
			_mgr.edit_splat_set_packed(x, y, ip[i], wp[i])
		_mgr.edit_splat_refresh_gpu()
	_refresh_status()


func _on_save() -> void:
	if not _find_mgr():
		return
	var ok: bool = _mgr.edit_save()
	if _status:
		_status.text = "ARAZI KAYDEDILDI" if ok else "KAYIT HATASI (Output)"
	if ok:
		_rescan_fs()


func _on_save_splat() -> void:
	if not _find_mgr() or not _mgr.has_method("edit_save_splat"):
		return
	var ok: bool = _mgr.edit_save_splat()
	if _status:
		_status.text = "BOYA KAYDEDILDI" if ok else "BOYA KAYIT HATASI (Output)"
	if ok:
		_rescan_fs()


func _on_save_hole() -> void:
	if not _find_mgr() or not _mgr.has_method("edit_save_hole"):
		return
	var ok: bool = _mgr.edit_hole_ensure() and _mgr.edit_save_hole()
	if _status:
		_status.text = "DELIK KAYDEDILDI" if ok else "DELIK KAYIT HATASI (Output)"
	if ok:
		_rescan_fs()


func _rescan_fs() -> void:
	var fs := get_editor_interface().get_resource_filesystem()
	if fs:
		fs.scan()
