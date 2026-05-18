@tool
extends EditorPlugin
# =====================================================================
#  TERRAIN TOOLS
#   Faz 1A: dokunmatik heightmap sculpt + kaydet + undo
#   Faz 1B: doku boyama (SINIRSIZ zemin, indeksli splat) + kaydet + undo
#  Godot editoru (telefon dahil) icinde calisir. Mevcut CDLOD/runtime
#  kodu DEGISMEZ; veri TerrainChunkManager.edit_* API'si uzerinden
#  duzenlenir.
# =====================================================================

var _panel: VBoxContainer
var _active := false
var _tool := 0          # 0 Heykel (sculpt)  1 Boya (paint)  2 Delik (hole)
var _mode := 0          # sculpt: 0 raise 1 lower 2 smooth 3 flatten
var _layer := 0         # boya: secili zemin indeksi
var _hole_open := true  # delik: true=ac (gorunmez)  false=kapat
var _radius_m := 40.0
var _strength := 0.06   # sculpt: ham yukseklik / vurus
var _opacity := 0.5     # boya: agirlik / vurus (0..1)
var _status: Label
var _layer_opt: OptionButton

var _mgr: Node = null
var _stroking := false
var _stroke_seen := {}
var _flatten_target := 0.0
# sculpt undo: idx(int key) + val(float)
var _stroke_idx := PackedInt32Array()
var _stroke_val := PackedFloat32Array()
# boya undo: key + paketli (idx,w) iki int
var _p_key := PackedInt32Array()
var _p_ip := PackedInt32Array()
var _p_wp := PackedInt32Array()
# delik undo: key + orijinal R8 deger (0..1)
var _o_key := PackedInt32Array()
var _o_val := PackedFloat32Array()
var _undo: Array = []          # [{kind, ...}]
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
	title.text = "TERRAIN TOOLS"
	_panel.add_child(title)

	var en := CheckButton.new()
	en.text = "Aktif (3D'ye dokun)"
	en.toggled.connect(func(v): _active = v; _refresh_status())
	_panel.add_child(en)

	var tool := OptionButton.new()
	for s in ["Heykel (sculpt)", "Boya (doku)", "Delik (hole)"]:
		tool.add_item(s)
	tool.item_selected.connect(_on_tool_changed)
	_panel.add_child(_row("Arac", tool))

	var mode := OptionButton.new()
	for s in ["Yukselt", "Alcalt", "Yumusat", "Duzlestir"]:
		mode.add_item(s)
	mode.item_selected.connect(func(i): _mode = i)
	_panel.add_child(_row("Heykel modu", mode))

	var hmode := OptionButton.new()
	for s in ["Delik ac", "Delik kapat"]:
		hmode.add_item(s)
	hmode.item_selected.connect(func(i): _hole_open = (i == 0))
	_panel.add_child(_row("Delik modu", hmode))

	_layer_opt = OptionButton.new()
	_layer_opt.item_selected.connect(func(i): _layer = i)
	_panel.add_child(_row("Zemin", _layer_opt))
	var lref := Button.new()
	lref.text = "Zemin listesini tazele"
	lref.pressed.connect(_reload_layers)
	_panel.add_child(lref)

	_panel.add_child(_slider("Yaricap (m)", 2.0, 400.0, _radius_m,
		func(v): _radius_m = v))
	_panel.add_child(_slider("Heykel guc", 0.005, 0.4, _strength,
		func(v): _strength = v))
	_panel.add_child(_slider("Boya yogunluk", 0.02, 1.0, _opacity,
		func(v): _opacity = v))

	var save := Button.new()
	save.text = "ARAZIYI KAYDET (height + meta)"
	save.pressed.connect(_on_save)
	_panel.add_child(save)

	var psave := Button.new()
	psave.text = "BOYAYI KAYDET (splat)"
	psave.pressed.connect(_on_save_splat)
	_panel.add_child(psave)

	var hsave := Button.new()
	hsave.text = "DELIGI KAYDET (holes)"
	hsave.pressed.connect(_on_save_hole)
	_panel.add_child(hsave)

	var undo := Button.new()
	undo.text = "GERI AL"
	undo.pressed.connect(_on_undo)
	_panel.add_child(undo)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_panel.add_child(_status)
	_refresh_status()


func _on_tool_changed(i: int) -> void:
	_tool = i
	if _tool == 1:
		_reload_layers()
	_refresh_status()


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
	var tl := "Heykel"
	if _tool == 1:
		tl = "Boya z%d" % _layer
	elif _tool == 2:
		tl = "Delik " + ("ac" if _hole_open else "kapat")
	_status.text = "Durum: %s | %s | Manager: %s\nUndo: %d adim" % [
		("AKTIF" if _active else "kapali"), tl, m, _undo.size()]


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
	if _tool == 1 and not _mgr.edit_splat_ensure():
		if _status:
			_status.text = "Boya icin Inspector'a 'layer_albedo' dokulari ekle."
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if _tool == 2 and not _mgr.edit_hole_ensure():
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
	if not _find_mgr():
		return
	if not _mgr.has_method("edit_save_splat"):
		return
	var ok: bool = _mgr.edit_save_splat()
	if _status:
		_status.text = "BOYA KAYDEDILDI" if ok else "BOYA KAYIT HATASI (Output)"
	if ok:
		_rescan_fs()


func _on_save_hole() -> void:
	if not _find_mgr():
		return
	if not _mgr.has_method("edit_save_hole"):
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
