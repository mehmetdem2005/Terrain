@tool
extends EditorPlugin
# =====================================================================
#  TERRAIN TOOLS  -  Faz 1A: dokunmatik heightmap sculpt + kaydet + undo
#  Godot editoru (telefon dahil) icinde calisir. Mevcut CDLOD/runtime
#  kodu DEGISMEZ; veri TerrainChunkManager.edit_* API'si uzerinden
#  duzenlenir. Faz 1B: doku boyama (splat), Faz 1C: delik maskesi.
# =====================================================================

var _panel: VBoxContainer
var _active := false
var _mode := 0          # 0 raise 1 lower 2 smooth 3 flatten
var _radius_m := 40.0
var _strength := 0.06   # ham yukseklik / vurus (0..1)
var _status: Label

var _mgr: Node = null
var _stroking := false
var _stroke_idx := PackedInt32Array()
var _stroke_val := PackedFloat32Array()
var _stroke_seen := {}
var _flatten_target := 0.0
var _undo: Array = []          # [{idx:PackedInt32, val:PackedFloat32}]
const UNDO_MAX := 8


func _enter_tree() -> void:
	_build_panel()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_BL, _panel)


func _exit_tree() -> void:
	if _panel:
		remove_control_from_docks(_panel)
		_panel.free()


func _build_panel() -> void:
	_panel = VBoxContainer.new()
	_panel.name = "Terrain"
	var title := Label.new()
	title.text = "TERRAIN SCULPT"
	_panel.add_child(title)

	var en := CheckButton.new()
	en.text = "Sculpt aktif (3D'ye dokun)"
	en.toggled.connect(func(v): _active = v; _refresh_status())
	_panel.add_child(en)

	var mode := OptionButton.new()
	for s in ["Yukselt", "Alcalt", "Yumusat", "Duzlestir"]:
		mode.add_item(s)
	mode.item_selected.connect(func(i): _mode = i)
	_panel.add_child(_row("Mod", mode))

	_panel.add_child(_slider("Yaricap (m)", 2.0, 400.0, _radius_m,
		func(v): _radius_m = v))
	_panel.add_child(_slider("Guc", 0.005, 0.4, _strength,
		func(v): _strength = v))

	var save := Button.new()
	save.text = "KAYDET (height.bin + meta)"
	save.pressed.connect(_on_save)
	_panel.add_child(save)

	var undo := Button.new()
	undo.text = "GERI AL"
	undo.pressed.connect(_on_undo)
	_panel.add_child(undo)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_panel.add_child(_status)
	_refresh_status()


func _row(lbl: String, ctrl: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = lbl
	l.custom_minimum_size.x = 90
	h.add_child(l)
	ctrl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(ctrl)
	return h


func _slider(lbl: String, lo: float, hi: float, val: float, cb: Callable) -> HBoxContainer:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = (hi - lo) / 200.0
	s.value = val
	var vl := Label.new()
	vl.custom_minimum_size.x = 52
	vl.text = "%.3f" % val
	s.value_changed.connect(func(v): vl.text = "%.3f" % v; cb.call(v))
	var h := _row(lbl, s)
	h.add_child(vl)
	return h


func _refresh_status() -> void:
	if _status == null:
		return
	var m := "VAR" if _find_mgr() else "YOK (sahnede TerrainChunkManager?)"
	_status.text = "Durum: %s | Manager: %s\nUndo: %d adim" % [
		("AKTIF" if _active else "kapali"), m, _undo.size()]


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


func _handles(_object) -> bool:
	return _active


func _forward_3d_gui_input(cam: Camera3D, event: InputEvent) -> int:
	if not _active or not _find_mgr():
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not _mgr.edit_ensure():
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	var pos := Vector2.ZERO
	var phase := -1   # 0 press 1 move 2 release
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pos = event.position
		phase = 0 if event.pressed else 2
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		pos = event.position
		phase = 1
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
	if not hit.get("hit", false):
		return EditorPlugin.AFTER_GUI_INPUT_STOP if _stroking else EditorPlugin.AFTER_GUI_INPUT_PASS
	var wp: Vector3 = hit["pos"]

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
	_stroke_idx = PackedInt32Array()
	_stroke_val = PackedFloat32Array()
	_stroke_seen = {}
	var tc: Vector2 = _mgr.edit_world_to_texel(wp.x, wp.z)
	_flatten_target = _mgr.edit_sample_raw(int(tc.x), int(tc.y))


func _dab(wp: Vector3) -> void:
	var hr: int = _mgr.edit_hr()
	var texel_m: float = float(_mgr.world_size) / float(hr - 1)
	var r_tex := _radius_m / texel_m
	var tc: Vector2 = _mgr.edit_world_to_texel(wp.x, wp.z)
	# undo: dab oncesi orijinal degerleri (ilk goruleni) sakla
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


func _end_stroke() -> void:
	_stroking = false
	if _stroke_idx.size() > 0:
		_undo.append({"idx": _stroke_idx, "val": _stroke_val})
		if _undo.size() > UNDO_MAX:
			_undo.pop_front()
	_refresh_status()


func _on_undo() -> void:
	if _undo.is_empty() or not _find_mgr():
		return
	var s: Dictionary = _undo.pop_back()
	_mgr.edit_scatter(s["idx"], s["val"])
	_mgr.edit_refresh_gpu()
	_refresh_status()


func _on_save() -> void:
	if not _find_mgr():
		return
	var ok: bool = _mgr.edit_save()
	if _status:
		_status.text = "KAYDEDILDI" if ok else "KAYIT HATASI (Output'a bak)"
	if ok:
		var fs := get_editor_interface().get_resource_filesystem()
		if fs:
			fs.scan()
